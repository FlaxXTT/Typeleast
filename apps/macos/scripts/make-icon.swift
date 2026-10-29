// make-icon.swift - render the app mark (same drawing as AppMark in Theme.swift)
// into an .iconset folder; build the .icns with: iconutil -c icns <dir>.iconset
// Usage: swift scripts/make-icon.swift Resources/AppIcon.iconset
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = rect.width * 0.08
    let box = rect.insetBy(dx: inset, dy: inset)
    // A white tile with a hairline edge, so it still reads on white backgrounds.
    let tile = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: box.width * 0.23, yRadius: box.width * 0.23)
    NSColor.white.setFill()
    tile.fill()
    NSColor(white: 0, alpha: 0.12).setStroke()
    tile.lineWidth = max(1, box.width * 0.012)
    tile.stroke()
    let heights: [CGFloat] = [0.26, 0.48, 0.70, 0.48, 0.26]
    let barWidth = box.width * 0.085
    let gap = box.width * 0.065
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = box.midX - total / 2
    NSColor(srgbRed: 0.08, green: 0.075, blue: 0.075, alpha: 1).setFill()
    for h in heights {
        let height = box.height * h
        NSBezierPath(roundedRect: NSRect(x: x, y: box.midY - height / 2, width: barWidth, height: height),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = render(base * scale) { try? data.write(to: URL(fileURLWithPath: out + "/" + name)) }
    }
}
print("wrote " + out)
