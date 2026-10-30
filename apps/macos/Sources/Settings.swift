import Foundation

// Settings.swift - UserDefaults-backed configuration for TypeLeast.

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

/// 翻译模式 target languages; the raw values are the codes the service knows.
enum TranslateLanguage: String, CaseIterable {
    case en, zh, ja, ko, fr, de, es, pt, it, ru
    var label: String {
        switch self {
        case .en: return "English"
        case .zh: return L10n.text("中文")
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .ru: return "Русский"
        }
    }
}

/// How Chinese and English are written in the output (语言变体).
enum ChineseVariant: String, CaseIterable {
    case hans, tw, hk
    var label: String {
        switch self {
        case .hans: return L10n.text("简体")
        case .tw: return L10n.text("繁体（台湾）")
        case .hk: return L10n.text("繁体（香港）")
        }
    }
}

/// The cleanup modes. "prompt" is the historical stored id for 自然整理.
/// Retired prompt tiers read as `.concise`; retired verbatim reads as `.prompt`.
enum VoiceStrength: String, CaseIterable {
    case concise, prompt, promptbeta
    var label: String {
        switch self {
        case .prompt: return L10n.text("自然整理")
        case .concise: return L10n.text("AI 整理")
        case .promptbeta: return L10n.text("提示词 Beta")
        }
    }

    /// The tier a stored value means: the prompt-mode tiers of 1.18 became AI 整理.
    static func stored(_ value: String?) -> VoiceStrength {
        if value == "promptbrief" || value == "promptify" { return .concise }
        if value == "off" { return .prompt }
        return VoiceStrength(rawValue: value ?? "") ?? .prompt
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

/// How long dictations stay in History.
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
    /// kVK_Space = 49, optionKey = 2048: 提示词模式 (Fn is for dictation only).
    static let optionSpaceDefault = HotKeyBinding(keyCode: 49, modifiers: 2048, enabled: true, name: "Option+Space")
    static let unset = HotKeyBinding(keyCode: 0, modifiers: 0, enabled: false, name: "")
    /// kVK_ANSI_V = 9, cmdKey (256) | controlKey (4096): "paste last transcript".
    static let pasteLastDefault = HotKeyBinding(keyCode: 9, modifiers: 256 | 4096, enabled: true, name: "Control+Command+V")
    /// kVK_Space with shiftKey (512) | optionKey (2048): 翻译, next to ⌥Space for 提示词模式.
    static let translateDefault = HotKeyBinding(keyCode: 49, modifiers: 512 | 2048, enabled: true, name: "Shift+Option+Space")

    var isFn: Bool { keyCode == 63 && modifiers == 0 }
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("DshVoiceSettingsDidChange")

    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        if defaults.object(forKey: "ui.practiceGate.v1") == nil {
            let existing = defaults.dictionaryRepresentation().keys.contains { key in
                key.hasPrefix("voice.") || key.hasPrefix("llm.") || key.hasPrefix("ui.onboardingDone") || key.hasPrefix("hk.")
            }
            defaults.set(!existing, forKey: "ui.practiceGate.v1")
        }
        if !defaults.bool(forKey:"voice.unifiedDictation.v1") {
            defaults.set("prompt",forKey:"voice.strength")
            defaults.set(600,forKey:"voice.maxSeconds")
            defaults.set(true,forKey:"voice.unifiedDictation.v1")
        }
        migratePromptKey()
    }

    /// Once: ⌥Space leaves dictation's second slot and becomes 提示词模式's key, unless another
    /// shortcut already uses it. Fn stays the dictation key.
    private func migratePromptKey() {
        guard !d.bool(forKey: "hk.promptKey.v1") else { return }
        d.set(true, forKey: "hk.promptKey.v1")
        let space = HotKeyBinding.optionSpaceDefault
        func isSpace(_ b: HotKeyBinding) -> Bool { b.enabled && b.keyCode == space.keyCode && b.modifiers == space.modifiers }
        if isSpace(decodeBinding("hk.alt.v2") ?? space) { encodeBinding("hk.alt.v2", .unset) }
        if decodeBinding("hk.assistant")?.enabled != true {
            let taken = [hotkeyMain, hotkeyAlt, hotkeyTranslate, hotkeyPasteLast].contains(where: isSpace)
            encodeBinding("hk.assistant", taken ? .unset : space)
        }
    }

