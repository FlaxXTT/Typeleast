// FrameShot.swift - give a screenshot rounded corners, a hairline border and a soft
// shadow on a transparent background, so it sits well on light and dark pages.
//
//   swiftc -O FrameShot.swift -o frame-shot && ./frame-shot in.png out.png [crop-height-px]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("usage: frame-shot in.png out.png [crop-height]"); exit(2) }
let cropHeight = args.count > 3 ? min(Int(args[3]) ?? cg.height, cg.height) : cg.height
let shot = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: cropHeight))!
let pad = 48.0, radius = 26.0
let w = Double(shot.width) + pad * 2, h = Double(shot.height) + pad * 2
let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let card = CGRect(x: pad, y: pad, width: Double(shot.width), height: Double(shot.height))
let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: CGColor(gray: 0, alpha: 0.22))
ctx.addPath(path)
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.draw(shot, in: card)
ctx.restoreGState()
ctx.addPath(path)
ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
ctx.setLineWidth(2)
ctx.strokePath()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
