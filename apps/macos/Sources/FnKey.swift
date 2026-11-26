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

/// One event-driven decision window for a bare Fn press or a configured chord.
struct FnTapDetector {
    static let decisionSeconds: TimeInterval = 2

    private var downAt: TimeInterval?
    private var spoiled = false
    var isDown: Bool { downAt != nil }

    static func inDecisionWindow(from down: TimeInterval?, to eventTime: TimeInterval) -> Bool {
        guard let down else { return false }
        let elapsed = eventTime - down
        return elapsed >= 0 && elapsed <= decisionSeconds
    }

    func allowsChord(at time: TimeInterval) -> Bool {
        Self.inDecisionWindow(from: downAt, to: time)
    }

    mutating func fnDown(at time: TimeInterval, otherModifiersHeld: Bool) {
        downAt = time
        spoiled = otherModifiersHeld
    }

    mutating func otherInput() {
        if isDown { spoiled = true }
    }

    mutating func fnUp(at time: TimeInterval) -> Bool {
        defer { self = FnTapDetector() }
        return !spoiled && allowsChord(at: time)
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

struct FnSpaceGesture {
    enum Result: Equatable {
        case pass, consumed, pressed, released(consumingSpace: Bool)
    }

    private enum Hold { case idle, spaceDown, fnOnly }
    private var hold = Hold.idle
    private var fnDownAt: TimeInterval?
    private var reservedForShift = false
    private var consumedDuringFn = false

    mutating func fnChanged(down: Bool, at time: TimeInterval) -> Result {
        if down {
            if fnDownAt == nil {
                fnDownAt = time
                reservedForShift = false
                if hold != .idle { consumedDuringFn = true }
            }
        } else {
            fnDownAt = nil
            if hold == .fnOnly {
                hold = .idle
                return .released(consumingSpace: false)
            }
        }
        return .pass
    }

    mutating func spaceChanged(down: Bool, repeated: Bool, canStart: Bool,
                               otherModifiersHeld: Bool, at time: TimeInterval) -> Result {
        switch hold {
        case .spaceDown:
            guard !down else { return .consumed }
            if fnDownAt != nil {
                hold = .fnOnly
                return .consumed
            }
            hold = .idle
            return .released(consumingSpace: true)
        case .fnOnly:
            if down && !repeated { hold = .spaceDown }
            return .consumed
        case .idle:
            guard canStart, down, !repeated, !otherModifiersHeld, !reservedForShift, !consumedDuringFn,
                  FnTapDetector.inDecisionWindow(from: fnDownAt, to: time) else { return .pass }
            hold = .spaceDown
            consumedDuringFn = true
            return .pressed
        }
    }

    mutating func reserveForShift() -> Bool {
        guard hold == .idle, !consumedDuringFn else { return false }
        reservedForShift = true
        return true
    }

    mutating func endFnGesture() -> Bool {
        defer { consumedDuringFn = false }
        return consumedDuringFn
    }

    mutating func cancel() -> Bool {
        let wasHeld = hold != .idle
        self = FnSpaceGesture()
        return wasHeld
    }
}

/// Filter only the configured Space chord. The tap thread never waits on the UI.
private final class FnSpaceFilter {
    let pressed: () -> Void
    let released: () -> Void
    let cancelled: () -> Void
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var allowed = false
    private var gesture = FnSpaceGesture()

    init(pressed: @escaping () -> Void, released: @escaping () -> Void, cancelled: @escaping () -> Void) {
        self.pressed = pressed
        self.released = released
        self.cancelled = cancelled
    }

    func setAllowed(_ allowed: Bool) {
        lock.withLock {
            guard self.allowed != allowed else { return }
            self.allowed = allowed
            cancelGesture()
        }
    }

    func endFnGesture() -> Bool { lock.withLock { gesture.endFnGesture() } }

    var isRunning: Bool { lock.withLock { eventTap != nil } }
    func reserveForShift() -> Bool { lock.withLock { gesture.reserveForShift() } }

    func start() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
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
            cancelGesture()
            return tap
        }
        if let tap { CFMachPortInvalidate(tap) }
    }

