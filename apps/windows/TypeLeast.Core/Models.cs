using System.Text.Json;
using System.Text.Json.Serialization;

namespace TypeLeast.Core;

// Models.cs - the JSON the local service speaks (service/lib/http.js). Decoding is
// lenient: unknown fields are ignored and missing ones keep their defaults.

public sealed class DownloadProgress
{
    [JsonPropertyName("received")] public double Received { get; set; }
    [JsonPropertyName("total")] public double Total { get; set; }
}

public sealed class SpeechModelOperation
{
    public string ModelId { get; set; } = "";
    public string Phase { get; set; } = "";
    public double Received { get; set; }
    public double Total { get; set; }
    public string? Error { get; set; }
    [JsonIgnore] public string Problem => Error switch {
        "checksum-mismatch" => L10n.T("文件校验失败，请重新下载。"),
        "download-failed" => L10n.T("下载失败，请检查网络或镜像后重试。"),
        "model-not-installed" => L10n.T("模型文件不完整，请重新下载。"),
        "model-load-failed" => L10n.T("模型加载失败，请重试或使用其他模型。"),
        "ENOSPC" => L10n.T("磁盘空间不足，请释放空间后重试。"),
        "EACCES" or "EPERM" => L10n.T("无法保存模型设置，请检查文件访问权限。"),
        _ => L10n.T("模型操作失败，请重试。当前模型保留。"),
    };
    [JsonIgnore] public bool Running => Phase is "downloading" or "waiting" or "loading";
}
public sealed class SpeechModelOption
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public double ModelBytes { get; set; }
    public string SourceUrl { get; set; } = "";
    public string LicenseUrl { get; set; } = "";
    public bool CanSetLanguage { get; set; }
    public bool Installed { get; set; }
}
public sealed class SpeechModelCatalog
{
    public string ActiveModelId { get; set; } = "sensevoice-small";
    public List<SpeechModelOption> Models { get; set; } = new();
    public SpeechModelOperation? Operation { get; set; }
    public string? Notice { get; set; }
}

public sealed class SpeechStatus
{
    [JsonPropertyName("providerId")] public string? ProviderId { get; set; }
    public string? ModelId { get; set; }
    public string? ModelName { get; set; }
    public bool? CanSetLanguage { get; set; }
    public List<string>? Languages { get; set; }
    public SpeechModelOperation? Operation { get; set; }
    public string? Notice { get; set; }
    [JsonPropertyName("ready")] public bool Ready { get; set; }
    /// <summary>loading | ready | missing-model | downloading | error</summary>
    [JsonPropertyName("phase")] public string? Phase { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("download")] public DownloadProgress? Download { get; set; }
    [JsonPropertyName("modelBytes")] public double? ModelBytes { get; set; }

    [JsonIgnore] public bool ModelsMissing => Phase == "missing-model";
    [JsonIgnore] public bool Downloading => Phase == "downloading";

    /// <summary>0..1 while downloading, else null.</summary>
    [JsonIgnore]
    public double? DownloadFraction =>
        Downloading && Download is { Total: > 0 } d ? Math.Clamp(d.Received / d.Total, 0, 1) : null;
}

public sealed class HealthResponse
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("service")] public string? Service { get; set; }
    [JsonPropertyName("version")] public string? Version { get; set; }
    [JsonPropertyName("provider")] public string? Provider { get; set; }
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("speech")] public SpeechStatus? Speech { get; set; }
    [JsonPropertyName("pid")] public int? Pid { get; set; }
}

public sealed class MsBreakdown
{
    [JsonPropertyName("transcribe")] public double? Transcribe { get; set; }
    [JsonPropertyName("polish")] public double? Polish { get; set; }
    [JsonPropertyName("total")] public double? Total { get; set; }
}

/// <summary>Prompt Beta: questions to answer first, or what the review did.</summary>
public sealed class BetaInfo
{
    [JsonPropertyName("sessionId")] public string? SessionId { get; set; }
    [JsonPropertyName("questions")] public List<string>? Questions { get; set; }
    [JsonPropertyName("confirmed")] public List<string>? Confirmed { get; set; }
    [JsonPropertyName("round")] public int? Round { get; set; }
    [JsonPropertyName("ready")] public bool? Ready { get; set; }
    [JsonPropertyName("notice")] public string? Notice { get; set; }
    [JsonPropertyName("issues")] public int? Issues { get; set; }
    [JsonPropertyName("patched")] public bool? Patched { get; set; }
}

public sealed record SuggestionCandidate(string Word, string HeardAs);

