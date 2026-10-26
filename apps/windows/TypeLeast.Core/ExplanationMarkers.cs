namespace TypeLeast.Core;

public static class ExplanationMarkers
{
    public static readonly string[] Ids = { "note", "background", "explanation", "aside" };
    public static readonly string[] VisibleIds = { "note" };
    public static (string Start, string End) Words(string id, bool english = false) => (id, english) switch {
        ("note", false) => ("备注", "说完了"),
        ("note", true) => ("side note", "back to text"),
        ("background", false) => ("补充背景开始", "补充背景结束"),
        ("explanation", false) => ("解释内容开始", "解释内容结束"),
        ("aside", false) => ("旁注开始", "旁注结束"),
        ("background", true) => ("context note begins", "context note ends"),
        ("explanation", true) => ("explanation begins", "explanation ends"),
        ("aside", true) => ("aside begins", "aside ends"),
        _ => ("", ""),
    };
    public static string Label(string id) {
        var words = Words(id, L10n.Culture.TwoLetterISOLanguageName == "en");
        return L10n.T("开始：{0}；结束：{1}", words.Start, words.End);
    }
}
