// MakePromo.swift - the 10-second promo film, cut from real material only:
// the screen recording made by record-demo.sh (real voice bar, real recognition,
// real cleanup, real paste) and the app's own rendered screens (Tools/render.sh).
//
//   swiftc -O MakePromo.swift -o make-promo
//   ./make-promo demo.mov render-dir AppIcon.icns promo.mp4 promo.gif
//
// System frameworks only (AVFoundation, AppKit, ImageIO). The recording is played
// faster in two places, and the film says so on screen ("实拍 · 已加速").
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 6 else {
    print("usage: make-promo demo.mov render-dir AppIcon.icns promo.mp4 promo.gif")
    exit(2)
}
let W = 1920, H = 1080, fps = 30
let duration = 10.0
let frameCount = Int(duration * Double(fps))

// MARK: - material

func loadImage(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("cannot read " + path); exit(1)
    }
    return image
}
let footage = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let generator = AVAssetImageGenerator(asset: footage)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let icon = loadImage(args[3])
let home = loadImage(args[2] + "/hub-home.png")
let settings = loadImage(args[2] + "/hub-settings.png").cropping(to: CGRect(x: 0, y: 0, width: 1920, height: 1440))!
let dictionary = loadImage(args[2] + "/hub-dictionary-dark.png")

func footageFrame(_ seconds: Double) -> CGImage? {
    try? generator.copyCGImage(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600), actualTime: nil)
}

/// Find when the voice bar first appears and when the text lands, from the pixels.
func findEvents() -> (barAt: Double, textAt: Double) {
    let length = CMTimeGetSeconds(footage.duration)
    var barAt = 3.5, textAt = 16.0
    var foundBar = false
    var t = 0.0
    while t < length {
        if let img = footageFrame(t) {
            let rep = NSBitmapImageRep(cgImage: img)
            let w = rep.pixelsWide, h = rep.pixelsHigh
            func dark(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
                var n = 0
                for y in stride(from: y0, to: y1, by: 4) { for x in stride(from: x0, to: x1, by: 4) {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.35 { n += 1 } } }
                return n
            }
            if !foundBar && dark(w * 2 / 5, h - h / 8, w * 3 / 5, h - 4) > 100 { barAt = t; foundBar = true }
            if foundBar && dark(w / 10, h / 8, w * 9 / 10, h / 2) > 100 { textAt = t; break }
        }
        t += 0.1
    }
    return (barAt, textAt)
}
let events = findEvents()
print(String(format: "voice bar at %.1fs, text at %.1fs", events.barAt, events.textAt))

// MARK: - timing helpers

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
/// Progress of t through [a, b], 0...1.
func phase(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func mix(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
/// 0 -> 1 over [a, a+f], 1 until b-f, -> 0 at b.
func window(_ t: Double, _ a: Double, _ b: Double, fade: Double = 0.25) -> Double {
    min(phase(t, a, a + fade), 1 - phase(t, b - fade, b))
}

// MARK: - drawing helpers

let ink = NSColor(calibratedWhite: 0.08, alpha: 1)
let grey = NSColor(calibratedWhite: 0.40, alpha: 1)
let accent = NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.84, alpha: 1)

func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: .semibold) }

/// Draw text centred on (cx, cy), with alpha and a vertical offset for motion.
func text(_ ctx: CGContext, _ s: String, _ f: NSFont, _ color: NSColor, cx: Double, cy: Double, alpha: Double, maxWidth: Double = 1700) {
    guard alpha > 0.001 else { return }
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = 8
    let attributed = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style])
    let bounds = attributed.boundingRect(with: NSSize(width: maxWidth, height: 1000), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attributed.draw(with: NSRect(x: cx - maxWidth / 2, y: cy - bounds.height / 2, width: maxWidth, height: bounds.height), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
}

/// An image as a floating card: rounded corners, hairline, soft shadow.
func card(_ ctx: CGContext, _ image: CGImage, rect: CGRect, radius: Double, alpha: Double) {
    guard alpha > 0.001 else { return }
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: rect)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()
}

