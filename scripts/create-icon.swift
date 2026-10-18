import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 512
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let box = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 452, height: 452), xRadius: 108, yRadius: 108)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.59, alpha: 1),
                              ending: NSColor(calibratedRed: 0.12, green: 0.69, blue: 0.63, alpha: 1))!
    gradient.draw(in: box, angle: 60)
    NSColor.white.withAlphaComponent(0.96).setStroke()
    let arrows = NSBezierPath()
    arrows.lineWidth = 26
    arrows.lineCapStyle = .round
    arrows.lineJoinStyle = .round
    arrows.move(to: NSPoint(x: 138, y: 310)); arrows.line(to: NSPoint(x: 369, y: 310))
    arrows.move(to: NSPoint(x: 321, y: 358)); arrows.line(to: NSPoint(x: 369, y: 310)); arrows.line(to: NSPoint(x: 321, y: 262))
    arrows.move(to: NSPoint(x: 374, y: 202)); arrows.line(to: NSPoint(x: 143, y: 202))
    arrows.move(to: NSPoint(x: 191, y: 250)); arrows.line(to: NSPoint(x: 143, y: 202)); arrows.line(to: NSPoint(x: 191, y: 154))
    arrows.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: folder.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
