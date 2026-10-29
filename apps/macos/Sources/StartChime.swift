import AppKit

// StartChime.swift - the two cue sounds, synthesised once in memory: a soft "登登".
// Start rises (G4 then C5), stop falls (G4 then D4). Near-pure sine notes with an 8 ms
// attack and a natural exponential tail (no hard cut-off), quiet, about 0.46 s in all.

enum StartChime {
    static let sampleRate: UInt32 = 44100

    /// 16-bit mono PCM of the start sound (rising).
    static func pcm() -> Data { render([(0.0, 392.0, 0.045, 0.13), (0.13, 523.3, 0.085, 0.15)]) }

    /// 16-bit mono PCM of the stop sound (falling).
    static func stopPCM() -> Data { render([(0.0, 392.0, 0.045, 0.13), (0.13, 293.7, 0.085, 0.16)]) }

    /// (start time, frequency, decay time, peak) per note; a 2% third partial keeps it from sounding hollow.
    private static func render(_ notes: [(Double, Double, Double, Double)]) -> Data {
        let rate = Double(sampleRate)
        let total = Int(rate * 0.46)
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / rate
            var v = 0.0
            for (start, freq, decay, peak) in notes where t >= start {
                let local = t - start
                let envelope = min(1.0, local / 0.008) * exp(-local / decay)
                v += peak * envelope * (sin(2 * .pi * freq * local) + 0.02 * sin(6 * .pi * freq * local))
            }
            v *= min(1.0, Double(total - i) / (rate * 0.03))   // 30 ms fade-out: no click at the end
            samples[i] = Int16(max(-1.0, min(1.0, v)) * Double(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let sound: NSSound? = NSSound(data: Wav.wrap(pcm: pcm(), sampleRate: sampleRate))
    static let stopSound: NSSound? = NSSound(data: Wav.wrap(pcm: stopPCM(), sampleRate: sampleRate))
}
