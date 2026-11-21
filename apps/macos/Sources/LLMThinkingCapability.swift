import Foundation

enum LLMThinkingControl: String, Codable {
    case thinking, enableThinking, reasoning, effort

    init?(parameter: String) {
        switch parameter {
        case "thinking": self = .thinking
        case "enable_thinking": self = .enableThinking
        case "reasoning": self = .reasoning
        case "reasoning_effort": self = .effort
        default: return nil
        }
    }
}

enum LLMThinkingMode: String, Codable {
    case enabled, disabled
    case providerDefault = "default"
}

struct LLMThinkingCapability: Codable, Equatable {
    enum Mode: String, Codable {
        case toggle, alwaysOn, alwaysOff, observed

        var label: String {
            switch self {
            case .toggle: return L10n.text("思考可开关")
            case .alwaysOn: return L10n.text("始终思考")
            case .alwaysOff: return L10n.text("不支持思考")
            case .observed: return L10n.text("支持思考，开关未验证")
            }
        }
    }

    let mode: Mode
    var control: LLMThinkingControl? = nil
    var effortLevels: [String]? = nil
    var defaultEffort: String? = nil

    var needsProbe: Bool { mode == .observed }

    static func fromCatalog(_ model: [String: Any], baseURL: String) -> Self? {
        let host = URL(string: baseURL)?.host?.lowercased()
        let protocols = model["api_capabilities"] as? [String: Any]
        let chat = protocols?["openai_chat_completions"] as? [String: Any]
        let generic = model["capabilities"] as? [String: Any]
        let thinking = (chat?["thinking"] ?? generic?["thinking"] ?? model["thinking"]) as? [String: Any]
        let effort = (thinking?["effort"] ?? model["effort"]) as? [String: Any]
        let ordered = (effort?["supported_levels"] as? [String] ?? []).reduce(into: [String]()) { levels, level in
            if levels.count < 12, !levels.contains(level),
               level.range(of: "^[a-z][a-z0-9_-]{0,23}$", options: .regularExpression) != nil {
                levels.append(level)
            }
        }
        let defaultEffort = (effort?["default_level"] as? String).flatMap { ordered.contains($0) ? $0 : nil }
        let declaredControl = (thinking?["parameter"] as? String).flatMap(LLMThinkingControl.init(parameter:))
        // DeepSeek's documented catalog lists the supported thinking levels and its API
        // defines how to disable thinking separately from the effort field.
        if host == "api.deepseek.com", !ordered.isEmpty, thinking == nil {
            return Self(mode: .toggle, control: .thinking, effortLevels: ordered, defaultEffort: defaultEffort)
        }
        let canEnable = thinking?["can_enable"] as? Bool
        let canDisable = thinking?["can_disable"] as? Bool
        let mode: Mode
        switch (thinking?["mode"] as? String, canEnable, canDisable) {
        case ("toggle", _, _), (_, true?, true?): mode = declaredControl == nil ? .observed : .toggle
        case ("always_on", _, _), (_, true?, false?): mode = .alwaysOn
        case ("always_off", _, _), (_, false?, true?), (_, false?, false?): mode = .alwaysOff
        default:
            let parameters = model["supported_parameters"] as? [String] ?? []
            guard !ordered.isEmpty || parameters.contains("reasoning") || parameters.contains("reasoning_effort") else { return nil }
            mode = .observed
        }
        return Self(mode: mode, control: declaredControl, effortLevels: ordered.isEmpty ? nil : ordered,
                    defaultEffort: defaultEffort)
    }
}

struct LLMCatalogModel: Identifiable, Equatable {
    let id: String
    let thinking: LLMThinkingCapability?

    static func decode(_ data: Data, baseURL: String) -> [Self] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return Self(id: id, thinking: LLMThinkingCapability.fromCatalog(model, baseURL: baseURL))
        }.sorted { $0.id < $1.id }
    }
}

/// Capabilities last a week, match the endpoint including its path, and contain no credentials.
struct LLMThinkingCache {
    private struct Entry: Codable {
        let capability: LLMThinkingCapability
        let updatedAt: Date
    }

    var defaults: UserDefaults = .standard
    private static let storageKey = "llm.thinkingCapabilities.v1"

    static func endpoint(_ baseURL: String) -> String {
        let text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text) else { return text }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        return components.string ?? text
    }

    private func entries(at now: Date) -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries.filter { now.timeIntervalSince($0.value.updatedAt) < 7 * 24 * 60 * 60 }
    }

    func capabilities(for baseURL: String, now: Date = Date()) -> [String: LLMThinkingCapability] {
        let prefix = Self.endpoint(baseURL) + "\n"
        var result: [String: LLMThinkingCapability] = [:]
        for (key, entry) in entries(at: now) where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = entry.capability
        }
        return result
    }

    func store(_ capabilities: [String: LLMThinkingCapability], for baseURL: String, now: Date = Date()) {
        guard !capabilities.isEmpty else { return }
        var entries = entries(at: now)
        let prefix = Self.endpoint(baseURL) + "\n"
        for (model, latest) in capabilities {
            let key = prefix + model.lowercased()
            let existing = entries[key]?.capability
            var merged = latest
            if let existing, latest.mode == .observed, !existing.needsProbe {
                merged = existing
            }
            merged.effortLevels = latest.effortLevels ?? existing?.effortLevels
            merged.defaultEffort = latest.defaultEffort ?? existing?.defaultEffort
            if merged.effortLevels?.contains(merged.defaultEffort ?? "") != true { merged.defaultEffort = nil }
            entries[key] = Entry(capability: merged, updatedAt: now)
        }
        let recent = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(150)
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
