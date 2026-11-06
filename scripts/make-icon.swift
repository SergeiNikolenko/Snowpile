// Renders Resources/AppIcon.icns: a white snowflake on a winter-sky squircle.
// Usage: swift scripts/make-icon.swift
import AppKit

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Snowpile.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.55, blue: 0.86, alpha: 1), NSColor(red: 0.12, green: 0.22, blue: 0.48, alpha: 1)])!
        .draw(in: shape, angle: -90)
    let drift = NSBezierPath()
    drift.move(to: NSPoint(x: tile.minX, y: tile.minY + tile.height * 0.2))
    drift.curve(to: NSPoint(x: tile.maxX, y: tile.minY + tile.height * 0.16),
                controlPoint1: NSPoint(x: tile.midX - tile.width * 0.15, y: tile.minY + tile.height * 0.34),
                controlPoint2: NSPoint(x: tile.midX + tile.width * 0.2, y: tile.minY + tile.height * 0.08))
    drift.line(to: NSPoint(x: tile.maxX, y: tile.minY))
    drift.line(to: NSPoint(x: tile.minX, y: tile.minY))
    drift.close()
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSColor(white: 0.97, alpha: 1).setFill()
    drift.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = flake.size
        flake.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.05, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
