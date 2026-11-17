// Renders the app icon (a small sunburst) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: rounded square inset ~10%.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.03, green: 0.04, blue: 0.08, alpha: 1)])!
        .draw(in: tilePath, angle: -90)

    let center = NSPoint(x: s / 2, y: s / 2)
    let rings: [(inner: CGFloat, outer: CGFloat, spans: [Double])] = [
        (0.13, 0.22, [0.34, 0.22, 0.17, 0.12, 0.09, 0.06]),
        (0.23, 0.30, [0.20, 0.10, 0.12, 0.07, 0.09, 0.05, 0.08, 0.04, 0.06]),
        (0.31, 0.36, [0.12, 0.05, 0.06, 0.04, 0.03, 0.08, 0.02, 0.05]),
    ]
    for (ringIndex, ring) in rings.enumerated() {
        var cursor = 0.0
        for (i, span) in ring.spans.enumerated() {
            let hue = (0.56 + (cursor + span / 2) * 0.92).truncatingRemainder(dividingBy: 1)
            let color = NSColor(calibratedHue: hue, saturation: 0.68 - CGFloat(ringIndex) * 0.08,
                                brightness: 0.95, alpha: 1)
            let path = NSBezierPath()
            let a0 = 90 - cursor * 360, a1 = 90 - (cursor + span) * 360
            path.appendArc(withCenter: center, radius: ring.outer * s, startAngle: a0, endAngle: a1, clockwise: true)
            path.appendArc(withCenter: center, radius: ring.inner * s, startAngle: a1, endAngle: a0, clockwise: false)
            path.close()
            color.setFill()
            path.fill()
            NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.13, alpha: 1).setStroke()
            path.lineWidth = max(1, s * 0.006)
            path.stroke()
            cursor += span
            _ = i
        }
    }
    let disc = NSBezierPath(ovalIn: NSRect(x: center.x - s * 0.115, y: center.y - s * 0.115, width: s * 0.23, height: s * 0.23))
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    disc.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
print("wrote \(output)")
