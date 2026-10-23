namespace TypeLeast.Core;

/// <summary>A term the cleanup model corrected, offered on the Dictionary page until added or ignored.</summary>
public sealed class WordSuggestion
{
    public string Word { get; set; } = "";
    public string HeardAs { get; set; } = "";
    public int Count { get; set; }
    public DateTime LastSeen { get; set; }
}

/// <summary>Local storage merging. Candidate detection and pronunciation live only in the service.</summary>
public static class WordSuggestions
{
    public const int Limit = 30;

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
            output.Insert(0, new WordSuggestion { Word = seen.Word, HeardAs = seen.HeardAs, Count = seen.Count + 1, LastSeen = now });
        }
        else output.Insert(0, new WordSuggestion { Word = word, HeardAs = heardAs, Count = 1, LastSeen = now });
        return output.Take(Limit).ToList();
    }

}
