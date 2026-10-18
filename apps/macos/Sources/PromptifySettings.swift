import SwiftUI
import AppKit

// PromptifySettings.swift - the system prompt of prompt mode (提示词模式).
//
// The default prompt is locked: it is shown read-only, and the user adds their
// own instructions at the end. Replacing the default is possible but guarded:
// a serious warning, a second confirmation, and a one-time code to type. Once it
// has been replaced, "恢复默认" puts the default back in one step.

struct PromptifySection: View {
    @EnvironmentObject var model: AppModel
    @State private var settings: PromptifySettings?
    @State private var appendix = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var status = ""
    @State private var statusOK = true

    var body: some View {
        SettingsSection(title: "提示词模式的系统提示词") {
            if let s = settings {
                HStack(spacing: 8) {
                    Image(systemName: s.modified ? "exclamationmark.triangle.fill" : "lock.fill")
                        .foregroundColor(s.modified ? Theme.warning : Theme.secondary)
                    Text(s.modified ? "默认提示词已被修改" : "默认提示词（锁定，不能直接删改）")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if s.modified {
                        Button("恢复默认") { restoreDefault() }.buttonStyle(PrimaryButtonStyle())
                    }
                    if !editing {
                        Button("修改默认提示词…") { beginEdit(s) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                if editing {
                    Text("正在修改默认提示词。保存后，提示词模式会用你的版本；随时可以「恢复默认」。")
                        .font(.system(size: 12)).foregroundColor(Theme.warning)
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 260)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.warning.opacity(0.6)))
                    HStack {
                        Button("保存修改") { saveOverride() }.buttonStyle(PrimaryButtonStyle())
                        Button("取消") { editing = false }.buttonStyle(SecondaryButtonStyle())
                        Spacer()
                    }
                } else {
                    ScrollView {
                        Text(s.override ?? s.default)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                }
                Text("追加内容（加在提示词结尾，作为「补充要求」）")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 6)
                Text("例如：「所有提示词都用英文写」「输出格式一律用 Markdown 表格」。不影响上面的默认内容。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                TextEditor(text: $appendix)
                    .font(.system(size: 13))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.secondary.opacity(0.3)))
                HStack(spacing: 10) {
                    Button("保存追加内容") { saveAppendix() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(appendix.trimmingCharacters(in: .whitespacesAndNewlines) == s.appendix)
                    if !status.isEmpty {
                        Text(status).font(.system(size: 12)).foregroundColor(statusOK ? Theme.success : Theme.warning)
                    }
                    Spacer()
                }
            } else {
                Text(status.isEmpty ? "正在读取…" : status)
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
        }
        .onAppear { load() }
    }

    // MARK: actions

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.promptifySync() }
            DispatchQueue.main.async {
                switch result {
                case .success(let s):
                    settings = s
                    appendix = s.appendix
                case .failure:
                    status = "本地服务还没就绪，就绪后再打开这一页。"
                }
            }
        }
    }

    private func apply(_ work: @escaping () throws -> PromptifySettings, done message: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                switch result {
                case .success(let s):
                    settings = s
                    appendix = s.appendix
                    status = message
                    statusOK = true
                case .failure(let error):
                    status = "保存失败：" + ((error as? ServiceError)?.description ?? error.localizedDescription)
                    statusOK = false
                }
            }
        }
    }

    private func saveAppendix() {
        let text = appendix
        apply({ try ServiceClient.shared.setPromptifySync(appendix: text) }, done: "追加内容已保存")
    }

    /// Three gates: a serious warning, a second confirmation, and a typed code.
    private func beginEdit(_ s: PromptifySettings) {
        let first = NSAlert()
        first.alertStyle = .critical
        first.messageText = "修改默认提示词有风险"
        first.informativeText = "默认提示词经过调校：它规定了固定的提示词结构，并要求模型不得编造数字、日期、人名等事实。改动它可能让提示词模式的效果明显变差，甚至输出不可用的内容。\n\n如果只是想加要求，请用下面的「追加内容」，那不会影响默认提示词。"
        first.addButton(withTitle: "取消")
        first.addButton(withTitle: "我了解风险，继续")
        guard first.runModal() == .alertSecondButtonReturn else { return }

        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "再次确认：要修改默认提示词吗？"
        second.informativeText = "修改后，提示词模式会完全使用你的版本。你随时可以在这里点「恢复默认」。"
        second.addButton(withTitle: "取消")
        second.addButton(withTitle: "确定修改")
        guard second.runModal() == .alertSecondButtonReturn else { return }

        let code = PromptifyGuard.makeCode()
        let third = NSAlert()
        third.alertStyle = .warning
        third.messageText = "输入验证码以解锁"
        third.informativeText = "请输入下面的 6 位验证码：\n\n" + code
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "6 位数字"
        third.accessoryView = field
        third.addButton(withTitle: "解锁")
        third.addButton(withTitle: "取消")
        third.window.initialFirstResponder = field
        guard third.runModal() == .alertFirstButtonReturn else { return }
        guard PromptifyGuard.matches(typed: field.stringValue, code: code) else {
            status = "验证码不对，没有解锁。"
            statusOK = false
            return
        }
        draft = s.override ?? s.default
        editing = true
        status = ""
    }

    private func saveOverride() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "提示词不能为空；想用默认的请点「恢复默认」。"
            statusOK = false
            return
        }
        editing = false
        apply({ try ServiceClient.shared.setPromptifySync(override: .some(text)) }, done: "已保存你的提示词")
    }

    private func restoreDefault() {
        let alert = NSAlert()
        alert.messageText = "恢复默认提示词？"
        alert.informativeText = "你修改过的版本会被丢弃，追加内容保留。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        editing = false
        apply({ try ServiceClient.shared.setPromptifySync(override: .some(nil)) }, done: "已恢复默认提示词")
    }
}
