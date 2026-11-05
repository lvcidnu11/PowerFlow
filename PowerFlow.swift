// PowerFlow — where your MacBook's charging power goes, from the menu bar.
// AppKit + IOKit only: no SwiftUI/Charts, nothing drawn while the panel is closed,
// menu bar redrawn only when its text changes, USB rescanned only on plug/unplug.
import AppKit
import IOKit

// MARK: - Data

struct Device: Equatable {
    let port: Int, watts: Double, volts: Double, amps: Double, vendor: Int, soc: Int?, name: String?
    var label: String { name ?? (vendor == 1452 ? "Apple device" : "USB-C device") }
    var symbol: String {
        let n = (name ?? "").lowercased()
        let table: [(String, String)] = [
            ("iphone", "iphone"), ("ipad", "ipad"), ("watch", "applewatch"), ("airpods max", "airpodsmax"),
            ("airpods pro", "airpodspro.chargingcase.wireless"), ("airpods", "airpods.chargingcase"),
            ("pencil", "applepencil"), ("keyboard", "keyboard"), ("mouse", "magicmouse"),
            ("trackpad", "rectangle.and.hand.point.up.left"), ("macbook", "laptopcomputer"), ("ipod", "ipod"),
            ("vision", "visionpro"), ("pixel", "smartphone"), ("galaxy", "smartphone"), ("android", "smartphone"),
            ("phone", "smartphone"), ("tab", "ipad.landscape"), ("power bank", "battery.100percent"),
            ("battery", "battery.100percent"), ("headphone", "headphones"), ("controller", "gamecontroller"),
            ("camera", "camera"), ("ssd", "externaldrive"), ("drive", "externaldrive"), ("disk", "externaldrive"),
        ]
        return table.first { n.contains($0.0) }?.1 ?? "cable.connector"
    }
}

struct Reading: Equatable {
    var plugged = false, ratedW = 0.0, adapterV = 0.0, inW = 0.0, lossW = 0.0, batteryW = 0.0, loadW = 0.0
    var percent = 0, minutes: Int? = nil, notCharging = 0
    var devices: [Device] = []
    var devicesW: Double { devices.reduce(0) { $0 + $1.watts } }
    var macW: Double { max(0, loadW - devicesW) }
    var status: String {
        if !plugged { return "On battery" }
        if batteryW > 0.3 { return "Charging" }
        if batteryW < -0.3 { return "Charger can't keep up" }
        return notCharging != 0 ? "Charging paused" : "Charger powering everything"
    }
}

private func num(_ a: Any?) -> Int64 { (a as? NSNumber)?.int64Value ?? 0 }  // int64 keeps signed values intact

/// Reads only the AppleSmartBattery keys we use (≈4× cheaper than copying the whole dictionary).
final class Reader {
    private let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    private var usbNames: [Int: String] = [:]
    private var usbDirty = true
    private var usbIterators: [io_iterator_t] = []
    private(set) var health = 0, cycles = 0
    private var healthAge = 1_000  // > refresh threshold, so the first read loads health

