import AppKit
import SwiftUI

// BetaPanel.swift - Prompt Beta's questions. A non-activating floating panel, so the text
// field the user dictated into keeps focus and the answer is pasted back there.


final class BetaPanel {
    private var panel: NSPanel?
    var onContinue: (() -> Void)?
    var onSkip: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A chosen or typed answer, sent without recording.
    var onAnswer: ((String) -> Void)?

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
                                     resume: { [weak self] in self?.onContinue?() },
                                     answer: { [weak self] in self?.onAnswer?($0) },
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
    var resume: () -> Void = {}
    var answer: (String) -> Void = { _ in }
    let skip: () -> Void
    let cancel: () -> Void
    @State private var chosen: [String: String] = [:]

    /// One-click answers for the boundary questions the service asks first.
    static func choices(for question: String) -> [String] {
        if question.contains("联网") || question.contains("search the web") {
            return [L10n.text("全部文件，可联网"), L10n.text("全部文件，仅本地"), L10n.text("只读我指定的文件")]
        }
        if question.contains("创新") || question.contains("new ideas") { return [L10n.text("创新探索"), L10n.text("重复执行")] }
        if question.contains("轮子") || question.contains("existing projects") { return [L10n.text("先找已有项目"), L10n.text("不用找")] }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("提示词模式 · 第 {0} 轮", info.round ?? 1))
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let goals = info.goals, !goals.isEmpty {
                        section(L10n.text("核心目的"), goals)
                    }
                    if let confirmed = info.confirmed, !confirmed.isEmpty {
                        section(info.goals?.isEmpty == false ? L10n.text("关键细节") : L10n.text("我的理解，请核对"), confirmed)
                    }
                    if let questions = info.questions, !questions.isEmpty {
                        Text(L10n.text("需要你说明")).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                        ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(index + 1) + ". " + question).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                let options = BetaQuestionsView.choices(for: question)
                                if !options.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(options, id: \.self) { option in
                                            Button(option) { chosen[question] = chosen[question] == option ? nil : option }
                                                .buttonStyle(ChoiceChipStyle(selected: chosen[question] == option))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 300)
            if let notice = info.notice {
                Text(BetaMessages.notice(notice)).font(.system(size: 12)).foregroundColor(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(busy ?? L10n.text("点选或按 {0} 语音补充，点「生成」结束。", hotkey))
                .font(.system(size: 11.5)).foregroundColor(busy == nil ? Theme.secondary : Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("取消"), action: cancel).buttonStyle(SecondaryButtonStyle())
                if chosen.isEmpty {
                    Button(L10n.text("语音补充"), action: resume).buttonStyle(SecondaryButtonStyle()).disabled(busy != nil)
                } else {
                    Button(L10n.text("发送选择")) {
                        let questions = info.questions ?? []
                        answer(questions.compactMap { q in chosen[q].map { q + " " + $0 } }.joined(separator: "\n"))
                        chosen = [:]
                    }.buttonStyle(SecondaryButtonStyle()).disabled(busy != nil)
                }
                Spacer()
                Button(L10n.text("生成"), action: skip).buttonStyle(PrimaryButtonStyle()).disabled(busy != nil)
            }
        }
        .padding(EdgeInsets(top: 30, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 440, alignment: .leading)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, text in
                Text("• " + text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small pill that stays highlighted once chosen.
private struct ChoiceChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(selected ? Theme.inkInverse : Theme.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Theme.ink : Theme.card))
            .overlay(Capsule().stroke(Theme.border))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
