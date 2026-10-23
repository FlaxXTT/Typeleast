import Foundation

// UI and hotkey entry points remain stable; the controller owns the recording lifecycle.
extension AppDelegate {
    func toggleDictation() { dictation.toggleDictation() }
    func toggleDictation(translateTo: String?) { dictation.toggleDictation(translateTo: translateTo) }
    func stopRecording(auto: Bool = false) { dictation.stopRecording(auto: auto) }
    func cancelDictation() { dictation.cancelDictation() }
    func pasteLast() { dictation.pasteLast() }
    func finishBetaWithoutAnswers() { dictation.finishBetaWithoutAnswers() }
    func dropBeta(notify: Bool) { dictation.dropBeta(notify: notify) }
}
