import Foundation
import AVFoundation
import Accelerate

/// One bounded snapshot, copied from the audio callback to the voice-bar renderer.
struct VoiceLevel: Equatable {
    var volume: Float = 0
    var signal: Float = 0
    var response: Float = 0.12
    var hasAudio = false
}

enum VoiceResponse {
    static func height(_ signal: Float) -> Float {
        // Continuous joins keep small changes in voice level from causing a jump.
        if signal < 0.03 { return 0.12 + signal / 0.03 * 0.08 }
        if signal < 0.10 { return 0.20 + 0.26 * (signal - 0.03) / 0.07 }
        let t = min(1, (signal - 0.10) / 0.90)
        return 0.46 + 0.46 * pow(t, 0.65)
    }
}

/// A 2048-point Hann-windowed FFT on the capture callback, never on the UI thread.
/// Frequency bounds are in Hz: bin indices change with the input device's sample rate.
final class VoiceSpectrum {
    static let fftSize = 2048
    private let setup: vDSP_DFT_Setup
    private let firstBin: Int
    private let lastBin: Int
    private let hop: Int
    private let window: [Float]
    private let magnitudeScale: Float
    private var samples = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize)
    private var imaginary = [Float](repeating: 0, count: fftSize)
    private var outputReal = [Float](repeating: 0, count: fftSize)
    private var outputImaginary = [Float](repeating: 0, count: fftSize)
    private var spectrum = [Float](repeating: 0, count: fftSize / 2)
    private var write = 0
    private var count = 0
    private var sinceAnalysis = 0
    private var recent = [Float](repeating: 0, count: 3)
    private var recentCount = 0
    private var recentIndex = 0
    private var noiseFloor: Float = 0
    private(set) var latest = VoiceLevel()

    init(sampleRate: Double) {
        setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD)!
        firstBin = max(1, Int(ceil(328 * Double(Self.fftSize) / sampleRate)))
        lastBin = min(Self.fftSize / 2 - 1, Int(floor(3300 * Double(Self.fftSize) / sampleRate)))
        hop = max(1, Int(sampleRate * 0.05))
        window = (0..<Self.fftSize).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(Self.fftSize - 1))) }
        magnitudeScale = 2 / window.reduce(0, +)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return }
        let interleaved = buffer.format.isInterleaved
        for frame in 0..<Int(buffer.frameLength) {
            var mono: Float = 0
            for channel in 0..<channels {
                let row = interleaved ? 0 : channel
                let index = interleaved ? frame * channels + channel : frame
                if let values = buffer.floatChannelData { mono += values[row][index] }
                else if let values = buffer.int16ChannelData { mono += Float(values[row][index]) / 32768 }
                else if let values = buffer.int32ChannelData { mono += Float(values[row][index]) / 2147483648 }
            }
            append(mono / Float(channels))
        }
        if buffer.frameLength > 0 { latest.hasAudio = true }
    }

    func consumePCM16(_ pcm: Data) {
        pcm.withUnsafeBytes { bytes in
            for index in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
                append(Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: Int16.self))) / 32768)
            }
        }
        if !pcm.isEmpty { latest.hasAudio = true }
    }

    private func append(_ value: Float) {
        samples[write] = value.isFinite ? value : 0
        write = (write + 1) % Self.fftSize
        count = min(Self.fftSize, count + 1)
        sinceAnalysis += 1
        if count == Self.fftSize && sinceAnalysis >= hop {
            sinceAnalysis = 0
            analyse()
        }
    }

    private func analyse() {
        for index in 0..<Self.fftSize {
            real[index] = samples[(write + index) % Self.fftSize] * window[index]
        }
        real.withUnsafeBufferPointer { input in
            imaginary.withUnsafeBufferPointer { zero in
                outputReal.withUnsafeMutableBufferPointer { re in
                    outputImaginary.withUnsafeMutableBufferPointer { im in
                        vDSP_DFT_Execute(setup, input.baseAddress!, zero.baseAddress!, re.baseAddress!, im.baseAddress!)
                    }
                }
            }
        }
        var energy: Float = 0
        if firstBin <= lastBin {
            for bin in firstBin...lastBin {
                let re = outputReal[bin], im = outputImaginary[bin]
                let magnitude = sqrt(re * re + im * im) * magnitudeScale
                spectrum[bin] = spectrum[bin] * 0.7 + magnitude * 0.3
                // Web Audio's default -100...-30 dB range, expressed as 0...1.
                let db = 20 * log10(max(1e-8, spectrum[bin]))
                energy += min(1, max(0, (db + 100) / 70))
            }
            energy /= Float(lastBin - firstBin + 1)
        }
        recent[recentIndex] = energy
        recentIndex = (recentIndex + 1) % recent.count
        recentCount = min(recent.count, recentCount + 1)
        let volume = recent.reduce(0, +) / Float(recentCount)
        let alpha: Float = volume <= noiseFloor + 0.01 ? 0.06 : 0.002
        noiseFloor = min(0.35, max(0, noiseFloor * (1 - alpha) + volume * alpha))
        let signal = max(0, volume - noiseFloor - 0.006)
        latest = VoiceLevel(volume: volume, signal: signal, response: VoiceResponse.height(signal), hasAudio: true)
    }
}

