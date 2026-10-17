import AVFoundation
import Foundation

// AudioConvert.swift - shared conversion: any input format -> 16 kHz mono PCM16 bytes.
// Extracted so the resampling path is unit-testable without a microphone.

enum AudioConvert {
    static let targetSampleRate: Double = 16000

    static func targetFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate,
                      channels: 1, interleaved: true)
    }

    static func makeConverter(from input: AVAudioFormat) -> AVAudioConverter? {
        guard let target = targetFormat() else { return nil }
        return AVAudioConverter(from: input, to: target)
    }

    /// Convert one input buffer; returns interleaved little-endian PCM16 mono bytes.
    static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                        to target: AVAudioFormat) -> Data? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 { return nil }
        guard let ch = out.int16ChannelData else { return nil }
        let bytes = Int(out.frameLength) * 2
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { memcpy(base, UnsafeRawPointer(ch[0]), bytes) }
        }
        return data
    }
}
