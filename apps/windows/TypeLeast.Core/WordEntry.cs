using System.Text;

namespace TypeLeast.Core;

public sealed class WordEntry
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Word { get; set; } = "";
    public string HeardAs { get; set; } = "";
    public string Source { get; set; } = "manual";
    /// <summary>「不发给模型」: never put into a model request; a heard-as spelling is fixed on this computer.</summary>
    public bool LocalOnly { get; set; }
    public string ServiceValue => HeardAs.Length == 0 ? Word : HeardAs + "=" + Word;
    public static WordEntry? Parse(string word, string heardAs = "", string source = "manual")
    {
        word = word.Trim(); heardAs = heardAs.Trim();
        if (word.Length == 0 || word.Length + heardAs.Length + (heardAs.Length > 0 ? 1 : 0) > 120 || (word + heardAs).Any(char.IsControl) || word.Contains('=') || heardAs.Contains('=')) return null;
        return new() { Word = word, HeardAs = heardAs == word ? "" : heardAs, Source = source == "auto" ? "auto" : "manual" };
    }
    public static WordEntry? FromLegacy(string value)
    {
        var parts = value.Split('=', 2);
        return parts.Length == 2 ? Parse(parts[1], parts[0]) : Parse(value);
    }
}

public sealed record WordImport(IReadOnlyList<WordEntry> Valid, int Duplicates, IReadOnlyList<int> InvalidLines)
{
    public static WordImport Preview(string csv, IEnumerable<WordEntry> existing)
    {
        if (csv.Length > 2 * 1024 * 1024) throw new InvalidDataException("CSV exceeds 2 MiB");
        var known = existing.Select(x => x.ServiceValue).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var valid = new List<WordEntry>(); var invalid = new List<int>(); var duplicates = 0;
        var lineNumber = 0;
        foreach (var line in csv.Replace("\r\n", "\n").Split('\n'))
        {
            lineNumber++;
            if (string.IsNullOrWhiteSpace(line)) continue;
            var cells = Cells(line);
            if (lineNumber == 1 && cells is { Count: > 0 } && cells[0].Trim('\uFEFF').ToLowerInvariant() is "word" or "正确写法") continue;
            var entry = cells is { Count: >= 1 and <= 2 } ? WordEntry.Parse(cells[0], cells.Count == 2 ? cells[1] : "") : null;
            if (entry is null) { invalid.Add(lineNumber); continue; }
            if (!known.Add(entry.ServiceValue)) { duplicates++; continue; }
            valid.Add(entry);
        }
        return new(valid, duplicates, invalid);
    }
    private static List<string>? Cells(string line)
    {
        var cells = new List<string>(); var text = new StringBuilder(); var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (c == '"')
            {
                if (quoted && i + 1 < line.Length && line[i + 1] == '"') { text.Append('"'); i++; }
                else quoted = !quoted;
            }
            else if (c == ',' && !quoted) { cells.Add(text.ToString()); text.Clear(); }
            else text.Append(c);
        }
        if (quoted) return null;
        cells.Add(text.ToString()); return cells;
    }
}
