import Foundation

// Settings.swift - UserDefaults-backed configuration for TypeLeast.

enum InsertionMode: String, CaseIterable {
    case autoPaste
    case clipboardOnly
    case preview
    var label: String {
        switch self {
        case .autoPaste: return L10n.text("自动粘贴到光标处")
        case .clipboardOnly: return L10n.text("仅复制到剪贴板")
        case .preview: return L10n.text("先预览（不粘贴）")
        }
    }
}

enum VoiceLanguage: String, CaseIterable {
    case auto, zh, en, yue, ja, ko
    var label: String {
        switch self {
        case .auto: return L10n.text("自动识别")
        case .zh: return L10n.text("中文")
        case .en: return "English"
        case .yue: return L10n.text("粤语")
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }
}

/// Cleanup is the Article prompt or nothing. The host's other strength names
/// (conservative, maximal) only change validation strictness, so the app no longer
/// offers them; a value saved by an older build reads as `.prompt`.
enum VoiceStrength: String, CaseIterable {
    case prompt, promptify, off
    var label: String {
        switch self {
        case .prompt: return L10n.text("自然整理")
        case .promptify: return L10n.text("提示词模式")
        case .off: return L10n.text("原话转写")
        }
    }

    var detail: String {
        switch self {
        case .prompt: return L10n.text("自然整理：去掉口头禅和重复，自我更正只留最后的说法，补标点，中英文之间加空格，把发音相近的词改成正确的英文术语。")
        case .promptify: return L10n.text("把你说的话改写成一份结构化提示词（角色、背景、任务、要求、语气与受众、输出格式），可以直接发给 AI。角色、语气、格式会自动补全；数字、日期、人名等事实你没说就不写。")
        case .off: return L10n.text("不调用大模型，只在本机去掉口头禅。速度最快。")
        }
    }
}

enum AppearancePreference: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .light: return L10n.text("浅色")
        case .dark: return L10n.text("深色")
        }
    }
}

/// How long dictations stay in History (Reference offers the same choices).
enum HistoryRetention: String, CaseIterable {
    case forever, year, month, week, day, never
    var label: String {
        switch self {
        case .forever: return L10n.text("永久")
        case .year: return L10n.text("1 年")
        case .month: return L10n.text("1 个月")
        case .week: return L10n.text("1 周")
        case .day: return L10n.text("24 小时")
        case .never: return L10n.text("不保存")
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .forever: return nil
        case .year: return 365 * 86400
        case .month: return 30 * 86400
        case .week: return 7 * 86400
        case .day: return 86400
        case .never: return 0
        }
    }
}

struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool
    var name: String

    /// kVK_Function = 63. Read through FnKeyMonitor, not Carbon (which never fires for it).
    static let fnDefault = HotKeyBinding(keyCode: 63, modifiers: 0, enabled: true, name: "Fn")
    /// kVK_Space = 49, optionKey = 2048.
    static let optionSpaceDefault = HotKeyBinding(keyCode: 49, modifiers: 2048, enabled: true, name: "Option+Space")
    /// kVK_ANSI_V = 9, cmdKey (256) | controlKey (4096): "paste last transcript".
    static let pasteLastDefault = HotKeyBinding(keyCode: 9, modifiers: 256 | 4096, enabled: true, name: "Control+Command+V")

    var isFn: Bool { keyCode == 63 && modifiers == 0 }
}

/// One dictionary word. `heardAs` is an optional hard rule ("heard=word"); auto-added
/// words never carry one, so learning can only ever add vocabulary.
struct LocalWord: Codable, Equatable, Identifiable {
    enum Source: String, Codable { case manual, auto }
    var id: String
    var word: String
    var heardAs: String?
    var source: Source
    var addedAt: Date

    /// The string the host stores: "word" or "heard=word".
    var hostEntry: String {
        if let heard = heardAs, !heard.isEmpty, heard != word { return heard + "=" + word }
        return word
    }
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("DshVoiceSettingsDidChange")
    static let wordsDidChange = Notification.Name("DshVoiceWordsDidChange")

    private let d = UserDefaults.standard