/// <summary>Bad optional suggestions never prevent decoding the actual dictation.</summary>
public sealed class SuggestionListConverter : JsonConverter<List<SuggestionCandidate>>
{
    public override bool HandleNull => true;
    public override List<SuggestionCandidate> Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var result = new List<SuggestionCandidate>();
        if (doc.RootElement.ValueKind != JsonValueKind.Array) return result;
        foreach (var item in doc.RootElement.EnumerateArray().Take(8))
        {
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("word", out var word) ||
                word.ValueKind != JsonValueKind.String || !item.TryGetProperty("heardAs", out var heard) || heard.ValueKind != JsonValueKind.String) continue;
            var w = word.GetString()!; var h = heard.GetString()!;
            if (w.Length is >= 2 and <= 30 && h.Length is >= 1 and <= 30 && !w.Any(char.IsControl) && !h.Any(char.IsControl) && !string.IsNullOrWhiteSpace(w) && !string.IsNullOrWhiteSpace(h))
                result.Add(new(w, h));
        }
        return result;
    }
    public override void Write(Utf8JsonWriter writer, List<SuggestionCandidate> value, JsonSerializerOptions options)
    {
        writer.WriteStartArray();
        foreach (var item in value.Take(8)) { writer.WriteStartObject(); writer.WriteString("word", item.Word); writer.WriteString("heardAs", item.HeardAs); writer.WriteEndObject(); }
        writer.WriteEndArray();
    }
}

public sealed class DictateResponse
{
    [JsonPropertyName("requestId")] public string? RequestId { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("raw")] public string Raw { get; set; } = "";
    [JsonPropertyName("fallback")] public bool Fallback { get; set; }
    [JsonPropertyName("fallbackReason")] public string? FallbackReason { get; set; }
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("provider")] public string? Provider { get; set; }
    [JsonPropertyName("ms")] public MsBreakdown? Ms { get; set; }
    [JsonPropertyName("beta")] public BetaInfo? Beta { get; set; }
    [JsonPropertyName("suggestions"), JsonConverter(typeof(SuggestionListConverter))]
    public List<SuggestionCandidate> Suggestions { get; set; } = new();
    /// <summary>翻译模式: the language the text was written in.</summary>
    [JsonPropertyName("translated")] public string? Translated { get; set; }

    /// <summary>Prompt Beta asked questions: nothing to paste yet.</summary>
    [JsonIgnore] public IReadOnlyList<string> BetaQuestions =>
        Beta?.SessionId is null ? Array.Empty<string>() : (IReadOnlyList<string>?)Beta.Questions ?? Array.Empty<string>();

    /// <summary>When fallback is true the service has already put the raw transcript in Text.</summary>
    [JsonIgnore] public bool BetaWaiting => !string.IsNullOrWhiteSpace(Beta?.SessionId);
    [JsonIgnore] public string InsertableText => BetaWaiting ? "" : Text.Length > 0 ? Text : Raw;
}

public sealed class LlmTestResult
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("ms")] public double? Ms { get; set; }
    [JsonPropertyName("code")] public string? Code { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("sample")] public string? Sample { get; set; }
}

/// <summary>Answer of POST /learned-word: the word a fix right after a paste teaches, or null.</summary>
public sealed class LearnedWordResult
{
    [JsonPropertyName("word")] public string? Word { get; set; }
}

/// <summary>Prompt mode (提示词模式): the fixed default, the user's additions and replacement.</summary>
public sealed class PromptifySettings
{
    [JsonPropertyName("default")] public string Default { get; set; } = "";
    [JsonPropertyName("appendix")] public string Appendix { get; set; } = "";
    [JsonPropertyName("override")] public string? Override { get; set; }
    [JsonPropertyName("modified")] public bool Modified { get; set; }
    [JsonPropertyName("effective")] public string Effective { get; set; } = "";
}

/// <summary>The one-time code the user must type before the default prompt can be replaced.</summary>
public static class PromptifyGuard
{
    public static string MakeCode() => System.Security.Cryptography.RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
    public static bool Matches(string? typed, string code) => (typed ?? "").Trim() == code;
}

public sealed class ApiErrorBody
{
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("code")] public string? Code { get; set; }
}

/// <summary>A model reached with the user's own key over the OpenAI-compatible protocol.</summary>
public sealed record LlmRoute(
    [property: JsonPropertyName("baseURL")] string BaseUrl,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("apiKey")] string ApiKey)
{
    /// <summary>Model ids from an OpenAI-compatible /models body: {"data": [{"id": …}]}.</summary>
    public static List<string> ModelIds(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return new();
            var ids = new List<string>();
            foreach (var item in data.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
                    ids.Add(id.GetString()!);
            }
            ids.Sort(StringComparer.Ordinal);
            return ids;
        }
        catch (JsonException)
        {
            return new();
        }
    }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };
}
