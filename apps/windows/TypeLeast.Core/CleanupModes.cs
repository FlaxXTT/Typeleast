namespace TypeLeast.Core;

/// <summary>The cleanup modes in display order. "prompt" remains the stored id for 自然整理.</summary>
public static class CleanupModes
{
    public static readonly string[] Codes = { "concise", "prompt", "promptbeta" };

    public static bool IsKnown(string? code) => code is not null && Array.IndexOf(Codes, code) >= 0;

    /// <summary>The mode a stored value means: the prompt-mode tiers of 1.18 became AI 整理, and
    /// retired verbatim and unknown values become 自然整理.</summary>
    public static string Stored(string? code) => code is "promptbrief" or "promptify" ? "concise" : IsKnown(code) ? code! : "prompt";

    public static string Title(string code) => code switch
    {
        "concise" => L10n.T("AI 整理"),
        "promptbeta" => L10n.T("提示词 Beta"),
        _ => L10n.T("自然整理"),
    };
}
