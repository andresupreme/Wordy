#!/usr/bin/env swift
// Draws the Wordy app icon and writes Packaging/AppIcon.iconset (PNG sizes).
// On a Mac, build_app.sh turns the iconset into AppIcon.icns with `iconutil`.
// Uses only AppKit, so there is no Pillow/Python dependency.
import AppKit

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let out = here.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let top = NSColor(srgbRed: 52 / 255, green: 52 / 255, blue: 54 / 255, alpha: 1)
let bottom = NSColor(srgbRed: 26 / 255, green: 26 / 255, blue: 28 / 255, alpha: 1)
let ink = NSColor(srgbRed: 238 / 255, green: 238 / 255, blue: 236 / 255, alpha: 1)

func drawIcon(in ctx: CGContext, pixels: CGFloat) {
    let scale = pixels / 1024
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    // Rounded square with a soft vertical gradient (macOS icon grid: 824 of 1024).
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [top.cgColor, bottom.cgColor] as CFArray
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 512, y: 924),
            end: CGPoint(x: 512, y: 100),
            options: []
        )
    }
    ctx.restoreGState()

    // Three text lines, in top-left coordinates like the original script.
    ctx.setFillColor(ink.cgColor)
    let rows: [(CGFloat, CGFloat)] = [(372, 500), (494, 430), (616, 290)]
    for (centerY, width) in rows {
        let y = 1024 - centerY - 23
        let bar = CGRect(x: 262, y: y, width: width, height: 46)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 23, cornerHeight: 23, transform: nil))
    }
    // The text cursor, right after the last line.
    let cx = 262 + 290 + 34
    let cursor = CGRect(x: cx, y: 1024 - 616 - 62, width: 26, height: 124)
    ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.fillPath()

    ctx.restoreGState()
}

func png(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
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
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    drawIcon(in: ctx, pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in sizes {
    guard let data = png(pixels: size) else {
        fatalError("could not render \(name)")
    }
    do {
        try data.write(to: out.appendingPathComponent(name))
    } catch {
        fatalError("could not write \(name): \(error)")
    }
}

if let master = png(pixels: 1024) {
    try? master.write(to: here.appendingPathComponent("icon_preview.png"))
}

print("wrote \(sizes.count) icon sizes")