    init() {
        // Plug/unplug notifications mark the USB name cache stale; no periodic scanning.
        let port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostDevice"), { ctx, it in
                Unmanaged<Reader>.fromOpaque(ctx!).takeUnretainedValue().usbDirty = true
                Reader.drain(it)
            }, me, &it)
            Reader.drain(it)  // arms the notification
            usbIterators.append(it)
        }
    }

    private static func drain(_ it: io_iterator_t) { while case let o = IOIteratorNext(it), o != 0 { IOObjectRelease(o) } }
    private func prop(_ k: String) -> Any? {
        IORegistryEntryCreateCFProperty(battery, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// On Apple Silicon each USB-C port has its own XHCI controller; the top byte of locationID is its index.
    private func usbByPort() -> [Int: String] {
        guard usbDirty else { return usbNames }
        usbDirty = false
        usbNames = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        while case let d = IOIteratorNext(it), d != 0 {
            defer { IOObjectRelease(d) }
            func p(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(d, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            guard let name = p("USB Product Name") as? String, let loc = (p("locationID") as? NSNumber)?.uint32Value else { continue }
            let port = Int(loc >> 24) + 1
            if usbNames[port] == nil { usbNames[port] = name }
        }
        return usbNames
    }

    func read() -> Reading? {
        guard battery != 0 else { return nil }
        var r = Reading()
        let tele = prop("PowerTelemetryData") as? [String: Any] ?? [:]
        let adapter = prop("AdapterDetails") as? [String: Any] ?? [:]
        r.plugged = (prop("ExternalConnected") as? Bool) ?? false
        let amps = num(prop("Amperage")), volts = num(prop("Voltage"))
        var bw = Double(num(tele["BatteryPower"])) / 1000
        if bw == 0 { bw = Double(abs(amps) * volts) / 1e6 }
        r.batteryW = amps < 0 ? -abs(bw) : abs(bw)
        if r.plugged {
            r.inW = Double(num(tele["SystemPowerIn"])) / 1000
            r.lossW = Double(num(tele["AdapterEfficiencyLoss"])) / 1000
            r.ratedW = Double(num(adapter["Watts"]))
            r.adapterV = Double(num(adapter["AdapterVoltage"])) / 1000
        }
        r.loadW = Double(num(tele["SystemLoad"])) / 1000
        if r.loadW <= 0 { r.loadW = max(0, r.inW - r.batteryW) }
        r.percent = Int(num(prop("CurrentCapacity")))
        let t = Int(num(prop("TimeRemaining")))
        r.minutes = (t > 0 && t < 65535) ? t : nil
        r.notCharging = Int(num((prop("ChargerData") as? [String: Any])?["NotChargingReason"]))

        // Health changes slowly; refresh it about every 10 minutes.
        healthAge += 1
        if healthAge > 200, let bd = prop("BatteryData") as? [String: Any] {
            healthAge = 0
            let design = num(bd["DesignCapacity"]), nominal = num(bd["NominalChargeCapacity"])
            health = design > 0 ? Int((Double(nominal) / Double(design) * 100).rounded()) : 0
            cycles = Int(num(prop("CycleCount")))
        }

        let fed = prop("FedDetails") as? [[String: Any]] ?? []
        let outs = (prop("PowerOutDetails") as? [[String: Any]] ?? []).filter { num($0["Watts"]) > 50 }
        let usb = outs.isEmpty ? [:] : usbByPort()
        r.devices = outs.map { o in
            let port = Int(num(o["PortIndex"]))
            let f = fed.indices.contains(port - 1) ? fed[port - 1] : [:]
            let soc = Int(num(f["FedStateOfCharge"]))
            return Device(port: port, watts: Double(num(o["Watts"])) / 1000,
                          volts: Double(num(o["AdapterVoltage"])) / 1000, amps: Double(num(o["Current"])) / 1000,
                          vendor: Int(num(f["FedVendorID"])), soc: soc > 0 ? soc : nil,
                          name: usb[port] ?? (outs.count == 1 && usb.count == 1 ? usb.values.first : nil))
        }
        return r
    }
}

// MARK: - Look

enum C {
    static let adapter = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.20, alpha: 1)
    static let battery = NSColor(srgbRed: 0.25, green: 0.78, blue: 0.45, alpha: 1)
    static let mac     = NSColor(srgbRed: 0.30, green: 0.55, blue: 0.95, alpha: 1)
    static let device  = NSColor(srgbRed: 0.75, green: 0.45, blue: 0.95, alpha: 1)
    static let other   = NSColor.systemGray
}

func batterySymbol(_ p: Int, charging: Bool = false) -> String {
    if charging && p >= 95 { return "battery.100percent.bolt" }
    return ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent"][min(4, max(0, (p + 12) / 25))]
}

func symbol(_ name: String, _ color: NSColor? = nil, size: CGFloat = 12) -> NSTextAttachment {
    var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
    let a = NSTextAttachment()
    a.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    if let s = a.image?.size { a.bounds = CGRect(x: 0, y: -2, width: s.width, height: s.height) }
    return a
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

// MARK: - Flow diagram

struct Node { let title: String, symbol: String, watts: Double, color: NSColor }

func nodes(_ r: Reading) -> ([Node], [Node]) {
    var src: [Node] = [], snk: [Node] = []
    if r.plugged && r.inW > 0.05 { src.append(Node(title: String(format: "Charger · %.0f W", r.ratedW), symbol: "powerplug.portrait.fill", watts: r.inW, color: C.adapter)) }
    if r.batteryW < -0.05 { src.append(Node(title: "Battery", symbol: batterySymbol(r.percent), watts: -r.batteryW, color: C.battery)) }
    if r.batteryW > 0.05 { snk.append(Node(title: "Battery", symbol: batterySymbol(r.percent), watts: r.batteryW, color: C.battery)) }
    snk.append(Node(title: "This Mac", symbol: "laptopcomputer", watts: r.macW, color: C.mac))
    for d in r.devices { snk.append(Node(title: d.label + (d.soc.map { " · \($0)%" } ?? ""), symbol: d.symbol, watts: d.watts, color: C.device)) }
    let gap = src.reduce(0) { $0 + $1.watts } - snk.reduce(0) { $0 + $1.watts }
    if gap > 0.5 { snk.append(Node(title: "Conversion / other", symbol: "arrow.triangle.branch", watts: gap, color: C.other)) }
    return (src, snk)
}

final class FlowView: NSView {
    var reading = Reading() { didSet { if reading != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 200) }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (src, snk) = nodes(reading)
        let total = max(snk.reduce(0) { $0 + $1.watts }, 0.01), srcTotal = max(src.reduce(0) { $0 + $1.watts }, 0.01)
        let gap: CGFloat = 10, nodeW: CGFloat = 8, leftX: CGFloat = 104, rightX = bounds.width - 118 - nodeW
        let usableH = bounds.height - 16
        let scale = (usableH - gap * CGFloat(max(snk.count, src.count) - 1)) / total

        func layout(_ ns: [Node], x: CGFloat) -> [CGRect] {
            let used = ns.reduce(0) { $0 + max(CGFloat($1.watts) * scale, 2) } + gap * CGFloat(max(ns.count - 1, 0))
            var y = (bounds.height - used) / 2
            return ns.map { n in
                let h = max(CGFloat(n.watts) * scale, 2)
                defer { y += h + gap }
                return CGRect(x: x, y: y, width: nodeW, height: h)
            }
        }
        let sr = layout(src, x: leftX), kr = layout(snk, x: rightX)

        // Ribbons: each source splits across sinks in proportion to sink size.
        var sy = sr.map(\.minY), ky = kr.map(\.minY)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGFloat = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.45 : 0.62
        for (si, s) in src.enumerated() {
            for (ki, k) in snk.enumerated() {
                let h = CGFloat(s.watts * k.watts / srcTotal) * scale
                guard h > 0.3 else { continue }
                let y0 = sy[si], y1 = ky[ki], x0 = sr[si].maxX, x1 = kr[ki].minX, mx = (x0 + x1) / 2
                sy[si] += h; ky[ki] += h
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x0, y: y0))
                p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: mx, y: y0), control2: CGPoint(x: mx, y: y1))
                p.addLine(to: CGPoint(x: x1, y: y1 + h))
                p.addCurve(to: CGPoint(x: x0, y: y0 + h), control1: CGPoint(x: mx, y: y1 + h), control2: CGPoint(x: mx, y: y0 + h))
                ctx.saveGState(); ctx.addPath(p); ctx.clip()
                let g = CGGradient(colorsSpace: cs, colors: [s.color.withAlphaComponent(alpha).cgColor, k.color.withAlphaComponent(alpha).cgColor] as CFArray, locations: nil)!
                ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
                ctx.restoreGState()
            }
        }

        func label(_ n: Node, _ r: CGRect, left: Bool) {
            n.color.setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            let s = NSMutableAttributedString(attachment: symbol(n.symbol, n.color, size: 11))
            s.append(text(" \(n.title)\n", 11, .medium, .secondaryLabelColor))
            s.append(text(String(format: "%.1f W", n.watts), 14, .semibold))
            if left { let p = NSMutableParagraphStyle(); p.alignment = .right; s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length)) }
            let w: CGFloat = left ? r.minX - 8 : bounds.width - r.maxX - 8
            let size = s.boundingRect(with: NSSize(width: w, height: 60), options: [.usesLineFragmentOrigin]).size
            s.draw(with: CGRect(x: left ? r.minX - 8 - w : r.maxX + 8, y: r.midY - size.height / 2, width: w, height: size.height), options: [.usesLineFragmentOrigin])
        }
        for (n, r) in zip(src, sr) { label(n, r, left: true) }
        for (n, r) in zip(snk, kr) { label(n, r, left: false) }
    }
}

