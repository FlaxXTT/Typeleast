import SwiftUI
import AppKit
import UniformTypeIdentifiers

// HubPages.swift - Home and History.

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
    private static var numberLanguage = ""
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
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
        if numberLanguage != L10n.language {
            decimal.locale = L10n.locale
            numberLanguage = L10n.language
        }
        return decimal.string(from: NSNumber(value: value)) ?? String(value)
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
                PageHeader(title: greeting)
                VStack(alignment: .leading, spacing: 18) {
                    HeroCard()
                    // Only what is not set up yet; nothing once everything works.
                    if SetupCard.pending(model) { SetupCard() }
                    InsightsPanel()
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
        Card(padding: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(L10n.text("按")).font(.system(size: 15, weight: .semibold))
                Keycap(label: model.hotkeyLabel)
                Text(L10n.text("说话，再按一次结束")).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 12)
                ShareButton(items: InsightsPanel.shareItems).fixedSize()
                Button(model.phase == .recording ? L10n.text("结束听写") : L10n.text("试一下")) { model.actions?.toggleDictation() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.phase == .thinking)
            }
            .padding(.leading, 6)
        }
    }
}

private struct SetupCard: View {
    @EnvironmentObject var model: AppModel

    static func pending(_ model: AppModel) -> Bool {
        !model.accessibilityTrusted || model.micStatus != .authorized || !model.serviceState.isRunning
            || model.speech?.ready != true || !model.llmConfigured
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("设置位置")).font(.system(size: 14, weight: .semibold))
                SetupRow(done: model.micStatus == .authorized, title: L10n.text("麦克风"),
                         detail: "",
                         action: model.micStatus == .denied ? L10n.text("打开设置") : L10n.text("允许")) {
                    if model.micStatus == .denied { model.actions?.openMicrophoneSettings() } else { model.actions?.requestMicrophone() }
                }
                SetupRow(done: model.accessibilityTrusted, title: L10n.text("辅助功能"),
                         detail: "", action: L10n.text("允许")) {
                    model.actions?.requestAccessibility()
                }
                SetupRow(done: model.serviceState.isRunning, title: L10n.text("本地服务"),
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

    /// A finished step is not shown at all.
    var body: some View {
        if !done { row }
    }

    private var row: some View {
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

private struct RecentCard: View {
    @EnvironmentObject var model: AppModel
    @State private var hoveringAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("最近")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !model.history.isEmpty {
                    Button { model.page = .history } label: {
                        HStack(spacing: 4) {
                            Text(L10n.text("查看全部"))
                            Image(systemName: "arrow.right")
                        }
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(hoveringAll ? Theme.accent : Theme.secondary)
                        .onHover { hoveringAll = $0 }
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

/// One cached projection survives page changes. It contains data, not live page views.
final class HistoryListCache: ObservableObject {
    struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let entries: [LocalHistoryEntry]
    }

    private struct Key: Equatable {
        let owner: ObjectIdentifier
        let revision: Int
        let filter: HistoryFilter
        let query: String
        let day: Date
        let calendar: Calendar
        let language: String
    }

    private var key: Key?
    private var groups: [DayGroup] = []

    func invalidate(unlessOwner owner: ObjectIdentifier, revision: Int) {
        if key?.owner == owner && key?.revision == revision { return }
        key = nil
        groups = []
    }

    func groupedEntries(_ entries: [LocalHistoryEntry], owner: ObjectIdentifier, revision: Int, filter: HistoryFilter,
                        query: String, day: Date, calendar: Calendar, language: String) -> [DayGroup] {
        let next = Key(owner: owner, revision: revision, filter: filter, query: query,
                       day: day, calendar: calendar, language: language)
        if key == next { return groups }
        var order: [Date] = []
        var map: [Date: [LocalHistoryEntry]] = [:]
        for entry in entries {
            if filter == .polished && entry.fallback { continue }
            if filter == .raw && !entry.fallback { continue }
            if !query.isEmpty && !entry.displayText.localizedCaseInsensitiveContains(query)
                && !entry.raw.localizedCaseInsensitiveContains(query) { continue }
            let date = calendar.startOfDay(for: entry.ts)
            if map[date] == nil { order.append(date) }
            map[date, default: []].append(entry)
        }
        groups = order.map { DayGroup(id: $0, title: Formatters.dayTitle($0), entries: map[$0] ?? []) }
        key = next
        return groups
    }
}

struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    let cache: HistoryListCache
    @State private var filter: HistoryFilter = .all
    @State private var query = ""
    @State private var confirmClear = false

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

            HistoryResults(model: model, cache: cache, revision: model.historyRevision, filter: filter,
                           query: query, day: Calendar.current.startOfDay(for: Date()),
                           calendar: Calendar.current, language: L10n.language)
                .equatable()
        }
        .alert(L10n.text("删除全部历史？"), isPresented: $confirmClear) {
            Button(L10n.text("删除"), role: .destructive) { model.actions?.clearHistory() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("删除全部历史和录音，无法恢复。"))
        }
    }
}

/// Service progress and unrelated settings must not rebuild the history list.
private struct HistoryResults: View, Equatable {
    let model: AppModel
    let cache: HistoryListCache
    let revision: Int
    let filter: HistoryFilter
    let query: String
    let day: Date
    let calendar: Calendar
    let language: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.cache === rhs.cache && lhs.revision == rhs.revision
            && lhs.filter == rhs.filter && lhs.query == rhs.query && lhs.day == rhs.day
            && lhs.calendar == rhs.calendar && lhs.language == rhs.language
    }

    var body: some View {
        let dayGroups = cache.groupedEntries(model.history, owner: ObjectIdentifier(model), revision: revision, filter: filter,
                                            query: query, day: day, calendar: calendar, language: language)
        Group {
            if dayGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 28)).foregroundColor(Theme.tertiary)
                    Text(query.isEmpty ? L10n.text("没有听写记录") : L10n.text("没有匹配的记录")).foregroundColor(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(dayGroups) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    let first = entry.id == group.entries.first?.id
                                    let last = entry.id == group.entries.last?.id
                                    let card = UnevenRoundedRectangle(
                                        topLeadingRadius: first ? Theme.radius : 0,
                                        bottomLeadingRadius: last ? Theme.radius : 0,
                                        bottomTrailingRadius: last ? Theme.radius : 0,
                                        topTrailingRadius: first ? Theme.radius : 0, style: .continuous)
                                    let row = VStack(spacing: 0) {
                                        HistoryRowContent(model: model, entry: entry, compact: false)
                                            .equatable()
                                        if !last { Divider().padding(.leading, 66) }
                                    }
                                    if first || last {
                                        row.background(card.fill(Theme.card)).clipShape(card)
                                    } else {
                                        row.background(Theme.card)
                                    }
                                }
                            } header: {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.secondary)
                                    .padding(.top, group.id == dayGroups.first?.id ? 0 : 18)
                                    .padding(.bottom, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 36)
                }
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: LocalHistoryEntry
    let compact: Bool

    var body: some View {
        HistoryRowContent(model: model, entry: entry, compact: compact).equatable()
    }
}

