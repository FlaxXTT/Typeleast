import Foundation

// UI and hotkey entry points remain stable; the controller owns the recording lifecycle.
extension AppDelegate {
    func toggleDictation() {
        if onboarding.practice.acceptsShortcut { onboarding.practice.toggle(); return }
        guard !settings.needsPractice else { showOnboarding(); return }
        dictation.toggleDictation()
    }
    func toggleDictation(translateTo: String?) {
        guard !onboarding.practice.acceptsShortcut && !onboarding.practice.busy else { return }
        guard !settings.needsPractice else { showOnboarding(); return }
        dictation.toggleDictation(translateTo: translateTo)
    }
    func stopRecording(auto: Bool = false) { dictation.stopRecording(auto: auto) }
    func cancelDictation() { if onboarding.practice.busy { onboarding.practice.cancel() } else { dictation.cancelDictation() } }
    func pasteLast() { guard !onboarding.practice.acceptsShortcut && !onboarding.practice.busy else { return }; guard !settings.needsPractice else { showOnboarding(); return }; dictation.pasteLast() }
    func finishBetaWithoutAnswers(answer: String?) { dictation.finishBetaWithoutAnswers(answer: answer) }
    func dropBeta(notify: Bool) { dictation.dropBeta(notify: notify) }
}