// MARK: - History (fixed-size ring buffer, drawn only when visible)

final class HistoryView: NSView {
    static let capacity = 200               // ≈ 10 min at 3 s
    private var series = [[Float]](repeating: [], count: 4)  // in, battery, mac, devices
    private let colors = [C.adapter, C.battery, C.mac, C.device]
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 90) }

    func push(_ r: Reading) {
        for (i, v) in [r.inW, r.batteryW, r.macW, r.devicesW].enumerated() {
            series[i].append(Float(v))
            if series[i].count > Self.capacity { series[i].removeFirst() }
        }
        if !isHidden { needsDisplay = true }
    }

    override func draw(_ dirty: NSRect) {
        let lo = min(0, series.flatMap { $0 }.min() ?? 0), hi = max(1, series.flatMap { $0 }.max() ?? 1)
        let plot = bounds.insetBy(dx: 2, dy: 14)
        func y(_ v: Float) -> CGFloat { plot.maxY - CGFloat((v - lo) / (hi - lo)) * plot.height }
        NSColor.separatorColor.setStroke()
        let zero = NSBezierPath(); zero.move(to: NSPoint(x: plot.minX, y: y(0))); zero.line(to: NSPoint(x: plot.maxX, y: y(0))); zero.stroke()
        for (s, c) in zip(series, colors) where s.count > 1 {
            let p = NSBezierPath(); p.lineWidth = 1.5
            for (i, v) in s.enumerated() {
                let pt = NSPoint(x: plot.maxX - CGFloat(s.count - 1 - i) * plot.width / CGFloat(Self.capacity - 1), y: y(v))
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            c.setStroke(); p.stroke()
        }
        text("Last 10 min", 10, .regular, .tertiaryLabelColor).draw(at: NSPoint(x: plot.minX, y: 0))
        text(String(format: "%.0f W", hi), 10, .regular, .tertiaryLabelColor).draw(at: NSPoint(x: plot.maxX - 34, y: 0))
    }
}

