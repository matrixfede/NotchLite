// Draws the NotchLite app icon and writes Resources/AppIcon.icns.
// Usage: swift Resources/make-icon.swift   (from the project root)

import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
        let s = size / 1024 // design grid is 1024 pt, Apple's macOS icon template
        let ctx = NSGraphicsContext.current!.cgContext

        // Squircle body with a soft drop shadow.
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12 * s), blur: 28 * s,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(bodyPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Background gradient: indigo → violet → warm coral.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let colors = [
            NSColor(red: 0.26, green: 0.28, blue: 0.85, alpha: 1).cgColor,
            NSColor(red: 0.55, green: 0.27, blue: 0.86, alpha: 1).cgColor,
            NSColor(red: 0.98, green: 0.47, blue: 0.42, alpha: 1).cgColor,
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY),
                               end: CGPoint(x: body.maxX, y: body.maxY), options: [])
        // Top sheen.
        let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.midY), options: [])
        ctx.restoreGState()

        // The island, hanging from the top edge like the notch.
        let island = CGRect(x: 232 * s, y: 100 * s, width: 560 * s, height: 190 * s)
        let islandPath = NSBezierPath()
        let r: CGFloat = 80 * s
        islandPath.move(to: CGPoint(x: island.minX, y: island.minY))
        islandPath.line(to: CGPoint(x: island.maxX, y: island.minY))
        islandPath.line(to: CGPoint(x: island.maxX, y: island.maxY - r))
        islandPath.appendArc(withCenter: CGPoint(x: island.maxX - r, y: island.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        islandPath.line(to: CGPoint(x: island.minX + r, y: island.maxY))
        islandPath.appendArc(withCenter: CGPoint(x: island.minX + r, y: island.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        islandPath.close()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 * s), blur: 30 * s,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        NSColor(white: 0.04, alpha: 1).setFill()
        islandPath.fill()
        ctx.restoreGState()

        // Artwork tile on the left wing.
        let art = CGRect(x: 290 * s, y: 168 * s, width: 84 * s, height: 84 * s)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: art, cornerWidth: 20 * s, cornerHeight: 20 * s, transform: nil))
        ctx.clip()
        let artGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(red: 1.0, green: 0.36, blue: 0.55, alpha: 1).cgColor,
            NSColor(red: 1.0, green: 0.68, blue: 0.30, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(artGradient, start: CGPoint(x: art.minX, y: art.minY),
                               end: CGPoint(x: art.maxX, y: art.maxY), options: [])
        ctx.restoreGState()

        // Equalizer bars on the right wing.
        let bars: [CGFloat] = [44, 78, 58, 88]
        for (index, height) in bars.enumerated() {
            let x = (650 + CGFloat(index) * 30) * s
            let bar = CGRect(x: x, y: (210 - height / 2) * s, width: 16 * s, height: height * s)
            NSColor(red: 0.40, green: 0.95, blue: 0.62, alpha: 1).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 8 * s, yRadius: 8 * s).fill()
        }

        // Two usage meters below: the agents' limits.
        for (index, fill) in [CGFloat(0.72), 0.38].enumerated() {
            let y = (560 + CGFloat(index) * 120) * s
            let track = CGRect(x: 232 * s, y: y, width: 560 * s, height: 56 * s)
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: track, xRadius: 28 * s, yRadius: 28 * s).fill()
            var level = track
            level.size.width *= fill
            NSColor.white.setFill()
            NSBezierPath(roundedRect: level, xRadius: 28 * s, yRadius: 28 * s).fill()
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png(drawIcon(size: CGFloat(pixels)), pixels: pixels).write(to: iconset.appendingPathComponent(name))
    }
}
try png(drawIcon(size: 1024), pixels: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
