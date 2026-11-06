import Foundation
import XCTest
@testable import mlx_asr

final class WorkerTests: XCTestCase {
    private func wav(samples: [Int16], channels: UInt16 = 1, rate: UInt32 = 16_000) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(channels)
        append(rate); append(rate * UInt32(channels) * 2)
        append(channels * 2); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(samples.count * 2))
        for sample in samples { append(UInt16(bitPattern: sample)) }
        return data
    }

    func testWavSamplesAndMalformedInput() throws {
        let decoded = try decodeWav(wav(samples: [0, 16384, -16384]))
        XCTAssertEqual(decoded, [0, 0.5, -0.5])
        XCTAssertThrowsError(try decodeWav(wav(samples: [1], channels: 2)))
        XCTAssertThrowsError(try decodeWav(wav(samples: [1], rate: 48_000)))
        XCTAssertThrowsError(try decodeWav(wav(samples: [])))
        XCTAssertThrowsError(try decodeWav(Data("not audio".utf8)))
    }

    func testSegmentationRetainsEverySampleInOrder() {
        var input = [Float](repeating: 0.3, count: 16_000 * 47 + 13)
        for i in (16_000 * 17)..<(16_000 * 17 + 1280) { input[i] = 0 }
        let ranges = boundaries(input)
        XCTAssertGreaterThan(ranges.count, 1)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, input.count)
        for pair in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
        }
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 16_000 * 20 })
        XCTAssertEqual(ranges.flatMap { input[$0] }, input)
    }

    func testJoiningLatinAndChineseSegments() {
        XCTAssertEqual(join("hello", "world"), "hello world")
        XCTAssertEqual(join("你好", "世界"), "你好世界")
        XCTAssertEqual(join("", "hello"), "hello")
    }

    func testOnlyAutomaticQwenLanguageIsReportedAsDetected() {
        XCTAssertEqual(detectedLanguageCode(modelType: "qwen3_asr", requested: "auto", reported: "Japanese"), "ja")
        XCTAssertEqual(detectedLanguageCode(modelType: "qwen3_asr", requested: "auto", reported: "Chinese"), "zh")
        XCTAssertNil(detectedLanguageCode(modelType: "qwen3_asr", requested: "zh", reported: "Chinese"))
        XCTAssertNil(detectedLanguageCode(modelType: "fun_asr_nano", requested: "auto", reported: "Chinese"))
        XCTAssertNil(detectedLanguageCode(modelType: "qwen3_asr", requested: "auto", reported: nil))
        XCTAssertNil(detectedLanguageCode(modelType: "qwen3_asr", requested: "auto", reported: "unknown"))
    }

    func testNoiseHintDoesNotTreatWeakVoiceOrSilenceAsNoise() {
        let count = 16_000 * 3
        var state: UInt32 = 41
        func nextNoise() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int((state >> 16) % 7) - 3) / 32_768
        }
        let whiteNoise = (0..<count).map { _ in nextNoise() }
        XCTAssertTrue(isLikelyStationaryNoise(whiteNoise[...]))
        // Different microphones can amplify the same stationary noise. The
        // level increase must not make a hallucination automatically usable.
        for gain: Float in [16, 64, 128] {
            let amplifiedNoise = whiteNoise.map { $0 * gain }
            XCTAssertTrue(isLikelyStationaryNoise(amplifiedNoise[...]), "gain: \(gain)")
        }
        XCTAssertFalse(isLikelyStationaryNoise(whiteNoise.prefix(8_000)))
        let zero = [Float](repeating: 0, count: count)
        XCTAssertFalse(isLikelyStationaryNoise(zero[...]))
        // Very quiet voiced sound, with silence on both sides and in the middle.
        let voice = (0..<count).map { i -> Float in
            guard (4_000..<20_000).contains(i) || (25_000..<43_000).contains(i) else { return 0 }
            return (3 * sin(Float(i) * 2 * .pi * 200 / 16_000)).rounded() / 32_768
        }
        XCTAssertFalse(isLikelyStationaryNoise(voice[...]))
        let lowTone = (0..<count).map { i in
            (3 * sin(Float(i) * 2 * .pi * 60 / 16_000)).rounded() / 32_768
        }
        XCTAssertTrue(isLikelyStationaryNoise(lowTone[...]))
        let amplifiedTone = lowTone.map { $0 * 32 }
        XCTAssertTrue(isLikelyStationaryNoise(amplifiedTone[...]))
        let louderHum = (0..<count).map { i in
            (256 * sin(Float(i) * 2 * .pi * 60 / 16_000)).rounded() / 32_768
        }
        XCTAssertTrue(isLikelyStationaryNoise(louderHum[...]))
        // A continuous weak vowel is also periodic; do not treat a typical
        // voice pitch as mains hum just because it has a steady level.
        let heldVowel = (0..<count).map { i in
            (32 * sin(Float(i) * 2 * .pi * 200 / 16_000)).rounded() / 32_768
        }
        XCTAssertFalse(isLikelyStationaryNoise(heldVowel[...]))
        let speechWithNoise = voice.map { $0 + nextNoise() / 3 }
        XCTAssertFalse(isLikelyStationaryNoise(speechWithNoise[...]))
        let noiseThenVoice = whiteNoise + voice
        XCTAssertFalse(isLikelyStationaryNoise(noiseThenVoice[...]))
        let voiceThenNoise = voice + whiteNoise
        XCTAssertFalse(isLikelyStationaryNoise(voiceThenNoise[...]))
        let longNoiseThenVoice = Array(repeating: whiteNoise, count: 20).flatMap { $0 } + voice
        XCTAssertFalse(isLikelyStationaryNoise(longNoiseThenVoice[...]))
    }

}