// MARK: - Panel

final class Panel: NSViewController {
    let flow = FlowView(), history = HistoryView()
    private let percent = NSTextField(labelWithString: ""), status = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: ""), info = NSTextField(labelWithString: "")
    private let toggle = NSButton(title: "Details", target: nil, action: nil)
    var onResize: (() -> Void)?

    override func loadView() {
        percent.font = .monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        status.font = .systemFont(ofSize: 13, weight: .semibold)
        for f in [sub, info] { f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); f.textColor = .secondaryLabelColor }
        let titles = NSStackView(views: [status, sub]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 1
        let header = NSStackView(views: [percent, titles]); header.spacing = 10

        toggle.bezelStyle = .inline; toggle.target = self; toggle.action = #selector(toggleDetails)
        toggle.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil); toggle.imagePosition = .imageTrailing
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:))); quit.bezelStyle = .inline
        let footer = NSStackView(views: [toggle, NSView(), quit])

        history.isHidden = true; info.isHidden = true
        let stack = NSStackView(views: [header, flow, history, info, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        for v in [flow, history, footer] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        view = stack
    }

    func show(_ r: Reading, health: Int, cycles: Int) {
        flow.reading = r
        percent.stringValue = "\(r.percent)%"
        status.stringValue = r.status
        var bits: [String] = []
        if let m = r.minutes {
            let t = m < 60 ? "\(m) min" : "\(m / 60)h \(m % 60)m"
            bits.append(r.batteryW > 0 ? "\(t) to full" : "\(t) left")
        }
        if health > 0 { bits.append("health \(health)%") }
        sub.stringValue = bits.joined(separator: " · ")
        var d: [String] = []
        if r.plugged { d.append(String(format: "Charger %.0f W at %.0f V, est. loss %.1f W", r.ratedW, r.adapterV, r.lossW)) }
        if cycles > 0 { d.append("\(cycles) battery cycles") }
        for dev in r.devices { d.append(String(format: "%@ on port %d: %.2f V × %.2f A", dev.label, dev.port, dev.volts, dev.amps)) }
        info.stringValue = d.joined(separator: "\n")
    }

    @objc private func toggleDetails() {
        history.isHidden.toggle(); info.isHidden = history.isHidden
        toggle.image = NSImage(systemSymbolName: history.isHidden ? "chevron.down" : "chevron.up", accessibilityDescription: nil)
        if !history.isHidden { history.needsDisplay = true }
        onResize?()
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let reader = Reader()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover(), panel = Panel()
    private var last: Reading?, lastTitle = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.delegate = self
        panel.onResize = { [weak self] in
            guard let self else { return }
            self.popover.contentSize = self.panel.view.fittingSize
        }
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        tick()
        // Battery telemetry refreshes every ~15–60 s, so a 3 s poll with generous tolerance
        // lets macOS coalesce wake-ups; each read costs ≈ 80 µs.
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 1.5
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        guard let r = reader.read() else { return }
        panel.history.push(r)
        guard r != last else { return }
        last = r
        updateTitle(r)
        if popover.isShown { panel.show(r, health: reader.health, cycles: reader.cycles) }
    }

    private func updateTitle(_ r: Reading) {
        var parts: [(String, String)] = []
        if r.plugged { parts.append(("bolt.fill", String(format: "%.0fW", r.inW))) }
        parts.append((batterySymbol(r.percent, charging: r.batteryW > 0.3), String(format: r.plugged ? "%+.0f" : "%.0fW", r.batteryW)))
        for d in r.devices { parts.append((d.symbol, String(format: "%.0f", d.watts))) }
        let key = parts.map { $0.0 + $0.1 }.joined()
        guard key != lastTitle else { return }  // nothing visible changed
        lastTitle = key
        let s = NSMutableAttributedString()
        for (i, (sym, val)) in parts.enumerated() {
            if i > 0 { s.append(text("  ", 12)) }
            s.append(NSAttributedString(attachment: symbol(sym)))
            s.append(text(" " + val, 12, .medium, .controlTextColor))
        }
        item.button?.attributedTitle = s
    }

    @objc private func togglePopover() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        if let r = last { panel.show(r, health: reader.health, cycles: reader.cycles) }
        popover.contentSize = panel.view.fittingSize
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--dump") {  // one reading for bug reports
    let reader = Reader()
    if let r = reader.read() {
        print(String(format: "plugged=%@ in=%.1fW battery=%+.1fW mac=%.1fW percent=%d health=%d%% cycles=%d",
                     r.plugged ? "yes" : "no", r.inW, r.batteryW, r.macW, r.percent, reader.health, reader.cycles))
        for d in r.devices {
            print(String(format: "port %d: %@ [%@] %.1fW (%.2fV %.2fA) soc=%@ vendor=%d",
                         d.port, d.label, d.symbol, d.watts, d.volts, d.amps, d.soc.map(String.init) ?? "-", d.vendor))
        }
    } else { print("no AppleSmartBattery") }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    // Renders the panel offscreen in light and dark: --snapshot <dir> [--demo]
    let dir = CommandLine.arguments[i + 1], reader = Reader()
    var r = reader.read() ?? Reading()
    if CommandLine.arguments.contains("--demo") {  // fixed sample with a phone attached
        r = Reading(plugged: true, ratedW: 90, adapterV: 20, inW: 54, lossW: 1.4, batteryW: 27, loadW: 27, percent: 88, minutes: 43)
        r.devices = [Device(port: 1, watts: 10.4, volts: 5.2, amps: 2, vendor: 1452, soc: 76, name: "iPhone")]
    }
    for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let p = Panel(); p.view.appearance = NSAppearance(named: look)
        p.show(r, health: reader.health, cycles: reader.cycles)
        if CommandLine.arguments.contains("--details") { p.history.push(r); p.perform(Selector(("toggleDetails"))) }
        let v = p.view; v.frame.size = v.fittingSize; v.layoutSubtreeIfNeeded()
        let bg = NSView(frame: v.bounds); bg.wantsLayer = true; bg.appearance = v.appearance
        bg.layer?.backgroundColor = (look == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
        bg.addSubview(v)
        let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds)!
        NSAppearance(named: look)!.performAsCurrentDrawingAppearance { bg.cacheDisplay(in: bg.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/panel-\(name).png"))
    }
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
