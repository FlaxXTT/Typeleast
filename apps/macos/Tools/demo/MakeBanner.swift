// MakeBanner.swift - the README banner: the app icon, the name and the promise.
//
//   swiftc -O MakeBanner.swift -o make-banner && ./make-banner AppIcon.icns banner.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOfFile: args[1]) else { print("usage: make-banner AppIcon.icns banner.png"); exit(2) }
let size = NSSize(width: 1280, height: 420)
let image = NSImage(size: size)
image.lockFocus()
let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.976, green: 0.972, blue: 0.960, alpha: 1),
                                   NSColor(calibratedRed: 0.925, green: 0.918, blue: 0.980, alpha: 1)])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: -20)
icon.draw(in: NSRect(x: 120, y: 120, width: 180, height: 180))
func text(_ s: String, _ font: NSFont, _ color: NSColor, at point: NSPoint) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
}
let ink = NSColor(calibratedWhite: 0.1, alpha: 1)
let grey = NSColor(calibratedWhite: 0.38, alpha: 1)
text("TypeLeast", NSFont.systemFont(ofSize: 76, weight: .bold), ink, at: NSPoint(x: 340, y: 228))
text("说话就是打字：本机识别，你的模型整理，直接写进光标处。", NSFont(name: "PingFang SC Medium", size: 30) ?? .systemFont(ofSize: 30), ink, at: NSPoint(x: 344, y: 172))
text("macOS  ·  Windows 11  ·  音频不出电脑  ·  自带 API Key", NSFont(name: "PingFang SC", size: 23) ?? .systemFont(ofSize: 23), grey, at: NSPoint(x: 346, y: 122))
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
