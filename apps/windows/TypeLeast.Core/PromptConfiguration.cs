using System.Text.Json;
using System.Text.Json.Nodes;

namespace TypeLeast.Core;

/// <summary>Editable JSON config shared with the service. Never overwrite malformed input.</summary>
public static class PromptConfiguration
{
    public static string Prepare(string? existing, PromptifySettings current)
    {
        if (existing is not null && System.Text.Encoding.UTF8.GetByteCount(existing) > 100_000) throw new InvalidDataException("Configuration too large");
        var obj = existing is null ? new JsonObject() : JsonNode.Parse(existing) as JsonObject
            ?? throw new InvalidDataException("Invalid configuration");
        foreach (var field in new[] { "appendix", "override" })
            if (obj[field] is not null && (obj[field] is not JsonValue value || !value.TryGetValue<string>(out _)))
                throw new InvalidDataException("Invalid configuration field");
        obj["appendix"] ??= current.Appendix;
        if (string.IsNullOrWhiteSpace(obj["override"]?.GetValue<string>()))
            obj["override"] = current.Override ?? current.Default;
        return obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n";
    }
}
