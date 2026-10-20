using System.Net;
using System.Text;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

public static class FormattedText
{
    public static string? HtmlClipboard(string text)
    {
        var rows = text.Replace("\r\n", "\n").Split('\n');
        if (!rows.Any(row => Regex.IsMatch(row, @"^\s*\d+[.)、]\s*\S"))) return null;
        var fragment = new StringBuilder(); var list = false;
        foreach (var row in rows)
        {
            var match = Regex.Match(row, @"^\s*\d+[.)、]\s*(.+)$");
            if (match.Success)
            {
                if (!list) { fragment.Append("<ol>"); list = true; }
                fragment.Append("<li>").Append(WebUtility.HtmlEncode(match.Groups[1].Value)).Append("</li>");
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
