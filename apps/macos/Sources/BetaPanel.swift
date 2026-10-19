import AppKit
import SwiftUI

// BetaPanel.swift - Prompt Beta's questions. A non-activating floating panel, so the text
// field the user dictated into keeps focus and the answer is pasted back there.

struct BetaPending {
    let sessionId: String
    let questions: [String]
    let appBundleId: String
    let field: FocusedField?
}

final class BetaPanel {
    private var panel: NSPanel?
    var onSkip: (() -> Void)?
    var onCancel: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func show(questions: [String], hotkey: String) {
        let view = BetaQuestionsView(questions: questions, hotkey: hotkey,
                                     skip: { [weak self] in self?.onSkip?() },
                                     cancel: { [weak self] in self?.onCancel?() })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            panel = p
        }
        p.contentView = host
        p.setContentSize(NSSize(width: 440, height: max(size.height, 160)))
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 440 - 24, y: f.maxY - p.frame.height - 24))
        }
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct BetaQuestionsView: View {
    let questions: [String]
    let hotkey: String
    let skip: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(L10n.text("提示词 Beta")).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
                Text(L10n.text("先回答几个问题")).font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(index + 1) + ".").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.secondary)
                        Text(question).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(L10n.text("按 {0} 口头回答，一次说完所有问题即可；没回答的会列进「待确认」。", hotkey))
                .font(.system(size: 11.5)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("取消"), action: cancel).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("跳过，直接生成"), action: skip).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(EdgeInsets(top: 30, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 440, alignment: .leading)
    }
}
