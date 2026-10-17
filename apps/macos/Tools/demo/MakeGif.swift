// MakeGif.swift - turn a screen recording into the README's animated GIF.
//
//   swiftc -O MakeGif.swift -o make-gif && ./make-gif input.mov output.gif config.json
//
// config.json: {"width": 760, "fps": 12, "start": 0.0, "end": 20.0,
//               "captions": [{"from": 0, "to": 5, "title": "…", "detail": "…"}]}
// Each frame gets a caption band on top (what is happening, and what was said,
// since a GIF has no sound) above the scaled recording. System frameworks only.
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Caption: Decodable { let from: Double; let to: Double; let title: String; let detail: String? }
struct Config: Decodable { let width: Int; let fps: Double; let start: Double; let end: Double; let captions: [Caption] }

let args = CommandLine.arguments
guard args.count == 4 else { FileHandle.standardError.write("usage: make-gif input.mov output.gif config.json\n".data(using: .utf8)!); exit(2) }
let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let captionHeight = 150
let background = CGColor(red: 0.969, green: 0.969, blue: 0.961, alpha: 1)

func caption(at t: Double) -> Caption? { config.captions.first { t >= $0.from && t < $0.to } }

func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, context: CGContext) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
}

let output = URL(fileURLWithPath: args[2])
let count = Int(((config.end - config.start) * config.fps).rounded())
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else { exit(1) }
CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
let delay = 1.0 / config.fps
var height = 0
for i in 0..<count {
    let t = config.start + Double(i) / config.fps
    guard let frame = try? generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil) else { continue }
    let videoHeight = Int((Double(frame.height) * Double(config.width) / Double(frame.width)).rounded())
    height = captionHeight + videoHeight
    guard let ctx = CGContext(data: nil, width: config.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: config.width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: config.width, height: videoHeight))
    if let c = caption(at: t - config.start) {
        draw(c.title, font: NSFont(name: "PingFang SC Semibold", size: 25) ?? .boldSystemFont(ofSize: 25), color: NSColor(calibratedWhite: 0.1, alpha: 1),
             in: CGRect(x: 20, y: height - 58, width: config.width - 40, height: 40), context: ctx)
        if let d = c.detail {
            draw(d, font: NSFont(name: "PingFang SC", size: 18) ?? .systemFont(ofSize: 18), color: NSColor(calibratedWhite: 0.38, alpha: 1),
                 in: CGRect(x: 30, y: height - 140, width: config.width - 60, height: 76), context: ctx)
        }
    }
    guard let image = ctx.makeImage() else { continue }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { FileHandle.standardError.write("could not write the GIF\n".data(using: .utf8)!); exit(1) }
print("wrote \(output.path) (\(count) frames, \(config.width)x\(height))")
