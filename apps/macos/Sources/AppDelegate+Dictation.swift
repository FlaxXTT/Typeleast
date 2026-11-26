import Foundation

enum TranslationShortcutAction: Equatable {
    case speech(target: String)
    case selectedText(target: String)

    static func resolve(selection: String?, speechTarget: String, selectionTarget: String) -> Self {
        guard let selection, DictationController.hasText(selection) else { return .speech(target: speechTarget) }
        return .selectedText(target: SelectionTranslator.target(for: selection, preferred: selectionTarget))
    }
}

// UI and hotkey entry points remain stable; the controller owns the recording lifecycle.
extension AppDelegate {
    func toggleDictation() {
        if onboarding.handleShortcut(.dictation) { return }
        guard !settings.needsPractice else { showOnboarding(); return }
        dictation.toggleDictation()
    }
    func toggleDictation(translateTo: String?) {
        guard !onboarding.isKeyWindow else { return }
        guard !settings.needsPractice else { showOnboarding(); return }
        dictation.toggleDictation(translateTo: translateTo)
    }
    func stopRecording(auto: Bool = false) { dictation.stopRecording(auto: auto) }
    func cancelDictation() { if onboarding.isKeyWindow { onboarding.practice.cancel() } else { dictation.cancelDictation() } }
    func pasteLast() { guard !onboarding.isKeyWindow else { return }; guard !settings.needsPractice else { showOnboarding(); return }; dictation.pasteLast() }
    func finishBetaWithoutAnswers(answer: String?) { dictation.finishBetaWithoutAnswers(answer: answer) }
    func dropBeta(notify: Bool) { dictation.dropBeta(notify: notify) }
}
