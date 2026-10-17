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

public sealed class SpeechStatus
{
    [JsonPropertyName("providerId")] public string? ProviderId { get; set; }
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

    /// <summary>When fallback is true the service has already put the raw transcript in Text.</summary>
    [JsonIgnore] public string InsertableText => Text.Length > 0 ? Text : Raw;
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