    func consumes(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock {
                cancelGesture()
                if type == .tapDisabledByTimeout, let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let time = Double(event.timestamp) / 1_000_000_000
        return process(key: key, flags: flags, isModifierEvent: type == .flagsChanged,
                       down: type == .keyDown, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                       canStart: true, at: time)
    }

    func process(key: Int64, flags: NSEvent.ModifierFlags, isModifierEvent: Bool, down: Bool,
                 repeated: Bool, canStart: Bool, at time: TimeInterval) -> Bool {
        let gestureKey = isModifierEvent ? Int64(FnKeyMonitor.keyCode) : Int64(FnChord.space.rawValue)
        guard key == gestureKey else { return false }
        return lock.withLock {
            let result: FnSpaceGesture.Result
            if isModifierEvent {
                result = gesture.fnChanged(down: flags.contains(.function), at: time)
            } else {
                result = gesture.spaceChanged(down: down, repeated: repeated,
                    canStart: canStart && allowed,
                    otherModifiersHeld: !flags.intersection(FnChord.standardModifiers).isEmpty, at: time)
            }
            switch result {
            case .pass: return false
            case .consumed: return true
            case .pressed:
                DispatchQueue.main.async(execute: pressed)
                return true
            case .released(let consumingSpace):
                DispatchQueue.main.async(execute: released)
                return consumingSpace
            }
        }
    }

    private func cancelGesture() {
        if gesture.cancel() { DispatchQueue.main.async(execute: cancelled) }
    }
}

/// Arbitrates clean Fn taps and the configured chords on the main thread.
final class FnKeyMonitor {
    static let shared = FnKeyMonitor()

    /// kVK_Function.
    static let keyCode: UInt16 = 63

    /// Called after a clean tap with the input source that was active when Fn went down.
    var onTap: ((String?) -> Void)?
    var onSpaceRelease: (() -> Void)?
    var onSpaceCancel: (() -> Void)?
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
    private var triggeredChord = false
    private lazy var spaceFilter = FnSpaceFilter(pressed: { [weak self] in
        guard let self, !self.capturingShortcut else { return }
        self.chords[.space]?()
    }, released: { [weak self] in
        self?.onSpaceRelease?()
    }, cancelled: { [weak self] in
        self?.onSpaceCancel?()
    })

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
        else if spaceFilter.isRunning { spaceFilter.stop() }
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
        resetGesture()
    }

    private func resetGesture() {
        detector = FnTapDetector()
        sourceAtDown = nil
        triggeredChord = false
    }

    private func forward(_ event: NSEvent, canConsume: Bool) -> Bool {
        let key = Int64(event.keyCode)
        let down = event.type == .keyDown
        let modifier = event.type == .flagsChanged
        if !spaceFilter.isRunning,
           spaceFilter.process(key: key, flags: event.modifierFlags, isModifierEvent: modifier,
                               down: down, repeated: down && event.isARepeat,
                               canStart: canConsume && event.modifierFlags.contains(.function),
                               at: event.timestamp), canConsume { return false }
        if modifier {
            handleFlags(key: key, flags: event.modifierFlags, at: event.timestamp)
        } else if down && !capturingShortcut {
            detector.otherInput()
        }
        return true
    }

    private func handleFlags(key: Int64, flags: NSEvent.ModifierFlags, at time: TimeInterval) {
        guard !capturingShortcut else { return }
        if key != Int64(Self.keyCode) {
            detector.otherInput()
            if key == Int64(FnChord.leftShift.rawValue), FnChord.matches(.leftShift, flags: flags) {
                triggerShift(at: time)
            }
        } else if flags.contains(.function) {
            guard !detector.isDown else { return }
            triggeredChord = false
            sourceAtDown = bareFnEnabled ? InputSourceProbe.currentID() : nil
            detector.fnDown(at: time, otherModifiersHeld: !flags.intersection(FnChord.standardModifiers).isEmpty)
            if (flags.rawValue & 0x06) == 0x02, FnChord.matches(.leftShift, flags: flags) {
                triggerShift(at: time)
            }
        } else {
            let cleanTap = detector.fnUp(at: time)
            let usedSpace = spaceFilter.endFnGesture()
            defer { resetGesture() }
            guard bareFnEnabled, cleanTap, !triggeredChord, !usedSpace else { return }
            let action = onTap
            let source = sourceAtDown
            DispatchQueue.main.async { action?(source) }
        }
    }

    private func triggerShift(at time: TimeInterval) {
        guard !triggeredChord, let action = chords[.leftShift],
              detector.allowsChord(at: time), spaceFilter.reserveForShift() else { return }
        triggeredChord = true
        DispatchQueue.main.async(execute: action)
    }
}
