import Foundation

/// Receives capture levels at 20 Hz and renders outward pulses on the animation clock.
struct VoiceWaveform {
    static let count = 10
    static let restingHeight: Double = 2
    static let peakHeight: Double = 26
    private static let lead: TimeInterval = 0.080
    private static let step: TimeInterval = 0.017
    private static let jitter: TimeInterval = 0.002
    private static let outerJitter: TimeInterval = 0.005
    private static let outerVariation = 0.88...1.12
    private static let attack: TimeInterval = 0.026
    private static let releaseStart: TimeInterval = attack + 0.012
    private static let decay: TimeInterval = 0.170
    private static let trailingDelay: ClosedRange<TimeInterval> = 0.008...0.012
    private static let trailingGain = 0.80...0.88
    private static let leftAccentColumn = count / 2 - 2
    private static let rightAccentColumn = count / 2 + 1
    private static let distances = (0..<count).map { max(count / 2 - 1 - $0, $0 - count / 2) }

    private struct Column {
        let delay: TimeInterval
        let gain: Double
    }

    private struct Pulse {
        let start: TimeInterval
        let amplitude: Double
        let columns: [Column]
        let accentColumn: Int

        var end: TimeInterval { start + Self.lastOffset + VoiceWaveform.releaseStart + VoiceWaveform.decay }

        private static let lastOffset = VoiceWaveform.step * Double(VoiceWaveform.count / 2 - 1)
            + VoiceWaveform.outerJitter + VoiceWaveform.trailingDelay.upperBound
    }

    private(set) var heights = [Double](repeating: restingHeight, count: count)
    private var pulses: [Pulse] = []
    private var drawnHeights = [Double](repeating: restingHeight, count: count)

    mutating func reset() { self = VoiceWaveform() }

    mutating func receive(_ level: Float, at now: TimeInterval, reduceMotion: Bool,
                          random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
        let volume = level.isFinite ? Double(min(1, max(0, level))) : 0
        // Soft input stays compact. Blend smoothly into the taller range as speech gets stronger.
        let blend = min(1, max(0, (volume - 0.54) / 0.22))
        let heightGain = 0.42 + 0.58 * blend * blend * (3 - 2 * blend)
        let amplitude = volume * heightGain * (Self.peakHeight - Self.restingHeight)
        if reduceMotion {
            pulses.removeAll(keepingCapacity: true)
            for (index, distance) in Self.distances.enumerated() {
                let gain = Self.gain(at: distance, isAccent: index == Self.rightAccentColumn)
                heights[index] = Self.restingHeight + amplitude * gain
            }
            return
        }
        guard volume > 0, volume == 1 || random(0...1) < volume else { return }
        // Choose the bias once per sound-driven pulse. The leading side keeps
        // the measured peak; the following side is only delayed and softened.
        let leadsOnLeft = random(0...1) < 0.5
        let delay = random(Self.trailingDelay)
        let gain = random(Self.trailingGain)
        pulses.removeAll { $0.end <= now }
        // Keep overlapping pulses on the same third column so they cannot light up a fourth.
        let accentColumn = pulses.last?.accentColumn ?? (leadsOnLeft ? Self.leftAccentColumn : Self.rightAccentColumn)
        let columns = Self.distances.enumerated().map { index, distance in
            let follows = (index < Self.count / 2) != leadsOnLeft
            let jitter = distance == 0 ? Self.jitter : Self.outerJitter
            let variation = distance == 0 ? 1 : random(Self.outerVariation)
            let spread = Double(distance) * Self.step + random(-jitter...jitter)
            let spatialGain = Self.gain(at: distance, isAccent: index == accentColumn)
            return Column(delay: spread + (follows ? delay : 0), gain: spatialGain * variation * (follows ? gain : 1))
        }
        pulses.append(Pulse(start: now + Self.lead, amplitude: amplitude, columns: columns, accentColumn: accentColumn))
    }

    @discardableResult
    mutating func advance(at now: TimeInterval) -> Bool {
        pulses.removeAll { $0.end <= now }
        for index in heights.indices {
            var peak: Double = 0
            for pulse in pulses {
                let column = pulse.columns[index]
                let age = now - pulse.start - column.delay
                guard age > 0, age < Self.releaseStart + Self.decay else { continue }
                let tail = 1 - max(0, age - Self.releaseStart) / Self.decay
                let envelope = age < Self.attack ? age / Self.attack : tail * tail
                peak = max(peak, pulse.amplitude * column.gain * envelope)
            }
            heights[index] = Self.restingHeight + peak
        }

        let dirty = zip(heights, drawnHeights).contains {
            abs($0 - $1) >= 0.05 || ($0 == Self.restingHeight && $1 != $0)
        }
        if dirty { drawnHeights = heights }
        return dirty
    }

    private static func gain(at distance: Int, isAccent: Bool) -> Double {
        if distance == 0 { return 1 }
        if isAccent { return 0.62 }
        return 1.30 * max(0.07, 0.27 - 0.05 * Double(distance))
    }
}
