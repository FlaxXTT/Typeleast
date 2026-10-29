import SwiftUI
import AppKit
import UniformTypeIdentifiers

// HubPages.swift - Home, History and Dictionary.

// MARK: - shared helpers

enum AppNames {
    private static var cache: [String: String] = [:]

    /// Names for common apps that may not be installed on this Mac (history can
    /// outlive an uninstall, and synced machines differ).
    private static let known: [String: String] = [
        "com.tencent.xinWeChat": L10n.text("微信"), "com.tencent.qq": "QQ", "com.tencent.WeWorkMac": L10n.text("企业微信"),
        "com.electron.lark": L10n.text("飞书"), "com.bytedance.lark": L10n.text("飞书"), "com.alibaba.DingTalkMac": L10n.text("钉钉"),
        "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord", "ru.keepcoder.Telegram": "Telegram",
        "com.apple.mail": L10n.text("邮件"), "com.apple.Notes": L10n.text("备忘录"), "com.apple.MobileSMS": L10n.text("信息"),
        "notion.id": "Notion", "md.obsidian": "Obsidian", "com.deepseek.dsh": "DeepSeek Harness",
    ]

    /// "com.apple.mail" -> "邮件"; falls back to the bundle id.
    static func name(for bundleId: String?) -> String {
        guard let id = bundleId, !id.isEmpty else { return L10n.text("未知应用") }
        if let cached = cache[id] { return cached }
        var name = known[id] ?? id
        if known[id] == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        cache[id] = name
        return name
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = L10n.text("M月d日 EEEE")
        return f
    }()

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.text("今天") }
        if calendar.isDateInYesterday(date) { return L10n.text("昨天") }
        return day.string(from: date)
    }

    static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func duration(_ seconds: Double) -> (String, String) {
        if seconds < 60 { return (seconds < 1 ? "0" : String(Int(seconds)), L10n.text("秒")) }
        if seconds < 3600 { return (String(Int(seconds / 60)), L10n.text("分钟")) }
        return (String(format: "%.1f", locale: L10n.locale, seconds / 3600), L10n.text("小时"))
    }
}

// MARK: - Home

struct HomePage: View {
    @EnvironmentObject var model: AppModel

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return L10n.text("早上好")
        case 12..<18: return L10n.text("下午好")
        default: return L10n.text("晚上好")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: greeting, subtitle: L10n.text("说话，不用打字。任何 App 都能用。"))
                VStack(alignment: .leading, spacing: 18) {
                    HeroCard()
                    if !model.accessibilityTrusted || model.micStatus != .authorized || !model.serviceUp || !model.llmConfigured {
                        SetupCard()
                    }
                    if !model.settings.guideDismissed { GuideCard() }
                    StatsRow(stats: model.stats)
                    ActivityCard()
                    RecentCard()
                    EngineCard()
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
    }
}

private struct HeroCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(padding: 22) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(L10n.text("按")).font(.system(size: 17, weight: .semibold))
                        Keycap(label: model.hotkeyLabel, large: true)
                        Text(L10n.text("开始，再按一次结束")).font(.system(size: 17, weight: .semibold))
                    }
                    Text(L10n.text("文字写到光标处。按 Esc 取消。"))
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(model.phase == .recording ? L10n.text("结束听写") : L10n.text("试一下")) { model.actions?.toggleDictation() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.phase == .thinking)
            }
        }
    }
}

