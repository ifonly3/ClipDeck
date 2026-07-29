#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: generate_app_icon.swift <output.iconset>\n".utf8)
    )
    exit(2)
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
let fileManager = FileManager.default
try fileManager.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

struct IconVariant {
    let points: Int
    let scale: Int

    var filename: String {
        scale == 1
            ? "icon_\(points)x\(points).png"
            : "icon_\(points)x\(points)@2x.png"
    }

    var pixels: Int {
        points * scale
    }
}

let variants = [
    IconVariant(points: 16, scale: 1),
    IconVariant(points: 16, scale: 2),
    IconVariant(points: 32, scale: 1),
    IconVariant(points: 32, scale: 2),
    IconVariant(points: 128, scale: 1),
    IconVariant(points: 128, scale: 2),
    IconVariant(points: 256, scale: 1),
    IconVariant(points: 256, scale: 2),
    IconVariant(points: 512, scale: 1),
    IconVariant(points: 512, scale: 2)
]

func makeIconPNG(pixelSize: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.cannotCreateBitmap
    }

    bitmap.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphicsContext.cgContext
    let scale = CGFloat(pixelSize) / 1_024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1_024, height: 1_024).fill()

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916),
        xRadius: 214,
        yRadius: 214
    )
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.19, green: 0.50, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.38, green: 0.24, blue: 0.88, alpha: 1)
    ])
    gradient?.draw(in: tile, angle: -55)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    context.scaleBy(x: scale, y: scale)

    let backSheet = NSBezierPath(
        roundedRect: NSRect(x: 274, y: 246, width: 520, height: 570),
        xRadius: 78,
        yRadius: 78
    )
    NSColor.white.withAlphaComponent(0.42).setFill()
    backSheet.fill()

    let frontSheet = NSBezierPath(
        roundedRect: NSRect(x: 224, y: 196, width: 520, height: 570),
        xRadius: 78,
        yRadius: 78
    )
    NSColor.white.withAlphaComponent(0.96).setFill()
    frontSheet.fill()

    let clip = NSBezierPath(
        roundedRect: NSRect(x: 346, y: 704, width: 276, height: 108),
        xRadius: 54,
        yRadius: 54
    )
    NSColor(calibratedRed: 0.24, green: 0.39, blue: 0.91, alpha: 1).setFill()
    clip.fill()

    let lineColor = NSColor(calibratedRed: 0.31, green: 0.35, blue: 0.48, alpha: 0.72)
    lineColor.setFill()
    for (index, width) in [332, 404, 286].enumerated() {
        let line = NSBezierPath(
            roundedRect: NSRect(
                x: 316,
                y: 572 - CGFloat(index * 112),
                width: CGFloat(width),
                height: 34
            ),
            xRadius: 17,
            yRadius: 17
        )
        line.fill()
    }

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.cannotEncodePNG
    }
    return data
}

for variant in variants {
    let data = try makeIconPNG(pixelSize: variant.pixels)
    try data.write(
        to: outputDirectory.appendingPathComponent(variant.filename),
        options: .atomic
    )
}

enum IconError: LocalizedError {
    case cannotCreateBitmap
    case cannotEncodePNG

    var errorDescription: String? {
        switch self {
        case .cannotCreateBitmap:
            return "Could not create an icon bitmap."
        case .cannotEncodePNG:
            return "Could not encode an icon PNG."
        }
    }
}
