import Foundation
import AppKit

func contextPreferencesTests() {
    let suite = "typeleast.tests.context." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); KeychainStore.stub = [:]; HistorySeal.reset() }
    let settings = Settings(defaults: defaults)
    check("fresh install requires real tutorial", settings.needsPractice)
    settings.explanationMarkers = "invalid"
    checkEq("invalid marker selection is disabled", settings.explanationMarkers, "")
    settings.onboardingDone = true
    check("finished tutorial remains finished after restart", !Settings(defaults: defaults).needsPractice)
    defaults.removePersistentDomain(forName: suite)
    defaults.set("prompt", forKey: "voice.strength")
    check("existing installation is never forced through new tutorial", !Settings(defaults: defaults).needsPractice)

    KeychainStore.stub = [:]; HistorySeal.reset()
    let preferences = PreferenceExamples(defaults: defaults)
    preferences.offer(historyId: "fictional-1", raw: "请把报告发给团队", aiText: "请将报告发送给团队。", corrected: "请发报告给团队。")
    checkEq("observed revision stays pending", preferences.pending.count, 1)
    check("pending revision is neither persisted nor sent", preferences.entries.isEmpty && preferences.wireExamples.isEmpty && defaults.data(forKey: "voice.preferenceExamples.sealed.v1") == nil)
    let example = preferences.pending[0]
    check("explicit confirmation saves example", preferences.confirm(example))
    check("confirmed example leaves pending", preferences.pending.isEmpty)
    let saved = defaults.data(forKey: "voice.preferenceExamples.sealed.v1")!
    check("stored example contains no plaintext", saved.range(of: Data("请发报告给团队".utf8)) == nil)
    checkEq("encrypted preference survives reload", PreferenceExamples(defaults: defaults).entries.first?.correctedText, "请发报告给团队。")
    preferences.setEnabled(example.id, false)
    check("disabled preference is not sent", preferences.wireExamples.isEmpty)
    check("preference wire contains no history identifier", preferences.entries[0].wire["historyId"] == nil)
    preferences.offer(historyId: "pending", raw: "报告", aiText: "会议报告", corrected: "报告摘要")
    preferences.clearPending()
    check("clearing pending preserves confirmed records", preferences.pending.isEmpty && preferences.entries.count == 1)
    defaults.set(Data("broken fixture".utf8), forKey: "voice.preferenceExamples.sealed.v1")
    let broken = PreferenceExamples(defaults: defaults)
    check("unreadable preferences cannot overwrite original", !broken.confirm(example) && defaults.data(forKey: "voice.preferenceExamples.sealed.v1") == Data("broken fixture".utf8))

    var progress = PracticeProgress()
    var response = DictateResponse()
    response.raw = "周三，不对，周四，不超过三页"; response.text = "周四，不超过 3 页。"
    check("tutorial rejects response without real model evidence", !progress.accept(response, seconds: 2, exercise: 0, markerId: "background"))
    response.model = "fictional-model"; response.ms = MSBreakdown(transcribe: 10, polish: 20, total: 30)
    check("tutorial accepts completed recognition and cleanup", progress.accept(response, seconds: 2, exercise: 0, markerId: "background"))
    response.fallback = true
    check("fallback cannot pass tutorial", !progress.accept(response, seconds: 2, exercise: 1, markerId: "background"))
    response.fallback = false
    response.explanation = ExplanationReceipt(used: true, segments: 1, markerId: "background")
    check("tutorial rejects receipt for another marker", !progress.accept(response, seconds: 2, exercise: 1, markerId: "aside"))
    check("tutorial accepts selected explanation receipt", progress.accept(response, seconds: 2, exercise: 1, markerId: "background"))
    check("voice alone does not finish review exercise", progress.accept(response, seconds: 2, exercise: 2, markerId: "background") && !progress.complete)
    check("unrelated review cannot pass", !progress.confirmReview(original: "other output", corrected: "new revision"))
    check("unchanged review cannot pass", !progress.confirmReview(original: response.text, corrected: response.text))
    check("confirmed revision finishes third exercise", progress.confirmReview(original: response.text, corrected: response.text + "请确认。") && progress.complete)
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