private struct SetupCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("完成设置")).font(.system(size: 14, weight: .semibold))
                SetupRow(done: model.micStatus == .authorized, title: L10n.text("麦克风"),
                         detail: "",
                         action: model.micStatus == .denied ? L10n.text("打开设置") : L10n.text("允许")) {
                    if model.micStatus == .denied { model.actions?.openMicrophoneSettings() } else { model.actions?.requestMicrophone() }
                }
                SetupRow(done: model.accessibilityTrusted, title: L10n.text("辅助功能"),
                         detail: "", action: L10n.text("允许")) {
                    model.actions?.requestAccessibility()
                }
                SetupRow(done: model.serviceState.isRunning, title: L10n.text("本地服务（需要 Node.js 22+）"),
                         detail: model.serviceState.isRunning ? L10n.text("运行中") : model.serviceSummary,
                         action: model.serviceState.needsNode ? L10n.text("下载 Node.js") : L10n.text("重新启动")) {
                    if model.serviceState.needsNode {
                        NSWorkspace.shared.open(URL(string: "https://nodejs.org/zh-cn/download")!)
                    } else {
                        model.actions?.restartService()
                    }
                }
                SetupRow(done: model.speech?.ready == true, title: model.speech?.displayName ?? L10n.text("未选择语音模型"),
                         detail: AppDelegate.speechProblem(model.speech).isEmpty ? L10n.text("就绪，本机识别") : AppDelegate.speechProblem(model.speech),
                         action: model.modelsMissing || model.speech?.phase == "error" ? L10n.text("选择语音模型") : "") {
                    model.actions?.downloadModels()
                }
                if model.speech?.networkFailure == true { MirrorHint { model.retryModelDownload() } }
                SetupRow(done: model.llmConfigured, title: L10n.text("整理模型（你的 API Key）"),
                         detail: model.llmConfigured ? model.modelSummary : "",
                         action: L10n.text("打开设置")) {
                    model.settingsCategory = 1
                    model.page = .settings
                }
            }
        }
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundColor(done ? Theme.success : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                }
            }
            Spacer()
            if !done && !action.isEmpty {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private struct StatsRow: View {
    let stats: DictationStats

    var body: some View {
        let saved = Formatters.duration(stats.savedSeconds)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: L10n.language == "en" ? 2 : 4), alignment: .leading, spacing: 12) {
            StatTile(value: Formatters.number(stats.words), unit: L10n.text("字"), label: L10n.text("听写字数"))
            StatTile(value: saved.0, unit: saved.1, label: L10n.text("节省的时间"))
            StatTile(value: Formatters.number(stats.wordsPerMinute), unit: L10n.text("字/分钟"), label: L10n.text("说话速度"))
            StatTile(value: Formatters.number(stats.dictations), unit: L10n.text("次"), label: L10n.text("听写次数"))
        }
    }
}

private struct StatTile: View {
    let value: String
    let unit: String
    let label: String

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12)).foregroundColor(Theme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: true, vertical: false)
                    Text(unit).font(.system(size: 12)).foregroundColor(Theme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }
}

private struct RecentCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("最近")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !model.history.isEmpty {
                    Button(L10n.text("查看全部")) { model.page = .history }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondary)
                }
            }
            if model.history.isEmpty {
                Card {
                    Text(L10n.text("没有听写记录。按 {0} 说一句。", model.hotkeyLabel))
                        .font(.system(size: 13))
                        .foregroundColor(Theme.secondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(model.history.prefix(4)) { entry in
                        HistoryRow(entry: entry, compact: true)
                        if entry.id != model.history.prefix(4).last?.id { Divider().padding(.leading, 66) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
            }
        }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("引擎")).font(.system(size: 14, weight: .semibold))
                EngineRow(symbol: "waveform", title: L10n.text("语音识别"), value: model.speechSummary)
                EngineRow(symbol: "sparkles", title: L10n.text("整理"), value: model.modelSummary)
            }
        }
    }
}

private struct EngineRow: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundColor(Theme.secondary)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
        }
    }
}

// MARK: - History

enum HistoryFilter: Hashable { case all, polished, raw }

struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: HistoryFilter = .all
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [LocalHistoryEntry] {
        model.history.filter { entry in
            switch filter {
            case .all: break
            case .polished: if entry.fallback { return false }
            case .raw: if !entry.fallback { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.displayText.localizedCaseInsensitiveContains(query) || entry.raw.localizedCaseInsensitiveContains(query)
        }
    }

    private struct DayGroup: Identifiable {
        let id: String
        let entries: [LocalHistoryEntry]
    }

    private var groups: [DayGroup] {
        var order: [String] = []
        var map: [String: [LocalHistoryEntry]] = [:]
        for entry in filtered {
            let key = Formatters.dayTitle(entry.ts)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(entry)
        }
        return order.map { DayGroup(id: $0, entries: map[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L10n.text("历史"), subtitle: "") {
                HStack(spacing: 10) {
                    Picker(L10n.text("保留"), selection: model.setting(\.historyRetention, then: {
                        HistoryStore.shared.applyRetention(Settings.shared.historyRetention)
                    })) {
                        ForEach(HistoryRetention.allCases, id: \.self) { Text(L10n.text("保留 ") + $0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    Menu {
                        Button(L10n.text("删除全部历史"), role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 32)
                }
            }
            HStack {
                ChipPicker(options: [(HistoryFilter.all, L10n.text("全部")), (.polished, L10n.text("已整理")), (.raw, L10n.text("已用原文"))], selection: $filter)
                Spacer()
                SearchField(text: $query)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 12)

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 28)).foregroundColor(Theme.tertiary)
                    Text(query.isEmpty ? L10n.text("没有听写记录") : L10n.text("没有匹配的记录")).foregroundColor(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups) { group in
                            let entries = group.entries
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.id).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.secondary)
                                VStack(spacing: 0) {
                                    ForEach(entries) { entry in
                                        HistoryRow(entry: entry, compact: false)
                                        if entry.id != entries.last?.id { Divider().padding(.leading, 66) }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }
        }
        .alert(L10n.text("删除全部历史？"), isPresented: $confirmClear) {
            Button(L10n.text("删除"), role: .destructive) { model.actions?.clearHistory() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("删除全部历史和录音，无法恢复。"))
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: LocalHistoryEntry
    let compact: Bool
    @State private var hovering = false
    @State private var expanded = false
    @State private var copied = false

    private var canRetry: Bool {
        // A Prompt Beta record cannot be retried: it would start a new clarification from scratch.
        guard entry.strength != "promptbeta", let path = entry.audioPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private var mode: VoiceStrength? {
        guard ["prompt", "concise", "promptbeta", "promptbrief", "promptify", "conservative", "maximal"].contains(entry.strength) else { return nil }
        return VoiceStrength.stored(entry.strength)
    }
    private var modeTint: Color {
        switch mode { case .concise: return Theme.accent; case .promptbeta: return Theme.style; default: return Theme.success }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Formatters.time.string(from: entry.ts))
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(Theme.tertiary)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if entry.displayText.isEmpty || compact {
                    Text(entry.displayText.isEmpty ? L10n.text("（没有识别到内容）") : entry.displayText)
                        .font(.system(size: 13.5))
                        .foregroundColor(Theme.ink)
                        .lineLimit(expanded ? nil : (compact ? 2 : 4))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipped()
                } else {
                    // Select a name or term, right-click, 加入词典.
                    SelectableText(text: entry.displayText, font: .systemFont(ofSize: 13.5), color: NSColor(Theme.ink),
                                   maxLines: expanded ? 0 : 4,
                                   onAddWord: { word in model.actions?.addWordFromHistory(word) },
                                   onPlainClick: { expanded.toggle() })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipped()
                }
                if expanded, !entry.raw.isEmpty, entry.raw != entry.displayText {
                    Text(L10n.text("原话：") + entry.raw)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(AppNames.name(for: entry.app)).font(.system(size: 11)).foregroundColor(Theme.tertiary).lineLimit(1)
                    if let task = entry.task { Badge(text:L10n.text(task == "assistant" ? "提示词模式" : task == "translation" ? "翻译" : "听写"),tint:task == "assistant" ? Theme.style : Theme.accent).fixedSize() }
                    else if let mode { Badge(text: mode.label, tint: modeTint).fixedSize() }
                    if entry.fallback { Badge(text: L10n.text("已用原文"), tint: Theme.warning).fixedSize() }
                    if copied { Badge(text: L10n.text("已复制"), tint: Theme.success).fixedSize() }
                }
            }
            // Reserve the action width. Hover must not change the text wrapping
            // after AppKit has reported its height to SwiftUI.
                HStack(spacing: 2) {
                    IconButton(symbol: "doc.on.doc", help: L10n.text("复制")) { copy(raw: false) }
                    if !compact {
                        IconButton(symbol: "text.quote", help: L10n.text("复制原话")) { copy(raw: true) }
                        if canRetry {
                            IconButton(symbol: "arrow.clockwise", help: L10n.text("用这段录音重试")) { model.actions?.retryEntry(id: entry.id) }
                        }
                        IconButton(symbol: "trash", help: L10n.text("删除"), role: .destructive) { model.actions?.deleteEntry(id: entry.id) }
                    }
                }
                .opacity(hovering || copied ? 1 : 0)
                .allowsHitTesting(hovering || copied)
                .accessibilityHidden(!hovering && !copied)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(hovering ? Theme.cardHover.opacity(0.6) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture { if !compact { expanded.toggle() } else { model.page = .history } }
    }

    private func copy(raw: Bool) {
        model.actions?.copyEntry(id: entry.id, raw: raw)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Dictionary

enum WordFilter: Hashable { case all, auto, manual }

struct ManualDictionaryPage: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: WordFilter = .all
    @State private var query = ""
    @State private var editor = WordEditorController()
    @State private var importNote = ""

    private var filtered: [LocalWord] {
        model.words.filter { word in
            switch filter {
            case .all: break
            case .auto: if word.source != .auto { return false }
            case .manual: if word.source != .manual { return false }
            }
            guard !query.isEmpty else { return true }
            return word.word.localizedCaseInsensitiveContains(query) || (word.heardAs ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L10n.text("词典"), subtitle: L10n.text("说过的名称写对。你改过的词会自动加入。")) {
                HStack(spacing: 8) {
                    Button(L10n.text("导入 CSV")) { importCSV() }.buttonStyle(SecondaryButtonStyle())
                    Button {
                        editor.show(title: L10n.text("新词"), word: "", heardAs: "", localOnly: false) { word, heard, localOnly in
                            Settings.shared.addWord(word, heardAs: heard, source: .manual, localOnly: localOnly)
                        }
                    } label: {
                        Label(L10n.text("新词"), systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            HStack {
                ChipPicker(options: [(WordFilter.all, L10n.text("全部")), (.auto, L10n.text("自动添加")), (.manual, L10n.text("手动添加"))], selection: $filter)
                Spacer()
                if !importNote.isEmpty { Text(importNote).font(.system(size: 12)).foregroundColor(Theme.secondary) }
                SearchField(text: $query)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "character.book.closed").font(.system(size: 28)).foregroundColor(Theme.tertiary)
                            Text(query.isEmpty ? L10n.text("词典是空的。") : L10n.text("没有匹配的词"))
                                .multilineTextAlignment(.center)
                                .foregroundColor(Theme.secondary)
                                .frame(maxWidth: 360)
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { word in
                                WordRow(word: word, onEdit: {
                                    editor.show(title: L10n.text("编辑"), word: word.word, heardAs: word.heardAs ?? "", localOnly: word.localOnly == true) { newWord, heard, localOnly in
                                        Settings.shared.updateWord(id: word.id, word: newWord, heardAs: heard, localOnly: localOnly)
                                    }
                                }, onDelete: {
                                    Settings.shared.removeWord(id: word.id)
                                })
                                if word.id != filtered.last?.id { Divider().padding(.leading, 16) }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .onDisappear { editor.close() }
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = L10n.text("每行一个词，或「识别成,正确写法」")
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let added = Settings.shared.importCSV(text)
        importNote = L10n.text("已导入 {0} 个词", added)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { importNote = "" }
    }
}

private struct WordRow: View {
    let word: LocalWord
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(word.word).font(.system(size: 14, weight: .semibold))
                if let heard = word.heardAs, !heard.isEmpty {
                    Text(L10n.text("常被识别成「{0}」", heard)).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                }
            }
            Spacer()
            if word.localOnly == true { Badge(text: L10n.text("不发给模型"), tint: Theme.warning) }
            Badge(text: word.source == .auto ? L10n.text("自动添加") : L10n.text("手动添加"),
                  tint: word.source == .auto ? Theme.accent : Theme.secondary)
            if hovering {
                IconButton(symbol: "pencil", help: L10n.text("编辑"), action: onEdit)
                IconButton(symbol: "trash", help: L10n.text("删除"), role: .destructive, action: onDelete)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(hovering ? Theme.cardHover.opacity(0.6) : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// A modeless editor: the dictionary remains scrollable while it is open.
private final class WordEditorController {
    private var panel: NSPanel?

    func show(title: String, word: String, heardAs: String, localOnly: Bool,
              onSave: @escaping (String, String?, Bool) -> Void) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 468, height: 330),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView:
            WordEditor(title: title, word: word, heardAs: heardAs, localOnly: localOnly,
                       onCancel: { [weak self] in self?.close() }, onSave: { [weak self] word, heard, localOnly in
                           onSave(word, heard, localOnly)
                           self?.close()
                       }))
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.close(); panel = nil }
}

private struct WordEditor: View {
    let title: String
    @State var word: String
    @State var heardAs: String
    @State var localOnly: Bool
    let onCancel: () -> Void
    let onSave: (String, String?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 18, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("词语")).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.secondary)
                TextField(L10n.text("例如 DeepSeek、张伟、Kubernetes"), text: $word)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("常被识别成（可选）")).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.secondary)
                TextField(L10n.text("例如 得普西克"), text: $heardAs)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.text("不发给模型"), isOn: $localOnly).toggleStyle(.checkbox)
                if localOnly && heardAs.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(L10n.text("没填识别成时，只修正英文大小写。")).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                }
            }
            HStack {
                Spacer()
                Button(L10n.text("取消"), action: onCancel).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(title == L10n.text("新词") ? L10n.text("添加") : L10n.text("保存")) {
                    onSave(word, heardAs.isEmpty ? nil : heardAs, localOnly)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
