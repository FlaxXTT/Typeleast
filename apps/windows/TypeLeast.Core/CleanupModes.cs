namespace TypeLeast.Core;

/// <summary>The four cleanup modes (整理档位) in the order the app shows them. "prompt" is the
/// historical id of 自然整理 and stays the stored value.</summary>
public static class CleanupModes
{
    public static readonly string[] Codes = { "prompt", "promptify", "promptbeta", "off" };

    public static bool IsKnown(string? code) => code is not null && Array.IndexOf(Codes, code) >= 0;

    public static string Title(string code) => code switch
    {
        "promptify" => L10n.T("提示词模式"),
        "promptbeta" => L10n.T("提示词 Beta"),
        "off" => L10n.T("原话转写"),
        _ => L10n.T("自然整理"),
    };

    public static string Detail(string code) => code switch
    {
        "promptify" => L10n.T("改写成结构化提示词，可直接发给 AI。"),
        "promptbeta" => L10n.T("先问几个关键问题，再起草和审查提示词；较慢。"),
        "off" => L10n.T("不调用整理模型，只去掉口水词。"),
        _ => L10n.T("去掉口水词、改通顺，适合日常输入。"),
    };
}
