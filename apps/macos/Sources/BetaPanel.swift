import AppKit
import SwiftUI

// BetaPanel.swift - Prompt Beta's questions. A non-activating floating panel, so the text
// field the user dictated into keeps focus and the answer is pasted back there.


final class BetaPanel {
    private var panel: NSPanel?
    var onSkip: (() -> Void)?
    var onCancel: (() -> Void)?

    private var shown: (info: BetaInfo, hotkey: String)?

    var isVisible: Bool { panel?.isVisible == true }

    /// While an answer is being recorded or checked the questions stay on screen (the user reads
    /// them while speaking); the status replaces the hint and the buttons wait.
    func setBusy(_ status: String?) {
        guard let shown, isVisible else { return }
        show(info: shown.info, hotkey: shown.hotkey, busy: status)
    }

    func show(info: BetaInfo, hotkey: String, busy: String? = nil) {
        let firstShow = !isVisible
        shown = (info, hotkey)
        let view = BetaQuestionsView(info: info, hotkey: hotkey, busy: busy,
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
        // Only placed when it appears: a busy update keeps it where the user may have moved it.
        if firstShow, let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 440 - 24, y: f.maxY - p.frame.height - 24))
        }
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

struct BetaQuestionsView: View {
    let info: BetaInfo
    let hotkey: String
    var busy: String? = nil
    let skip: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("提示词 Beta · 第 {0} 轮", info.round ?? 1))
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
            Text(info.ready == true ? L10n.text("信息已清楚，可继续补充或生成。") : L10n.text("先把信息说清楚"))
                .font(.system(size: 12)).foregroundColor(Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let confirmed = info.confirmed, !confirmed.isEmpty {
                        Text(L10n.text("当前理解，请核对")).font(.system(size: 12, weight: .semibold))
                        ForEach(Array(confirmed.enumerated()), id: \.offset) { _, text in
                            Text("• " + text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let questions = info.questions, !questions.isEmpty {
                        Text(L10n.text("待补充的信息")).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                            Text(String(index + 1) + ". " + question).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 240)
            if let notice = info.notice {
                Text(BetaMessages.notice(notice)).font(.system(size: 12)).foregroundColor(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(busy ?? L10n.text("按 {0} 继续补充，点「生成」结束。", hotkey))
                .font(.system(size: 11.5)).foregroundColor(busy == nil ? Theme.secondary : Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("取消"), action: cancel).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("结束补充并生成"), action: skip).buttonStyle(PrimaryButtonStyle())
            }.disabled(busy != nil)
        }
        .padding(EdgeInsets(top: 30, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 440, alignment: .leading)
    }
}
