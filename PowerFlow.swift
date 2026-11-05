// PowerFlow — live view of where your MacBook's power goes.
// Reads AppleSmartBattery telemetry from the IORegistry (no root needed).
import SwiftUI
import Charts
import IOKit

// MARK: - Model

struct PortDevice: Identifiable, Hashable {
    let id: Int          // port index
    let watts: Double
    let volts: Double
    let amps: Double
    let vendorID: Int
    let deviceSoC: Int?  // the attached device's own battery %, if it reports one
    var label: String {
        let vendor = vendorID == 1452 ? "Apple device" : (vendorID == 0 ? "USB device" : "Device")
        return "\(vendor) · port \(id)"
    }
}

struct PowerSample: Identifiable {
    let id = UUID()
    let time: Date
    let adapterConnected: Bool
    let adapterRatedW: Double
    let adapterVolts: Double
    let systemInW: Double        // power actually entering the Mac from the adapter
    let adapterLossW: Double     // Apple's estimate of adapter conversion loss
    let batteryW: Double         // + charging, - discharging
    let systemLoadW: Double      // everything except battery (Mac + USB out)
    let devices: [PortDevice]
    let percent: Int
    let isCharging: Bool
    let notChargingReason: Int
    let tempC: Double
    let minutesRemaining: Int?

    var devicesW: Double { devices.reduce(0) { $0 + $1.watts } }
    var macW: Double { max(0, systemLoadW - devicesW) }
    var batteryInW: Double { max(0, batteryW) }
    var batteryOutW: Double { max(0, -batteryW) }
}

enum BatteryReader {
    static func read() -> PowerSample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func i(_ any: Any?) -> Int64 { (any as? NSNumber)?.int64Value ?? 0 }  // int64 handles signed wrap
        let tele = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = d["AdapterDetails"] as? [String: Any] ?? [:]
        let charger = d["ChargerData"] as? [String: Any] ?? [:]
        let external = (d["ExternalConnected"] as? Bool) ?? false

        let amperage = i(d["Amperage"])          // mA, signed
        let voltage = i(d["Voltage"])            // mV
        var batteryW = Double(i(tele["BatteryPower"])) / 1000
        if batteryW == 0 { batteryW = Double(abs(amperage) * voltage) / 1_000_000 }
        batteryW = amperage < 0 ? -abs(batteryW) : abs(batteryW)

        var systemInW = Double(i(tele["SystemPowerIn"])) / 1000
        if !external { systemInW = 0 }
        var loadW = Double(i(tele["SystemLoad"])) / 1000
        if loadW <= 0 { loadW = max(0, systemInW - batteryW) }

        let fed = d["FedDetails"] as? [[String: Any]] ?? []
        let outs = d["PowerOutDetails"] as? [[String: Any]] ?? []
        let devices: [PortDevice] = outs.compactMap { o in
            let w = Double(i(o["Watts"])) / 1000
            guard w > 0.05 else { return nil }
            let port = Int(i(o["PortIndex"]))
            let f = (port - 1 >= 0 && port - 1 < fed.count) ? fed[port - 1] : [:]
            let soc = Int(i(f["FedStateOfCharge"]))
            return PortDevice(id: port, watts: w,
                              volts: Double(i(o["AdapterVoltage"])) / 1000,
                              amps: Double(i(o["Current"])) / 1000,
                              vendorID: Int(i(f["FedVendorID"])),
                              deviceSoC: soc > 0 ? soc : nil)
        }

        let remaining = Int(i(d["TimeRemaining"]))
        return PowerSample(
            time: Date(),
            adapterConnected: external,
            adapterRatedW: Double(i(adapter["Watts"])),
            adapterVolts: Double(i(adapter["AdapterVoltage"])) / 1000,
            systemInW: systemInW,
            adapterLossW: external ? Double(i(tele["AdapterEfficiencyLoss"])) / 1000 : 0,
            batteryW: batteryW,
            systemLoadW: loadW,
            devices: devices,
            percent: Int(i(d["CurrentCapacity"])),
            isCharging: (d["IsCharging"] as? Bool) ?? false,
            notChargingReason: Int(i(charger["NotChargingReason"])),
            tempC: Double(i(d["Temperature"])) / 100,
            minutesRemaining: (remaining > 0 && remaining < 65535) ? remaining : nil)
    }
}

@MainActor
final class PowerMonitor: ObservableObject {
    @Published var current: PowerSample?
    @Published var history: [PowerSample] = []
    private var timer: Timer?
    let maxHistory = 300 // 10 min at 2 s

    init() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func tick() {
        guard let s = BatteryReader.read() else { return }
        current = s
        history.append(s)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
    }

    var menuTitle: String {
        guard let s = current else { return "⚡︎ --" }
        if s.adapterConnected {
            let dev = s.devicesW > 0.05 ? String(format: " 📱%.0f", s.devicesW) : ""
            return String(format: "⚡︎%.0fW 🔋%+.0f%@", s.systemInW, s.batteryW, dev)
        }
        return String(format: "🔋%.0fW", s.batteryOutW)
    }
}

