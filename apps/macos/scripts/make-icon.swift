// Compile with Sources/AppIconArtwork.swift; see docs/APP_ICON.md.
// Every resolution is rendered directly from vectors, never from a scaled PNG.
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum IconGenerator {
    static func png(size: Int) throws -> Data {
        let context = CGContext(data: nil, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        AppIconArtwork.draw(in: context,
                            rect: CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    static func main() throws {
        let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let artwork = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try png(size: 1024).write(to: artwork)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                let name = "icon_\(base)x\(base)\(suffix).png"
                try png(size: base * scale).write(to: iconset.appendingPathComponent(name))
            }
        }
        print("Created \(artwork.path) and \(iconset.path)")
    }
}
