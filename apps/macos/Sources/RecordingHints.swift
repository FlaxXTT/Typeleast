import AppKit
import SwiftUI

struct TypingHintWindow {
    static let interval: TimeInterval = 60
    static let threshold = 60
    static let cooldown: TimeInterval = 48 * 60 * 60

    static func permitsReminder(lastShown: Date?, now: Date) -> Bool {
        lastShown.map { now.timeIntervalSince($0) >= cooldown } ?? true
    }

    private var bundle: String?
    private var samples: [TimeInterval] = []

    mutating func record(_ times: [TimeInterval], in app: String, now: TimeInterval) -> Bool {
        if bundle != app { reset(); bundle = app }
        let cutoff = now - Self.interval
        samples.removeAll { $0 < cutoff }
        samples.append(contentsOf: times.filter { $0 >= cutoff })
        return samples.count > Self.threshold
    }

    mutating func reset() {
        bundle = nil
        samples.removeAll(keepingCapacity: true)
    }
}

/// Independent, nonactivating card presentation. A card stays up even with no active capture.
final class RecordingHints {
    private enum Hint: Equatable {
        case ready
        case reminder(String)
    }

    private let settings: Settings
    private let isIdle: () -> Bool
    private let permissionsReady: () -> Bool
    private var monitor: Any?
    private var observesTyping = false
    private var queue: [Hint] = []
    private var current: Hint?
    private var panel: PillPanel?
    private var timeout: DispatchWorkItem?
    private var recommendations: DispatchWorkItem?
    private var typing = TypingHintWindow()
    private var pendingKeys: [TimeInterval] = []
    private var pendingApp: String?
    private var probe: DispatchWorkItem?
    private var focusCheckInFlight = false
    private var focusGeneration = 0
    private var lastProbeAt: TimeInterval = 0

    init(settings: Settings, permissionsReady: @escaping () -> Bool = {
        AXIsProcessTrusted() && Recorder.authorizationStatus() == .authorized
    }, isIdle: @escaping () -> Bool) {
        self.settings = settings
        self.permissionsReady = permissionsReady
        self.isIdle = isIdle
    }

    var isVisible: Bool { panel?.isVisible == true }

    deinit { stop() }

    func start() {
        observesTyping = true
        permissionsChanged()
    }

    func stop() {
        observesTyping = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recommendations?.cancel()
        recommendations = nil
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
        queue.removeAll()
        current = nil
        resetTyping()
    }

