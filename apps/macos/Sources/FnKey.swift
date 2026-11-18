import AppKit
import ApplicationServices
import Carbon

enum FnChord: UInt32 {
    case leftShift = 56
    case space = 49

    static let modifier = UInt32(kEventKeyModifierFnMask)
    static let standardModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var keyLabel: String { self == .leftShift ? "Left Shift" : "Space" }
    var binding: HotKeyBinding {
        HotKeyBinding(keyCode: rawValue, modifiers: Self.modifier, enabled: true, name: "Fn + " + keyLabel)
    }

    static func matches(_ chord: FnChord, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.function) else { return false }
        let others = flags.intersection(standardModifiers)
        switch chord {
        case .leftShift:
            // NX_DEVICELSHIFTKEYMASK and NX_DEVICERSHIFTKEYMASK distinguish the two sides.
            return others == .shift && (flags.rawValue & 0x06) != 0x04
        case .space:
            return others.isEmpty
        }
    }
}

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

    /// macOS stores "Do Nothing" as 0. Only that explicit choice can skip
    /// waiting for a possible system input-source switch; unknown stays cautious.
    static func delay(systemUsageType: Int?) -> TimeInterval {
        systemUsageType == 0 ? 0 : settleSeconds
    }

    static var currentDelay: TimeInterval {
        let value = CFPreferencesCopyValue("AppleFnUsageType" as CFString, kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
        return delay(systemUsageType: value?.intValue)
    }

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

private let fnSpaceCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let filter = Unmanaged<FnSpaceFilter>.fromOpaque(context).takeUnretainedValue()
    return filter.consumes(type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Filter only the configured Space chord. The tap thread never waits on the UI.
private final class FnSpaceFilter {
    let pressed: () -> Void
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var allowed = false
    private var held = false
    private var consumedDuringFn = false

    init(pressed: @escaping () -> Void) { self.pressed = pressed }

    func setAllowed(_ allowed: Bool) {
        lock.withLock { self.allowed = allowed }
    }

    func endFnGesture() -> Bool {
        lock.withLock {
            defer { consumedDuringFn = false }
            return consumedDuringFn
        }
    }

    func start() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: fnSpaceCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        lock.withLock { eventTap = tap }
        let thread = Thread { [self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            withExtendedLifetime(self) { CFRunLoopRun() }
        }
        thread.name = "TypeLeast Fn+Space"
        thread.qualityOfService = .userInteractive
        CGEvent.tapEnable(tap: tap, enable: true)
        thread.start()
    }

    func stop() {
        let tap = lock.withLock {
            let tap = eventTap
            eventTap = nil
            held = false
            consumedDuringFn = false
            return tap
        }
        if let tap { CFMachPortInvalidate(tap) }
    }

    func consumes(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock {
                held = false
                if type == .tapDisabledByTimeout, let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            }
            return false
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(FnChord.space.rawValue) else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        return lock.withLock {
            if held {
                if type == .keyUp { held = false }
                return true
            }
            guard allowed && type == .keyDown && FnChord.matches(.space, flags: flags),
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            held = true
            consumedDuringFn = true
            DispatchQueue.main.async(execute: pressed)
            return true
        }
    }
}

/// Arbitrates clean Fn taps and the configured chords on the main thread.
final class FnKeyMonitor {
    static let shared = FnKeyMonitor()

    /// kVK_Function.
    static let keyCode: UInt16 = 63

    /// Called after a clean tap with the input source that was active when Fn went down.
    var onTap: ((String?) -> Void)?
    var capturingShortcut = false {
        didSet {
            if capturingShortcut != oldValue {
                resetGesture()
                spaceFilter.setAllowed(!capturingShortcut && chords[.space] != nil)
            }
        }
    }

    private var detector = FnTapDetector()
    private var monitors: [Any] = []
    private var sourceAtDown: String?
    private var bareFnEnabled = false
    private var chords: [FnChord: () -> Void] = [:]
    private var eatsSpace = false
    private var triggeredChord = false
    private lazy var spaceFilter = FnSpaceFilter { [weak self] in
        guard let self, !self.capturingShortcut else { return }
        self.detector.otherInput()
        _ = self.trigger(.space)
    }

    var isRunning: Bool { !monitors.isEmpty }

    func configure(bareFn: Bool, chords: [FnChord: () -> Void]) {
        bareFnEnabled = bareFn
        self.chords = chords
        refreshEventSource()
    }

    func refreshEventSource() {
        guard bareFnEnabled || !chords.isEmpty else { stop(); return }
        spaceFilter.setAllowed(!capturingShortcut && chords[.space] != nil)
        if chords[.space] != nil && AXIsProcessTrusted() { spaceFilter.start() }
        else { spaceFilter.stop() }
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            _ = self?.forward(event, canConsume: false)
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.forward(event, canConsume: true) == false ? nil : event
        }) { monitors.append(local) }
    }

    func stop() {
        spaceFilter.stop()
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        eatsSpace = false
        resetGesture()
    }

    private func resetGesture() {
        detector = FnTapDetector()
        sourceAtDown = nil
        triggeredChord = false
    }

    private func forward(_ event: NSEvent, canConsume: Bool) -> Bool {
        if event.type == .flagsChanged {
            handleFlags(key: Int64(event.keyCode), flags: event.modifierFlags)
            return true
        }
        return forwardKey(Int64(event.keyCode), flags: event.modifierFlags, down: event.type == .keyDown,
                          repeated: event.type == .keyDown && event.isARepeat, canConsume: canConsume)
    }

    private func handleFlags(key: Int64, flags: NSEvent.ModifierFlags) {
        guard !capturingShortcut else { return }
        if key != Int64(Self.keyCode) {
            detector.otherInput()
            if key == Int64(FnChord.leftShift.rawValue), FnChord.matches(.leftShift, flags: flags) {
                _ = trigger(.leftShift)
            }
        } else if flags.contains(.function) {
            guard !detector.isDown else { return }
            triggeredChord = false
            sourceAtDown = bareFnEnabled ? InputSourceProbe.currentID() : nil
            detector.fnDown(at: Date(), otherModifiersHeld: !flags.intersection(FnChord.standardModifiers).isEmpty)
            if (flags.rawValue & 0x06) == 0x02, FnChord.matches(.leftShift, flags: flags) {
                _ = trigger(.leftShift)
            }
        } else {
            let cleanTap = detector.fnUp(at: Date())
            let usedSpace = spaceFilter.endFnGesture()
            defer { resetGesture() }
            guard bareFnEnabled && cleanTap && !usedSpace else { return }
            let action = onTap
            let source = sourceAtDown
            DispatchQueue.main.async { action?(source) }
        }
    }

    private func forwardKey(_ key: Int64, flags: NSEvent.ModifierFlags, down: Bool,
                            repeated: Bool, canConsume: Bool) -> Bool {
        let isSpace = key == Int64(FnChord.space.rawValue)
        if isSpace && eatsSpace && canConsume {
            if !down { eatsSpace = false }
            return false
        }
        guard !capturingShortcut && down else { return true }
        detector.otherInput()
        guard canConsume && isSpace && !repeated && FnChord.matches(.space, flags: flags),
              trigger(.space) else { return true }
        eatsSpace = true
        return false
    }

    @discardableResult
    private func trigger(_ chord: FnChord) -> Bool {
        guard !triggeredChord, let action = chords[chord] else { return false }
        triggeredChord = true
        DispatchQueue.main.async(execute: action)
        return true
    }
}
