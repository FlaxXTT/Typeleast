import Darwin
import Foundation
import MLX
import MLXAudioSTT

// Protocol: "serve --model-dir /absolute/path" writes {"ready":true}, then
// accepts newline-delimited JSON headers {"language":"auto","bytes":N}
// followed by exactly N bytes of 16 kHz mono PCM16 WAV. Each response is one
// JSON line. A client cancels inference by terminating this process.
// "probe --model-dir /absolute/path" validates and loads the model once.
// Neither the current audio nor its transcript is written to disk or logs.

private enum WorkerError: Error {
    case arguments, model, protocolError, audio, output
}

private struct Request: Decodable {
    let language: String
    let bytes: Int
}

private let maximumWavBytes = 24 * 1024 * 1024
private let sampleRate = 16_000
private let input = FileHandle.standardInput

private func readExactly(_ count: Int) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        guard let part = try input.read(upToCount: count - result.count), !part.isEmpty else {
            throw WorkerError.protocolError
        }
        result.append(part)
    }
    return result
}

private func readHeader() throws -> Data? {
    var header = Data()
    while header.count <= 4096 {
        guard let byte = try input.read(upToCount: 1), !byte.isEmpty else {
            if header.isEmpty { return nil }
            throw WorkerError.protocolError
        }
        if byte[byte.startIndex] == 10 { return header }
        header.append(byte)
    }
    throw WorkerError.protocolError
}

private func uint16(_ data: Data, _ offset: Int) -> Int {
    Int(data[offset]) | (Int(data[offset + 1]) << 8)
}
private func uint32(_ data: Data, _ offset: Int) -> Int {
    uint16(data, offset) | (uint16(data, offset + 2) << 16)
}

func decodeWav(_ data: Data) throws -> [Float] {
    guard data.count >= 44, data.count <= maximumWavBytes,
          data.subdata(in: 0..<4) == Data("RIFF".utf8),
          data.subdata(in: 8..<12) == Data("WAVE".utf8),
          uint32(data, 4) == data.count - 8 else { throw WorkerError.audio }
    var offset = 12
    var formatOK = false
    var pcm: Range<Int>?
    while offset + 8 <= data.count {
        let id = data.subdata(in: offset..<(offset + 4))
        let size = uint32(data, offset + 4)
        let start = offset + 8
        guard size <= data.count - start else { throw WorkerError.audio }
        if id == Data("fmt ".utf8) {
            guard size >= 16, uint16(data, start) == 1, uint16(data, start + 2) == 1,
                  uint32(data, start + 4) == sampleRate, uint16(data, start + 14) == 16 else {
                throw WorkerError.audio
            }
            formatOK = true
        } else if id == Data("data".utf8) {
            guard pcm == nil, size > 0, size % 2 == 0 else { throw WorkerError.audio }
            pcm = start..<(start + size)
        }
        offset = start + size + (size & 1)
    }
    guard formatOK, let pcm else { throw WorkerError.audio }
    var samples = [Float]()
    samples.reserveCapacity(pcm.count / 2)
    for index in stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2) {
        let bits = UInt16(uint16(data, index))
        samples.append(Float(Int16(bitPattern: bits)) / 32768.0)
    }
    return samples
}

// Split only when needed, at the quietest short window near the end of the
// segment. No samples are dropped; the caller receives the exact boundaries.
func boundaries(_ samples: [Float]) -> [Range<Int>] {
    let maxSamples = sampleRate * 20
    let searchStart = sampleRate * 12
    let window = 1280
    var start = 0
    var result = [Range<Int>]()
    while samples.count - start > maxSamples {
        let end = start + maxSamples
        var best = start + searchStart
        var lowest = Float.infinity
        var cursor = best
        while cursor + window <= end {
            var energy: Float = 0
            for index in cursor..<(cursor + window) { energy += abs(samples[index]) }
            if energy < lowest { lowest = energy; best = cursor + window / 2 }
            cursor += window
        }
        result.append(start..<best)
        start = best
    }
    if start < samples.count { result.append(start..<samples.count) }
    return result
}