    func permissionsChanged() {
        let available = eligible
        if available && observesTyping, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.keyDown($0) }
        } else if !available, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            resetTyping()
        }
        guard available, !settings.recordingReadyHintShown, shortcut != nil else { return }
        settings.recordingReadyHintShown = true
        enqueue(.ready)
    }

    func recordingStarted() {
        resetTyping()
        queue.removeAll { if case .reminder = $0 { return true }; return false }
        if case .reminder = current { dismiss() }
    }

    func foregroundChanged() {
        resetTyping()
        if case .reminder(let app) = current, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != app {
            dismiss()
        }
        permissionsChanged()
    }

    func openRecommendation(_ bundle: String, onFailure: (() -> Void)? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            onFailure?()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] app, error in
            let opened = app != nil && error == nil
            DispatchQueue.main.async {
                if opened { self?.scheduleRecommendation(bundle) }
                else { onFailure?() }
            }
        }
    }

    private func scheduleRecommendation(_ bundle: String) {
        guard !settings.recommendedRecordingHintShown else { return }
        recommendations?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.eligible, self.isIdle(), self.shortcut != nil,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle,
                  !self.settings.recommendedRecordingHintShown else { return }
            self.settings.recommendedRecordingHintShown = true
            self.showReminder(in: bundle)
        }
        recommendations = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private var eligible: Bool {
        settings.onboardingDone && permissionsReady()
    }

    private var shortcut: String? {
        guard let key = [settings.hotkeyMain, settings.hotkeyAlt].first(where: \.enabled) else { return nil }
        return key.isFn ? "Fn" : HotKeyCentre.describe(keyCode: key.keyCode, modifiers: key.modifiers)
    }

    private func keyDown(_ event: NSEvent) {
        // Count only the occurrence of a typing key, never characters or field contents.
        guard settings.onboardingDone, isIdle(), AXIsProcessTrusted(), !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .function]).isEmpty,
              event.keyCode <= 50, event.keyCode != 48,
              let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              app != Bundle.main.bundleIdentifier,
              TypingHintWindow.permitsReminder(lastShown: settings.recordingReminderLastShown, now: Date())
        else { return }
        if pendingApp != app { resetTyping(); pendingApp = app }
        pendingKeys.append(ProcessInfo.processInfo.systemUptime)
        scheduleFocusCheck()
    }

    private func scheduleFocusCheck() {
        guard probe == nil, !focusCheckInFlight, !pendingKeys.isEmpty, let app = pendingApp else { return }
        let generation = focusGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.focusGeneration == generation else { return }
            self.probe = nil
            self.focusCheckInFlight = true
            self.lastProbeAt = ProcessInfo.processInfo.systemUptime
            let keys = self.pendingKeys
            self.pendingKeys.removeAll(keepingCapacity: true)
            DispatchQueue.global(qos: .utility).async {
                let editable = FieldContextReader.hasEditableFocus(in: app)
                DispatchQueue.main.async { self.acceptFocusCheck(editable, keys: keys, app: app, generation: generation) }
            }
        }
        probe = work
        let delay = max(0, lastProbeAt + 0.35 - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func acceptFocusCheck(_ editable: Bool, keys: [TimeInterval], app: String, generation: Int) {
        focusCheckInFlight = false
        defer { scheduleFocusCheck() }
        guard focusGeneration == generation, isIdle(),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app else { return }
        guard editable else { return }
        if typing.record(keys, in: app, now: ProcessInfo.processInfo.systemUptime), eligible, shortcut != nil {
            showReminder(in: app)
        }
    }

    private func resetTyping() {
        focusGeneration += 1
        probe?.cancel()
        probe = nil
        pendingApp = nil
        pendingKeys.removeAll(keepingCapacity: true)
        typing.reset()
    }

    private func showReminder(in app: String) {
        resetTyping()
        enqueue(.reminder(app))
    }

    private func enqueue(_ hint: Hint) {
        guard hint != current, !queue.contains(hint) else { return }
        queue.append(hint)
        presentNext()
    }

    private func presentNext() {
        guard current == nil, !queue.isEmpty else { return }
        let hint = queue.removeFirst()
        guard let shortcut, eligible else { presentNext(); return }
        if case .reminder(let app) = hint,
           !isIdle() || NSWorkspace.shared.frontmostApplication?.bundleIdentifier != app {
            presentNext()
            return
        }
        let isReady = hint == .ready
        let view: NSView
        if isReady {
            let host = HintHost(rootView: ReadyCard(shortcut: shortcut) { [weak self] in self?.dismiss() })
            host.frame = NSRect(x: 0, y: 0, width: 324, height: 128)
            view = host
        } else {
            let host = NSHostingView(rootView: TypingReminderPill(shortcut: shortcut))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            view = host
        }
        let card = PillPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if !isReady { card.appearance = VoiceBarPalette.appearance }
        card.contentView = view
        card.isFloatingPanel = true
        card.becomesKeyOnlyIfNeeded = true
        card.level = .statusBar
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        card.hidesOnDeactivate = false
        card.isReleasedWhenClosed = false
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = true
        card.ignoresMouseEvents = !isReady
        card.animationBehavior = .none
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(x: (area.midX - card.frame.width / 2).rounded(), y: area.minY + 72)
        if !isReady { settings.recordingReminderLastShown = Date() }
        card.setFrameOrigin(origin)
        current = hint
        panel = card
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            card.alphaValue = 0
            if isReady { card.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 10)) }
        }
        card.orderFrontRegardless()
        if card.alphaValue == 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = VoiceBarGeometry.shapeDuration
                card.animator().setFrameOrigin(origin)
                card.animator().alphaValue = 1
            }
        }
        let work = DispatchWorkItem { [weak self, weak card] in
            guard let self, self.panel === card else { return }
            self.dismiss()
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isReady ? 999 : 3), execute: work)
    }

    private func dismiss() {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
        current = nil
        presentNext()
    }

    private final class HintHost: NSHostingView<ReadyCard> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private struct ReadyCard: View {
        let shortcut: String
        let dismiss: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("可以开始听写了"))
                    .font(.system(size: 15, weight: .semibold))
                Label(L10n.text("按下 {0} 即可听写", shortcut), systemImage: "waveform")
                    .font(.system(size: 13))
                Button(L10n.text("明白了"), action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .hoverFeedback(.compact)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
        }
    }
}

private struct TypingReminderPill: View {
    let shortcut: String
    private static let message = "按下 {0} 即可听写"
    private static let waveform: [CGFloat] = [5, 9, 14, 11, 6]
    private let ink = Color(nsColor: VoiceBarPalette.ink)
    private let edge = Color(nsColor: VoiceBarPalette.edge)

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: VoiceBarGeometry.waveformBarGap) {
                ForEach(Self.waveform.indices, id: \.self) { index in
                    Capsule().fill(ink.opacity(0.86))
                        .frame(width: VoiceBarGeometry.waveformBarWidth, height: Self.waveform[index])
                }
            }
            HStack(spacing: 5) {
                let template = L10n.text(Self.message)
                if let slot = template.range(of: "{0}") {
                    Text(template[..<slot.lowerBound].trimmingCharacters(in: .whitespaces))
                    Text(shortcut)
                        .font(.custom("AvenirNext-DemiBold", size: 12))
                        .padding(.horizontal, 7)
                        .frame(height: 21)
                        .background(ink.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(edge.opacity(0.75)))
                    Text(template[slot.upperBound...].trimmingCharacters(in: .whitespaces))
                } else {
                    Text(L10n.text(Self.message, shortcut))
                }
            }
            .font(L10n.language == "en" ? .custom("AvenirNext-Medium", size: 13)
                                       : InterfaceTypography.localized(13, weight: .medium))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 13)
        .frame(height: PillView.height)
        .background(Color(nsColor: VoiceBarPalette.surfaceTop), in: Capsule())
        .overlay(Capsule().strokeBorder(edge))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.text(Self.message, shortcut)))
    }
}
