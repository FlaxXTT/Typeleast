import AppKit
import SwiftUI
import QuartzCore

// A non-activating undo capsule above the recording pill keeps focus in the target app.

final class LearnedToast {
    private static let undoDuration: TimeInterval = 2.5
    private static let fadeDuration: TimeInterval = 0.25

    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var dismissalID = UUID()
    /// Called when the toast goes away without 撤销 (timed out or replaced).
    private var expired: (() -> Void)?

    func show(message: String, undo: @escaping () -> Void, expired: (() -> Void)? = nil) {
        finish()
        self.expired = expired
        let view = LearnedToastView(message: message, undo: { [weak self] in
            self?.expired = nil
            undo()
            self?.hide()
        })
        let host = NSHostingView(rootView: view)
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            panel = p
        }
        p.contentView = host
        p.setContentSize(size)
        // The SwiftUI card owns its corner shape. A window-radius mask cuts off its border.
        p.invalidateShadow()
        // Bottom-centre of the screen the mouse is on, above the recording pill.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 110))
        }
        p.orderFrontRegardless()
        let t = Timer(timeInterval: Self.undoDuration, repeats: false) { [weak self] _ in self?.fadeOut() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    /// Go away now; anything waiting on 撤销 is dropped.
    func finish() {
        let done = expired
        expired = nil
        hide()
        done?()
    }

    private func hide() {
        dismissalID = UUID()
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.ignoresMouseEvents = false
        }
    }

    /// Disable undo when its window expires, then fade the card.
    private func fadeOut() {
        hideTimer = nil
        let done = expired
        expired = nil
        done?()
        guard let panel else { return }
        panel.ignoresMouseEvents = true
        let id = UUID()
        dismissalID = id
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.dismissalID == id else { return }
            self.hide()
        }
    }
}

struct LearnedToastView: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        let shape = Capsule(style: .circular)
        let ink = Color(nsColor: VoiceBarPalette.ink)
        HStack(spacing: 6) {
            Text(message)
                .font(InterfaceTypography.localized(12, weight: .semibold))
                .foregroundColor(ink)
                .lineLimit(1)
            Button(action: undo) {
                Text(L10n.text("撤销"))
                    .font(InterfaceTypography.localized(12, weight: .medium))
                    .foregroundColor(ink)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(shape.fill(ink.opacity(0.16)))
            }
            .buttonStyle(FlatActionButtonStyle(cornerRadius: Theme.capsuleRadius))
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(minWidth: RecordingBarMode.handsFree.width)
        .frame(height: PillView.height)
        .fixedSize()
        .background(Color(nsColor: VoiceBarPalette.surfaceTop), in: shape)
        .overlay(shape.strokeBorder(Color(nsColor: VoiceBarPalette.edge)).allowsHitTesting(false))
    }
}
