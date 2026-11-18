import Foundation

/// The latest microphone level on the same decibel scale as the input meter.
struct VoiceLevel: Equatable {
    var volume: Float = 0
    var hasAudio = false
}

/// A real microphone peak enters in the centre and decays toward the edges.
/// The two halves follow the same envelope, with no generated pulses.
struct VoiceWaveform {
    static let count = 10
    static let restingHeight: Double = 2
    private static let pairCount = count / 2
    private static let peakHeight: Double = 20

    private(set) var heights = [Double](repeating: restingHeight, count: count)
    private var envelopes = [Double](repeating: 0, count: pairCount)
    private var drawnHeights = [Double](repeating: restingHeight, count: count)

    mutating func reset() { self = VoiceWaveform() }

    @discardableResult
    mutating func advance(level: VoiceLevel, delta: Double, reduceMotion: Bool) -> Bool {
        let dt = min(0.1, max(0, delta))
        let volume = level.hasAudio ? Double(Recorder.clampLevel(level.volume)) : 0
        let normalized = min(1, max(0, (volume - 0.10) / 0.80))
        let target = pow(normalized, 1.25) * (Self.peakHeight - Self.restingHeight)

        for pair in envelopes.indices.reversed() {
            if reduceMotion {
                envelopes[pair] = target
            } else {
                let input = pair == 0 ? target : envelopes[pair - 1]
                let smoothing = pair == 0 ? (input > envelopes[pair] ? 0.026 : 0.085) : 0.040
                envelopes[pair] += (input - envelopes[pair]) * (1 - exp(-dt / smoothing))
                if input == 0 && envelopes[pair] < 0.05 { envelopes[pair] = 0 }
            }
            let height = Self.restingHeight + envelopes[pair] * (1 - 0.16 * Double(pair))
            heights[Self.pairCount - 1 - pair] = height
            heights[Self.pairCount + pair] = height
        }

        let dirty = zip(heights, drawnHeights).contains { abs($0 - $1) >= 0.05 }
        if dirty { drawnHeights = heights }
        return dirty
    }
}
