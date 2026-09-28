// Draws the disk image window background: a soft blue field, an arrow from the app to Applications, and an
// install hint. Writes background.png (1x) and background@2x.png into the given folder; dmgbuild combines them.
//
//   swift scripts/dmg-background.swift build/dmg
//
// The layout matches scripts/dmg-settings.py: a 660×400 window with 128-pt icons centered at (165, 190) and
// (495, 190), measured from the top left.
import AppKit

let width = 660.0
let height = 400.0
let iconY = 190.0

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func draw() {
    // Top-left origin, like Finder's icon positions.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    NSGradient(
        starting: NSColor(srgbRed: 0.965, green: 0.980, blue: 0.996, alpha: 1),
        ending: NSColor(srgbRed: 0.863, green: 0.925, blue: 0.984, alpha: 1)
    )!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Arrow between the icons (their edges are at 229 and 431), one path so the translucent joins don't darken.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: iconY))
    arrow.line(to: NSPoint(x: 396, y: iconY))
    arrow.move(to: NSPoint(x: 376, y: iconY - 18))
    arrow.line(to: NSPoint(x: 396, y: iconY))
    arrow.line(to: NSPoint(x: 376, y: iconY + 18))
    arrow.lineWidth = 7
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(srgbRed: 0.106, green: 0.439, blue: 0.945, alpha: 0.85).setStroke()
    arrow.stroke()

    let hint = NSAttributedString(
        string: "Drag CareMyMac to Applications to install",
        attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.106, green: 0.180, blue: 0.345, alpha: 0.8),
        ]
    )
    let size = hint.size()
    // Flip the text back so it isn't mirrored.
    NSGraphicsContext.saveGraphicsState()
    let unflip = NSAffineTransform()
    unflip.translateX(by: 0, yBy: 330 + size.height / 2)
    unflip.scaleX(by: 1, yBy: -1)
    unflip.concat()
    hint.draw(at: NSPoint(x: (width - size.width) / 2, y: 0))
    NSGraphicsContext.restoreGraphicsState()
}

for scale in [1, 2] {
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    // Point size at 1/scale of the pixels records 72 or 144 dpi, which is how Finder tells the two apart.
    image.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@\(scale)x.png"
    try image.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
