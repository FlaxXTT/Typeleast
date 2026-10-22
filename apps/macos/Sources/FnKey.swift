import AppKit
import Carbon

// FnKey.swift - single-press Fn (Globe) as the dictation key.
//
// Carbon RegisterEventHotKey accepts a bare Fn but macOS never delivers it, so Fn is
// read from modifier-change events instead. NSEvent global monitors for
// .flagsChanged need only the Accessibility grant the app already asks for (for
// paste); no Input Monitoring is requested. The key-down monitor records nothing but
// a single "some other key was pressed while Fn was held" bit, so Fn+arrow (Home/End)
// and Fn+F-keys never start a dictation; the key itself is never read.

/// Pure tap recogniser: Fn down, Fn up within a short window, nothing else pressed.
struct FnTapDetector {
    /// Longer holds are treated as "the user is doing something else with Fn".
    static let maxTapSeconds: TimeInterval = 0.6

    private(set) var isDown = false
    private var downAt: Date?
    private var spoiled = false

    /// Fn went down. Another modifier already held spoils the tap (⌃Fn, ⌘Fn …).
    mutating func fnDown(at time: Date, otherModifiersHeld: Bool) {
        isDown = true
        downAt = time
        spoiled = otherModifiersHeld
    }

    /// Any other key or modifier while Fn is held turns the press into a chord.
    mutating func otherInput() {
        if isDown { spoiled = true }
    }

    /// Fn went up. Returns true when that completes a clean tap.
    mutating func fnUp(at time: Date) -> Bool {
        defer {
            isDown = false
            downAt = nil
            spoiled = false
        }
        guard isDown, let started = downAt, !spoiled else { return false }
        let held = time.timeIntervalSince(started)
        return held >= 0 && held <= FnTapDetector.maxTapSeconds
    }
}

/// Fn is also the 🌐 key. When macOS uses a tap to switch the keyboard input source
/// (中/英), that tap was meant for the system, and it must not open the microphone.
enum FnTapGate {
    /// How long after a tap the input source gets to change before dictation starts.
    static let settleSeconds: TimeInterval = 0.25

    /// True unless the input source demonstrably changed across the tap. An unknown
    /// source (nil) never blocks: the gate must not break Fn for people without one.
    static func shouldStart(sourceAtPress: String?, sourceAfter: String?) -> Bool {
        guard let before = sourceAtPress, let after = sourceAfter else { return true }
        return before == after
    }
}

/// The current keyboard input source id, e.g. "com.apple.keylayout.US". Main thread only.
enum InputSourceProbe {
    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

/// Installs the event monitors and turns clean Fn taps into a callback on the main thread.
final class FnKeyMonitor {
    static let shared = FnKeyMonitor()

    /// kVK_Function.
    static let keyCode: UInt16 = 63

    /// Called after a clean tap with the input source that was active when Fn went down.
    var onTap: ((String?) -> Void)?

    private var detector = FnTapDetector()
    private var monitors: [Any] = []
    private var sourceAtDown: String?

    var isRunning: Bool { !monitors.isEmpty }

    /// Events only arrive once the app is trusted for Accessibility; calling this
    /// earlier is harmless and starts working as soon as the grant appears.
    func start() {
        guard monitors.isEmpty else { return }
        if let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
        }) { monitors.append(flags) }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.detector.otherInput()
        }) { monitors.append(keys) }
        // The app's own windows (Settings, onboarding) receive local events instead.
        if let localFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
            return event
        }) { monitors.append(localFlags) }
        if let localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.detector.otherInput()
            return event
        }) { monitors.append(localKeys) }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        detector = FnTapDetector()
    }

    private func handleFlags(_ event: NSEvent) {
        let others = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == FnKeyMonitor.keyCode else {
            // A different modifier changed while Fn is held: that is a chord.
            detector.otherInput()
            return
        }
        if event.modifierFlags.contains(.function) {
            sourceAtDown = InputSourceProbe.currentID()
            detector.fnDown(at: Date(), otherModifiersHeld: !others.isEmpty)
        } else if detector.fnUp(at: Date()) {
            let action = onTap
            let source = sourceAtDown
            DispatchQueue.main.async { action?(source) }
        }
    }
}
