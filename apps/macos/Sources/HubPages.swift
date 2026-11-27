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
        L10n.formattedNumber(NSNumber(value: value))
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
    @State private var showsSetup = false
    var animationsReady = true
    static let horizontalInset: CGFloat = 12
    static let columnGap: CGFloat = 14
    static let insightsFraction: CGFloat = 0.67

    var body: some View {
        GeometryReader { geometry in
            let gap = Self.columnGap
            let width = max(0, geometry.size.width - gap)
            let insightsWidth = width * Self.insightsFraction
            HStack(alignment: .top, spacing: gap) {
                InsightsPanel(animationsReady: animationsReady)
                    .frame(width: insightsWidth, height: geometry.size.height)
                    .background {
                        HomeDotGrid()
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .padding(-6)
                    }
                VStack(alignment: .leading, spacing: 12) {
                    ShortcutReferenceCard()
                    EngineCard()
                    if SetupCard.pending(model) {
                        Button { showsSetup.toggle() } label: {
                            Label(L10n.text("完成设置"), systemImage: "exclamationmark.circle")
                                .font(Theme.captionFont)
                                .foregroundColor(Theme.accent)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(FlatActionButtonStyle())
                        .popover(isPresented: $showsSetup, arrowEdge: .trailing) {
                            SetupCard().frame(width: 420).padding(12)
                        }
                    }
                    HomeVersionFooter()
                }
                .padding(.top, 20)
                .frame(width: width - insightsWidth, height: geometry.size.height, alignment: .top)
            }
        }
        .padding(EdgeInsets(top: 28, leading: Self.horizontalInset, bottom: 16, trailing: Self.horizontalInset))
        .foregroundStyle(Theme.homeInk)
        .background(Theme.homeWindow)
        .overlay(alignment: .topTrailing) {
            ShareButton(items: InsightsPanel.shareItems)
                .frame(width: ShareButton.size.width, height: ShareButton.size.height)
                .padding(.top, 4)
                .padding(.trailing, 18)
        }
    }
}

private struct ShortcutReferenceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    shortcut(L10n.text("口述"), binding: model.settings.hotkeyMain)
                    ServiceBadge().fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ServiceBadge()
                    shortcut(L10n.text("口述"), binding: model.settings.hotkeyMain)
                }
            }
            shortcut(L10n.text("翻译"), binding: model.settings.hotkeyTranslate)
            shortcut(L10n.text("调用"), binding: model.settings.hotkeyAssistant)
            Menu(L10n.text("试试听写")) {
                Button(L10n.text("备忘录")) { model.actions?.openRecommendedApp("com.apple.Notes") }
                Button(L10n.text("文本编辑")) { model.actions?.openRecommendedApp("com.apple.TextEdit") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Theme.captionFont)
            .hoverFeedback()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .hoverCard(Theme.homeSidebar, radius: Theme.homeCardRadius)
    }

    private func shortcut(_ title: String, binding: HotKeyBinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            InterfaceTypography.text(title, size: Theme.homeSecondarySize).foregroundColor(Theme.homeLabel)
            if binding.enabled {
                ShortcutKeyLayout(spacing: 4) {
                    ForEach(Array(keys(binding).enumerated()), id: \.offset) { _, key in
                        InterfaceTypography.text(key, size: 13, weight: .semibold)
                            .padding(.horizontal, 7).frame(minWidth: 27, minHeight: 27)
                            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.homeTile))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.homeBorder, lineWidth: 1))
                    }
                }
            } else {
                Button(L10n.text("设置快捷键")) {
                    model.settingsCategory = .dictation
                    model.navigate(to: .settings)
                }.buttonStyle(FlatActionButtonStyle()).font(Theme.captionFont).foregroundColor(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keys(_ binding: HotKeyBinding) -> [String] {
        if binding.isFn { return ["Fn"] }
        if let chord = binding.fnChord { return ["Fn", chord.keyLabel] }
        var result: [String] = []
        if binding.modifiers & 4096 != 0 { result.append("Control") }
        if binding.modifiers & 2048 != 0 { result.append("Option") }
        if binding.modifiers & 512 != 0 { result.append("Shift") }
        if binding.modifiers & 256 != 0 { result.append("Command") }
        result.append(HotKeyCentre.keyName(binding.keyCode))
        return result
    }
}

private struct ServiceBadge: View {
    @EnvironmentObject var model: AppModel

    private var badgeText: String {
        if model.serviceUp { return "Ready" }
        if model.modelsDownloading {
            return L10n.text("正在下载模型 ") + (model.speech?.downloadFraction.map { String(Int($0 * 100)) + "%" } ?? "…")
        }
        if model.modelsMissing { return L10n.text("语音模型未下载") }
        if case .running = model.serviceState { return L10n.text("正在加载语音模型") }
        return L10n.text("本地服务未就绪")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.serviceUp ? Theme.success : Theme.warning)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            InterfaceTypography.text(badgeText, size: 12, weight: .medium)
                .foregroundColor(Theme.homeLabel)
                .lineLimit(1)
                .help(badgeText)
            if model.modelsMissing {
                Button(L10n.text("下载模型")) { model.actions?.downloadModels() }
                    .buttonStyle(FlatActionButtonStyle())
                    .foregroundColor(Theme.accent)
                    .fixedSize()
            } else if !model.serviceUp && !model.modelsDownloading {
                Button(L10n.text("重启")) { model.actions?.restartService() }
                    .buttonStyle(FlatActionButtonStyle())
                    .foregroundColor(Theme.accent)
                    .fixedSize()
            }
        }
        .font(Theme.captionFont)
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(Capsule().fill(Theme.homeTile))
    }
}

