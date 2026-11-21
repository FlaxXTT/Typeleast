import Foundation

/// Tracks capture levels on the animation clock and delays the envelope from left to right.
struct VoiceWaveform {
    static let count = 10
    static let restingHeight: Double = 2
    static let peakHeight: Double = 26

    private static let attack: TimeInterval = 0.020
    private static let release: TimeInterval = 0.052
    private static let sampleTimeout: TimeInterval = 0.12
    private static let phraseGap: TimeInterval = 0.18
    private static let speechThreshold = 0.08
    private static let minimumEnvelope = 0.008
    private static let leftMiddle = count / 2 - 1
    private static let rightMiddle = count / 2
    private static let leftShoulder = leftMiddle - 1
    private static let rightShoulder = rightMiddle + 1
    // The three main columns get more time between their onsets than the small edge columns.
    private static let delays: [TimeInterval] = [0, 0.006, 0.012, 0.020, 0.044, 0.068, 0.082, 0.090, 0.098, 0.106]
    private static let columnGains: [Double] = [0.055, 0.125, 0.20, 0.54, 0.73, 0.63, 0.323, 0.20, 0.125, 0.055]
    private static let variationAmount = 0.10
    private static let longestDelay = delays[count - 1]

    /// Each level starts a continuous segment. Keep only the history the delayed columns need.
    private struct Segment {
        let time: TimeInterval
        let from: Double
        let target: Double
        let liftedEnds: (left: Bool, right: Bool)

        func value(at now: TimeInterval) -> Double {
            let elapsed = max(0, now - time)
            let response = target > from ? VoiceWaveform.attack : VoiceWaveform.release
            let held = min(elapsed, VoiceWaveform.sampleTimeout)
            let value = target + (from - target) * exp(-held / response)
            let expired = max(0, elapsed - VoiceWaveform.sampleTimeout)
            let amplitude = expired > 0 ? value * exp(-expired / VoiceWaveform.release) : value
            return amplitude < VoiceWaveform.minimumEnvelope ? 0 : amplitude
        }
    }

    private(set) var heights = [Double](repeating: restingHeight, count: count)
    private var drawnHeights = [Double](repeating: restingHeight, count: count)
    private var segments: [Segment] = []
    private var edgePhases = SIMD3<Double>.zero
    private var lastSpeechAt: TimeInterval?

    mutating func reset(edgePhases: SIMD3<Double> = .zero) {
        self = VoiceWaveform()
        self.edgePhases = edgePhases
    }

    mutating func receive(_ level: Float, at now: TimeInterval, reduceMotion: Bool,
                          drawEndpointLift: () -> Bool = { Int.random(in: 0..<5) == 0 }) {
        let volume = level.isFinite ? Double(min(1, max(0, level))) : 0
        // The capture meter boosts quiet signals with a fourth root. Restore some
        // of the dynamic range so quiet speech moves the middle columns only a little.
        let calibratedLevel = volume * volume
        let amplitude = pow(min(1, max(0, (calibratedLevel - 0.036) / 0.95)), 0.88)
        if reduceMotion {
            segments.removeAll(keepingCapacity: true)
            lastSpeechAt = nil
            for index in heights.indices {
                heights[index] = Self.columnHeight(amplitude, at: index, texture: 0)
            }
            return
        }
        let previous = segments.last
        if let previous, now < previous.time { return }
        let from = previous?.value(at: now) ?? 0
        var liftedEnds = previous?.liftedEnds ?? (left: false, right: false)
        if amplitude >= Self.speechThreshold {
            // Choose once at the onset of a phrase so the shape does not flicker between frames.
            if lastSpeechAt.map({ now - $0 >= Self.phraseGap }) ?? true {
                liftedEnds = (left: drawEndpointLift(), right: drawEndpointLift())
            }
            lastSpeechAt = now
        }
        while segments.count > 1 && segments[1].time <= now - Self.longestDelay {
            segments.removeFirst()
        }
        let segment = Segment(time: now, from: from, target: amplitude, liftedEnds: liftedEnds)
        if previous?.time == now {
            segments[segments.count - 1] = segment
        } else {
            segments.append(segment)
        }
    }

    @discardableResult
    mutating func advance(at now: TimeInterval) -> Bool {
        for index in heights.indices {
            let time = now - Self.delays[index]
            let segment = segments.last { $0.time <= time }
            let amplitude = segment?.value(at: time) ?? 0
            let texture = amplitude > 0 && !(Self.leftShoulder...Self.rightMiddle).contains(index)
                ? edgeVariation(at: time, column: index) : 0
            let lift = index == 0 && segment?.liftedEnds.left == true
                || index == Self.count - 1 && segment?.liftedEnds.right == true
            heights[index] = Self.columnHeight(amplitude, at: index, texture: texture, liftEndpoint: lift)
        }
        let dirty = zip(heights, drawnHeights).contains {
            abs($0 - $1) >= 0.05 || ($0 == Self.restingHeight && $1 != $0)
        }
        if dirty { drawnHeights = heights }
        return dirty
    }

    private func edgeVariation(at time: TimeInterval, column index: Int) -> Double {
        let column = Double(index)
        let phase = edgePhases[index % 3]
        return 0.7 * sin(time * (9 + column * 0.71) + column * 2.33 + phase)
            + 0.3 * sin(time * (5 + column * 0.47) - column * 1.31 - phase)
    }

    private static let centerLogRange = log(4.0)
    private static let outerLogRange = log(25.0)

    private static func columnHeight(_ amplitude: Double, at index: Int, texture: Double,
                                     liftEndpoint: Bool = false) -> Double {
        let excursion: Double
        let gain = columnGains[index]
        if (leftShoulder...rightMiddle).contains(index) {
            // Blend into the logarithmic response as speech reaches a moderate level.
            let blend = min(1, max(0, (amplitude - 0.18) / 0.49))
            let weight = blend * blend * (3 - 2 * blend)
            let quiet = 0.5 * amplitude
            let voiced = log1p(3 * amplitude) / centerLogRange
            let shaped = quiet + (voiced - quiet) * weight
            // Give the two center columns more lift during speech without clipping at the peak.
            let lift = index == leftMiddle || index == rightMiddle
                ? 0.42 * weight * shaped * (1 - shaped) : 0
            // The middle columns share the voice envelope, with separate gains and delays.
            excursion = (shaped + lift) * gain
        } else {
            // A steeper logarithmic curve at the bottom makes quiet input visible at the edges.
            let soft = log1p(24 * amplitude) / outerLogRange
            // The right shoulder gains a little more travel at speech levels while staying quiet at onset.
            let shoulder = index == rightShoulder ? 0.45 + 0.55 * min(1, amplitude / 0.64) : 1
            let endpoint = liftEndpoint ? 1.3 : 1
            excursion = soft * gain * shoulder * endpoint * (1 + variationAmount * texture)
        }
        return restingHeight + (peakHeight - restingHeight) * excursion
    }
}
