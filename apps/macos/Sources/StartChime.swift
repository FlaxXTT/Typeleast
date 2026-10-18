import AppKit

// StartChime.swift - the "recording started" sound: two short, bright notes
// (E6 then B6) with a 2 ms attack and a fast decay, synthesised once in memory.
// Replaces the system "Tink", which sounds dull. The stop sound is unchanged.

enum StartChime {
    static let sampleRate: UInt32 = 44100

    /// 16-bit mono PCM of the chime.
    static func pcm() -> Data {
        let rate = Double(sampleRate)
        let total = Int(rate * 0.24)
        // (start time, frequency, peak) per note; each note has a soft octave partial for sparkle.
        let notes: [(Double, Double, Double)] = [(0.0, 1318.5, 0.30), (0.075, 1975.5, 0.34)]
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / rate
            var v = 0.0
            for (start, freq, peak) in notes where t >= start {
                let local = t - start
                let attack = min(1.0, local / 0.002)
                let envelope = attack * exp(-local / 0.055)
                v += peak * envelope * (sin(2 * .pi * freq * local) + 0.25 * sin(4 * .pi * freq * local))
            }
            v *= min(1.0, Double(total - i) / (rate * 0.03))   // 30 ms fade-out: no click at the end
            samples[i] = Int16(max(-1.0, min(1.0, v)) * Double(Int16.max))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static let sound: NSSound? = NSSound(data: Wav.wrap(pcm: pcm(), sampleRate: sampleRate))
}
