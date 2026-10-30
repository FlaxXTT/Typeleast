using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

public static class FormattedText
{
    private static readonly System.Text.RegularExpressions.Regex ListStart =
        new(@"^\s*(\d{1,3}[.、．)）](?!\d)|[-*•]\s)\s*\S", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    /// <summary>A numbered or bulleted list starts on its own line: when the cursor follows other text on
    /// the same line (or what precedes it could not be read), a line break goes first.</summary>
    public static string SeparatingList(string text, string? before)
    {
        if (!ListStart.IsMatch(text)) return text;
        if (before is not null && before.Split('\n')[^1].Trim(' ', '\t', '\r').Length == 0) return text;
        return "\n" + text;
    }

    public static string? HtmlClipboard(string text)
    {
        var rows = text.Replace("\r\n", "\n").Split('\n');
        if (!rows.Any(row => Regex.IsMatch(row, @"^\s*\d+[.)、]\s*\S"))) return null;
        var fragment = new StringBuilder(); var list = false;
        foreach (var row in rows)
        {
            var match = Regex.Match(row, @"^\s*(?<number>\d{1,9})[.)、]\s*(?<body>.+)$");
            if (match.Success)
            {
                if (!list) { fragment.Append("<ol>"); list = true; }
                fragment.Append("<li value=\"").Append(match.Groups["number"].Value).Append("\">").Append(WebUtility.HtmlEncode(match.Groups["body"].Value)).Append("</li>");
            }
            else { if (list) { fragment.Append("</ol>"); list = false; } fragment.Append("<p>").Append(WebUtility.HtmlEncode(row)).Append("</p>"); }
        }
        if (list) fragment.Append("</ol>");
        const string before = "<html><body><!--StartFragment-->";
        const string after = "<!--EndFragment--></body></html>";
        const string template = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
        var start = Encoding.UTF8.GetByteCount(string.Format(template, 0, 0, 0, 0));
        var fragmentStart = start + Encoding.UTF8.GetByteCount(before);
        var fragmentEnd = fragmentStart + Encoding.UTF8.GetByteCount(fragment.ToString());
        var end = fragmentEnd + Encoding.UTF8.GetByteCount(after);
        return string.Format(System.Globalization.CultureInfo.InvariantCulture, template, start, end, fragmentStart, fragmentEnd) + before + fragment + after;
    }
}
