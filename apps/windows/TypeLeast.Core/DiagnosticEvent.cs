using System.Globalization;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

/// <summary>Allowlisted numeric diagnostics. Never accepts exception messages or payloads.</summary>
public sealed record DiagnosticEvent(string Operation, string Stage, string? Reason = null,
    double? ElapsedMs = null, int? HttpStatus = null, int? Characters = null)
{
    public static string SafeReason(string? value)
    {
        if (value is null or "") return "ok";
        if (value is "no-api-key" or "model-timeout" or "model-max-tokens" or "output-format"
            or "cancelled" or "strength-off" or "empty-transcript" or "internal-error"
            or "speech-not-ready" or "too-long" or "too-short" or "invented-numbers"
            or "new-numbers" or "length-ratio" or "empty-output" or "NETWORK") return value;
        if (Regex.IsMatch(value, @"^(model-error:)?HTTP_[1-5][0-9]{2}$", RegexOptions.CultureInvariant)) return value;
        return "other";
    }

    public string Format()
    {
        var op = Operation is "dictation" or "translation" or "beta" or "connection-test" ? Operation : "other";
        var stage = Stage is "complete" or "transport" or "cancelled" ? Stage : "other";
        var elapsed = ElapsedMs is >= 0 and <= 86_400_000 ? ElapsedMs.Value.ToString("F0", CultureInfo.InvariantCulture) : "unknown";
        var status = HttpStatus is >= 100 and <= 599 ? HttpStatus.Value.ToString(CultureInfo.InvariantCulture) : "unknown";
        var chars = Characters is >= 0 and <= 10_000_000 ? Characters.Value.ToString(CultureInfo.InvariantCulture) : "unknown";
        return $"operation={op} stage={stage} reason={SafeReason(Reason)} elapsedMs={elapsed} http={status} characters={chars}";
    }
}
