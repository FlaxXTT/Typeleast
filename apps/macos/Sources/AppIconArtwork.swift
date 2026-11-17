import AppKit

/// Shared vector artwork for the app bundle, Dock, sidebar and onboarding.
/// Enclosure: Apple App Icon Template (Illustrator, iOS 27), scaled into an
/// 824 × 824 tile on the legacy macOS 1024 × 1024 ICNS canvas.
/// Source and reproduction instructions: docs/APP_ICON.md.
enum AppIconArtwork {
    static let canvasSize: CGFloat = 1024
    static let barRatios: [CGFloat] = [0.30, 0.58, 1.00, 0.72, 0.42]

    static func outline(in rect: CGRect) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 1024 * rect.width,
                    y: rect.minY + y / 1024 * rect.height)
        }
        let path = CGMutablePath()
        path.move(to: p(1024.000, 373.000))
        path.addCurve(to: p(1023.916, 330.274), control1: p(1024.000, 358.757), control2: p(1024.006, 344.517))
        path.addCurve(to: p(1023.384, 294.291), control1: p(1023.847, 318.278), control2: p(1023.709, 306.284))
        path.addCurve(to: p(1016.492, 215.953), control1: p(1022.675, 268.157), control2: p(1021.137, 241.797))
        path.addCurve(to: p(991.963, 141.516), control1: p(1011.779, 189.736), control2: p(1004.088, 165.336))
        path.addCurve(to: p(945.898, 78.102), control1: p(980.046, 118.103), control2: p(964.474, 96.679))
        path.addCurve(to: p(882.484, 32.037), control1: p(927.321, 59.526), control2: p(905.897, 43.954))
        path.addCurve(to: p(808.047, 7.508), control1: p(858.664, 19.912), control2: p(834.264, 12.221))
        path.addCurve(to: p(729.709, 0.616), control1: p(782.203, 2.863), control2: p(755.843, 1.325))
        path.addCurve(to: p(693.726, 0.084), control1: p(717.716, 0.291), control2: p(705.722, 0.153))
        path.addCurve(to: p(651.000, 0.000), control1: p(679.483, -0.006), control2: p(665.243, 0.000))
        path.addLine(to: p(373.000, 0.000))
        path.addCurve(to: p(330.274, 0.084), control1: p(358.757, 0.000), control2: p(344.517, -0.006))
        path.addCurve(to: p(294.291, 0.616), control1: p(318.278, 0.153), control2: p(306.284, 0.291))
        path.addCurve(to: p(215.954, 7.508), control1: p(268.158, 1.325), control2: p(241.797, 2.863))
        path.addCurve(to: p(141.516, 32.037), control1: p(189.736, 12.221), control2: p(165.336, 19.912))
        path.addCurve(to: p(78.103, 78.102), control1: p(118.104, 43.954), control2: p(96.679, 59.526))
        path.addCurve(to: p(32.037, 141.516), control1: p(59.526, 96.679), control2: p(43.955, 118.103))
        path.addCurve(to: p(7.509, 215.953), control1: p(19.913, 165.336), control2: p(12.221, 189.736))
        path.addCurve(to: p(0.617, 294.291), control1: p(2.863, 241.797), control2: p(1.325, 268.157))
        path.addCurve(to: p(0.084, 330.274), control1: p(0.291, 306.284), control2: p(0.153, 318.278))
        path.addCurve(to: p(0.000, 373.000), control1: p(-0.006, 344.517), control2: p(0.000, 358.757))
        path.addLine(to: p(0.000, 651.000))
        path.addCurve(to: p(0.084, 693.726), control1: p(0.000, 665.243), control2: p(-0.006, 679.483))
        path.addCurve(to: p(0.617, 729.709), control1: p(0.153, 705.722), control2: p(0.291, 717.716))
        path.addCurve(to: p(7.509, 808.046), control1: p(1.325, 755.842), control2: p(2.863, 782.203))
        path.addCurve(to: p(32.037, 882.484), control1: p(12.221, 834.264), control2: p(19.913, 858.664))
        path.addCurve(to: p(78.103, 945.897), control1: p(43.955, 905.896), control2: p(59.526, 927.321))
        path.addCurve(to: p(141.516, 991.963), control1: p(96.679, 964.474), control2: p(118.104, 980.045))
        path.addCurve(to: p(215.954, 1016.491), control1: p(165.336, 1004.087), control2: p(189.736, 1011.779))
        path.addCurve(to: p(294.291, 1023.384), control1: p(241.797, 1021.137), control2: p(268.158, 1022.675))
        path.addCurve(to: p(330.274, 1023.916), control1: p(306.284, 1023.709), control2: p(318.278, 1023.847))
        path.addCurve(to: p(373.000, 1024.000), control1: p(344.517, 1024.006), control2: p(358.757, 1024.000))
        path.addLine(to: p(651.000, 1024.000))
        path.addCurve(to: p(693.726, 1023.916), control1: p(665.243, 1024.000), control2: p(679.483, 1024.006))
        path.addCurve(to: p(729.709, 1023.384), control1: p(705.722, 1023.847), control2: p(717.716, 1023.709))
        path.addCurve(to: p(808.047, 1016.491), control1: p(755.843, 1022.675), control2: p(782.203, 1021.137))
        path.addCurve(to: p(882.484, 991.963), control1: p(834.264, 1011.779), control2: p(858.664, 1004.087))
        path.addCurve(to: p(945.898, 945.897), control1: p(905.897, 980.045), control2: p(927.321, 964.474))
        path.addCurve(to: p(991.963, 882.484), control1: p(964.474, 927.321), control2: p(980.046, 905.896))
        path.addCurve(to: p(1016.492, 808.046), control1: p(1004.088, 858.664), control2: p(1011.779, 834.264))
        path.addCurve(to: p(1023.384, 729.709), control1: p(1021.137, 782.203), control2: p(1022.675, 755.842))
        path.addCurve(to: p(1023.916, 693.726), control1: p(1023.709, 717.716), control2: p(1023.847, 705.722))
        path.addCurve(to: p(1024.000, 651.000), control1: p(1024.006, 679.483), control2: p(1024.000, 665.243))
        path.closeSubpath()
        return path
    }

    private static func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    static func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / canvasSize, y: rect.height / canvasSize)
        context.setShouldAntialias(true)

        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let enclosure = outline(in: tile)
        context.saveGState()
        context.addPath(enclosure)
        context.clip()
        context.setFillColor(colour(0xFAFAF9))
        context.fill(tile)

        // Five-percent radial light, arriving from above-left. No cast shadow.
        let light = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [colour(0xFFFFFF, alpha: 0.05),
                                        colour(0xFFFFFF, alpha: 0)] as CFArray,
                               locations: [0, 1])!
        let origin = CGPoint(x: tile.minX + tile.width * 0.28,
                             y: tile.maxY - tile.height * 0.06)
        context.drawRadialGradient(light, startCenter: origin, startRadius: 0,
                                   endCenter: origin, endRadius: tile.width * 0.95,
                                   options: [.drawsAfterEndLocation])

        // Clip the outer half of a 2px stroke to leave an exactly 1px inner edge.
        context.addPath(enclosure)
        context.setStrokeColor(colour(0x111111, alpha: 0.06))
        context.setLineWidth(2)
        context.strokePath()
        context.restoreGState()

        let barWidth: CGFloat = 76
        let gap: CGFloat = 36
        let maximumHeight: CGFloat = 464
        let totalWidth = CGFloat(barRatios.count) * barWidth + CGFloat(barRatios.count - 1) * gap
        for (index, ratio) in barRatios.enumerated() {
            let height = maximumHeight * ratio
            let bar = CGRect(x: tile.midX - totalWidth / 2 + CGFloat(index) * (barWidth + gap),
                             y: tile.midY - height / 2, width: barWidth, height: height)
            context.setFillColor(colour(index == 4 ? 0x1F5DF2 : 0x1D1A1A))
            context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2,
                                  cornerHeight: barWidth / 2, transform: nil))
            context.fillPath()
        }
    }

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, rect: rect)
            return true
        }
    }
}
