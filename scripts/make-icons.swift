import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "dist/VectorScroll.iconset"
let outputURL = URL(fileURLWithPath: output)
try? FileManager.default.removeItem(at: outputURL)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for spec in specs {
    let image = drawIcon(size: spec.1)
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(spec.0)")
    }
    try png.write(to: outputURL.appendingPathComponent(spec.0))
}

private func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let tile = NSBezierPath(
        roundedRect: rect.insetBy(dx: size * 0.08, dy: size * 0.08),
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    NSColor.black.setFill()
    tile.fill()

    let center = NSPoint(x: size / 2, y: size / 2)
    drawArrow(from: NSPoint(x: center.x, y: center.y + size * 0.12), to: NSPoint(x: center.x, y: center.y + size * 0.34), size: size)
    drawArrow(from: NSPoint(x: center.x, y: center.y - size * 0.12), to: NSPoint(x: center.x, y: center.y - size * 0.34), size: size)
    drawArrow(from: NSPoint(x: center.x - size * 0.12, y: center.y), to: NSPoint(x: center.x - size * 0.34, y: center.y), size: size)
    drawArrow(from: NSPoint(x: center.x + size * 0.12, y: center.y), to: NSPoint(x: center.x + size * 0.34, y: center.y), size: size)

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - size * 0.05,
        y: center.y - size * 0.05,
        width: size * 0.1,
        height: size * 0.1
    )).fill()

    image.unlockFocus()
    return image
}

private func drawArrow(from start: NSPoint, to end: NSPoint, size: CGFloat) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = max(2, size * 0.06)
    path.lineCapStyle = .round
    NSColor.white.setStroke()
    path.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength = size * 0.1
    let spread = CGFloat.pi / 7

    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: NSPoint(
        x: end.x - cos(angle - spread) * headLength,
        y: end.y - sin(angle - spread) * headLength
    ))
    head.move(to: end)
    head.line(to: NSPoint(
        x: end.x - cos(angle + spread) * headLength,
        y: end.y - sin(angle + spread) * headLength
    ))
    head.lineWidth = max(2, size * 0.06)
    head.lineCapStyle = .round
    head.stroke()
}