    private func changed() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }

    // MARK: hotkeys

    /// Fn, like Reference. It is read from modifier changes (FnKeyMonitor) with the
    /// Accessibility grant; Carbon cannot deliver it. Stored under a new key so a
    /// binding saved by an older build does not silently override the new default.
    var hotkeyMain: HotKeyBinding {
        get { decodeBinding("hk.main.v2") ?? HotKeyBinding.fnDefault }
        set { encodeBinding("hk.main.v2", newValue); changed() }
    }

    /// Second binding for keyboards without a usable Fn (Reference's "Add another").
    var hotkeyAlt: HotKeyBinding {
        get { decodeBinding("hk.alt.v2") ?? HotKeyBinding.optionSpaceDefault }
        set { encodeBinding("hk.alt.v2", newValue); changed() }
    }

    /// Re-insert the most recent transcript (Reference "Paste last transcript").
    var hotkeyPasteLast: HotKeyBinding {
        get { decodeBinding("hk.pasteLast") ?? HotKeyBinding.pasteLastDefault }
        set { encodeBinding("hk.pasteLast", newValue); changed() }
    }

    private func decodeBinding(_ key: String) -> HotKeyBinding? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyBinding.self, from: data)
    }

    private func encodeBinding(_ key: String, _ value: HotKeyBinding) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    // MARK: dictation

    var interfaceLanguage: String {
        get { L10n.normalized(d.string(forKey: L10n.preferenceKey)) }
        set { d.set(L10n.normalized(newValue), forKey: L10n.preferenceKey); changed() }
    }

    var language: String {
        get { VoiceLanguage(rawValue: d.string(forKey: "voice.language") ?? "auto")?.rawValue ?? "auto" }
        set { d.set(newValue, forKey: "voice.language"); changed() }
    }

    var strength: String {
        get { (VoiceStrength(rawValue: d.string(forKey: "voice.strength") ?? "") ?? .prompt).rawValue }
        set { d.set(newValue, forKey: "voice.strength"); changed() }
    }

    var insertionMode: String {
        get { d.string(forKey: "voice.insertion") ?? InsertionMode.autoPaste.rawValue }
        set { d.set(newValue, forKey: "voice.insertion"); changed() }
    }

    var restoreClipboard: Bool {
        get { bool("voice.restoreClipboard", default: true) }
        set { d.set(newValue, forKey: "voice.restoreClipboard"); changed() }
    }

    /// Read the text around the cursor at dictation start and send it as context.
    var readFieldContext: Bool {
        get { bool("voice.fieldContext", default: true) }
        set { d.set(newValue, forKey: "voice.fieldContext"); changed() }
    }

    /// Add a word to the dictionary when the user corrects it right after a dictation.
    var autoLearn: Bool {
        get { bool("voice.autoLearn", default: true) }
        set { d.set(newValue, forKey: "voice.autoLearn"); changed() }
    }

    /// Paste numbered lists as real lists in rich-text apps (Notes, Mail, Pages, Word).
    var richTextLists: Bool {
        get { bool("voice.richLists", default: true) }
        set { d.set(newValue, forKey: "voice.richLists"); changed() }
    }

    // MARK: audio

    var soundEnabled: Bool {
        get { bool("voice.sound", default: true) }
        set { d.set(newValue, forKey: "voice.sound"); changed() }
    }

    var muteWhileDictating: Bool {
        get { bool("voice.muteOthers", default: false) }
        set { d.set(newValue, forKey: "voice.muteOthers"); changed() }
    }

    var inputDeviceUID: String {
        get { d.string(forKey: "voice.inputDevice") ?? "" }
        set { d.set(newValue, forKey: "voice.inputDevice"); changed() }
    }

    var maxSeconds: Int {
        get { d.object(forKey: "voice.maxSeconds") == nil ? 120 : d.integer(forKey: "voice.maxSeconds") }
        set { d.set(newValue, forKey: "voice.maxSeconds"); changed() }
    }

    // MARK: general

    var appearance: AppearancePreference {
        get { AppearancePreference(rawValue: d.string(forKey: "ui.appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "ui.appearance"); changed() }
    }

    /// Reference "Show app in dock". On by default so the main window is one click away.
    var showInDock: Bool {
        get { bool("ui.showInDock", default: true) }
        set { d.set(newValue, forKey: "ui.showInDock"); changed() }
    }

    /// A Node.js chosen by the user; empty means "find it automatically".
    var nodePath: String {
        get { d.string(forKey: "service.nodePath") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "service.nodePath"); changed() }
    }

    /// A huggingface.co mirror for the one-time model download; empty means huggingface.co.
    var modelMirror: String {
        get { d.string(forKey: "service.modelMirror") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "service.modelMirror"); changed() }
    }

    /// Reference "Show voice bar on desktop": a small resting bar at the bottom of the screen.
    ///
    /// Off by default (new key, so the earlier default-on does not carry over): it
    /// floats above every window and swallows clicks on the spot it covers, which
    /// interferes with normal work. People who want it turn it on in Settings.
    var showIdleBar: Bool {
        get { bool("ui.showIdleBar.v2", default: false) }
        set { d.set(newValue, forKey: "ui.showIdleBar.v2"); changed() }
    }

    var launchAtLogin: Bool {
        get { d.bool(forKey: "voice.launchAtLogin") }
        set { d.set(newValue, forKey: "voice.launchAtLogin"); changed() }
    }

    var onboardingDone: Bool {
        get { d.bool(forKey: "ui.onboardingDone.v1") }
        set { d.set(newValue, forKey: "ui.onboardingDone.v1"); changed() }
    }

    /// Whether to build the pill panel shortly after launch.
    ///
    /// The panel costs ~35 MB resident and is only needed once dictation starts.
    /// Warming it early keeps the first recording's waveform frame complete;
    /// turning this off keeps idle memory at the floor and accepts that the very
    /// first recording may show the pill one frame late.
    var warmUpPill: Bool {
        get { d.object(forKey: "voice.warmUpPill") as? Bool ?? true }
        set { d.set(newValue, forKey: "voice.warmUpPill"); changed() }
    }

    // MARK: history

    var historyRetention: HistoryRetention {
        get { HistoryRetention(rawValue: d.string(forKey: "history.retention") ?? "") ?? .forever }
        set { d.set(newValue.rawValue, forKey: "history.retention"); changed() }
    }

    /// Keep the recording for 24 h so History can retry with the same audio (Reference keeps audio too).
    var keepAudio24h: Bool {
        get { bool("voice.keepAudio24h.v2", default: true) }
        set { d.set(newValue, forKey: "voice.keepAudio24h.v2"); changed() }
    }

    // MARK: dictionary

    var words: [LocalWord] {
        get {
            if let data = d.data(forKey: "voice.words.v2"),
               let list = try? JSONDecoder().decode([LocalWord].self, from: data) { return list }
            return migratedWords()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "voice.words.v2") }
            NotificationCenter.default.post(name: Settings.wordsDidChange, object: nil)
        }
    }

    /// Entries in the service's format, for PUT /dictionary.
    var hostDictionary: [String] { words.map(\.hostEntry) }

    @discardableResult
    func addWord(_ word: String, heardAs: String? = nil, source: LocalWord.Source) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = heardAs?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }
        var list = words
        // Auto-learning never overrides what the user typed in by hand.
        if source == .auto, list.contains(where: { $0.word.caseInsensitiveCompare(w) == .orderedSame }) { return false }
        list.removeAll { $0.word.caseInsensitiveCompare(w) == .orderedSame }
        list.insert(LocalWord(id: UUID().uuidString, word: w, heardAs: (h?.isEmpty ?? true) ? nil : h,
                              source: source, addedAt: Date()), at: 0)
        words = list
        return true
    }

    func updateWord(id: String, word: String, heardAs: String?) {
        var list = words
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = heardAs?.trimmingCharacters(in: .whitespacesAndNewlines)
        list[index].heardAs = (h?.isEmpty ?? true) ? nil : h
        words = list
    }

    func removeWord(id: String) {
        words = words.filter { $0.id != id }
    }

    /// Import a CSV: one entry per line, "word" or "heard,word" (Reference "Import CSV").
    func importCSV(_ text: String) -> Int {
        var added = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) }
            guard let last = cells.last, !last.isEmpty else { continue }
            let heard = cells.count >= 2 ? cells[0] : nil
            if addWord(last, heardAs: heard, source: .manual) { added += 1 }
        }
        return added
    }

    /// Words saved by older builds as [DictEntry] (from/to pairs).
    private func migratedWords() -> [LocalWord] {
        guard let data = d.data(forKey: "voice.dictionary"),
              let old = try? JSONDecoder().decode([DictEntry].self, from: data) else { return [] }
        return old.map { entry in
            LocalWord(id: UUID().uuidString, word: entry.to,
                      heardAs: entry.from == entry.to ? nil : entry.from,
                      source: .manual, addedAt: Date())
        }
    }
}
