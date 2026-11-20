import Foundation

/// Tracks capture levels on the animation clock and gives nearby columns a slight delay.
struct VoiceWaveform {
    static let count = 10
    static let restingHeight: Double = 2
    static let peakHeight: Double = 26

    private static let attack: TimeInterval = 0.020
    private static let release: TimeInterval = 0.052
    private static let sampleTimeout: TimeInterval = 0.12
    private static let phrasePause: TimeInterval = 0.20
    private static let minimumEnvelope = 0.008
    private static let leftMiddle = count / 2 - 1
    private static let rightMiddle = count / 2
    private static let leftAccent = leftMiddle - 1
    private static let rightAccent = rightMiddle + 1
    private static let step: TimeInterval = 0.016
    private static let longestDelay = step * Double(leftMiddle)

    /// Each level starts a continuous segment. Keep only the history the delayed columns need.
    private struct Segment {
        let time: TimeInterval
        let from: Double
        let target: Double

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
    private var lastVoiceAt: TimeInterval?
    private var leadsOnLeft = true

    mutating func reset() { self = VoiceWaveform() }

    mutating func receive(_ level: Float, at now: TimeInterval, reduceMotion: Bool) {
        let volume = level.isFinite ? Double(min(1, max(0, level))) : 0
        // The capture meter boosts quiet signals with a fourth root. Restore some
        // of the dynamic range so quiet speech moves the middle columns only a little.
        let calibratedLevel = volume * volume
        let amplitude = pow(min(1, max(0, (calibratedLevel - 0.036) / 0.95)), 0.88)
        if reduceMotion {
            segments.removeAll(keepingCapacity: true)
            lastVoiceAt = nil
            leadsOnLeft = true
            for index in heights.indices {
                heights[index] = Self.columnHeight(amplitude, at: index, lead: Self.leftMiddle,
                                                   accent: Self.rightAccent, texture: 0, reduceMotion: true)
            }
            return
        }
        let previous = segments.last
        if let previous, now < previous.time { return }
        if amplitude > 0 {
            if let lastVoiceAt, now >= lastVoiceAt + Self.phrasePause {
                leadsOnLeft.toggle()
            }
            lastVoiceAt = now
        }
        let from = previous?.value(at: now) ?? 0
        while segments.count > 1 && segments[1].time <= now - Self.longestDelay {
            segments.removeFirst()
        }
        let segment = Segment(time: now, from: from, target: amplitude)
        if previous?.time == now {
            segments[segments.count - 1] = segment
        } else {
            segments.append(segment)
        }
    }

    @discardableResult
    mutating func advance(at now: TimeInterval) -> Bool {
        let lead = leadsOnLeft ? Self.leftMiddle : Self.rightMiddle
        let follow = leadsOnLeft ? Self.rightMiddle : Self.leftMiddle
        let accent = leadsOnLeft ? Self.leftAccent : Self.rightAccent
        for index in heights.indices {
            let delay = index == lead ? 0 : index == follow ? 0.012 : index == accent ? 0.030 :
                Self.step * Double(Self.distance(fromMiddle: index))
            let time = now - delay
            let segment = segments.last { $0.time <= time }
            let amplitude = segment?.value(at: time) ?? 0
            let texture = amplitude > 0 && index != lead && index != follow && index != accent
                ? sin(time * (9 + Double(index) * 0.71) + Double(index) * 2.33) : 0
            heights[index] = Self.columnHeight(amplitude, at: index, lead: lead, accent: accent, texture: texture)
        }
        let dirty = zip(heights, drawnHeights).contains {
            abs($0 - $1) >= 0.05 || ($0 == Self.restingHeight && $1 != $0)
        }
        if dirty { drawnHeights = heights }
        return dirty
    }

    private static func distance(fromMiddle index: Int) -> Int {
        max(leftMiddle - index, index - rightMiddle)
    }

    private static let centerLogRange = log(4.0)
    private static let outerLogRange = log(25.0)

    private static func columnHeight(_ amplitude: Double, at index: Int, lead: Int, accent: Int,
                                     texture: Double, reduceMotion: Bool = false) -> Double {
        let distance = distance(fromMiddle: index)
        let excursion: Double
        if distance == 0 || index == accent {
            // Blend into the logarithmic response as speech reaches a moderate level.
            let blend = min(1, max(0, (amplitude - 0.18) / 0.49))
            let weight = blend * blend * (3 - 2 * blend)
            let quiet = 0.5 * amplitude
            let voiced = log1p(3 * amplitude) / centerLogRange
            let gain = index == accent ? 0.56 : (index == lead || reduceMotion ? 1 : 0.89)
            excursion = (quiet + (voiced - quiet) * weight) * gain
        } else {
            // A steeper logarithmic curve at the bottom makes quiet input visible at the edges.
            let soft = log1p(24 * amplitude) / outerLogRange
            let taper = max(0.05, 0.19 - Double(distance) * 0.035)
            excursion = soft * taper * (1 + 0.17 * texture)
        }
        return restingHeight + (peakHeight - restingHeight) * excursion
    }
}
