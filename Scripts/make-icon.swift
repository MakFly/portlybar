import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT.icns\n", stderr)
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let temporaryRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("PortlyBarIcon.\(UUID().uuidString)", isDirectory: true)
let directory = temporaryRoot.appendingPathComponent("PortlyBar.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryRoot) }

func render(size: Int, scale: Int, filename: String) throws {
    let pixels = size * scale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "PortlyBarIcon", code: 1) }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = CGFloat(size) * 0.045
    let tile = rect.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(size) * 0.22
    let background = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(red: 0.10, green: 0.48, blue: 1.0, alpha: 1),
        NSColor(red: 0.22, green: 0.18, blue: 0.76, alpha: 1),
    ])?.draw(in: background, angle: -45)

    NSColor.white.withAlphaComponent(0.94).setStroke()
    let stroke = max(2, CGFloat(size) * 0.06)
    let centerY = CGFloat(size) * 0.5
    let left = CGFloat(size) * 0.24
    let middle = CGFloat(size) * 0.53
    let dotX = CGFloat(size) * 0.72
    let offset = CGFloat(size) * 0.20
    for y in [centerY - offset, centerY, centerY + offset] {
        let path = NSBezierPath()
        path.lineWidth = stroke
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: left, y: y))
        path.curve(
            to: NSPoint(x: middle, y: centerY),
            controlPoint1: NSPoint(x: CGFloat(size) * 0.40, y: y),
            controlPoint2: NSPoint(x: CGFloat(size) * 0.42, y: centerY)
        )
        path.stroke()
    }
    NSColor.white.setFill()
    let dotSize = CGFloat(size) * 0.17
    NSBezierPath(ovalIn: NSRect(x: dotX - dotSize / 2, y: centerY - dotSize / 2, width: dotSize, height: dotSize)).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PortlyBarIcon", code: 2)
    }
    try data.write(to: directory.appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try render(size: size, scale: 1, filename: "icon_\(size)x\(size).png")
    try render(size: size, scale: 2, filename: "icon_\(size)x\(size)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", directory.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
