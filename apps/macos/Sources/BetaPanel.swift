import AppKit
import SwiftUI

// BetaPanel.swift - Prompt Beta's questions. A non-activating floating panel, so the text
// field the user dictated into keeps focus and the answer is pasted back there.

/// What the panel shows. One instance lives as long as the panel, so a status update or a new
/// round changes the view in place and the chosen answers stay until the questions change.
final class BetaPanelModel: ObservableObject {
    @Published var info = BetaInfo()
    @Published var hotkey = ""
    @Published var busy: String?
    /// One-click answers, by question.
    @Published var chosen: [String: String] = [:]

    /// The chosen answers as one reply, or nil when none is chosen.
    var chosenAnswer: String? {
        let lines = (info.questions ?? []).compactMap { q in chosen[q].map { q + " " + $0 } }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// A click on a panel that is not key acts at once instead of only focusing it.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class BetaPanel {
    private var panel: NSPanel?
    let model = BetaPanelModel()
    var onContinue: (() -> Void)?
    /// 生成, with the chosen answers that were not sent yet.
    var onSkip: ((String?) -> Void)?
    var onCancel: (() -> Void)?
    /// A chosen or typed answer, sent without recording.
    var onAnswer: ((String) -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    /// While an answer is being recorded or checked the questions stay on screen (the user reads
    /// them while speaking); the status replaces the hint and the buttons wait.
    func setBusy(_ status: String?) {
        guard isVisible else { return }
        model.busy = status
    }

    /// `anchor` is the cursor the prompt will go to: the panel appears beside it, on its screen.
    func show(info: BetaInfo, hotkey: String, busy: String? = nil, anchor: NSRect? = nil) {
        let firstShow = !isVisible
        if model.info.sessionId != info.sessionId || model.info.questions != info.questions { model.chosen = [:] }
        model.info = info
        model.hotkey = hotkey
        model.busy = busy
        let p = panel ?? makePanel()
        p.contentView?.layoutSubtreeIfNeeded()
        let height = max(p.contentView?.fittingSize.height ?? 0, 160)
        p.setContentSize(NSSize(width: 440, height: height))
        // Only placed when it appears: a later update keeps it where the user may have moved it.
        if firstShow { place(p, anchor: anchor) }
        p.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
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
        // Also over a full-screen app and on whichever Space the user is in.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let model = self.model
        p.contentView = FirstClickHostingView(rootView: BetaQuestionsView(model: model,
            resume: { [weak self] in self?.onContinue?() },
            answer: { [weak self] in self?.onAnswer?($0) },
            skip: { [weak self] in self?.onSkip?($0) },
            cancel: { [weak self] in self?.onCancel?() }))
        panel = p
        return p
    }

    /// Beside the cursor (not over the line being written), else the top right of the screen
    /// with the mouse; always fully on that screen.
    private func place(_ p: NSPanel, anchor: NSRect?) {
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let f = screen.visibleFrame, size = p.frame.size, gap: CGFloat = 16
        var origin: NSPoint
        if let a = anchor {
            let x = a.maxX + gap + size.width <= f.maxX ? a.maxX + gap : a.minX - gap - size.width
            origin = NSPoint(x: x, y: a.maxY - size.height)
        } else {
            origin = NSPoint(x: f.maxX - size.width - 24, y: f.maxY - size.height - 24)
        }
        origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
        origin.y = min(max(origin.y, f.minY + 8), f.maxY - size.height - 8)
        p.setFrameOrigin(origin)
    }
}

struct BetaQuestionsView: View {
    @ObservedObject var model: BetaPanelModel
    var resume: () -> Void = {}
    var answer: (String) -> Void = { _ in }
    let skip: (String?) -> Void
    let cancel: () -> Void

    /// A fixed view of one round, for renders and tests.
    init(info: BetaInfo, hotkey: String, skip: @escaping (String?) -> Void, cancel: @escaping () -> Void) {
        let model = BetaPanelModel()
        model.info = info
        model.hotkey = hotkey
        self.init(model: model, skip: skip, cancel: cancel)
    }

    init(model: BetaPanelModel, resume: @escaping () -> Void = {}, answer: @escaping (String) -> Void = { _ in },
         skip: @escaping (String?) -> Void, cancel: @escaping () -> Void) {
        self.model = model
        self.resume = resume
        self.answer = answer
        self.skip = skip
        self.cancel = cancel
    }

    private var info: BetaInfo { model.info }

    /// One-click answers for the boundary questions the service asks first.
    static func choices(for question: String) -> [String] {
        if question.contains("联网") || question.contains("search the web") {
            return [L10n.text("全部文件，可联网"), L10n.text("全部文件，仅本地"), L10n.text("只读我指定的文件")]
        }
        if question.contains("轮子") || question.contains("existing projects") { return [L10n.text("先找已有项目"), L10n.text("不用找")] }
        if question.contains("创新") || question.contains("new ideas") { return [L10n.text("创新探索"), L10n.text("重复执行")] }
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
                                            Button(option) { model.chosen[question] = model.chosen[question] == option ? nil : option }
                                                .buttonStyle(ChoiceChipStyle(selected: model.chosen[question] == option))
                                                .disabled(model.busy != nil)
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
            Text(model.busy ?? L10n.text("点选或按 {0} 语音补充，点「生成」结束。", model.hotkey))
                .font(.system(size: 11.5)).foregroundColor(model.busy == nil ? Theme.secondary : Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("取消"), action: cancel).buttonStyle(SecondaryButtonStyle())
                if let chosen = model.chosenAnswer {
                    Button(L10n.text("发送选择")) {
                        model.chosen = [:]
                        answer(chosen)
                    }.buttonStyle(SecondaryButtonStyle()).disabled(model.busy != nil)
                } else {
                    Button(L10n.text("语音补充"), action: resume).buttonStyle(SecondaryButtonStyle()).disabled(model.busy != nil)
                }
                Spacer()
                // Chosen answers not sent yet go with 生成 rather than being dropped.
                Button(L10n.text("生成")) {
                    let chosen = model.chosenAnswer
                    model.chosen = [:]
                    skip(chosen)
                }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy != nil)
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
