namespace TypeLeast.Core;

/// <summary>A saved candidate from older versions, migrated to automatic learning.</summary>
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

    public static bool ValidCandidate(string? word, string? heardAs) =>
        word is not null && heardAs is not null && word.Length is >= 2 and <= 30 && heardAs.Length is >= 1 and <= 30 &&
        !(word + heardAs).Any(char.IsControl) && !word.Contains('=') && !heardAs.Contains('=') &&
        !string.IsNullOrWhiteSpace(word) && !string.IsNullOrWhiteSpace(heardAs);

    /// <summary>Use only service-filtered pairs. Never replace a user's spelling or revive a deleted word.</summary>
    public static bool ApplyAutomatic(AppSettings settings, IEnumerable<SuggestionCandidate> candidates)
    {
        if (!settings.LearnCorrections) return false;
        var known = settings.DictionaryEntries.Select(e => e.Word).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var dismissed = settings.DismissedSuggestions.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var pending = settings.WordSuggestions.Take(Limit).Where(s => s is not null).Select(s => new SuggestionCandidate(s.Word, s.HeardAs))
            .Concat(candidates.Take(8)).ToList();
        var changed = settings.WordSuggestions.Count > 0;
        foreach (var candidate in pending)
        {
            if (!ValidCandidate(candidate.Word, candidate.HeardAs)) continue;
            if (WordEntry.Parse(candidate.Word, candidate.HeardAs, "auto") is not { } entry ||
                dismissed.Contains(entry.Word) || !known.Add(entry.Word)) continue;
            settings.DictionaryEntries.Add(entry);
            changed = true;
        }
        settings.WordSuggestions = new();
        return changed;
    }

    public static void RememberDeletion(AppSettings settings, IEnumerable<WordEntry> removed) =>
        settings.DismissedSuggestions = settings.DismissedSuggestions.Concat(removed.Select(e => e.Word.ToLowerInvariant()))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();

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
