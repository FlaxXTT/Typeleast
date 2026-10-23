namespace TypeLeast.Core;

/// <summary>The four cleanup modes (整理档位) in the order the app shows them. "prompt" is the
/// historical id of 自然整理 and stays the stored value.</summary>
public static class CleanupModes
{
    public static readonly string[] Codes = { "prompt", "promptbrief", "promptify", "promptbeta", "off" };

    public static bool IsKnown(string? code) => code is not null && Array.IndexOf(Codes, code) >= 0;

    public static string Title(string code) => code switch
    {
        "promptbrief" => L10n.T("提示词 · 普通"),
        "promptify" => L10n.T("提示词 · 标准格式"),
        "promptbeta" => L10n.T("提示词 Beta"),
        "off" => L10n.T("原话转写"),
        _ => L10n.T("自然整理"),
    };

    public static string Detail(string code) => code switch
    {
        "promptbrief" => L10n.T("积极压缩口语，保留核心意图和约束，简洁、直白、易读。"),
        "promptify" => L10n.T("一次整理核心意图，用自然段和编号表达，不套角色等模板。"),
        "promptbeta" => L10n.T("多轮补充背景、目标和期望，由你决定何时生成；用量随轮次增加。"),
        "off" => L10n.T("不调用整理模型，只去掉口水词。"),
        _ => L10n.T("去掉口水词、改通顺，适合日常输入。"),
    };
}
