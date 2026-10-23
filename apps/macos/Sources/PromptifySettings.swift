import SwiftUI
import AppKit

// Prompt text stays in a configuration file, never in a page-sized editor.
struct PromptifySection: View {
    @EnvironmentObject var model: AppModel
    @State private var settings: PromptifySettings?
    @State private var status = ""
    @State private var statusOK = true

    var body: some View {
        SettingsSection(title: L10n.text("提示词模式的系统提示词")) {
            Text(settings == nil ? L10n.text("正在读取…") : settings?.modified == true ? L10n.text("默认提示词已被修改") : L10n.text("正在使用默认提示词"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(settings?.modified == true ? Theme.warning : Theme.secondary)
            Text(L10n.text("默认提示词不建议修改。需要调整时，在配置文件中编辑；保存后下一次整理生效。"))
                .font(.system(size: 12)).foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("配置文件仅影响标准格式档；普通档使用内置规则。"))
                .font(.system(size: 12)).foregroundColor(Theme.secondary)
            HStack {
                Button(L10n.text("打开配置文件…")) { openConfiguration() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(settings == nil)
                if settings?.modified == true {
                    Button(L10n.text("恢复默认")) { restoreDefault() }.buttonStyle(SecondaryButtonStyle())
                }
                Button(L10n.text("重新读取")) { load() }.buttonStyle(SecondaryButtonStyle())
            }
            if !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundColor(statusOK ? Theme.success : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in load() }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.promptifySync() }
            DispatchQueue.main.async {
                switch result {
                case .success(let s): settings = s
                case .failure: status = L10n.text("本地服务还没就绪，就绪后再打开这一页。"); statusOK = false
                }
            }
        }
    }

    /// Three gates: a serious warning, a second confirmation, and a typed code.
    private func openConfiguration() {
        let first = NSAlert()
        first.alertStyle = .critical
        first.messageText = L10n.text("修改默认提示词有风险")
        first.informativeText = L10n.text("默认提示词用于忠实保留你的意思，不建议修改。改动可能使结果偏离原意。只需补充要求时，请只修改配置文件中的 appendix，保留 override。")
        first.addButton(withTitle: L10n.text("取消"))
        first.addButton(withTitle: L10n.text("我了解风险，继续"))
        guard first.runModal() == .alertSecondButtonReturn else { return }

        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = L10n.text("再次确认：要修改默认提示词吗？")
        second.informativeText = L10n.text("修改后，提示词模式会完全使用你的版本。你随时可以在这里点「恢复默认」。")
        second.addButton(withTitle: L10n.text("取消"))
        second.addButton(withTitle: L10n.text("确定修改"))
        guard second.runModal() == .alertSecondButtonReturn else { return }

        let code = PromptifyGuard.makeCode()
        let third = NSAlert()
        third.alertStyle = .warning
        third.messageText = L10n.text("输入验证码以解锁")
        third.informativeText = L10n.text("请输入下面的 6 位验证码：\n\n") + code
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = L10n.text("6 位数字")
        third.accessoryView = field
        third.addButton(withTitle: L10n.text("解锁"))
        third.addButton(withTitle: L10n.text("取消"))
        third.window.initialFirstResponder = field
        guard third.runModal() == .alertFirstButtonReturn else { return }
        guard PromptifyGuard.matches(typed: field.stringValue, code: code) else {
            status = L10n.text("验证码不对，没有解锁。")
            statusOK = false
            return
        }
        guard let s = settings else { return }
        let path = (ServiceClient.stateDirectory as NSString).appendingPathComponent("promptify.json")
        do {
            let existing = FileManager.default.contents(atPath: path)
            let data = try PromptifyConfigFile.editableData(existing: existing, settings: s)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { throw CocoaError(.fileNoSuchFile) }
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: editor,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            status = L10n.text("保存配置文件后，下一次整理生效。"); statusOK = true
        } catch {
            status = L10n.text("配置文件无法打开，原文件已保留。请检查格式和文件权限。"); statusOK = false
        }
    }

    private func restoreDefault() {
        let alert = NSAlert()
        alert.messageText = L10n.text("恢复默认提示词？")
        alert.informativeText = L10n.text("你修改过的版本会被丢弃，追加内容保留。")
        alert.addButton(withTitle: L10n.text("恢复默认"))
        alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.setPromptifySync(override: .some(nil)) }
            DispatchQueue.main.async {
                switch result {
                case .success(let s): settings = s; status = L10n.text("已恢复默认提示词"); statusOK = true
                case .failure: status = L10n.text("保存失败，请重试。"); statusOK = false
                }
            }
        }
    }
}