private struct ShortcutKeyLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (index, point) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: .unspecified)
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}

private struct HomeVersionFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            InterfaceTypography.text(L10n.text("版本 {0}", "v" + Updater.currentVersion), size: 12)
                .foregroundColor(Theme.homeLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button {
                model.actions?.checkForUpdates(interactive: true)
            } label: {
                Label(L10n.text("检查更新"), systemImage: "arrow.clockwise")
                    .font(InterfaceTypography.localized(12, weight: .medium))
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FlatActionButtonStyle())
            .foregroundColor(Theme.accent)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 54)
        .background(Theme.homeTileSurface, in: RoundedRectangle(cornerRadius: Theme.homeActivityRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.homeActivityRadius).strokeBorder(Theme.homeBorder, lineWidth: 1))
    }
}

private struct SetupCard: View {
    @EnvironmentObject var model: AppModel

    static func pending(_ model: AppModel) -> Bool {
        model.credentialsLocked || !model.accessibilityTrusted || model.micStatus != .authorized || !model.serviceState.isRunning
            || !model.recognitionConfigured || !model.llmConfigured
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("设置位置")).font(InterfaceTypography.localized(14, weight: .semibold))
                if model.credentialsLocked { CredentialUnlockRow() }
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
                if model.settings.onlineASRProvider == .local {
                    SetupRow(done: model.recognitionConfigured, title: model.speech?.displayName ?? L10n.text("未选择语音模型"),
                         detail: AppDelegate.speechProblem(model.speech).isEmpty ? L10n.text("就绪，本机识别") : AppDelegate.speechProblem(model.speech),
                         action: model.modelsMissing || model.speech?.phase == "error" ? L10n.text("选择语音模型") : "") {
                        model.actions?.downloadModels()
                    }
                    if model.speech?.networkFailure == true { MirrorHint { model.retryModelDownload() } }
                } else if model.onlineASRKeyPresence == false {
                    SetupRow(done: false, title: model.settings.onlineASRProvider.label,
                             detail: L10n.text("待配置 API Key"), action: L10n.text("打开设置")) {
                        model.settingsCategory = .models
                        model.navigate(to: .settings)
                    }
                }
                if !model.credentialsLocked || !LLMPreset.find(model.settings.llmPresetID).needsKey {
                    SetupRow(done: model.llmConfigured, title: L10n.text("整理模型"),
                             detail: model.llmConfigured ? model.modelSummary : "",
                             action: L10n.text("打开设置")) {
                        model.settingsCategory = .models
                        model.navigate(to: .settings)
                    }
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
                Text(title).font(InterfaceTypography.localized(14, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(InterfaceTypography.localized(12)).foregroundColor(Theme.secondary)
                }
            }
            Spacer()
            if !done && !action.isEmpty {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private struct EngineCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let speech = model.speechEngineSummary
        let cleanup = model.cleanupEngineSummary
        let speechBrand = EngineBrand.speech(provider: model.settings.onlineASRProvider, modelID: model.speech?.modelId)
        let cleanupBrand = cleanup.detail.flatMap { _ in
            EngineBrand.cleanup(providerID: model.settings.llmPresetID, modelID: model.settings.llmModel)
        }
        VStack(alignment: .leading, spacing: 0) {
            InterfaceTypography.text(L10n.text("引擎"), size: Theme.homeFigureSize, weight: .medium)
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 9) {
                EngineRow(symbol: "waveform", title: L10n.text("语音识别"), value: speech.name, detail: speech.detail,
                          brand: speechBrand)
                Divider().overlay(Theme.homeBorder)
                EngineRow(symbol: "sparkles", title: L10n.text("整理"), value: cleanup.name, detail: cleanup.detail,
                          brand: cleanupBrand)
            }
            Spacer(minLength: 5)
            Button {
                model.settingsCategory = .models
                model.navigate(to: .settings)
            } label: {
                HStack(spacing: 8) {
                    Label(L10n.text("管理模型"), systemImage: "slider.horizontal.3")
                        .font(InterfaceTypography.localized(13, weight: .medium))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Theme.homeSelection, in: RoundedRectangle(cornerRadius: Theme.listGroupRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatActionButtonStyle(cornerRadius: Theme.listGroupRadius, feedback: .magnetic))
            .foregroundColor(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .hoverCard(Theme.homeTileSurface, radius: Theme.homeCardRadius, border: Theme.homeBorder)
    }
}

private struct EngineRow: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String?
    let brand: EngineBrand?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
            HStack(spacing: 7) {
                if let brand { EngineLogo(brand: brand) }
                InterfaceTypography.text(value, size: 15, weight: .semibold)
                    .lineLimit(2).minimumScaleFactor(0.85).help(value)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let detail {
                InterfaceTypography.text(detail, size: 11, weight: .medium)
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.cardHover, in: Capsule())
                    .help(detail)
            }
        }
    }
}

// MARK: - History

enum HistoryFilter: Hashable { case all, polished, raw }

struct HistoryPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: HistoryFilter = .all
    @State private var confirmClear = false
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var dayGroups: [DayGroup] = []

