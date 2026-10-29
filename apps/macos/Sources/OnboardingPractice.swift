import Foundation
import AVFoundation
import Combine

/// The practice passes when one real recording was recognised and cleaned up; what was said is up to the user.
struct PracticeProgress {
    enum Outcome: Equatable { case passed, tooShort, nothingHeard, notCleaned }
    private(set) var complete = false
    mutating func accept(_ response: DictateResponse, seconds: Double) -> Outcome {
        guard seconds >= 0.6 else { return .tooShort }
        guard !response.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingHeard }
        guard !response.fallback, !response.insertableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notCleaned }
        complete = true
        return .passed
    }
}

/// No paste, clipboard, field context, history or vocabulary learning.
final class OnboardingPracticeController: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var progress = PracticeProgress()
    @Published private(set) var raw = ""
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    /// Recent microphone levels for the pill's waveform, newest last.
    @Published private(set) var levels: [Float] = []
    private var levelTimer: Timer?
    private let recorder = Recorder()
    private let settings: Settings
    private let client: ServiceClient
    private var generation = 0
    private var pendingAudio: URL?
    var acceptsShortcut = false
    init(settings: Settings = .shared, client: ServiceClient = .shared) {
        self.settings = settings; self.client = client
        recorder.maxSeconds = 40
        recorder.onAutoStop = { [weak self] in self?.stop() }
    }
    var complete: Bool { progress.complete }
    var busy: Bool { phase != .idle }
    var sample: String {
        L10n.language == "en" ? "Send the report on Tuesday, no wait, on Thursday. Keep it under 3 pages." : "嗯，把报告周三发，不对，改成周四，不超过三页。"
    }
    func toggle() {
        if phase == .recording { stop(); return }
        guard phase == .idle else { return }
        guard settings.activeLLMRoute != nil else { status = L10n.text("请先配置可用的整理模型。"); return }
        switch Recorder.authorizationStatus() {
        case .notDetermined:
            Recorder.requestMicrophoneAccess { [weak self] allowed in
                guard let self else { return }; if allowed { self.toggle() } else { self.status = L10n.text("需要麦克风权限才能完成真实语音练习。") }
            }
            return
        case .authorized: break
        default: status = L10n.text("需要麦克风权限才能完成真实语音练习。"); return
        }
        do {
            raw = ""; output = ""
            recorder.demoPCM = nil
            try recorder.start(); phase = .recording; status = ""
            levels = Array(repeating: 0, count: 18)
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, self.phase == .recording else { return }
                self.levels = Array((self.levels + [RecordingBarFormat.clampLevel(self.recorder.level())]).suffix(18))
            }
            RunLoop.main.add(t, forMode: .common); levelTimer = t
        } catch { status = L10n.text("打不开麦克风，请检查设备和权限。"); phase = .idle }
    }
    func stop() {
        guard phase == .recording else { return }
        levelTimer?.invalidate(); levelTimer = nil
        do {
            let recording = try recorder.finish()
            guard let route = settings.activeLLMRoute else { try? FileManager.default.removeItem(at: recording.url); status = L10n.text("请先配置可用的整理模型。"); phase = .idle; return }
            pendingAudio = recording.url
            let language = settings.language
            let token = generation
            phase = .thinking; status = ""
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: Result<DictateResponse, Error> = Result {
                    defer { try? FileManager.default.removeItem(at: recording.url) }
                    let wav = try Data(contentsOf: recording.url)
                    try? FileManager.default.removeItem(at: recording.url)
                    return try self?.client.dictateSync(wav: wav, language: language, appBundleId: "tutorial", strength: "concise",
                        llm: route) ?? DictateResponse()
                }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.pendingAudio = nil
                    self.phase = .idle
                    switch result {
                    case .failure(let error): self.status = L10n.text("没有完成：") + ((error as? ServiceError).map { "\($0)" } ?? error.localizedDescription)
                    case .success(let response):
                        self.raw = response.raw; self.output = response.insertableText
                        switch self.progress.accept(response, seconds: recording.seconds) {
                        case .passed: self.status = L10n.text("通过了。点「继续」。")
                        case .tooShort: self.status = L10n.text("录音太短，请再说一次。")
                        case .nothingHeard: self.status = L10n.text("没听清，请再说一次。")
                        case .notCleaned: self.status = L10n.text("识别到了，但整理没完成。请检查整理模型和 API Key。")
                        }
                    }
                }
            }
        } catch { phase = .idle; status = L10n.text("录音太短或设备异常，请重试。") }
    }
    func cancel() { generation += 1; levelTimer?.invalidate(); levelTimer = nil; recorder.cancel(); if let pendingAudio { try? FileManager.default.removeItem(at: pendingAudio) }; pendingAudio = nil; phase = .idle; raw = ""; output = "" }
    func reset() { cancel(); progress = PracticeProgress(); status = "" }
}
