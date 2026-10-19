namespace TypeLeast.Core;

/// <summary>A provider the Settings page offers, with the values a user would otherwise look up.
/// The same list as apps/macos/Sources/LLMSettings.swift.</summary>
public sealed record LlmPreset(string Id, string Name, string BaseUrl, string ModelHint, bool NeedsKey, string KeyPage)
{
    public static readonly IReadOnlyList<LlmPreset> All = new[]
    {
        new LlmPreset("deepseek", L10n.T("DeepSeek 官方 API"), "https://api.deepseek.com/v1", "deepseek-chat", true, "https://platform.deepseek.com/api_keys"),
        new LlmPreset("zhipu", L10n.T("智谱 GLM"), "https://open.bigmodel.cn/api/paas/v4", "glm-4-flash", true, "https://open.bigmodel.cn/usercenter/apikeys"),
        new LlmPreset("moonshot", L10n.T("Kimi（月之暗面）"), "https://api.moonshot.cn/v1", "moonshot-v1-8k", true, "https://platform.moonshot.cn/console/api-keys"),
        new LlmPreset("qwen", L10n.T("通义千问"), "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus", true, "https://dashscope.console.aliyun.com/apiKey"),
        new LlmPreset("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "deepseek/deepseek-chat", true, "https://openrouter.ai/keys"),
        new LlmPreset("openai", "OpenAI", "https://api.openai.com/v1", "gpt-4o-mini", true, "https://platform.openai.com/api-keys"),
        new LlmPreset("ollama", L10n.T("本机 Ollama"), "http://127.0.0.1:11434/v1", "qwen2.5:7b", false, "https://ollama.com"),
        new LlmPreset("custom", L10n.T("自定义（OpenAI 兼容）"), "", L10n.T("模型 ID"), true, ""),
    };

    public static LlmPreset Find(string? id) => All.FirstOrDefault(p => p.Id == id) ?? All[0];

    /// <summary>Whether a base URL may carry a key: https, or http to this computer only.</summary>
    public static bool IsAllowedBaseUrl(string? text)
    {
        if (!Uri.TryCreate(text?.Trim(), UriKind.Absolute, out var uri)) return false;
        if (uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return false;
        if (uri.Scheme == Uri.UriSchemeHttps) return true;
        return uri.Scheme == Uri.UriSchemeHttp && (uri.Host is "127.0.0.1" or "localhost" or "[::1]" or "::1");
    }
}
