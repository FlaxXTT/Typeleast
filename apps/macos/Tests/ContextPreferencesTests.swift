import Foundation
import AppKit
import AVFoundation
import CoreAudio

func contextPreferencesTests() {
    let suite = "typeleast.tests.context." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); KeychainStore.stub = [:]; HistorySeal.reset() }
    let settings = Settings(defaults: defaults)
    check("fresh install requires real tutorial", settings.needsPractice)
    settings.onboardingDone = true
    check("finished tutorial remains finished after restart", !Settings(defaults: defaults).needsPractice)
    defaults.removePersistentDomain(forName: suite)
    defaults.set("prompt", forKey: "voice.strength")
    check("existing installation is never forced through new tutorial", !Settings(defaults: defaults).needsPractice)

    // The onboarding recorder must use the selected input on every attempt,
    // including after the user changes it. No device is opened in this test.
    let practiceRecorder = Recorder()
    let testEngine = AVAudioEngine()
    var resolvedUIDs = [String]()
    var appliedIDs = [AudioDeviceID?]()
    var usedExpectedEngine = true
    let resolveInput: (String) -> AudioDeviceID? = { uid in
        resolvedUIDs.append(uid)
        return uid == "fictional-microphone" ? 42 : nil
    }
    let applyInput: (AudioDeviceID?, AVAudioEngine) -> Void = { id, engine in
        appliedIDs.append(id)
        usedExpectedEngine = usedExpectedEngine && engine === testEngine
    }
    OnboardingPracticeController.configureInput(practiceRecorder, uid: "fictional-microphone", resolve: resolveInput, apply: applyInput)
    practiceRecorder.prepareEngine?(testEngine)
    OnboardingPracticeController.configureInput(practiceRecorder, uid: "", resolve: resolveInput, apply: applyInput)
    practiceRecorder.prepareEngine?(testEngine)
    checkEq("practice resolves the current microphone before each recording", resolvedUIDs, ["fictional-microphone", ""])
    check("practice applies the chosen input and then system default", appliedIDs.count == 2 && appliedIDs[0] == 42 && appliedIDs[1] == nil)
    check("practice applies input to its recording engine", usedExpectedEngine)

    let practiceRaw = "报告周三发，不对，周四，不超过三页。"
    let practiceOutput = "报告周四发，不超过三月。"
    let practiceRows = PracticeResultRow.rows(raw: practiceRaw, output: practiceOutput)
    checkEq("practice identifies both stages in order", practiceRows.map(\.title), ["原始识别", "整理结果"])
    checkEq("practice preserves both original texts without truncation", practiceRows.map(\.text), [practiceRaw, practiceOutput])
    checkEq("failed cleanup can still show the transcript", PracticeResultRow.rows(raw: practiceRaw, output: "").map(\.text), [practiceRaw])
    check("an empty practice does not show result rows", PracticeResultRow.rows(raw: "  ", output: "\n").isEmpty)
    let reviewRows = PracticeResultRow.rows(raw: practiceRaw, output: practiceOutput, needsReview: true)
    checkEq("suspect cleanup is labeled for review", reviewRows.map(\.title), ["原始识别", "待核对整理结果"])
    checkEq("suspect cleanup preserves source and candidate", reviewRows.map(\.text), [practiceRaw, practiceOutput])

    var progress = PracticeProgress()
    var response = DictateResponse()
    response.raw = "周三，不对，周四，不超过三页"; response.text = "周四，不超过 3 页。"
    checkEq("a short recording is asked again", progress.accept(response, seconds: 0.3), .tooShort)
    response.fallback = true
    checkEq("a failed cleanup does not pass", progress.accept(response, seconds: 2), .notCleaned)
    check("…and the practice stays open", !progress.complete)
    response.fallback = false
    response.text = "周四交，不超过三页。"
    checkEq("any recognised and cleaned sentence passes, Chinese numerals included", progress.accept(response, seconds: 2), .passed)
    check("…and the practice is complete", progress.complete)
    var suspect = DictateResponse()
    suspect.qualityReview = QualityReview(kind: "quantity", original: practiceRaw, candidate: practiceOutput)
    checkEq("suspect quantity requires review even if raw and text are empty", progress.accept(suspect, seconds: 2), .needsReview)
    check("suspect result revokes an earlier success", !progress.complete)
    response.corrections = [TermCorrection(from: "哭达", to: "CUDA", reason: nil)]
    response.intention = "交周报"
    checkEq("corrections and intention never reach the inserted text", response.insertableText, "周四交，不超过三页。")

    // Test AppKit's proposed width directly, without opening a window or reading history.
    let view = HistoryTextView()
    view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = false
    view.font = .systemFont(ofSize: 14)
    view.string = String(repeating: "这是虚构的长文本，包含条件、数字 123 和 English words。", count: 8)
    let narrow = view.measuredSize(width: 180), wide = view.measuredSize(width: 500)
    check("history grows vertically at a narrow width", narrow.height > wide.height && wide.height > 30)
    checkEq("repeated layout has a stable height", view.measuredSize(width: 180).height, narrow.height)
    view.string = "短文本"
    check("history height shrinks after content changes", view.measuredSize(width: 180).height < narrow.height)
}
