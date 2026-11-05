// Renders the PowerFlow app icon to a 1024x1024 PNG.
// Usage: swift icon/make_icon.swift <out.png> [--light] [--bleed]
//   --bleed: full-bleed square art (no tile/shadow) for an Icon Composer .icon layer;
//            macOS 26 applies its own rounded mask, shadow and glass.
import AppKit

let S: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let light = args.contains("--light")
let bleed = args.contains("--bleed")
let out = args.first { !$0.hasPrefix("--") } ?? "icon_1024.png"

// Theme
let bgTop: UInt32    = light ? 0xfdfdff : 0x252e55
let bgBottom: UInt32 = light ? 0xe3e7f2 : 0x10142a
let shadowA: CGFloat = light ? 0.22 : 0.35
let glowA: CGFloat   = light ? 0.30 : 0.16
let ribbonA: (CGFloat, CGFloat) = light ? (0.95, 1.0) : (0.85, 0.95)
let shineA: CGFloat  = light ? 0.0 : 0.08
let strokeC: (UInt32, CGFloat) = light ? (0x000000, 0.08) : (0xffffff, 0.10)

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
            blue: CGFloat(h & 0xff) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downward (easier to reason about).
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
if bleed {  // map the 824pt tile onto the whole canvas
    ctx.scaleBy(x: S / 824, y: S / 824); ctx.translateBy(x: -100, y: -100)
}

func linear(_ colors: [CGColor], _ p0: CGPoint, _ p1: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: p0, end: p1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// --- Squircle tile (macOS icon grid: 824pt tile inset 100pt) ---
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = bleed ? CGPath(rect: tile, transform: nil)
                     : CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// drop shadow
if !bleed {
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, shadowA))
ctx.addPath(tilePath); ctx.setFillColor(rgb(bgBottom)); ctx.fillPath()
ctx.restoreGState()
}

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
linear([rgb(bgTop), rgb(bgBottom)], CGPoint(x: 0, y: tile.minY), CGPoint(x: 0, y: tile.maxY))
// soft glow behind the source
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xffc23d, glowA), rgb(0xffc23d, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 300, y: 512), endRadius: 420, options: [])

// --- Sankey flows ---
let srcX: CGFloat = 330, dstX: CGFloat = 760
let srcTop: CGFloat = 300, srcH: CGFloat = 424
// (share of the source, destination top, color)
let sinks: [(CGFloat, CGFloat, UInt32)] = [
    (0.55, 230, 0x43d17a),  // battery — green
    (0.27, 500, 0x4f8ff7),  // Mac — blue
    (0.18, 680, 0xc073f5),  // device — purple
]
let yellow: UInt32 = 0xffc23d
var cursor = srcTop
for (share, dTop, color) in sinks {
    let h = srcH * share
    let y0 = cursor, y1 = dTop
    cursor += h
    let mx = (srcX + dstX) / 2
    let p = CGMutablePath()
    p.move(to: CGPoint(x: srcX, y: y0))
    p.addCurve(to: CGPoint(x: dstX, y: y1), control1: CGPoint(x: mx, y: y0), control2: CGPoint(x: mx, y: y1))
    p.addLine(to: CGPoint(x: dstX, y: y1 + h))
    p.addCurve(to: CGPoint(x: srcX, y: y0 + h), control1: CGPoint(x: mx, y: y1 + h), control2: CGPoint(x: mx, y: y0 + h))
    p.closeSubpath()
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    linear([rgb(yellow, ribbonA.0), rgb(color, ribbonA.1)], CGPoint(x: srcX, y: 0), CGPoint(x: dstX, y: 0))
    ctx.restoreGState()

    // destination node
    let node = CGRect(x: dstX - 2, y: y1, width: 46, height: h)
    ctx.addPath(CGPath(roundedRect: node, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(rgb(color)); ctx.fillPath()
}

// source node: a rounded yellow pill with a lightning bolt
let srcNode = CGRect(x: 214, y: srcTop - 6, width: 124, height: srcH + 12)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(yellow, 0.6))
ctx.addPath(CGPath(roundedRect: srcNode, cornerWidth: 40, cornerHeight: 40, transform: nil))
ctx.clip()
linear([rgb(0xffd866), rgb(0xffa91f)], CGPoint(x: 0, y: srcNode.minY), CGPoint(x: 0, y: srcNode.maxY))
ctx.restoreGState()

// bolt
let cx = srcNode.midX, cy = srcNode.midY
let bolt = CGMutablePath()
let pts: [(CGFloat, CGFloat)] = [(26, -150), (-50, 24), (-6, 24), (-26, 150), (50, -28), (6, -28)]
bolt.move(to: CGPoint(x: cx + pts[0].0, y: cy + pts[0].1))
for (x, y) in pts.dropFirst() { bolt.addLine(to: CGPoint(x: cx + x, y: cy + y)) }
bolt.closeSubpath()
ctx.addPath(bolt); ctx.setFillColor(rgb(0x1a1f38)); ctx.fillPath()

// subtle top highlight on tile
linear([rgb(0xffffff, shineA), rgb(0xffffff, 0)], CGPoint(x: 0, y: tile.minY), CGPoint(x: 0, y: tile.minY + 260))
ctx.restoreGState()

// inner stroke
if !bleed { ctx.addPath(tilePath); ctx.setStrokeColor(rgb(strokeC.0, strokeC.1)); ctx.setLineWidth(2); ctx.strokePath() }

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
