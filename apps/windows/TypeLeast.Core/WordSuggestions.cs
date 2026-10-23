namespace TypeLeast.Core;

/// <summary>A term the cleanup model corrected, offered on the Dictionary page until added or ignored.</summary>
public sealed class WordSuggestion
{
    public string Word { get; set; } = "";
    public string HeardAs { get; set; } = "";
    public int Count { get; set; }
    public DateTime LastSeen { get; set; }
}

/// <summary>
/// Dictionary suggestions from what the cleanup model changed: the recognised words and the cleaned
/// text are compared word by word; a replaced span that became a latin term ("德普西克" → "DeepSeek",
/// "deep seek" → "DeepSeek") is a candidate. This works in every app, also where the field cannot be
/// read. Chinese cannot be compared by sound here, so a latin span must look like the same word, and
/// nothing is added until the user chooses to.
/// </summary>
public static class WordSuggestions
{
    public const int Limit = 30;

    /// <summary>Latin words (with . + # - _ inside) and single CJK characters; everything else separates.</summary>
    public static List<string> Tokens(string text)
    {
        var tokens = new List<string>();
        var word = new System.Text.StringBuilder();
        void Flush() { if (word.Length > 0) { tokens.Add(word.ToString().Trim('.', '_', '+', '#', '-')); word.Clear(); } }
        foreach (var c in text)
        {
            if (char.IsAsciiLetterOrDigit(c)) word.Append(c);
            else if (word.Length > 0 && "._+#-".Contains(c)) word.Append(c);
            else if (IsCjk(c)) { Flush(); tokens.Add(c.ToString()); }
            else Flush();
        }
        Flush();
        return tokens.Where(t => t.Length > 0).ToList();
    }

    public static string Join(IEnumerable<string> tokens)
    {
        var text = new System.Text.StringBuilder();
        foreach (var t in tokens)
        {
            if (text.Length > 0 && char.IsAsciiLetterOrDigit(text[^1]) && t.Length > 0 && t[0] < 128) text.Append(' ');
            text.Append(t);
        }
        return text.ToString();
    }

    /// <summary>(heard, word) pairs the model corrected into a latin term.</summary>
    public static List<(string Heard, string Word)> Candidates(string raw, string cleaned)
    {
        var a = Tokens(raw).Take(400).ToList();
        var b = Tokens(cleaned).Take(400).ToList();
        var result = new List<(string, string)>();
        if (a.Count == 0 || b.Count == 0) return result;
        var table = new int[a.Count + 1, b.Count + 1];
        for (var i = a.Count - 1; i >= 0; i--)
            for (var j = b.Count - 1; j >= 0; j--)
                table[i, j] = a[i] == b[j] ? table[i + 1, j + 1] + 1 : Math.Max(table[i + 1, j], table[i, j + 1]);
        var runA = new List<string>();
        var runB = new List<string>();
        void Close()
        {
            if (runA.Count > 0 && runB.Count > 0)
            {
                var heard = Join(runA);
                var word = Join(runB);
                var caseOnly = runA.Count == runB.Count && string.Concat(runA).Equals(string.Concat(runB), StringComparison.OrdinalIgnoreCase);
                var latinHeard = !heard.Any(IsCjk);
                if (word.Any(char.IsAsciiLetter) && !word.Any(IsCjk) && word.Length is >= 2 and <= 30 && heard.Length <= 30 && !caseOnly
                    && (!latinHeard || EditCorrection.Similarity(heard.Replace(" ", "").ToLowerInvariant(), word.Replace(" ", "").ToLowerInvariant()) >= 0.6))
                    result.Add((heard, word));
            }
            runA.Clear(); runB.Clear();
        }
        int x = 0, y = 0;
        while (x < a.Count || y < b.Count)
        {
            if (x < a.Count && y < b.Count && a[x] == b[y]) { Close(); x++; y++; }
            else if (y < b.Count && (x == a.Count || table[x, y + 1] >= table[x + 1, y])) runB.Add(b[y++]);
            else runA.Add(a[x++]);
        }
        Close();
        return result;
    }

    /// <summary>Add one sighting: words already in the dictionary or ignored are left out; the newest first.</summary>
    public static List<WordSuggestion> Merge(IEnumerable<WordSuggestion> list, string word, string heardAs, DateTime now,
        ISet<string> known, ISet<string> dismissed)
    {
        var key = word.ToLowerInvariant();
        var output = list.ToList();
        if (known.Contains(key) || dismissed.Contains(key)) return output;
        var index = output.FindIndex(s => s.Word.Equals(word, StringComparison.OrdinalIgnoreCase));
        if (index >= 0)
        {
            var seen = output[index];
            output.RemoveAt(index);
            seen.Count++; seen.LastSeen = now;
            output.Insert(0, seen);
        }
        else output.Insert(0, new WordSuggestion { Word = word, HeardAs = heardAs, Count = 1, LastSeen = now });
        return output.Take(Limit).ToList();
    }

    private static bool IsCjk(char c) => c is >= '㐀' and <= '鿿' or >= '豈' and <= '﫿';
}
