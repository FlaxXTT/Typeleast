import AppKit
import SwiftUI

// LearnedToast.swift - a short message with 撤销, shown for a few seconds: "转录已取消" after a
// cancelled recording, "已把「DeepSeek」加入词典" after the edit learner adds a word. A
// non-activating panel above the recording pill, so the app being typed into keeps focus.

final class LearnedToast {
    static let duration: TimeInterval = 6

    private var panel: NSPanel?
    private var hideTimer: Timer?
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
        let size = host.fittingSize
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
        // Bottom-centre of the screen the mouse is on, above the recording pill.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 110))
        }
        p.orderFrontRegardless()
        let t = Timer(timeInterval: LearnedToast.duration, repeats: false) { [weak self] _ in self?.finish() }
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
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }
}

struct LearnedToastView: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(red: 0.45, green: 0.55, blue: 1.0))
            Text(message)
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            Button(action: undo) {
                Text(L10n.text("撤销")).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12)))
    }
}
