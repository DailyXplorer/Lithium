#!/usr/bin/env swift
// Renders Support/AppIcon.icns: a white Phosphor feather on a lavender-to-indigo squircle.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let support = root.appending(path: "Support")

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024

    // Apple's macOS icon grid: an 824 pt body centered on a 1024 pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 24 * scale
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.80, green: 0.83, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.53, green: 0.58, blue: 0.97, alpha: 1),
        NSColor(srgbRed: 0.33, green: 0.34, blue: 0.86, alpha: 1),
    ])!.draw(in: shape, angle: -65)

    // Soft top highlight, like light hitting glass.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)])!
        .draw(in: shape, angle: -90)

    var svg = try! String(contentsOf: support.appending(path: "feather-fill.svg"), encoding: .utf8)
    svg = svg.replacingOccurrences(of: "currentColor", with: "#FFFFFF")
    let feather = NSImage(data: Data(svg.utf8))!
    let glyph = 500 * scale
    let glyphRect = NSRect(x: (size - glyph) / 2 + 8 * scale, y: (size - glyph) / 2 - 6 * scale, width: glyph, height: glyph)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 0.15, green: 0.12, blue: 0.55, alpha: 0.35)
    glow.shadowOffset = NSSize(width: 0, height: -8 * scale)
    glow.shadowBlurRadius = 18 * scale
    glow.set()
    feather.draw(in: glyphRect)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * factor)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appending(path: name))
    }
}
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: support.appending(path: "AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appending(path: "AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(support.appending(path: "AppIcon.icns").path)
