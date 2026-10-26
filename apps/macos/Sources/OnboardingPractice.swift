import Foundation
import AVFoundation
import Combine

/// Evidence is accepted only from /dictate after a real recording in the tutorial controller.
struct PracticeProgress {
    private(set) var completed: Set<Int> = []
    private var reviewText: String?
    private(set) var markerId = ""
    var reviewReady: Bool { reviewText != nil }
    var complete: Bool { completed == Set([0, 1, 2]) }
    mutating func accept(_ response: DictateResponse, seconds: Double, exercise: Int, markerId: String) -> Bool {
        if exercise == 2 { reviewText = nil }
        guard seconds >= 0.6, !response.fallback, response.clarification == nil, !response.contextOnly,
              !response.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              response.model?.isEmpty == false, response.ms?.transcribe != nil, response.ms?.polish != nil else { return false }
        switch exercise {
        case 0:
            guard response.raw.range(of: "不对|说错了|改成|改为|no[ ,]+wait|I mean|rather", options: [.regularExpression, .caseInsensitive]) != nil else { return false }
            guard response.text.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
            completed.insert(0)
        case 1:
            guard let receipt = response.explanation, receipt.used, receipt.segments > 0, receipt.markerId == markerId,
                  let marker = ExplanationMarkers(rawValue: markerId) else { return false }
            for word in [marker.words.0, marker.words.1] {
                if response.text.range(of: word, options: .caseInsensitive) != nil { return false }
            }
            completed.insert(1); self.markerId = markerId
        case 2: reviewText = response.text
        default: return false
        }
        return true
    }
    mutating func confirmReview(original: String, corrected: String) -> Bool {
        guard reviewText == original, !original.isEmpty, !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              corrected != original, corrected.count <= 4000 else { return false }
        completed.insert(2); reviewText = nil; return true
    }
}

/// No paste, clipboard, field context, history, vocabulary learning or real preference writes.
final class OnboardingPracticeController: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var progress = PracticeProgress()
    @Published private(set) var raw = ""
    @Published private(set) var output = ""
    @Published private(set) var status = ""
    @Published var exercise = 0
    @Published var revision = ""
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
    var complete: Bool { progress.complete && progress.markerId == settings.explanationMarkers }
    var busy: Bool { phase != .idle }
    var sample: String {
        let english = L10n.language == "en"
        switch exercise {
        case 0: return english ? "Send the report on Tuesday, no wait, on Thursday. Keep it under 3 pages." : "嗯，把报告周三发，不对，改成周四，不超过三页。"
        case 1:
            let marker = ExplanationMarkers(rawValue: settings.explanationMarkers) ?? .background
            return english ? "I want a ROG laptop. \(marker.words.0) ROG refers to Republic of Gamers. \(marker.words.1) My budget is under 10000 yuan." : "我想买一台 ROG 电脑。\(marker.words.0)，ROG 指的是玩家国度那个 ROG，\(marker.words.1)。预算不超过一万元。"
        default: return english ? "Please send the meeting report to the team." : "请把会议报告发给团队。"
        }
    }
    func toggle() {
        if phase == .recording { stop(); return }
        guard phase == .idle else { return }
        guard !settings.explanationMarkers.isEmpty else { status = L10n.text("请先选择一组解释触发词。"); return }
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
            raw = ""; output = ""; revision = ""
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
            let round = exercise, marker = settings.explanationMarkers, language = settings.language
            let token = generation
            phase = .thinking; status = L10n.text("正在整理…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result: Result<DictateResponse, Error> = Result {
                    defer { try? FileManager.default.removeItem(at: recording.url) }
                    let wav = try Data(contentsOf: recording.url)
                    try? FileManager.default.removeItem(at: recording.url)
                    return try self?.client.dictateSync(wav: wav, language: language, appBundleId: "tutorial", strength: "concise",
                        llm: route, explanationMarkers: marker) ?? DictateResponse()
                }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.pendingAudio = nil
                    self.phase = .idle
                    switch result {
                    case .failure: self.status = L10n.text("练习未通过，请检查服务和模型后重试。")
                    case .success(let response):
                        self.raw = response.raw; self.output = response.text; self.revision = response.text
                        let accepted = self.progress.accept(response, seconds: recording.seconds, exercise: round, markerId: marker)
                        self.status = accepted ? L10n.text("识别与整理通过。") : L10n.text("练习未通过，请检查识别结果、触发词和模型后重试。")
                    }
                }
            }
        } catch { phase = .idle; status = L10n.text("录音太短或设备异常，请重试。") }
    }
    func confirmReview() {
        if progress.confirmReview(original: output, corrected: revision) { status = L10n.text("练习已完成，不会保存为正式偏好。") }
    }
    func cancel() { generation += 1; recorder.cancel(); if let pendingAudio { try? FileManager.default.removeItem(at: pendingAudio) }; pendingAudio = nil; phase = .idle; raw = ""; output = ""; revision = "" }
    func reset() { cancel(); progress = PracticeProgress(); exercise = 0; status = "" }
}