/// Flag narrow classes of low-level, stationary noise for review.
/// This is not a general speech detector: it must never discard the audio or the
/// recognizer's candidate, because weak speech and noise can be ambiguous.
func isLikelyStationaryNoise(_ samples: ArraySlice<Float>) -> Bool {
    let frameSize = 1_600 // 100 ms at 16 kHz
    guard samples.count >= sampleRate else { return false }
    var peak = 0.0, energy = 0.0, correlation = 0.0
    var previous = 0.0, havePrevious = false
    var previousSign = 0, zeroCrossings = 0, nonzero = 0
    var frameEnergy = 0.0, frameCount = 0
    var frameRMS = [Double]()
    frameRMS.reserveCapacity(samples.count / frameSize)
    for sample in samples {
        let value = Double(sample)
        guard value.isFinite else { return false }
        peak = max(peak, abs(value))
        // Keep the upper limit well below normal speech, but do not assume a
        // microphone's digital gain is identical on every device.
        if peak > 2_048.0 / 32_768.0 { return false }
        energy += value * value
        if havePrevious { correlation += value * previous }
        previous = value
        havePrevious = true
        let sign = value > 0 ? 1 : value < 0 ? -1 : 0
        if sign != 0 {
            nonzero += 1
            if previousSign != 0 && sign != previousSign { zeroCrossings += 1 }
            previousSign = sign
        }
        frameEnergy += value * value
        frameCount += 1
        if frameCount == frameSize {
            frameRMS.append(sqrt(frameEnergy / Double(frameCount)))
            frameEnergy = 0
            frameCount = 0
        }
    }
    guard energy > 0,
          Double(nonzero) / Double(samples.count) >= 0.7,
          frameRMS.count >= 2 else { return false }
    let mean = frameRMS.reduce(0, +) / Double(frameRMS.count)
    guard mean > 0 else { return false }
    let variance = frameRMS.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(frameRMS.count)
    let coefficientOfVariation = sqrt(variance) / mean
    let adjacentCorrelation = abs(correlation / energy)
    let crossingRate = Double(zeroCrossings) / Double(max(nonzero - 1, 1))
    // Even a small voice or pause can break the stationarity of a long noise
    // recording. If one complete frame differs substantially, do not mark the
    // entire recording based on its otherwise quiet background.
    guard frameRMS.allSatisfy({ abs($0 - mean) <= 0.35 * mean }) else { return false }
    // Higher-level audio needs stricter stationarity than the old extremely
    // quiet threshold. This is still only a review hint: a sustained whisper,
    // hiss or voiced sound can resemble noise, so it is never discarded.
    let veryQuiet = peak <= 32.0 / 32_768.0
    let broadband = mean <= 0.02 && adjacentCorrelation < 0.2 && crossingRate > 0.32
        && coefficientOfVariation < (veryQuiet ? 0.08 : 0.04)
    // Restrict the tonal case to approximately mains-frequency hum. A steady
    // low-level human vowel can otherwise resemble a clean periodic tone.
    let stableTone = mean <= 0.006 && adjacentCorrelation > 0.85
        && crossingRate >= 0.004 && crossingRate <= 0.0095
        && coefficientOfVariation < (veryQuiet ? 0.015 : 0.008)
    return broadband || stableTone
}

func join(_ left: String, _ right: String) -> String {
    guard !left.isEmpty else { return right }
    guard let a = left.unicodeScalars.last, let b = right.unicodeScalars.first else { return left + right }
    let latinOrDigit = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    return left + (latinOrDigit.contains(a) && latinOrDigit.contains(b) ? " " : "") + right
}

