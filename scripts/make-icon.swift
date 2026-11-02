import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawBubble(_ rectangle: NSRect, fill: NSColor, tail: CGFloat) {
    fill.setFill()
    NSBezierPath(roundedRect: rectangle, xRadius: rectangle.width * 0.23,
                 yRadius: rectangle.height * 0.31).fill()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rectangle.minX + tail, y: rectangle.minY + 0.03))
    path.line(to: NSPoint(x: rectangle.minX + tail - 0.06, y: rectangle.minY - 0.08))
    path.line(to: NSPoint(x: rectangle.minX + tail + 0.10, y: rectangle.minY + 0.02))
    path.close()
    path.fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels))
        (transform as NSAffineTransform).concat()
        NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.73, blue: 0.48, alpha: 1),
                   ending: NSColor(srgbRed: 0.02, green: 0.48, blue: 0.34, alpha: 1))!
            .draw(in: NSBezierPath(roundedRect: NSRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88),
                                  xRadius: 0.20, yRadius: 0.20), angle: -90)
        drawBubble(NSRect(x: 0.20, y: 0.43, width: 0.44, height: 0.30),
                   fill: NSColor.white.withAlphaComponent(0.45), tail: 0.13)
        drawBubble(NSRect(x: 0.36, y: 0.28, width: 0.44, height: 0.30), fill: .white, tail: 0.23)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
    }
}
