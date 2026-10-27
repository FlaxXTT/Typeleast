import Foundation

// Wav.swift - canonical 44-byte RIFF/PCM16 writer + parser (contract: 16 kHz mono PCM16, <= 24 MiB, <= 600 s).

enum Wav {
    static let sampleRate: UInt32 = 16000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16
    static let maxBytes = 24 * 1024 * 1024

    struct Info: Equatable {
        var audioFormat: UInt16
        var channels: UInt16
        var sampleRate: UInt32
        var byteRate: UInt32
        var blockAlign: UInt16
        var bitsPerSample: UInt16
        var headerBytes: Int
        var dataBytes: Int
        var riffSize: UInt32
        var totalBytes: Int
        var durationSeconds: Double { sampleRate == 0 || channels == 0 || bitsPerSample == 0 ? 0 : Double(dataBytes) / Double(byteRate) }
    }

    static func header(dataBytes: Int, sampleRate: UInt32 = Wav.sampleRate,
                       channels: UInt16 = Wav.channels, bits: UInt16 = Wav.bitsPerSample) -> Data {
        var d = Data()
        let blockAlign = channels * (bits / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let riffSize = UInt32(36 + dataBytes)
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE32(riffSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE32(16)
        d.appendLE16(1)                 // PCM
        d.appendLE16(channels)
        d.appendLE32(sampleRate)
        d.appendLE32(byteRate)
        d.appendLE16(blockAlign)
        d.appendLE16(bits)
        d.append(contentsOf: Array("data".utf8))
        d.appendLE32(UInt32(dataBytes))
        return d
    }

    static func wrap(pcm: Data, sampleRate: UInt32 = Wav.sampleRate,
                     channels: UInt16 = Wav.channels, bits: UInt16 = Wav.bitsPerSample) -> Data {
        var out = header(dataBytes: pcm.count, sampleRate: sampleRate, channels: channels, bits: bits)
        out.append(pcm)
        return out
    }

    static func write(pcm: Data, to url: URL) throws {
        let data = wrap(pcm: pcm)
        try data.write(to: url, options: .atomic)
    }

    static func parse(_ data: Data) -> Info? {
        guard data.count >= 44 else { return nil }
        func u32(_ o: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in (0..<4).reversed() { v = (v << 8) | UInt32(data[o + i]) }
            return v
        }
        func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | (UInt16(data[o + 1]) << 8) }
        func str(_ o: Int, _ n: Int) -> String {
            String(bytes: data[o..<(o + n)], encoding: .ascii) ?? ""
        }
        guard str(0, 4) == "RIFF", str(8, 4) == "WAVE" else { return nil }
        var offset = 12
        var info = Info(audioFormat: 0, channels: 0, sampleRate: 0, byteRate: 0, blockAlign: 0,
                        bitsPerSample: 0, headerBytes: 0, dataBytes: 0, riffSize: u32(4), totalBytes: data.count)
        while offset + 8 <= data.count {
            let id = str(offset, 4)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " && body + 16 <= data.count {
                info.audioFormat = u16(body)
                info.channels = u16(body + 2)
                info.sampleRate = u32(body + 4)
                info.byteRate = u32(body + 8)
                info.blockAlign = u16(body + 12)
                info.bitsPerSample = u16(body + 14)
            } else if id == "data" {
                info.headerBytes = body
                info.dataBytes = min(size, data.count - body)
                return info
            }
            offset = body + size + (size % 2)
        }
        return nil
    }

    /// True when the file is exactly the canonical 44-byte-header PCM16 layout the host expects.
    static func isCanonical(_ data: Data) -> Bool {
        guard let i = parse(data) else { return false }
        return i.headerBytes == 44
            && i.audioFormat == 1
            && i.channels == 1
            && i.sampleRate == 16000
            && i.bitsPerSample == 16
            && i.blockAlign == 2
            && i.byteRate == 32000
            && i.riffSize == UInt32(36 + i.dataBytes)
            && i.totalBytes == 44 + i.dataBytes
    }

    static func describe(_ data: Data) -> String {
        guard let i = parse(data) else { return "not a RIFF/WAVE file (" + String(data.count) + " bytes)" }
        let dur = String(format: "%.2fs", i.durationSeconds)
        return "RIFF/WAVE fmt=" + String(i.audioFormat)
            + " ch=" + String(i.channels)
            + " sr=" + String(i.sampleRate)
            + " bits=" + String(i.bitsPerSample)
            + " blockAlign=" + String(i.blockAlign)
            + " byteRate=" + String(i.byteRate)
            + " header=" + String(i.headerBytes) + "B"
            + " data=" + String(i.dataBytes) + "B"
            + " dur=" + dur
            + " canonical=" + String(isCanonical(data))
    }
}

extension Data {
    mutating func appendLE32(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE16(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
