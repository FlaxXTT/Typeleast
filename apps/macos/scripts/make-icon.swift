// Compile with Sources/AppIconArtwork.swift; see docs/APP_ICON.md.
// Every resolution is rendered directly from vectors, never from a scaled PNG.
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum IconGenerator {
    static func png(size: Int, surface: AppIconArtwork.Surface = .systemIcon) throws -> Data {
        let context = CGContext(data: nil, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        AppIconArtwork.draw(in: context,
                            rect: CGRect(x: 0, y: 0, width: size, height: size), surface: surface)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data as Data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    /// PNG-backed ICO frames use the exact same edge-to-edge vector artwork.
    static func ico() throws -> Data {
        let sizes = [16, 32, 48, 96, 128, 256]
        let frames = try sizes.map { try png(size: $0, surface: .interface) }
        var data = Data()
        append(UInt16(0), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(sizes.count), to: &data)
        var offset = 6 + sizes.count * 16
        for (size, frame) in zip(sizes, frames) {
            let dimension = UInt8(size == 256 ? 0 : size)
            data.append(contentsOf: [dimension, dimension, 0, 0])
            append(UInt16(1), to: &data)
            append(UInt16(32), to: &data)
            append(UInt32(frame.count), to: &data)
            append(UInt32(offset), to: &data)
            offset += frame.count
        }
        frames.forEach { data.append($0) }
        return data
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
        let repository = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let media = repository.appendingPathComponent("docs/media", isDirectory: true)
        try png(size: 256, surface: .interface).write(to: media.appendingPathComponent("icon-256.png"))
        try png(size: 96, surface: .interface).write(to: media.appendingPathComponent("favicon-96.png"))
        let icon = try ico()
        try icon.write(to: media.appendingPathComponent("favicon.ico"))
        try icon.write(to: repository.appendingPathComponent("apps/windows/TypeLeast/Assets/TypeLeast.ico"))
        print("Created \(artwork.path) and \(iconset.path)")
    }
}