/// A language hint may be echoed by the library, so it is not detection.
func detectedLanguageCode(modelType: String, requested: String, reported: String?) -> String? {
    guard modelType == "qwen3_asr", requested == "auto", let reported else { return nil }
    let languageMap = ["chinese": "zh", "mandarin": "zh", "english": "en",
                       "japanese": "ja", "korean": "ko", "cantonese": "yue"]
    let value = reported.lowercased()
    return languageMap[value] ?? (["zh", "en", "ja", "ko", "yue"].contains(value) ? value : nil)
}

private func writeJSON(_ value: [String: Any], to output: FileHandle) throws {
    guard JSONSerialization.isValidJSONObject(value) else { throw WorkerError.output }
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(10)
    try output.write(contentsOf: data)
}

@main
private enum Main {
    static func main() async {
        // Third-party tokenizer setup can print to stdout. Keep stdout reserved
        // for protocol responses without copying its output into application logs.
        let protocolFD = dup(STDOUT_FILENO)
        let nullFD = open("/dev/null", O_WRONLY)
        guard protocolFD >= 0, nullFD >= 0, dup2(nullFD, STDOUT_FILENO) >= 0 else { exit(1) }
        close(nullFD)
        let output = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: true)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3, ["serve", "probe"].contains(args[0]), args[1] == "--model-dir",
                  args[2].hasPrefix("/") else { throw WorkerError.arguments }
            let directory = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw WorkerError.model }
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
            guard let modelType = config?["model_type"] as? String,
                  ["fun_asr_nano", "qwen3_asr"].contains(modelType) else { throw WorkerError.model }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let metalLibrary = executable.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
            guard FileManager.default.fileExists(atPath: metalLibrary.path) else { throw WorkerError.model }
            GPU.metallib = metalLibrary
            // An explicit local directory avoids implicit network model downloads.
            let model = try await STT.loadModel(modelRepo: directory.path, modelType: modelType)
            if args[0] == "probe" { return }
            try writeJSON(["ready": true], to: output)
            while let header = try readHeader() {
                let request = try JSONDecoder().decode(Request.self, from: header)
                guard request.bytes > 0, request.bytes <= maximumWavBytes,
                      ["auto", "zh", "en", "ja", "ko", "yue"].contains(request.language) else {
                    throw WorkerError.protocolError
                }
                let samples = try decodeWav(readExactly(request.bytes))
                let selectedLanguage = request.language == "auto" ? nil : request.language
                var text = ""
                var segments = [[String: Any]]()
                var detected = [String]()
                // Judge the whole recording. A quiet stretch inside a long
                // recording must not hold otherwise valid speech for review.
                let noiseSuspected = isLikelyStationaryNoise(samples[...])
                for range in boundaries(samples) {
                    // Do not invoke a generative recognizer on digital silence.
                    if samples[range].allSatisfy({ $0 == 0 }) { continue }
                    let audio = MLXArray(Array(samples[range]))
                    let parameters = STTGenerateParameters(maxTokens: 2048, temperature: 0, language: selectedLanguage)
                    let result = model.generate(audio: audio, generationParameters: parameters)
                    let part = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty {
                        text = join(text, part)
                        segments.append(["index": segments.count, "text": part,
                                         "startSample": range.lowerBound, "samples": range.count])
                        // A forced language is echoed by the library; it is
                        // not an independent detection of the audio language.
                        if modelType == "qwen3_asr" && request.language == "auto" {
                            detected.append(detectedLanguageCode(modelType: modelType, requested: request.language,
                                                                 reported: result.language) ?? "")
                        }
                    }
                }
                var response: [String: Any] = ["text": text, "segments": segments]
                if noiseSuspected { response["noiseSuspected"] = true }
                if let first = detected.first, !first.isEmpty, detected.allSatisfy({ $0 == first }) {
                    response["detectedLanguage"] = first
                }
                try writeJSON(response, to: output)
            }
        } catch {
            // Do not print errors containing model paths, user speech or transcript.
            if CommandLine.arguments.dropFirst().first == "serve" {
                try? writeJSON(["error": "mlx-worker-failed"], to: output)
            }
            exit(1)
        }
    }
}