/// A small rounded label, e.g. "实拍 · 已加速".
func chip(_ ctx: CGContext, _ s: String, x: Double, y: Double, alpha: Double) {
    guard alpha > 0.001 else { return }
    let f = font("PingFang SC Medium", 24)
    let attributed = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
    let size = attributed.size()
    let rect = CGRect(x: x, y: y, width: size.width + 32, height: size.height + 14)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.78 * alpha))
    ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attributed.draw(at: NSPoint(x: rect.minX + 16, y: rect.minY + 7))
    NSGraphicsContext.restoreGraphicsState()
}

func background(_ ctx: CGContext) {
    let colors = [CGColor(red: 0.976, green: 0.972, blue: 0.960, alpha: 1), CGColor(red: 0.925, green: 0.918, blue: 0.985, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
}

// MARK: - the film

let spoken = "「嗯，那个，我们明天下午三点开会，呃，不对，是后天上午十点。然后呢，大家记得把上周的数据带上。」"
let titleFont = font("PingFang SC Semibold", 104)
let headFont = font("PingFang SC Semibold", 64)
let subFont = font("PingFang SC", 34)

// Footage time for film time t: two real-time-ish stretches, sped up where the
// person is talking, so the whole sentence fits.
func sourceTime(_ t: Double) -> Double {
    if t < 5.3 { return mix(events.barAt - 0.3, events.textAt - 1.5, phase(t, 1.3, 5.3)) }
    return mix(events.textAt - 1.5, events.textAt + 0.9, phase(t, 5.3, 7.4))
}

func drawFrame(_ ctx: CGContext, _ t: Double) {
    background(ctx)

    // 1. Hook (0 - 1.4 s)
    let hookA = window(t, 0.0, 0.85, fade: 0.2)
    text(ctx, "打字太慢？", titleFont, ink, cx: Double(W) / 2, cy: Double(H) / 2 + 20 + 30 * (1 - easeOut(phase(t, 0, 0.3))), alpha: hookA)
    let hookB = window(t, 0.7, 1.55, fade: 0.2)
    text(ctx, "直接说。", titleFont, accent, cx: Double(W) / 2, cy: Double(H) / 2 + 20 + 30 * (1 - easeOut(phase(t, 0.7, 1.0))), alpha: hookB)

    // 2-3. Real footage (1.3 - 7.6 s), one camera: push in on the voice bar, then on the text.
    let footageAlpha = window(t, 1.3, 7.7, fade: 0.3)
    if footageAlpha > 0.001, let frame = footageFrame(sourceTime(t)) {
        let aspect = Double(frame.width) / Double(frame.height)
        let baseW = 1360.0, baseH = baseW / aspect
        let base = CGRect(x: (Double(W) - baseW) / 2, y: 90, width: baseW, height: baseH)
        // Camera: scale and focus point within the card (0...1 from the bottom-left).
        let pushBar = easeInOut(phase(t, 1.5, 5.0))
        let toText = easeInOut(phase(t, 5.2, 6.3))
        let scale = mix(mix(0.96, 1.22, pushBar), 1.42, toText)
        let focusX = mix(0.5, 0.45, toText)
        let focusY = mix(mix(0.42, 0.18, pushBar), 0.86, toText)
        let fx = base.minX + base.width * focusX, fy = base.minY + base.height * focusY
        let anchorY = mix(mix(Double(H) * 0.45, Double(H) * 0.36, pushBar), Double(H) * 0.52, toText)
        let rect = CGRect(x: Double(W) / 2 - (fx - base.minX) * scale, y: anchorY - (fy - base.minY) * scale,
                          width: base.width * scale, height: base.height * scale)
        card(ctx, frame, rect: rect, radius: 22 * scale, alpha: footageAlpha)
        // A soft wash at the top keeps the words readable over the footage.
        let washAlpha = footageAlpha * window(t, 1.4, 5.5, fade: 0.3)
        if washAlpha > 0.001 {
            let wash = [CGColor(red: 0.972, green: 0.968, blue: 0.972, alpha: 0), CGColor(red: 0.972, green: 0.968, blue: 0.972, alpha: 0.94 * washAlpha)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: wash, locations: [0, 0.45])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: Double(H) - 330), end: CGPoint(x: 0, y: Double(H)), options: [.drawsAfterEndLocation])
        }
        chip(ctx, "实拍 · 已加速", x: 56, y: Double(H) - 92, alpha: footageAlpha)

        // What is being said, word by word, while the bar listens.
        let typed = phase(t, 1.6, 4.9)
        let shown = String(spoken.prefix(Int((Double(spoken.count) * typed).rounded())))
        text(ctx, "按一下 fn，随口说", headFont, ink, cx: Double(W) / 2, cy: Double(H) - 112, alpha: window(t, 1.5, 5.4, fade: 0.25))
        text(ctx, shown, font("PingFang SC", 32), grey, cx: Double(W) / 2, cy: Double(H) - 196, alpha: window(t, 1.5, 5.4, fade: 0.25), maxWidth: 1560)

        // The result.
        let landed = window(t, 6.75, 7.7, fade: 0.2)
        text(ctx, "口头禅去掉，改口照办。", headFont, ink, cx: Double(W) / 2, cy: 150, alpha: landed)
    }

    // 4. The real app (7.5 - 9.0 s): three screens fan in.
    let appAlpha = window(t, 7.5, 9.05, fade: 0.25)
    if appAlpha > 0.001 {
        let cards: [(CGImage, Double, Double, Double)] = [(settings, -610, 0.0, 0.74), (dictionary, 610, 0.08, 0.74), (home, 0, 0.16, 1.0)]
        for (image, dx, delay, size) in cards {
            let p = easeOut(phase(t, 7.5 + delay, 8.1 + delay))
            let w = 900.0 * size, h = w * Double(image.height) / Double(image.width)
            let rect = CGRect(x: Double(W) / 2 + dx * p - w / 2, y: 330 - 80 * (1 - p) - (size < 1 ? 30 : 0), width: w, height: h)
            card(ctx, image, rect: rect, radius: 18, alpha: appAlpha * p)
        }
        text(ctx, "本机识别 · 你的模型整理 · 任何输入框", headFont, ink, cx: Double(W) / 2, cy: 170, alpha: appAlpha)
    }

    // 5. End card (8.9 - 10 s)
    let endAlpha = phase(t, 8.9, 9.25)
    if endAlpha > 0.001 {
        let rise = 20 * (1 - easeOut(phase(t, 8.9, 9.4)))
        ctx.saveGState()
        ctx.setAlpha(endAlpha)
        ctx.draw(icon, in: CGRect(x: Double(W) / 2 - 90, y: Double(H) / 2 + 70 - rise, width: 180, height: 180))
        ctx.restoreGState()
        text(ctx, "TypeLeast", font("SF Pro Display Bold", 96), ink, cx: Double(W) / 2, cy: Double(H) / 2 - 20 - rise, alpha: endAlpha)
        text(ctx, "说话就是打字。", font("PingFang SC Medium", 44), ink, cx: Double(W) / 2, cy: Double(H) / 2 - 110 - rise, alpha: endAlpha)
        text(ctx, "macOS · Windows 11 · 识别在本机 · 自带 API Key", subFont, grey, cx: Double(W) / 2, cy: Double(H) / 2 - 180 - rise, alpha: endAlpha)
    }
}

// MARK: - render: H.264 MP4 and a smaller looping GIF

let mp4 = URL(fileURLWithPath: args[4])
try? FileManager.default.removeItem(at: mp4)
let writer = try AVAssetWriter(outputURL: mp4, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: W,
    AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: W,
    kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let gifW = 960, gifH = 540, gifEvery = 2
let gif = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[5]) as CFURL, UTType.gif.identifier as CFString, frameCount / gifEvery, nil)!
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)

for i in 0..<frameCount {
    let t = Double(i) / Double(fps)
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pixels = buffer else { continue }
    CVPixelBufferLockBaseAddress(pixels, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    drawFrame(ctx, t)
    if i % gifEvery == 0, let full = ctx.makeImage(),
       let small = CGContext(data: nil, width: gifW, height: gifH, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        small.interpolationQuality = .high
        small.draw(full, in: CGRect(x: 0, y: 0, width: gifW, height: gifH))
        CGImageDestinationAddImage(gif, small.makeImage()!, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: Double(gifEvery) / Double(fps)]] as CFDictionary)
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed, CGImageDestinationFinalize(gif) else { print("render failed: \(String(describing: writer.error))"); exit(1) }
print("wrote \(args[4]) and \(args[5])")