/// Ten fixed bars; real voice energy enters at 20 Hz and travels outwards at 60 Hz.
/// Random variation is bounded and is only added to microphone-driven impulses.
struct VoiceWaveform {
    static let count = 10
    private struct Impulse {
        var due: Double
        var centre: Double
        var height: Double
        var reach: Double
        var applied: UInt16 = 0
    }
    private(set) var heights = [Double](repeating: 2, count: count)
    private(set) var opacities = [Double](repeating: 0.5, count: count)
    private var targets = [Double](repeating: 2, count: count)
    private var ages = [Double](repeating: 0, count: count)
    private var drawnHeights = [Double](repeating: 2, count: count)
    private var drawnOpacities = [Double](repeating: 0.5, count: count)
    private var impulses: [Impulse] = []
    private var time: Double = 0
    private var injectionTime: Double = 0
    private var capturedFor: Double = 0
    private var currentHeight: Double = 2
    private var active = false
    private var quietFor: Double = 0
    private var centreOffset: Double = 0
    private var targetCentreOffset: Double = 0
    private var randomState: UInt64 = 0x746970656C656173

    mutating func reset() { self = VoiceWaveform() }

    private mutating func random() -> Double {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Double(randomState >> 11) / 9007199254740992
    }

    @discardableResult
    mutating func advance(level: VoiceLevel, delta: Double, reduceMotion: Bool) -> Bool {
        let dt = max(0, min(0.1, delta))
        time += dt
        capturedFor = level.hasAudio ? capturedFor + dt : 0
        let centre = Double(Self.count - 1) / 2
        // Separate entry/exit thresholds keep breaths and short pauses from flickering.
        if !level.hasAudio {
            active = false
            quietFor = 0
        } else if active {
            quietFor = level.signal < 0.008 ? quietFor + dt : 0
            if quietFor >= 0.15 { active = false }
        } else if level.signal > 0.015 {
            active = true
            quietFor = 0
        }
        let target = active ? 2 + 14 * Double(level.response) : 2
        let responseTime = target > currentHeight ? 0.10 : 0.24
        currentHeight += (target - currentHeight) * (1 - exp(-dt / responseTime))
        // A new pulse picks a destination; the centre travels there instead of jumping.
        if !active { targetCentreOffset = 0 }
        centreOffset += (targetCentreOffset - centreOffset) * (1 - exp(-dt / 0.65))
        let voiceCentre = centre + centreOffset
        let reach = 2 + 3 * min(1, Double(level.signal) / 0.20)

        for index in heights.indices {
            let distance = abs(Double(index) - centre)
            opacities[index] = !level.hasAudio ? 0.5 : reduceMotion ? 1
                : 0.5 + 0.5 * min(1, max(0, (capturedFor - distance * 0.05) / 0.12))
            if reduceMotion {
                targets[index] = 2 + (currentHeight - 2) * max(0, 1 - distance / reach)
                continue
            }
            ages[index] += dt
            // The outer bars settle a little later than the centre bars.
            let release = 0.24 + distance / (centre + 0.5) * 0.08
            targets[index] = 2 + (targets[index] - 2) * exp(-dt / release)
            if ages[index] > 1.1 || targets[index] < 2.05 { targets[index] = 2 }
            if active {
                // Quiet speech stays near the centre; stronger speech spreads wider.
                let weight = max(0, 1 - abs(Double(index) - voiceCentre) / reach)
                targets[index] = max(targets[index], 2 + (currentHeight - 2) * weight)
            }
        }
        if reduceMotion {
            impulses.removeAll(keepingCapacity: true)
        } else {
            injectionTime += dt
            if injectionTime >= 0.05 {
                injectionTime.formTruncatingRemainder(dividingBy: 0.05)
                if active {
                    let variation = level.signal < 0.03 ? 0.01 : level.signal < 0.10 ? 0.04 : 0.06
                    let height = min(16, max(2, currentHeight + (random() * 2 - 1) * variation * 14))
                    if level.signal >= 0.10 && random() < min(0.6, Double(level.signal) * 1.5) {
                        targetCentreOffset = (random() * 2 - 1) * 1.2
                        impulses.append(Impulse(due: time + 0.08, centre: voiceCentre, height: height, reach: reach))
                    }
                }
            }
            for eventIndex in impulses.indices {
                for bar in heights.indices {
                    let bit = UInt16(1) << bar
                    if impulses[eventIndex].applied & bit != 0 { continue }
                    let distance = abs(Double(bar) - impulses[eventIndex].centre)
                    if time < impulses[eventIndex].due + distance * 0.014 { continue }
                    let decay = max(0, 1 - distance / impulses[eventIndex].reach)
                    let target = min(16, 2 + (impulses[eventIndex].height - 2) * decay * (0.95 + random() * 0.1))
                    targets[bar] = max(targets[bar], target)
                    ages[bar] = 0
                    impulses[eventIndex].applied |= bit
                }
            }
            impulses.removeAll { $0.applied == (UInt16(1) << Self.count) - 1 }
        }
        // Events change envelopes, never the displayed height. Each bar follows smoothly.
        for index in heights.indices {
            let distance = abs(Double(index) - centre)
            let response = targets[index] > heights[index] ? 0.045 : 0.18 + distance * 0.012
            heights[index] += (targets[index] - heights[index]) * (1 - exp(-dt / response))
            if targets[index] == 2 && heights[index] < 2.05 { heights[index] = 2 }
        }
        let dirty = zip(heights, drawnHeights).contains { abs($0 - $1) >= 0.05 }
            || zip(opacities, drawnOpacities).contains { abs($0 - $1) >= 0.01 }
        if dirty { drawnHeights = heights; drawnOpacities = opacities }
        return dirty
    }
}
