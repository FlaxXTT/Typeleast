import AppKit

/// An editable, non-modal panel. No dictionary writes and no automatic insertion.
final class NameConfirmationPanel: NSObject, NSWindowDelegate {
    enum Choice { case edit(String), original, supplement, retry, cancel }
    private var panel: NSPanel?
    private var reply: ((Choice) -> Void)?
    private var editor: NSTextView?
    private var frontApp: NSRunningApplication?

    func show(question: String, raw: String, kind: String? = nil, reply: @escaping (Choice) -> Void) {
        dismiss()
        self.reply = reply
        frontApp = NSWorkspace.shared.frontmostApplication
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = L10n.text(kind == "quality" ? "检查整理结果" : kind == "explanation" ? "检查解释触发词" : "确认本次名称")
        p.minSize = NSSize(width: 520, height: 320)
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let label = NSTextField(wrappingLabelWithString: L10n.text(kind == "quality" ? "本次整理尚未完成。可继续整理，或编辑后确认插入；不会自动插入原文。" : kind == "explanation" ? "开始词与结束词须成对出现。可继续口述补全，或编辑本次内容。" : "名称有歧义，请补充全称、用途或拼写。确认前不会粘贴。"))
        let detail = NSTextField(wrappingLabelWithString: question)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let text = NSTextView()
        text.string = raw
        text.font = .systemFont(ofSize: 14)
        text.isRichText = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let row = NSStackView()
        row.spacing = 8
        let buttons: [(String,Selector)] = kind == "quality" ? [("继续整理",#selector(retry)),("使用修改内容",#selector(accept)),("取消",#selector(cancel))] : [("使用修改内容",#selector(accept)),("继续口述",#selector(supplement)),("保留原文",#selector(original)),("取消",#selector(cancel))]
        for (title, action) in buttons {
            row.addArrangedSubview(NSButton(title: L10n.text(title), target: self, action: action))
        }
        for view in [label, detail, scroll, row] { stack.addArrangedSubview(view) }
        p.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        editor = text
        panel = p
        p.center()
        p.orderFrontRegardless()
    }

    private func finish(_ choice: Choice) {
        let callback = reply
        // Restore only our panel's focus, never steal focus from another application.
        let restore = panel?.isKeyWindow == true && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        dismiss()
        if restore { frontApp?.activate(options: []) }
        frontApp = nil
        callback?(choice)
    }
    @objc private func accept() {
        let text = editor?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, text.count <= 32000 else { NSSound.beep(); return }
        finish(.edit(text))
    }
    @objc private func retry() { finish(.retry) }
    @objc private func original() { finish(.original) }
    @objc private func supplement() { finish(.supplement) }
    @objc private func cancel() { finish(.cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return false }
    func dismiss() { reply = nil; panel?.delegate = nil; panel?.close(); panel = nil; editor = nil }
}
