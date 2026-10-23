using System.Text.RegularExpressions;

namespace TypeLeast.Core;

/// <summary>Release notes are bounded plain text. Never render or execute remote markup.</summary>
public static class ReleaseSummary
{
    public static string Text(string markdown, string? language = null)
    {
        var source = markdown[..Math.Min(64000, markdown.Length)];
        var languages = (language ?? L10n.Language).StartsWith("en", StringComparison.OrdinalIgnoreCase) ? new[] { "en", "zh" } : new[] { "zh", "en" };
        var selected = source;
        foreach (var lang in languages)
        {
            var marker = "<!-- typeleast-update:" + lang + " -->";
            var start = source.IndexOf(marker, StringComparison.Ordinal);
            if (start < 0) continue;
            start += marker.Length;
            var end = source.IndexOf("<!-- /typeleast-update -->", start, StringComparison.Ordinal);
            if (end < 0) continue;
            selected = source[start..end]; break;
        }
        var lines = selected.Split('\n').Select(s => s.Trim()).ToArray();
        var bullets = lines.Where(s => s.StartsWith("- ") || s.StartsWith("* ")).Select(s => s[2..]).ToArray();
        var chosen = bullets.Length > 0 ? bullets : lines.Where(s => s.Length > 0 && !s.StartsWith('#') && !s.StartsWith('|') && !s.StartsWith('<'));
        return string.Join("\n", chosen.Take(4).Select(line => {
            var plain = Regex.Replace(line, @"\[([^]]+)\]\([^)]*\)", "$1");
            plain = Regex.Replace(plain, "<[^>]*>", "");
            plain = Regex.Replace(plain, "[*`]", "");
            plain = new string(plain.Where(c => !char.IsControl(c)).ToArray());
            return "• " + plain[..Math.Min(140, plain.Length)];
        }));
    }
}
