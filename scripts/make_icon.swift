// Generează AppIcon.iconset: „C” alb mare + „Cleaner” pe albastru curat.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.62, blue: 1.00, alpha: 1), NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.90, alpha: 1)])!.draw(in: path, angle: -90)
    // Textul „Cleaner” doar unde se poate citi; la mărimi mici rămâne doar „C”.
    let withWord = px >= 128
    let c = NSAttributedString(string: "C", attributes: [
        .font: NSFont.systemFont(ofSize: rect.height * (withWord ? 0.56 : 0.72), weight: .heavy),
        .foregroundColor: NSColor.white])
    let cs = c.size()
    let cy = withWord ? rect.midY - cs.height * 0.30 : rect.midY - cs.height / 2
    c.draw(at: NSPoint(x: rect.midX - cs.width / 2, y: cy))
    if withWord {
        let w = NSAttributedString(string: "Cleaner", attributes: [
            .font: NSFont.systemFont(ofSize: rect.height * 0.15, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
        let ws = w.size()
        w.draw(at: NSPoint(x: rect.midX - ws.width / 2, y: rect.minY + rect.height * 0.10))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
