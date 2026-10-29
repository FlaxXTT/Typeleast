import Foundation
import AppKit

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
    response.contextOnly = true
    checkEq("explanation-only response cannot be inserted", response.insertableText, "")

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
