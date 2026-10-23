import AppKit
import SwiftUI

// LearnedToast.swift - "已把「DeepSeek」加入词典 · 撤销", shown for a few seconds when the
// edit learner adds a word. A non-activating panel above the recording pill, so the app
// being typed into keeps focus; 撤销 removes the word again.

final class LearnedToast {
    static let duration: TimeInterval = 6

    private var panel: NSPanel?
    private var hideTimer: Timer?

    func show(word: String, undo: @escaping () -> Void) {
        let view = LearnedToastView(word: word, undo: { [weak self] in
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
        hideTimer?.invalidate()
        let t = Timer(timeInterval: LearnedToast.duration, repeats: false) { [weak self] _ in self?.hide() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }
}

struct LearnedToastView: View {
    let word: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.text("已把「") + word + L10n.text("」加入词典"))
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            Button(L10n.text("撤销"), action: undo).buttonStyle(SecondaryButtonStyle())
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 10))
        .background(Capsule().fill(Theme.window))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
    }
}
