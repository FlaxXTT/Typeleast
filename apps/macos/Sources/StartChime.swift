import AppKit

// StartChime.swift - the "recording started" sound: two soft, mid notes rising
// (E5 then A5) with a 6 ms attack and a rounded decay, synthesised once in memory.
// Quieter and warmer than the earlier bright E6/B6 chime. The stop sound is unchanged.

enum StartChime {
    static let sampleRate: UInt32 = 44100

    /// 16-bit mono PCM of the chime.
    static func pcm() -> Data {
        let rate = Double(sampleRate)
        let total = Int(rate * 0.30)
        // (start time, frequency, peak) per note; a faint octave partial keeps it from sounding hollow.
        let notes: [(Double, Double, Double)] = [(0.0, 659.3, 0.20), (0.07, 880.0, 0.22)]
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / rate
            var v = 0.0
            for (start, freq, peak) in notes where t >= start {
                let local = t - start
                let attack = min(1.0, local / 0.006)
                let envelope = attack * exp(-local / 0.09)
                v += peak * envelope * (sin(2 * .pi * freq * local) + 0.08 * sin(4 * .pi * freq * local))
            }
            v *= min(1.0, Double(total - i) / (rate * 0.03))   // 30 ms fade-out: no click at the end
            samples[i] = Int16(max(-1.0, min(1.0, v)) * Double(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let sound: NSSound? = NSSound(data: Wav.wrap(pcm: pcm(), sampleRate: sampleRate))
}
