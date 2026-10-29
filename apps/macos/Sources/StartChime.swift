import AppKit

// StartChime.swift - the two cue sounds, synthesised once in memory: a blunt "嘟嘟".
// Start rises (G4 then C5), stop falls (C5 then G4). Pure sine notes with a soft
// 12 ms attack and a short rounded decay, so they sound dull rather than sharp.

enum StartChime {
    static let sampleRate: UInt32 = 44100

    /// 16-bit mono PCM of the start sound (rising).
    static func pcm() -> Data { render([(0.0, 392.0), (0.11, 523.3)]) }

    /// 16-bit mono PCM of the stop sound (falling).
    static func stopPCM() -> Data { render([(0.0, 523.3), (0.11, 392.0)]) }

    /// (start time, frequency) per note; every note is the same soft "嘟".
    private static func render(_ notes: [(Double, Double)]) -> Data {
        let rate = Double(sampleRate)
        let total = Int(rate * 0.26)
        let length = 0.095, peak = 0.22
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / rate
            var v = 0.0
            for (start, freq) in notes where t >= start && t < start + length {
                let local = t - start
                let attack = min(1.0, local / 0.012)
                let release = min(1.0, (length - local) / 0.025)
                v += peak * attack * release * exp(-local / 0.12) * sin(2 * .pi * freq * local)
            }
            samples[i] = Int16(max(-1.0, min(1.0, v)) * Double(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let sound: NSSound? = NSSound(data: Wav.wrap(pcm: pcm(), sampleRate: sampleRate))
    static let stopSound: NSSound? = NSSound(data: Wav.wrap(pcm: stopPCM(), sampleRate: sampleRate))
}
