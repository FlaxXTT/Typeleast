import AppKit
import SwiftUI

/// Bundled brand artwork is selected by model family when known, including through routers.
enum EngineBrand: String, CaseIterable {
    case doubao, qwen, deepseek, zhipu, kimi, openai, openrouter, ollama
    case funasr, alibabacloud, moss, claude, gemini, mistral, meta, grok, minimax

    private static let families: [(EngineBrand, [String])] = [
        (.qwen, ["qwen", "qwq"]), (.deepseek, ["deepseek"]), (.claude, ["claude"]),
        (.gemini, ["gemini"]), (.kimi, ["kimi", "moonshot"]), (.zhipu, ["glm"]),
        (.doubao, ["doubao"]), (.openai, ["gpt-", "chatgpt", "o1-", "o3-", "o4-"]),
        (.mistral, ["mistral", "mixtral", "codestral"]), (.meta, ["llama"]),
        (.grok, ["grok"]), (.minimax, ["minimax"]),
    ]

    static func speech(provider: OnlineASRProvider, modelID: String?) -> Self? {
        switch provider {
        case .doubao: return .doubao
        case .funASR: return .alibabacloud
        case .local:
            let id = modelID?.lowercased() ?? ""
            if id.hasPrefix("mlx-qwen3-asr-") || id.hasPrefix("qwen3-asr") { return .qwen }
            if id.hasPrefix("mlx-fun-asr-") || id.hasPrefix("fun-asr") { return .funasr }
            if id.hasPrefix("moss-transcribe") { return .moss }
            return nil
        }
    }

    static func cleanup(providerID: String, modelID: String) -> Self? {
        let parts = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "/")
        let name = parts.last.map(String.init) ?? ""
        // A router or local runner can serve many unrelated model families.
        if let family = families.first(where: { family in family.1.contains(where: { name.hasPrefix($0) }) }) {
            return family.0
        }
        if ["o1", "o3", "o4"].contains(name) { return .openai }
        if parts.count > 1, let publisher = parts.first {
            switch publisher {
            case "anthropic": return .claude
            case "meta-llama": return .meta
            case "mistralai": return .mistral
            case "x-ai": return .grok
            case "z-ai", "zhipuai": return .zhipu
            case "moonshotai": return .kimi
            case "minimax": return .minimax
            default: break
            }
        }
        return providerID == "moonshot" ? .kimi : Self(rawValue: providerID)
    }

    var image: NSImage? { Self.images[self] }

    private static let images: [EngineBrand: NSImage] = Dictionary(uniqueKeysWithValues: allCases.compactMap { brand in
        for format in ["png", "svg"] {
            if let url = Bundle.main.url(forResource: brand.rawValue, withExtension: format, subdirectory: "EngineLogos"),
               let image = NSImage(contentsOf: url) {
                return (brand, image)
            }
        }
        return nil
    })

    var usesLightBackgroundInDarkMode: Bool {
        switch self {
        case .openai, .ollama, .grok: return true
        default: return false
        }
    }
}

struct EngineLogo: View {
    let brand: EngineBrand
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let artwork = brand.image {
            let needsBackground = colorScheme == .dark && brand.usesLightBackgroundInDarkMode
            Image(nsImage: artwork)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: brand == .funasr ? 31 : 18, height: 18)
                .padding(2)
                .background(needsBackground ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
    }
}
