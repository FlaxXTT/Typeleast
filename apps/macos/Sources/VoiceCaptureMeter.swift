import Accelerate
import AVFoundation

/// Capture-side voice-band analyser. One instance belongs to one audio tap.
final class VoiceCaptureMeter {
    static let interval: TimeInterval = 0.05
    private static let size = 2048
    private static let smoothing: Float = 0.7
    private static let window = (0..<size).map { sample -> Float in
        let phase = 2 * Double.pi * Double(sample) / Double(size)
        return Float(0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase))
    }

    private let fft: vDSP_DFT_Setup
    private let samplesPerTick: Int
    private let voiceBins: ClosedRange<Int>
    private let binsPerBand: Float
    private let zeros = [Float](repeating: 0, count: size)
    private var ring = [Float](repeating: 0, count: size)
    private var input = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size)
    private var imaginary = [Float](repeating: 0, count: size)
    private var spectrum: [Float]
    private var frameLevels = [Float](repeating: 0, count: 3)
    private var nextLevel = 0
    private var writeIndex = 0
    private var pendingSamples = 0
    private var noiseFloor: Float = 0
    private(set) var level: Float = 0

    init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate >= 2_200 else { return nil }
        let binWidth = sampleRate / Double(Self.size)
        let first = max(1, Int(ceil(109 / binWidth)))
        let last = min(Self.size / 2 - 1, Int(floor(1094 / binWidth)))
        guard first <= last,
              let fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.size), .FORWARD) else { return nil }
        self.fft = fft
        samplesPerTick = Int((sampleRate * Self.interval).rounded())
        voiceBins = first...last
        binsPerBand = Float((1094 - 109) / binWidth)
        spectrum = [Float](repeating: 0, count: voiceBins.count)
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    func append(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.stride
        guard count > 0, channels > 0 else { return }
        if let values = buffer.floatChannelData {
            append(count: count) { frame in
                (0..<channels).reduce(0) { $0 + values[$1][frame * stride] } / Float(channels)
            }
        } else if let values = buffer.int16ChannelData {
            append(count: count) { frame in
                (0..<channels).reduce(0) { $0 + Float(values[$1][frame * stride]) } / (32768 * Float(channels))
            }
        } else if let values = buffer.int32ChannelData {
            append(count: count) { frame in
                (0..<channels).reduce(0) { $0 + Float(values[$1][frame * stride]) } / (2147483648 * Float(channels))
            }
        }
    }

    func append(count: Int, sample: (Int) -> Float) {
        for index in 0..<count {
            let value = sample(index)
            ring[writeIndex] = value.isFinite ? value : 0
            writeIndex = (writeIndex + 1) % Self.size
            pendingSamples += 1
            if pendingSamples == samplesPerTick {
                pendingSamples = 0
                updateLevel()
            }
        }
    }

    private func updateLevel() {
        for index in 0..<Self.size {
            input[index] = ring[(writeIndex + index) % Self.size] * Self.window[index]
        }
        vDSP_DFT_Execute(fft, input, zeros, &real, &imaginary)
        var bandSum: Float = 0
        for (index, bin) in voiceBins.enumerated() {
            let magnitude = hypot(real[bin], imaginary[bin]) * (2 / Float(Self.size))
            spectrum[index] = Self.smoothing * spectrum[index] + (1 - Self.smoothing) * magnitude
            bandSum += spectrum[index]
        }
        let bandMean = bandSum / Float(voiceBins.count)
        // Refer the mean to the same bandwidth at every input sample rate.
        frameLevels[nextLevel] = bandMean * binsPerBand
        nextLevel = (nextLevel + 1) % frameLevels.count
        let energy = frameLevels.reduce(0, +) / Float(frameLevels.count)

        // The floor follows room noise in pauses, with a slower rise during speech.
        let margin: Float = 0.004
        let drift = energy - noiseFloor
        let weight: Float = drift > margin ? 0.03 : 0.12
        noiseFloor += min(drift, 0.016) * weight
        let signal = min(1, max(0, (energy - noiseFloor - margin) / 0.14))
        level = pow(signal, 0.25)
    }
}
