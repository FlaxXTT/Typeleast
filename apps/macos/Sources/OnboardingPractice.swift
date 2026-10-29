import Foundation
import AVFoundation
import Combine

/// Evidence is accepted only from /dictate after a real recording in the tutorial controller.
struct PracticeProgress {
    private(set) var complete = false
    mutating func accept(_ response: DictateResponse, seconds: Double) -> Bool {
        guard seconds >= 0.6, !response.fallback, response.clarification == nil, !response.contextOnly,
              !response.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.model?.isEmpty == false, response.ms?.transcribe != nil, response.ms?.polish != nil,
              response.raw.range(of: "不对|说错了|改成|改为|no[ ,]+wait|I mean|rather", options: [.regularExpression, .caseInsensitive]) != nil,
              response.text.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        complete = true
        return true
    }
}

/// No paste, clipboard, field context, history or vocabulary learning.
final class OnboardingPracticeController: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var progress = PracticeProgress()
    @Published private(set) var raw = ""
    @Published private(set) var output = ""
    @Published private(set) var status = ""
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
            try recorder.start(); phase = .recording; status = L10n.text("正在听…")
        } catch { status = L10n.text("打不开麦克风，请检查设备和权限。"); phase = .idle }
    }
    private func stop() {
        guard phase == .recording else { return }
        do {
            let recording = try recorder.finish()
            guard let route = settings.activeLLMRoute else { try? FileManager.default.removeItem(at: recording.url); status = L10n.text("请先配置可用的整理模型。"); phase = .idle; return }
            pendingAudio = recording.url
            let language = settings.language
            let token = generation
            phase = .thinking; status = L10n.text("正在整理…")
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
                    case .failure: self.status = L10n.text("练习未通过，请检查服务和模型后重试。")
                    case .success(let response):
                        self.raw = response.raw; self.output = response.text
                        let accepted = self.progress.accept(response, seconds: recording.seconds)
                        self.status = accepted ? L10n.text("识别与整理通过。") : L10n.text("练习未通过，请检查识别结果和模型后重试。")
                    }
                }
            }
        } catch { phase = .idle; status = L10n.text("录音太短或设备异常，请重试。") }
    }
    func cancel() { generation += 1; recorder.cancel(); if let pendingAudio { try? FileManager.default.removeItem(at: pendingAudio) }; pendingAudio = nil; phase = .idle; raw = ""; output = "" }
    func reset() { cancel(); progress = PracticeProgress(); status = "" }
}
