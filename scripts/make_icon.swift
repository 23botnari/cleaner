// Generează AppIcon.iconset: inel de stocare deschis, cu segmentul eliberat în verde, pe grafit.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func arc(center c: NSPoint, radius r: CGFloat, from a: CGFloat, to b: CGFloat, width w: CGFloat, color: NSColor) {
    let p = NSBezierPath()
    p.appendArc(withCenter: c, radius: r, startAngle: a, endAngle: b, clockwise: false)
    p.lineWidth = w
    p.lineCapStyle = .round
    color.setStroke()
    p.stroke()
}

for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Grila de iconițe macOS: corpul ocupă ~80% din pânză.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.23, alpha: 1),
                        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)])!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    shape.lineWidth = max(1, s / 512)
    shape.stroke()

    let c = NSPoint(x: body.midX, y: body.midY)
    let r = body.width * 0.29
    let w = body.width * 0.12
    // Unghiuri AppKit: 0° = dreapta, sens trigonometric. Inel gri cu gol sus-dreapta; în gol, segmentul „eliberat”.
    arc(center: c, radius: r, from: 100, to: 360, width: w, color: NSColor(white: 0.93, alpha: 1))
    arc(center: c, radius: r, from: 34, to: 66, width: w, color: NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