// MARK: - Colors

enum Palette {
    static let adapter = Color(red: 0.98, green: 0.72, blue: 0.20)
    static let battery = Color(red: 0.25, green: 0.78, blue: 0.45)
    static let mac     = Color(red: 0.30, green: 0.55, blue: 0.95)
    static let device  = Color(red: 0.75, green: 0.45, blue: 0.95)
    static let loss    = Color.gray
}

// MARK: - Sankey

struct FlowNode: Identifiable {
    let id: String
    let title: String
    let watts: Double
    let color: Color
}

struct SankeyView: View {
    let sources: [FlowNode]
    let sinks: [FlowNode]

    var body: some View {
        Canvas { ctx, size in
            let total = max(sinks.reduce(0) { $0 + $1.watts }, 0.01)
            let gap: CGFloat = 14
            let nodeW: CGFloat = 14
            let labelW: CGFloat = 150
            let leftX = labelW, rightX = size.width - labelW - nodeW
            let usableH = size.height - 20

            func layout(_ nodes: [FlowNode]) -> [CGRect] {
                let gaps = gap * CGFloat(max(nodes.count - 1, 0))
                let scale = (usableH - gaps) / total
                let used = nodes.reduce(0) { $0 + CGFloat($1.watts) * scale } + gaps
                var y = (size.height - used) / 2
                return nodes.map { n in
                    let h = max(CGFloat(n.watts) * scale, 2)
                    defer { y += h + gap }
                    return CGRect(x: 0, y: y, width: nodeW, height: h)
                }
            }
            let srcR = layout(sources).map { $0.offsetBy(dx: leftX, dy: 0) }
            let snkR = layout(sinks).map { $0.offsetBy(dx: rightX, dy: 0) }
            let scale = (usableH - gap * CGFloat(max(sinks.count - 1, sources.count - 1, 0))) / total

            // ribbons: each source split across sinks in proportion to sink size
            var srcCursor = srcR.map { $0.minY }
            var snkCursor = snkR.map { $0.minY }
            let srcTotal = max(sources.reduce(0) { $0 + $1.watts }, 0.01)
            for (si, s) in sources.enumerated() {
                for (ki, k) in sinks.enumerated() {
                    let w = s.watts * k.watts / srcTotal
                    let h = CGFloat(w) * scale
                    guard h > 0.3 else { continue }
                    let y0 = srcCursor[si], y1 = snkCursor[ki]
                    srcCursor[si] += h; snkCursor[ki] += h
                    let x0 = srcR[si].maxX, x1 = snkR[ki].minX, mx = (x0 + x1) / 2
                    var p = Path()
                    p.move(to: CGPoint(x: x0, y: y0))
                    p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mx, y: y0), control2: CGPoint(x: mx, y: y1))
                    p.addLine(to: CGPoint(x: x1, y: y1 + h))
                    p.addCurve(to: CGPoint(x: x0, y: y0 + h), control1: CGPoint(x: mx, y: y1 + h), control2: CGPoint(x: mx, y: y0 + h))
                    p.closeSubpath()
                    ctx.fill(p, with: .linearGradient(Gradient(colors: [s.color.opacity(0.45), k.color.opacity(0.45)]),
                                                      startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                }
            }

            func drawLabel(_ n: FlowNode, _ r: CGRect, leftSide: Bool) {
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(n.color))
                let text = Text("\(n.title)\n").font(.system(size: 12, weight: .medium))
                    + Text(String(format: "%.1f W", n.watts)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                let resolved = ctx.resolve(text.foregroundColor(.primary))
                if leftSide {
                    ctx.draw(resolved, at: CGPoint(x: r.minX - 8, y: r.midY), anchor: .trailing)
                } else {
                    ctx.draw(resolved, at: CGPoint(x: r.maxX + 8, y: r.midY), anchor: .leading)
                }
            }
            for (n, r) in zip(sources, srcR) { drawLabel(n, r, leftSide: true) }
            for (n, r) in zip(sinks, snkR) { drawLabel(n, r, leftSide: false) }
        }
    }
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject var monitor: PowerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = monitor.current {
                header(s)
                let (src, snk) = nodes(s)
                if snk.reduce(0, { $0 + $1.watts }) > 0.1 {
                    SankeyView(sources: src, sinks: snk)
                        .frame(height: 260)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                } else {
                    Text("No measurable power flow right now.").foregroundStyle(.secondary).frame(height: 260)
                }
                stats(s)
                historyChart
                explainer(s)
            } else {
                Text("Couldn't read AppleSmartBattery from IORegistry.")
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 720)
    }

    func nodes(_ s: PowerSample) -> ([FlowNode], [FlowNode]) {
        var src: [FlowNode] = []
        var snk: [FlowNode] = []
        if s.adapterConnected && s.systemInW > 0.05 {
            src.append(.init(id: "adapter", title: String(format: "Adapter (%.0f W, %.0f V)", s.adapterRatedW, s.adapterVolts), watts: s.systemInW, color: Palette.adapter))
        }
        if s.batteryOutW > 0.05 {
            src.append(.init(id: "battout", title: "Battery (discharging)", watts: s.batteryOutW, color: Palette.battery))
        }
        if s.batteryInW > 0.05 {
            snk.append(.init(id: "battin", title: "Into battery", watts: s.batteryInW, color: Palette.battery))
        }
        snk.append(.init(id: "mac", title: "Mac (CPU, screen, …)", watts: s.macW, color: Palette.mac))
        for d in s.devices {
            let soc = d.deviceSoC.map { " · \($0)%" } ?? ""
            snk.append(.init(id: "dev\(d.id)", title: d.label + soc, watts: d.watts, color: Palette.device))
        }
        // Rounding mismatch between independently-measured telemetry values
        let srcSum = src.reduce(0) { $0 + $1.watts }, snkSum = snk.reduce(0) { $0 + $1.watts }
        if srcSum - snkSum > 0.5 {
            snk.append(.init(id: "other", title: "Unaccounted / conversion", watts: srcSum - snkSum, color: Palette.loss))
        }
        return (src, snk)
    }

    func header(_ s: PowerSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(s.percent)%").font(.system(size: 34, weight: .bold).monospacedDigit())
            VStack(alignment: .leading) {
                Text(statusText(s)).font(.headline)
                if let m = s.minutesRemaining {
                    Text(s.batteryW > 0 ? "≈ \(m/60)h \(m%60)m until full" : "≈ \(m/60)h \(m%60)m remaining")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(String(format: "%.1f °C", s.tempC)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    func statusText(_ s: PowerSample) -> String {
        if !s.adapterConnected { return "On battery" }
        if s.batteryW > 0.3 { return "Charging" }
        if s.batteryW < -0.3 { return "Plugged in — adapter can't keep up, battery helping" }
        return s.notChargingReason != 0 ? "Plugged in — charging paused (optimized / limit)" : "Plugged in — battery idle, adapter powers everything"
    }

    func stats(_ s: PowerSample) -> some View {
        let input = max(s.systemInW, 0.01)
        return HStack(spacing: 12) {
            stat("To battery", s.adapterConnected ? s.batteryInW / input : nil, s.batteryInW, Palette.battery)
            stat("To Mac", s.adapterConnected ? s.macW / input : nil, s.macW, Palette.mac)
            stat("To devices", s.adapterConnected ? s.devicesW / input : nil, s.devicesW, Palette.device)
            stat("Adapter loss (est.)", nil, s.adapterLossW, Palette.loss)
        }
    }

    func stat(_ title: String, _ frac: Double?, _ w: Double, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f W", w)).font(.title3.weight(.semibold).monospacedDigit())
            Text(frac.map { String(format: "%.0f%% of input", $0 * 100) } ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(c.opacity(0.12)))
    }

    struct Pt: Identifiable { let id = UUID(); let t: Date; let w: Double; let kind: String }

    var historyChart: some View {
        let pts = monitor.history.flatMap { s -> [Pt] in [
            Pt(t: s.time, w: s.batteryW, kind: "Battery (+in / −out)"),
            Pt(t: s.time, w: s.macW, kind: "Mac"),
            Pt(t: s.time, w: s.devicesW, kind: "Devices"),
            Pt(t: s.time, w: s.systemInW, kind: "Adapter in"),
        ]}
        return VStack(alignment: .leading, spacing: 4) {
            Text("Last 10 minutes").font(.caption).foregroundStyle(.secondary)
            Chart(pts) { p in
                LineMark(x: .value("Time", p.t), y: .value("W", p.w))
                    .foregroundStyle(by: .value("Flow", p.kind))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale([
                "Adapter in": Palette.adapter, "Battery (+in / −out)": Palette.battery,
                "Mac": Palette.mac, "Devices": Palette.device,
            ])
            .chartYAxisLabel("W")
            .frame(height: 150)
        }
    }

    func explainer(_ s: PowerSample) -> some View {
        Text(s.devices.isEmpty
             ? "Plug a phone into a USB-C port to see it as its own flow."
             : "While plugged in, USB-C devices are fed from the Mac's system power rail, which the adapter supplies — the battery isn't cycled to charge them unless total demand exceeds the adapter.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - App

@main
struct PowerFlowApp: App {
    @StateObject private var monitor = PowerMonitor()

    var body: some Scene {
        Window("PowerFlow", id: "main") {
            ContentView().environmentObject(monitor)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuContent().environmentObject(monitor)
        } label: {
            Text(monitor.menuTitle).monospacedDigit()
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var monitor: PowerMonitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let s = monitor.current {
            Text(String(format: "Adapter in: %.1f W", s.systemInW))
            Text(String(format: "Battery: %+.1f W (%d%%)", s.batteryW, s.percent))
            Text(String(format: "Mac: %.1f W", s.macW))
            ForEach(s.devices) { d in Text(String(format: "%@: %.1f W", d.label, d.watts)) }
            Divider()
        }
        Button("Open PowerFlow") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
