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
    [System.Text.Json.Serialization.JsonIgnore] public string? ReplacementHeard => HeardAs.Length>0?HeardAs:LocalOnly&&Word.ToLowerInvariant()!=Word?Word.ToLowerInvariant():null;
    [System.Text.Json.Serialization.JsonIgnore] public string ApprovalKey => Id+"|"+(ReplacementHeard??"")+"="+Word;
    public string RequestValue => Source == "auto" ? Word : ServiceValue;
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