private struct HistoryRowContent: View, Equatable {
    // Actions read the live model only when invoked; the text does not subscribe to it.
    let model: AppModel
    let entry: LocalHistoryEntry
    let compact: Bool
    @State private var hovering = false
    @State private var expanded = false
    @State private var copied = false
    @State private var retryAvailable = false
    @State private var checkedAudioPath: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.entry == rhs.entry && lhs.compact == rhs.compact
    }

    private var retryAudioPath: String? {
        // A Prompt Beta record cannot be retried: it would start a new clarification from scratch.
        entry.strength == "promptbeta" ? nil : entry.audioPath
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
                .foregroundColor(hovering ? Theme.accent : Theme.tertiary)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if entry.displayText.isEmpty || compact {
                    Text(entry.displayText.isEmpty ? (entry.fallbackReason == "quantity-conflict" ? L10n.text("数量或单位待核对") : L10n.text("（没有识别到内容）")) : entry.displayText)
                        .font(.system(size: 13.5))
                        .foregroundColor(Theme.ink)
                        .lineLimit(expanded ? nil : (compact ? 2 : 4))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipped()
                        .onTapGesture { if entry.qualityReview != nil { expanded.toggle() } }
                } else {
                    SelectableText(text: entry.displayText, font: .systemFont(ofSize: 13.5), color: NSColor(Theme.ink),
                                   maxLines: expanded ? 0 : 4,
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
                if expanded, let review = entry.qualityReview {
                    Text(L10n.text("原始识别") + "：" + review.original)
                        .font(.system(size: 12)).foregroundColor(Theme.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("待核对整理结果") + "：" + review.candidate)
                        .font(.system(size: 12)).foregroundColor(Theme.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(AppNames.name(for: entry.app)).font(.system(size: 11)).foregroundColor(Theme.tertiary).lineLimit(1)
                    if let task = entry.task { Badge(text:L10n.text(task == "assistant" ? "提示词模式" : task == "translation" ? "翻译" : "听写"),tint:task == "assistant" ? Theme.style : Theme.accent).fixedSize() }
                    else if let mode { Badge(text: mode.label, tint: modeTint).fixedSize() }
                    if entry.fallback {
                        let held = ["suspected-noise", "recognition-repetition", "quantity-conflict"].contains(entry.fallbackReason ?? "") && !entry.inserted
                        Badge(text: held ? L10n.text("未自动输入") : L10n.text("已用原文"), tint: Theme.warning).fixedSize()
                    }
                    if copied { Badge(text: L10n.text("已复制"), tint: Theme.success).fixedSize() }
                }
            }
            // Reserve the action width. Hover must not change the text wrapping
            // after AppKit has reported its height to SwiftUI.
                HStack(spacing: 2) {
                    IconButton(symbol: "doc.on.doc", help: L10n.text("复制")) { copy(raw: false) }
                    if !compact {
                        IconButton(symbol: "text.quote", help: L10n.text("复制原话")) { copy(raw: true) }
                        if retryAudioPath != nil {
                            let available = retryAvailable && checkedAudioPath == retryAudioPath
                            IconButton(symbol: "arrow.clockwise", help: L10n.text("用这段录音重试")) { model.actions?.retryEntry(id: entry.id) }
                                .opacity(available ? 1 : 0)
                                .disabled(!available)
                                .accessibilityHidden(!available)
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
        .task(id: retryAudioPath) {
            retryAvailable = false
            checkedAudioPath = nil
            guard !compact, let path = retryAudioPath else { return }
            let available = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard !Task.isCancelled else { return }
            checkedAudioPath = path
            retryAvailable = available
        }
    }

    private func copy(raw: Bool) {
        model.actions?.copyEntry(id: entry.id, raw: raw)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
