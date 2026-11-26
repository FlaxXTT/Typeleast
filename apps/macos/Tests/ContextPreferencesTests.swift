import Foundation
import AppKit
import CoreAudio
import SwiftUI

func contextPreferencesTests() {
    let suite = "typeleast.tests.context." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); KeychainStore.stub = [:]; HistorySeal.reset() }
    let settings = Settings(defaults: defaults)
    check("fresh install starts onboarding", settings.needsPractice)
    settings.onboardingDone = true
    check("finished tutorial remains finished after restart", !Settings(defaults: defaults).needsPractice)
    defaults.removePersistentDomain(forName: suite)
    defaults.set("prompt", forKey: "voice.strength")
    check("existing installation is never forced through new tutorial", !Settings(defaults: defaults).needsPractice)

    settings.translateTarget = "ja"
    checkEq("selection translation follows the shortcut language by default", settings.preferredSelectionTranslateTarget, "ja")
    settings.selectionTranslateTarget = "fr"
    let reopened = Settings(defaults: defaults)
    checkEq("selection translation keeps its independent language across restarts", reopened.preferredSelectionTranslateTarget, "fr")
    checkEq("the selection language leaves the shortcut language intact", reopened.translateTarget, "ja")
    settings.selectionTranslate = false
    check("the selection button can stay disabled with a saved language", !reopened.selectionTranslate && reopened.selectionTranslateTarget == "fr")
    settings.selectionTranslateTarget = ""
    checkEq("resetting selection language follows the shortcut again", reopened.preferredSelectionTranslateTarget, "ja")
    defaults.set("invalid", forKey: "voice.selectionTranslateTarget")
    checkEq("an unknown selection translation language follows the shortcut", reopened.preferredSelectionTranslateTarget, "ja")

    let inputNames: [AudioDeviceID: String] = [
        10: "MacBook Pro麦克风", 20: "USB Mic", 30: "Studio Aggregate", 40: "CADefaultDeviceAggregate-100-0",
    ]
    func recordingInputName(_ id: AudioDeviceID?, members: [AudioDeviceID] = [], defaultID: AudioDeviceID = 10) -> String? {
        AudioDevices.recordingInputName(for: id, inputName: { inputNames[$0] },
                                        activeMembers: { _ in members }, defaultInput: { defaultID })
    }
    checkEq("automatic route names the microphone and skips its output member",
            recordingInputName(40, members: [50, 10]), "MacBook Pro麦克风")
    checkEq("an active input takes priority over a new system default",
            recordingInputName(40, members: [20, 50]), "USB Mic")
    checkEq("an aggregate with several active inputs prefers its system default member",
            recordingInputName(40, members: [10, 20], defaultID: 20), "USB Mic")
    checkEq("automatic route uses the default if active members are unavailable",
            recordingInputName(40), "MacBook Pro麦克风")
    checkEq("explicit input keeps its own name", recordingInputName(20), "USB Mic")
    checkEq("a named aggregate keeps its own name", recordingInputName(30), "Studio Aggregate")
    checkEq("an unreadable route does not claim to use a different microphone", recordingInputName(nil), nil)

    let demo = OnboardingPracticeController(recordingHold: 0, processingHold: 0)
    typealias Readiness = OnboardingReadiness
    checkEq("first dictation waits for the local model download",
            Readiness.Speech.local(serviceRunning: true, status: SpeechStatus(providerId: "fixture", ready: false, phase: "downloading"),
                                   operation: nil), .downloading)
    checkEq("the setup distinguishes a missing local model from one being prepared",
            Readiness.Speech.local(serviceRunning: true, status: SpeechStatus(providerId: "fixture", ready: false, phase: "missing-model"),
                                   operation: nil), .missingModel)
    checkEq("the setup checks a locked Keychain before suggesting cloud dictation",
            Readiness.Speech.cloud(locked: true, hasKey: true), .keyLocked)
    checkEq("the setup distinguishes a saved cloud key from a tested connection",
            Readiness.Speech.cloud(locked: false, hasKey: true), .savedKey)
    checkEq("first dictation sends the user to the missing microphone permission",
            Readiness(speech: .ready, microphone: false, writing: true, shortcut: "Fn").next, .microphone)
    checkEq("first dictation waits for cross-app writing permission",
            Readiness(speech: .savedKey, microphone: true, writing: false, shortcut: "Fn").next, .writing)
    checkEq("first dictation waits for an enabled shortcut",
            Readiness(speech: .ready, microphone: true, writing: true, shortcut: nil).next, .shortcut)
    checkEq("first dictation can start without a cleanup model",
            Readiness(speech: .ready, microphone: true, writing: true, shortcut: "Fn").next, nil)
    checkEq("a conflicting shortcut can fall back to an enabled alternate",
            Readiness.shortcutLabel(main: .optionSpaceDefault, alternate: .fnDefault, problems: ["main": "Conflict"]), "Fn")
    checkEq("a conflicting shortcut with no alternate is unavailable",
            Readiness.shortcutLabel(main: .optionSpaceDefault, alternate: .unset, problems: ["main": "Conflict"]), nil)
    checkEq("onboarding teaches all four workflows", OnboardingDemo.allCases.count, 4)
    checkEq("onboarding shows the default dictation shortcut", OnboardingDemo.dictation.shortcutLabel(in: settings), "Fn")
    checkEq("onboarding shows the default translation chord", OnboardingDemo.voiceTranslation.shortcutLabel(in: settings), "Fn + Left Shift")
    checkEq("onboarding shows the default Skill chord", OnboardingDemo.skill.shortcutLabel(in: settings), "Fn + Space")
    func waitForDemo() { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
    demo.enter(.dictation)
    demo.handle(.translation)
    check("an unrelated shortcut cannot start the wrong demo", !demo.busy)
    demo.handle(.dictation)
    check("dictation simulates listening without a configured model", demo.phase == .recording)
    let practiceFrame = NSRect(x: 0, y: 0, width: 610, height: 400)
    let practiceWindow = NSWindow(contentRect: practiceFrame, styleMask: [.titled], backing: .buffered, defer: false)
    practiceWindow.isReleasedWhenClosed = false
    defer { practiceWindow.close() }
    let practiceView = NSHostingView(rootView: OnboardingPracticeView(practice: demo, demo: .dictation)
        .environmentObject(AppModel()).frame(width: practiceFrame.width, height: practiceFrame.height))
    practiceWindow.contentView = practiceView
    practiceView.layoutSubtreeIfNeeded()
    demo.handle(.dictation)
    practiceView.layoutSubtreeIfNeeded()
    waitForDemo()
    practiceView.layoutSubtreeIfNeeded()
    checkEq("the recorded example always writes the known dictation result", demo.output, OnboardingDemo.dictation.result)
    demo.enter(.voiceTranslation)
    demo.playExample()
    waitForDemo()
    checkEq("play example completes voice translation without recording", demo.output, OnboardingDemo.voiceTranslation.result)
    demo.enter(.selectionTranslation)
    demo.handle(.translation)
    check("translation highlights the practice text when it was not selected", demo.selectionHighlighted)
    waitForDemo()
    checkEq("selection translation produces the known panel result", demo.output, OnboardingDemo.selectionTranslation.result)
    demo.enter(.skill)
    demo.handle(.skill, held: true)
    check("a held Skill chord opens the example and waits for release", demo.showingSkill && demo.output.isEmpty)
    demo.releaseSkill()
    waitForDemo()
    checkEq("releasing the Skill shortcut writes the known example", demo.output, OnboardingDemo.skill.result)
    demo.enter(.voiceTranslation)
    demo.playExample()
    demo.enter(nil)
    waitForDemo()
    check("leaving the demo discards an in-flight result and clears shortcut interception", demo.mode == nil && !demo.busy && demo.output.isEmpty)

    var response = DictateResponse()
    response.text = "周四交，不超过三页。"
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
