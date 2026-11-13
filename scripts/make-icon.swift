import AppKit

guard CommandLine.arguments.count == 2 else {
    print("usage: swift make-icon.swift <output.iconset>")
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The app's sound stage in miniature: outside sound arrives from both sides,
/// stops at the ear cups, and a flat line is all that reaches the listener.
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let plateRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.set()
    NSColor.black.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x2B2D31), color(0x151618)])!.draw(in: plate, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    let mid: CGFloat = 512
    let cups: [CGFloat] = [372, 652]
    let cupWidth: CGFloat = 64
    let gap: CGFloat = 34

    // Outside sound, loudest next to the cups and running off the edge of the plate.
    for side in [-1.0, 1.0] as [CGFloat] {
        let start = (side < 0 ? cups[0] : cups[1]) + side * (cupWidth / 2 + gap)
        let wave = NSBezierPath()
        let length: CGFloat = 250
        for step in 0...80 {
            let distance = length * CGFloat(step) / 80
            let swell = 118 * (0.45 + 0.55 * min(distance / 90, 1))
            let point = NSPoint(x: start + side * distance, y: mid + swell * sin(distance / 150 * 2 * .pi + 0.5))
            if step == 0 { wave.move(to: point) } else { wave.line(to: point) }
        }
        wave.lineWidth = 46
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        color(0xFFB454).setStroke()
        wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    let quiet = NSBezierPath()
    quiet.move(to: NSPoint(x: cups[0] + cupWidth / 2 + gap, y: mid))
    quiet.line(to: NSPoint(x: cups[1] - cupWidth / 2 - gap, y: mid))
    quiet.lineWidth = 46
    quiet.lineCapStyle = .round
    color(0x8F9BFF).setStroke()
    quiet.stroke()

    for x in cups {
        let cup = NSBezierPath(roundedRect: NSRect(x: x - cupWidth / 2, y: mid - 215, width: cupWidth, height: 430),
                               xRadius: cupWidth / 2, yRadius: cupWidth / 2)
        color(0xF1F2EE).setFill()
        cup.fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
