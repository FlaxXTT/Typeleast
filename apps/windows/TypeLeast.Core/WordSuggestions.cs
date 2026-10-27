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

}