    static func migrateAICleanup(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "voice.aiCleanupDefault.v1") else { return }
        defaults.set("concise", forKey: "voice.strength")
        defaults.set(true, forKey: "voice.aiCleanupDefault.v1")
    }

    private func changed() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }

    // MARK: hotkeys

    /// Fn. It is read from modifier changes (FnKeyMonitor) with the
    /// Accessibility grant; Carbon cannot deliver it. Stored under a new key so a
    /// binding saved by an older build does not silently override the new default.
    var hotkeyMain: HotKeyBinding {
        get { decodeBinding("hk.main.v2") ?? HotKeyBinding.fnDefault }
        set { encodeBinding("hk.main.v2", newValue); changed() }
    }

    /// Second binding for keyboards without a usable Fn ("Add another"); none by default.
    var hotkeyAlt: HotKeyBinding {
        get { decodeBinding("hk.alt.v2") ?? HotKeyBinding.unset }
        set { encodeBinding("hk.alt.v2", newValue); changed() }
    }

    /// 提示词模式: ⌥Space by default. With text selected, the selection is the draft to revise.
    var hotkeyAssistant: HotKeyBinding {
        get { decodeBinding("hk.assistant") ?? HotKeyBinding.optionSpaceDefault }
        set { encodeBinding("hk.assistant", newValue); changed() }
    }

    /// 翻译模式: dictate, and the cleaned-up text is inserted in the target language.
    var hotkeyTranslate: HotKeyBinding {
        get { decodeBinding("hk.translate") ?? HotKeyBinding.translateDefault }
        set { encodeBinding("hk.translate", newValue); changed() }
    }

    /// Re-insert the most recent transcript ("Paste last transcript").
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

    var translateTarget: String {
        get { (TranslateLanguage(rawValue: d.string(forKey: "voice.translateTarget") ?? "") ?? .en).rawValue }
        set { d.set(newValue, forKey: "voice.translateTarget"); changed() }
    }

    var zhVariant: String {
        get { (ChineseVariant(rawValue: d.string(forKey: "voice.zhVariant") ?? "") ?? .hans).rawValue }
        set { d.set(newValue, forKey: "voice.zhVariant"); changed() }
    }

    /// Sent with every request ("zh=tw"); nil for simplified Chinese.
    var variantsHeader: String? { zhVariant == ChineseVariant.hans.rawValue ? nil : "zh=" + zhVariant }

    var strength: String {
        get { VoiceStrength.stored(d.string(forKey: "voice.strength")).rawValue }
        set { d.set(newValue, forKey: "voice.strength"); changed() }
    }

    /// Read the text around the cursor at dictation start and send it as context.
    var readFieldContext: Bool {
        // Off by default (as on Windows): when on, text near the cursor and the window
        // title go to the cleanup model's provider with each dictation.
        get { bool("voice.fieldContext", default: false) }
        set { d.set(newValue, forKey: "voice.fieldContext"); changed() }
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
        get { d.object(forKey: "voice.maxSeconds") == nil ? 600 : d.integer(forKey: "voice.maxSeconds") }
        set { d.set(newValue, forKey: "voice.maxSeconds"); changed() }
    }

    // MARK: general

    var appearance: AppearancePreference {
        get { AppearancePreference(rawValue: d.string(forKey: "ui.appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "ui.appearance"); changed() }
    }

    /// "Show app in dock". On by default so the main window is one click away.
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
    /// Where updates are downloaded from: auto, github or mirror (UpdateSources).
    var updateSource: String {
        get { d.string(forKey: "voice.updateSource").flatMap { UpdateSources.modes.contains($0) ? $0 : nil } ?? "auto" }
        set { d.set(newValue, forKey: "voice.updateSource"); changed() }
    }

    var modelMirror: String {
        get { d.string(forKey: "service.modelMirror") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "service.modelMirror"); changed() }
    }

    /// "Show voice bar on desktop": a small resting bar at the bottom of the screen.
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

    /// The home page's 「设置在哪」 card was dismissed with 知道了.
    var guideDismissed: Bool {
        get { d.bool(forKey: "ui.guideDismissed.v1") }
        set { d.set(newValue, forKey: "ui.guideDismissed.v1"); changed() }
    }

    var needsPractice: Bool { d.bool(forKey: "ui.practiceGate.v1") && !onboardingDone }

    var onboardingDone: Bool {
        get { d.bool(forKey: "ui.onboardingDone.v1") }
        set { d.set(newValue, forKey: "ui.onboardingDone.v1"); if newValue { d.set(false, forKey: "ui.practiceGate.v1") }; changed() }
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

    /// Keep the recording for five minutes (HistoryStore.audioLifetime) so History can retry
    /// with the same audio. The stored key keeps its old name.
    var keepAudio24h: Bool {
        get { bool("voice.keepAudio24h.v2", default: true) }
        set { d.set(newValue, forKey: "voice.keepAudio24h.v2"); changed() }
    }
}
