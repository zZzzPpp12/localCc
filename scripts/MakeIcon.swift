import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int, filename: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = CGFloat(pixels)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: size / 1024, y: size / 1024)
    let rect = NSRect(x: 48, y: 48, width: 928, height: 928)
    let path = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
    NSColor(srgbRed: 0.89, green: 0.97, blue: 0.93, alpha: 1).setFill(); path.fill()
    let colors = [NSColor(srgbRed: 0.98, green: 1, blue: 0.99, alpha: 1), NSColor(srgbRed: 0.77, green: 0.93, blue: 0.87, alpha: 1)]
    NSGradient(colors: colors)!.draw(in: path, angle: -60)
    let mint = NSColor(srgbRed: 0.10, green: 0.62, blue: 0.48, alpha: 1)
    let lilac = NSColor(srgbRed: 0.57, green: 0.43, blue: 0.79, alpha: 1)
    for (radius, width, end, tint): (CGFloat, CGFloat, CGFloat, NSColor) in [(338, 38, -18, mint), (242, 29, 36, lilac)] {
        let track = NSBezierPath(); track.appendArc(withCenter: NSPoint(x: 512, y: 534), radius: radius, startAngle: -45, endAngle: 225, clockwise: false)
        track.lineWidth = width; track.lineCapStyle = .round
        NSColor(srgbRed: 0.14, green: 0.42, blue: 0.33, alpha: 0.10).setStroke(); track.stroke()
        let arc = NSBezierPath(); arc.appendArc(withCenter: NSPoint(x: 512, y: 534), radius: radius, startAngle: 225, endAngle: end, clockwise: true)
        arc.lineWidth = width; arc.lineCapStyle = .round; tint.setStroke(); arc.stroke()
    }
    let symbol = "◉" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 157, weight: .light), .foregroundColor: NSColor(srgbRed: 0.10, green: 0.32, blue: 0.25, alpha: 1)]
    let measured = symbol.size(withAttributes: attrs)
    symbol.draw(at: NSPoint(x: 512 - measured.width / 2, y: 534 - measured.height / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
    try png.write(to: output.appendingPathComponent(filename))
}
for base in [16, 32, 128, 256, 512] {
    try render(base, filename: "icon_\(base)x\(base).png")
    try render(base * 2, filename: "icon_\(base)x\(base)@2x.png")
}