    private struct CacheKey: Equatable {
        let historyRevision: Int
        let filter: HistoryFilter
        let day: Date
        let language: String
        let timeZone: String
    }

    private var cacheKey: CacheKey {
        CacheKey(historyRevision: model.historyRevision, filter: filter, day: day,
                 language: L10n.language, timeZone: TimeZone.current.identifier)
    }

    private var filtered: [LocalHistoryEntry] {
        model.history.filter(matchesFilter)
    }

    private func matchesFilter(_ entry: LocalHistoryEntry) -> Bool {
        switch filter {
        case .all: return true
        case .polished: return !entry.fallback && entry.recognitionFailure == nil
        case .raw: return entry.fallback
        }
    }

    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let entries: [LocalHistoryEntry]
    }

    private func groupedEntries(_ entries: [LocalHistoryEntry]) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var map: [Date: [LocalHistoryEntry]] = [:]
        for entry in entries {
            let key = calendar.startOfDay(for: entry.ts)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(entry)
        }
        return order.map { DayGroup(id: $0, title: Formatters.dayTitle($0), entries: map[$0] ?? []) }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            let entry = selectedEntry
            HStack(spacing: 0) {
                historyList.frame(maxWidth: .infinity)
                if wide, let entry {
                    Divider().overlay(Theme.border)
                    HistoryDetail(entry: entry, close: closeDetail)
                        .id(entry.id).frame(width: 300).background(Theme.detail)
                }
            }
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    if !wide, let entry {
                        let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                        HistoryDetail(entry: entry, close: closeDetail)
                            .id(entry.id)
                            .frame(width: min(360, max(0, geometry.size.width - 24)))
                            .background(shape.fill(Theme.detail))
                            .clipShape(shape)
                            .overlay(shape.strokeBorder(Theme.border).allowsHitTesting(false))
                            .shadow(color: .black.opacity(0.14), radius: 12, x: -3)
                            .padding([.vertical, .trailing], 8)
                            .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : Theme.standard, value: !wide && entry != nil)
            }
        }
        .onDisappear(perform: closeDetail)
    }

    private var selectedEntry: LocalHistoryEntry? {
        guard let id = model.selectedHistoryID else { return nil }
        return model.history.first { $0.id == id && matchesFilter($0) }
    }

    private func closeDetail() {
        if model.selectedHistoryID != nil { model.selectedHistoryID = nil }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "History") {
                HStack(spacing: 10) {
                    Picker(L10n.text("保留"), selection: model.setting(\.historyRetention, then: {
                        HistoryStore.shared.applyRetention(Settings.shared.historyRetention)
                    })) {
                        ForEach(HistoryRetention.allCases, id: \.self) { Text(L10n.text("保留 ") + $0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 130)
                    .hoverFeedback(.fixed)
                    Menu {
                        Button(L10n.text("删除全部历史"), role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 32)
                    .hoverFeedback(.compact)
                }
            }
            historyChips
                .padding(.horizontal, Theme.pageInset)
                .padding(.bottom, 12)

            if model.credentialsLocked {
                CredentialUnlockRow()
                    .frame(maxWidth: 400)
                    .frame(maxWidth: .infinity, maxHeight: dayGroups.isEmpty ? .infinity : nil)
                    .padding(.horizontal, Theme.pageInset)
                    .padding(.vertical, 12)
            }

            if dayGroups.isEmpty {
                if !model.credentialsLocked {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.system(size: 28)).foregroundColor(Theme.tertiary)
                        Text(L10n.text(model.historyUnavailable ? "无法读取历史" : "没有听写记录"))
                            .foregroundColor(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HubScrollView(key: "history") {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(dayGroups) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    let first = entry.id == group.entries.first?.id
                                    let last = entry.id == group.entries.last?.id
                                    let card = UnevenRoundedRectangle(
                                        topLeadingRadius: first ? Theme.listGroupRadius : 0,
                                        bottomLeadingRadius: last ? Theme.listGroupRadius : 0,
                                        bottomTrailingRadius: last ? Theme.listGroupRadius : 0,
                                        topTrailingRadius: first ? Theme.listGroupRadius : 0, style: .circular)
                                    VStack(spacing: 0) {
                                        HistoryRow(entry: entry, compact: false, selected: model.selectedHistoryID == entry.id) {
                                            model.selectedHistoryID = entry.id
                                        }
                                    }
                                    .padding(.top, first ? 4 : 0)
                                    .padding(.bottom, last ? 4 : 0)
                                    .background(card.fill(Theme.card))
                                    .clipShape(card)
                                }
                            } header: {
                                Text(group.title)
                                    .font(InterfaceTypography.localized(12, weight: .semibold)).foregroundColor(Theme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                                    .background(Theme.window.opacity(0.96))
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pageInset)
                    .padding(.bottom, 32)
                }
            }
        }
        .alert(L10n.text("删除全部历史？"), isPresented: $confirmClear) {
            Button(L10n.text("删除"), role: .destructive) { model.actions?.clearHistory() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("删除全部历史和录音，无法恢复。"))
        }
        .onChange(of: cacheKey, initial: true) { _, _ in
            let entries = filtered
            dayGroups = groupedEntries(entries)
            if let id = model.selectedHistoryID, !entries.contains(where: { $0.id == id }) {
                closeDetail()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            day = Calendar.current.startOfDay(for: Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            day = Calendar.current.startOfDay(for: Date())
        }
    }

    private var historyChips: some View {
        ChipPicker(options: [(HistoryFilter.all, L10n.text("全部")), (.polished, L10n.text("已整理")), (.raw, L10n.text("已用原文"))], selection: $filter)
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: AppModel
    let entry: LocalHistoryEntry
    let compact: Bool
    var selected = false
    var onSelect: (() -> Void)? = nil
    @FocusState private var keyboardFocused: Bool
    @State private var hovering = false
    @State private var expanded = false
    @State private var copyFeedback: UUID?
    private var copied: Bool { copyFeedback != nil }
    @State private var retryAvailable = false

    private var canRetry: Bool {
        // A Prompt Beta record cannot be retried: it would start a new clarification from scratch.
        entry.strength != "promptbeta" && retryAvailable
    }

    private var retryTitle: String? {
        if entry.canRetryCleanup { return L10n.text("重试整理") }
        return canRetry ? L10n.text("用这段录音重试") : nil
    }

    private var mode: VoiceStrength? {
        guard ["prompt", "concise", "promptbeta", "promptbrief", "promptify", "conservative", "maximal"].contains(entry.strength) else { return nil }
        return VoiceStrength.stored(entry.strength)
    }
    private var modeTint: Color {
        switch mode { case .concise: return Theme.accent; case .promptbeta: return Theme.style; default: return Theme.success }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            InterfaceTypography.text(Formatters.time.string(from: entry.ts), size: 12)
                .foregroundColor(hovering ? Theme.accent : Theme.tertiary)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if model.retryingHistoryID == entry.id {
                    SkeletonWave(height: 24)
                } else if let failure = entry.recognitionFailure {
                    Text(failure.kind.message)
                        .font(Theme.rowFont).foregroundColor(Theme.warning)
                    if !compact, let retryTitle {
                        Button(retryTitle) { model.actions?.retryEntry(id: entry.id) }
                            .buttonStyle(FlatActionButtonStyle()).foregroundColor(Theme.accent)
                            .disabled(model.phase != .idle)
                    }
                } else if entry.displayText.isEmpty || compact {
                    Text(entry.qualityReview != nil ? L10n.text("待确认")
                         : entry.displayText.isEmpty ? L10n.text("（没有识别到内容）") : entry.displayText)
                        .font(Theme.rowFont)
                        .foregroundColor(entry.qualityReview == nil ? Theme.ink : Theme.warning)
                        .lineLimit(compact ? 1 : (expanded ? nil : 4))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipped()
                        .onTapGesture {
                            if compact || onSelect != nil { selectOrExpand() }
                            else if entry.qualityReview != nil { expanded.toggle() }
                        }
                } else {
                    SelectableText(text: entry.displayText, font: InterfaceTypography.localizedAppKit(14), color: NSColor(Theme.ink),
                                   maxLines: expanded ? 0 : 4, lineHeight: 22,
                                   onPlainClick: { selectOrExpand() })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipped()
                }
                if expanded, !entry.raw.isEmpty, entry.raw != entry.displayText {
                    Text(L10n.text("原话：") + entry.raw)
                        .font(InterfaceTypography.localized(12))
                        .foregroundColor(Theme.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if expanded, let review = entry.qualityReview {
                    Text(L10n.text("原始识别") + "：" + review.original)
                        .font(InterfaceTypography.localized(12)).foregroundColor(Theme.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.text("待核对整理结果") + "：" + review.candidate)
                        .font(InterfaceTypography.localized(12)).foregroundColor(Theme.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("查看并确认")) { model.actions?.reviewEntry(id: entry.id) }
                        .buttonStyle(FlatActionButtonStyle()).foregroundColor(Theme.accent)
                }
                if !compact && (expanded || entry.fallback) {
                HStack(spacing: 6) {
                    Text(AppNames.name(for: entry.app)).font(InterfaceTypography.localized(11)).foregroundColor(Theme.tertiary).lineLimit(1)
                    if let task = entry.task { Badge(text:L10n.text(task == "assistant" ? "提示词模式" : task == "translation" ? "翻译" : "听写"),tint:task == "assistant" ? Theme.style : Theme.accent).fixedSize() }
                    else if let mode { Badge(text: mode.label, tint: modeTint).fixedSize() }
                    if entry.fallback && entry.qualityReview == nil {
                        let held = ["suspected-noise", "recognition-repetition", "quantity-conflict"].contains(entry.fallbackReason ?? "") && !entry.inserted
                        Badge(text: held ? L10n.text("未自动输入") : L10n.text("已用原文"), tint: Theme.warning).fixedSize()
                    }
                }
                }
            }
            // Reserve the action width. Hover must not change the text wrapping
            // after AppKit has reported its height to SwiftUI.
                HStack(spacing: 2) {
                    if entry.qualityReview != nil {
                        IconButton(symbol: "pencil.line", help: L10n.text("查看并确认"), symbolSize: 14) {
                            model.actions?.reviewEntry(id: entry.id)
                        }
                    } else if entry.recognitionFailure == nil {
                        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? L10n.text("已复制") : L10n.text("复制"), symbolSize: 14) { copy(raw: false) }
                    } else {
                        Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
                    }
                    if !compact {
                        if entry.qualityReview == nil, entry.recognitionFailure == nil {
                            IconButton(symbol: "text.quote", help: L10n.text("复制原话"), symbolSize: 14) { copy(raw: true) }
                        } else {
                            Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
                        }
                        if entry.recognitionFailure == nil, let retryTitle {
                            IconButton(symbol: "arrow.clockwise", help: retryTitle, symbolSize: 14) { model.actions?.retryEntry(id: entry.id) }
                                .disabled(model.phase != .idle)
                        } else {
                            Color.clear.frame(width: 32, height: 32).accessibilityHidden(true)
                        }
                        IconButton(symbol: "trash", help: L10n.text("删除"), role: .destructive, symbolSize: 14) { model.actions?.deleteEntry(id: entry.id) }
                    }
                }
                .frame(height: 24)
                .opacity(hovering || copied || selected || keyboardFocused ? 1 : 0)
                .allowsHitTesting(hovering || copied || selected || keyboardFocused)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 4 : 8)
        .frame(minHeight: compact ? 32 : 42)
        .contentShape(Rectangle())
        .background(selected ? Theme.selection : hovering ? Theme.controlHover : Color.clear)
        .help(AppNames.name(for: entry.app))
        .focusable(!compact).focused($keyboardFocused)
        .transientHover($hovering)
        .onTapGesture { selectOrExpand() }
        .onSubmit { selectOrExpand() }
        .resetCopyFeedback($copyFeedback)
        .contextMenu {
            if entry.recognitionFailure == nil {
                Button(L10n.text("复制")) { copy(raw: false) }
                Button(L10n.text("复制原话")) { copy(raw: true) }
            }
            if !compact, let retryTitle {
                Button(retryTitle) { model.actions?.retryEntry(id: entry.id) }.disabled(model.phase != .idle)
            }
            if !compact { Button(L10n.text("删除"), role: .destructive) { model.actions?.deleteEntry(id: entry.id) } }
        }
        .task(id: entry.audioPath) {
            retryAvailable = false
            guard !compact, entry.audioPath != nil else { return }
            let available = await Task.detached(priority: .utility) { entry.retryAudioURL() != nil }.value
            guard !Task.isCancelled else { return }
            retryAvailable = available
        }
    }

    private func copy(raw: Bool) {
        model.actions?.copyEntry(id: entry.id, raw: raw)
        copyFeedback = UUID()
    }

    private func selectOrExpand() {
        if compact {
            model.selectedHistoryID = entry.id
            model.page = .history
        } else if let onSelect {
            onSelect()
        } else {
            expanded.toggle()
        }
    }
}

private struct HistoryDetail: View {
    @EnvironmentObject var model: AppModel
    let entry: LocalHistoryEntry
    let close: () -> Void
    @State private var copyFeedback: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("记录详情")).font(InterfaceTypography.localized(14, weight: .semibold))
                Spacer()
                IconButton(symbol: "xmark", help: L10n.text("关闭"), feedback: .fixed, action: close)
                    .keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider().overlay(Theme.border)
            HubScrollView(showsChrome: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppNames.name(for: entry.app)).font(InterfaceTypography.localized(14, weight: .medium))
                        Text(Formatters.dayTitle(entry.ts) + " · " + Formatters.time.string(from: entry.ts))
                            .font(InterfaceTypography.localized(11)).foregroundColor(Theme.tertiary)
                    }
                    if let failure = entry.recognitionFailure {
                        detailText(failure.provider.label, failure.kind.message)
                    } else if let review = entry.qualityReview {
                        detailText(L10n.text("原始识别"), review.original)
                        detailText(L10n.text("待核对整理结果"), review.candidate)
                    } else {
                        detailText(L10n.text("听写结果"), entry.displayText)
                        if !entry.raw.isEmpty, entry.raw != entry.displayText { detailText(L10n.text("原始识别"), entry.raw) }
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.border)
            HStack {
                if entry.qualityReview != nil {
                    Button(L10n.text("查看并确认")) { model.actions?.reviewEntry(id: entry.id) }
                        .buttonStyle(PrimaryButtonStyle())
                } else if entry.recognitionFailure == nil {
                    Button(copyFeedback != nil ? L10n.text("已复制") : L10n.text("复制")) {
                        model.actions?.copyEntry(id: entry.id, raw: false)
                        copyFeedback = UUID()
                    }.buttonStyle(PrimaryButtonStyle())
                }
                if entry.canRetryCleanup || (entry.recognitionFailure != nil && entry.retryAudioURL() != nil) {
                    Button(L10n.text(entry.canRetryCleanup ? "重试整理" : "用这段录音重试")) {
                        model.actions?.retryEntry(id: entry.id)
                    }.buttonStyle(SecondaryButtonStyle()).disabled(model.phase != .idle)
                }
                Spacer()
                IconButton(symbol: "trash", help: L10n.text("删除"), role: .destructive) {
                    model.actions?.deleteEntry(id: entry.id)
                }
            }.padding(24)
        }
        .foregroundColor(Theme.ink)
        .resetCopyFeedback($copyFeedback)
        .onExitCommand(perform: close)
    }

    private func detailText(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(InterfaceTypography.localized(11, weight: .medium)).foregroundColor(Theme.tertiary)
            Text(text.isEmpty ? L10n.text("（没有识别到内容）") : text)
                .font(InterfaceTypography.localized(14)).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
