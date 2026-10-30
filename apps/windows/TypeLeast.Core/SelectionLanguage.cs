namespace TypeLeast.Core;

/// <summary>Which language a selection is translated into (选中即翻译).</summary>
public static class SelectionLanguage
{
    /// <summary>翻译's target, except that text already in that language goes the other way:
    /// Chinese ⇄ the target (English when the target is Chinese).</summary>
    public static string Target(string text, string preferred)
    {
        int letters = 0, han = 0, latin = 0;
        foreach (var c in text)
        {
            if (!char.IsLetter(c)) continue;
            letters++;
            if (c is >= '\u3400' and <= '\u9FFF' or >= '\uF900' and <= '\uFAFF') han++;
            else if (c < 128) latin++;
        }
        var mostlyChinese = letters > 0 && han * 2 >= letters;
        if (preferred == "zh") return mostlyChinese ? "en" : "zh";
        var alreadyTarget = preferred == "en" && letters > 0 && latin * 2 > letters;
        return alreadyTarget ? "zh" : preferred;
    }
}
