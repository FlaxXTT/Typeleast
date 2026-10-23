namespace TypeLeast.Core;

/// <summary>The cleanup modes (整理档位) in the order the app shows them. Natural cleanup has two
/// tiers: 标准 ("prompt", its historical id and stored value) and 精简 ("concise").</summary>
public static class CleanupModes
{
    public static readonly string[] Codes = { "prompt", "concise", "promptbeta", "off" };

    public static bool IsKnown(string? code) => code is not null && Array.IndexOf(Codes, code) >= 0;

    /// <summary>The mode a stored value means: the prompt-mode tiers of 1.18 became 精简整理, and
    /// anything else unknown is 标准整理.</summary>
    public static string Stored(string? code) => code is "promptbrief" or "promptify" ? "concise" : IsKnown(code) ? code! : "prompt";

    public static string Title(string code) => code switch
    {
        "concise" => L10n.T("精简整理"),
        "promptbeta" => L10n.T("提示词 Beta"),
        "off" => L10n.T("原话转写"),
        _ => L10n.T("标准整理"),
    };

    public static string Detail(string code) => code switch
    {
        "concise" => L10n.T("更短，只留要点"),
        "promptbeta" => L10n.T("多轮补充后写成提示词"),
        "off" => L10n.T("不用模型，只去口头禅"),
        _ => L10n.T("去口头禅，改通顺"),
    };
}
