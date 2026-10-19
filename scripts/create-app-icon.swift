import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: create-app-icon.swift output.png")
}

let canvas = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let iconShape = NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 218, yRadius: 218)
let greenGradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.96, blue: 0.34, alpha: 1),
    NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.25, alpha: 1),
    NSColor(calibratedRed: 0.00, green: 0.56, blue: 0.19, alpha: 1)
])!
greenGradient.draw(in: iconShape, angle: -45)

NSGraphicsContext.saveGraphicsState()
iconShape.addClip()
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.02)
])!.draw(in: NSRect(x: 36, y: 520, width: 952, height: 468), angle: -90)
NSGraphicsContext.restoreGraphicsState()

NSColor.white.setFill()
let barHeights: [(CGFloat, CGFloat)] = [(238, 300), (412, 470), (586, 370), (760, 590)]
for (x, height) in barHeights {
    NSBezierPath(roundedRect: NSRect(x: x, y: 220, width: 100, height: height), xRadius: 50, yRadius: 50).fill()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode app icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
