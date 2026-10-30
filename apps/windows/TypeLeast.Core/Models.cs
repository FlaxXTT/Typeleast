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
        "download-failed" => L10n.T("下载失败。请检查网络或镜像后重试。"),
        "model-not-installed" => L10n.T("模型文件不完整，请重新下载。"),
        "model-load-failed" => L10n.T("模型加载失败。请重试或换一个模型。"),
        "ENOSPC" => L10n.T("磁盘空间不足。请释放空间后重试。"),
        "EACCES" or "EPERM" => L10n.T("无法保存模型设置。请检查文件权限。"),
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
    public string? Family { get; set; }
    public string? Precision { get; set; }
    public string? Category { get; set; }
    public bool Registered { get; set; }
    public bool Downloadable { get; set; }
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
    [JsonIgnore] public string DisplayName => string.IsNullOrWhiteSpace(ModelName) ? L10n.T("未选择语音模型") : ModelName;
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
    /// <summary>拆解提示词: the selected prompt's core goals, before its details (Confirmed).</summary>
    [JsonPropertyName("goals")] public List<string>? Goals { get; set; }
    [JsonPropertyName("round")] public int? Round { get; set; }
    [JsonPropertyName("ready")] public bool? Ready { get; set; }
    [JsonPropertyName("notice")] public string? Notice { get; set; }
    [JsonPropertyName("issues")] public int? Issues { get; set; }
    [JsonPropertyName("patched")] public bool? Patched { get; set; }
}

/// <summary>A term the cleanup model corrected, kept in History for the description of the user's work.</summary>
public sealed class TermCorrection
{
    [JsonPropertyName("from")] public string From { get; set; } = "";
    [JsonPropertyName("to")] public string To { get; set; } = "";
    [JsonPropertyName("reason")] public string? Reason { get; set; }
}

public sealed class TaskProgress
{
    public string Stage { get; set; } = "waiting";
    public int Completed { get; set; }
    public int Total { get; set; }
    public string Label => Stage switch {
        "recognizing" => L10n.T("正在识别…"), "preparing" => L10n.T("正在理解全文…"),
        "generating" => Total > 1 ? L10n.T("正在整理 {0}/{1}", Completed, Total) : L10n.T("正在整理…"),
        "checking" => L10n.T("正在检查完整性…"), "translating" => L10n.T("正在翻译…"), _ => L10n.T("正在处理…") };
}

public sealed class DictateResponse
{
    public string? Task { get; set; }
    [JsonPropertyName("requestId")] public string? RequestId { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("raw")] public string Raw { get; set; } = "";
    [JsonPropertyName("fallback")] public bool Fallback { get; set; }
    [JsonPropertyName("fallbackReason")] public string? FallbackReason { get; set; }
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("provider")] public string? Provider { get; set; }
    [JsonPropertyName("ms")] public MsBreakdown? Ms { get; set; }
    [JsonPropertyName("beta")] public BetaInfo? Beta { get; set; }
    /// <summary>What the cleanup model corrected and understood; stored in History, never inserted.</summary>
    [JsonPropertyName("corrections"), JsonConverter(typeof(LenientConverter<List<TermCorrection>>))] public List<TermCorrection>? Corrections { get; set; }
    [JsonPropertyName("intention"), JsonConverter(typeof(LenientConverter<string>))] public string? Intention { get; set; }
    /// <summary>翻译模式: the language the text was written in.</summary>
    [JsonPropertyName("translated")] public string? Translated { get; set; }

    /// <summary>Prompt Beta asked questions: nothing to paste yet.</summary>
    [JsonIgnore] public IReadOnlyList<string> BetaQuestions =>
        Beta?.SessionId is null ? Array.Empty<string>() : (IReadOnlyList<string>?)Beta.Questions ?? Array.Empty<string>();

    /// <summary>When fallback is true the service has already put the raw transcript in Text.</summary>
    [JsonIgnore] public bool BetaWaiting => !string.IsNullOrWhiteSpace(Beta?.SessionId);
    [JsonIgnore] public string InsertableText => BetaWaiting ? "" : Text.Length > 0 ? Text : Raw;
}

/// <summary>An optional field of the wrong shape is read as absent instead of failing the whole response.</summary>
public sealed class LenientConverter<T> : JsonConverter<T> where T : class
{
    public override bool HandleNull => true;
    public override T? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        try { return doc.RootElement.Deserialize<T>(options); }
        catch (JsonException) { return null; }
    }
    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) => JsonSerializer.Serialize(writer, value, options);
}

public sealed class LlmTestResult
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("ms")] public double? Ms { get; set; }
    [JsonPropertyName("code")] public string? Code { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("sample")] public string? Sample { get; set; }
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
