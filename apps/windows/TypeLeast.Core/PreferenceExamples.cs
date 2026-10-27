using System.Text.Json.Serialization;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;

namespace TypeLeast.Core;

public sealed class PreferenceExample
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string HistoryId { get; set; } = "";
    public string Raw { get; set; } = "";
    public string AiText { get; set; } = "";
    public string CorrectedText { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public bool Confirmed { get; set; }
    public bool Enabled { get; set; } = true;
    [JsonIgnore] public bool Valid => !string.IsNullOrEmpty(Id) && Id.Length <= 64 && !string.IsNullOrEmpty(HistoryId) && new[] { Raw, AiText, CorrectedText }.All(s => !string.IsNullOrWhiteSpace(s) && s.Length <= 4000) && AiText != CorrectedText;
    [JsonIgnore] public object Wire => new { id = Id, raw = Raw, aiText = AiText, correctedText = CorrectedText, confirmed = Confirmed, enabled = Enabled };
}

/// <summary>Only explicitly confirmed examples reach encrypted storage and the model request.</summary>
public sealed class PersonalizationArchive {
    public int FormatVersion { get; set; } = 3;
    public List<PreferenceExample> Entries { get; set; } = new();
    public List<string> Excluded { get; set; } = new();
    public Dictionary<string,bool> WordStates { get; set; } = new();
    public Dictionary<string,bool> RuleStates { get; set; } = new();
}
public sealed class PreferenceExamples
{
    private readonly string path;
    private readonly IHistoryProtection protection;
    private bool locked;
    public List<PreferenceExample> Entries { get; private set; } = new();
    public List<string> Excluded { get; private set; } = new();
    public Dictionary<string,bool> WordStates { get; private set; } = new();
    public Dictionary<string,bool> RuleStates { get; private set; } = new();
    public List<PreferenceExample> Pending { get; } = new();
    public string? Problem { get; private set; }
    public long Revision { get; private set; }
    public event Action? Changed;
    public bool VocabularyRemovalComplete { get; private set; }
    public PreferenceExamples(string path, IHistoryProtection? protection = null)
    {
        this.path = path; this.protection = protection ?? new DpapiHistoryProtection();
        byte[]? plain = null;
        try {
            plain = this.protection.Unprotect(File.ReadAllBytes(path));
            using var document=JsonDocument.Parse(plain);
            var archive=document.RootElement.ValueKind==JsonValueKind.Array
                ? new PersonalizationArchive {Entries=JsonSerializer.Deserialize<List<PreferenceExample>>(plain,Json.Options)!}
                : JsonSerializer.Deserialize<PersonalizationArchive>(plain,Json.Options);
            if(archive?.Entries is null || (archive.FormatVersion!=2&&archive.FormatVersion!=3) || archive.Excluded is null || archive.WordStates is null || archive.RuleStates is null || archive.Entries.Count>100 || archive.Entries.Any(x=>x is null || !x.Valid || !x.Confirmed) || archive.Excluded.Count>512 || archive.Excluded.Any(x=>x is null || x.Length>120 || x.Any(char.IsControl)) || archive.WordStates.Count>2000 || archive.RuleStates.Count>2000)throw new JsonException();
            Entries=archive.Entries;
            VocabularyRemovalComplete=(archive.FormatVersion==3&&archive.Excluded.Count==0&&archive.WordStates.Count==0&&archive.RuleStates.Count==0)||Save(Entries);
        } catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { VocabularyRemovalComplete=true; }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or CryptographicException or PlatformNotSupportedException) { locked = true; Problem = "preferences-unavailable"; }
        finally { if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
    public void Prepare(string historyId, string raw, string aiText)
    {
        if (string.IsNullOrWhiteSpace(raw) || string.IsNullOrWhiteSpace(aiText) || raw.Length > 4000 || aiText.Length > 4000) { Problem = "preferences-limit"; return; }
        Pending.RemoveAll(x => x.HistoryId == historyId);
        Pending.Insert(0, new PreferenceExample { HistoryId=historyId, Raw=raw, AiText=aiText, CorrectedText=aiText });
        if (Pending.Count > 5) Pending.RemoveRange(5, Pending.Count-5);
        Revision++; Changed?.Invoke();
    }
    public void Offer(string historyId, string raw, string aiText, string corrected)
    {
        var item = new PreferenceExample { HistoryId = historyId, Raw = raw, AiText = aiText, CorrectedText = corrected };
        if (!item.Valid || Entries.Any(x => x.HistoryId == historyId && x.CorrectedText == corrected)) return;
        Pending.RemoveAll(x => x.HistoryId == historyId); Pending.Insert(0, item);
        if (Pending.Count > 5) Pending.RemoveRange(5, Pending.Count - 5);
        Revision++; Changed?.Invoke();
    }
    public bool Confirm(PreferenceExample item)
    {
        if (!item.Valid || (Entries.Count >= 100 && !Entries.Any(x=>x.Id==item.Id))) { Problem = "preferences-limit"; return false; }
        // Do not mark a pending observation as confirmed when persistence fails.
        var copy = new PreferenceExample { Id = item.Id, HistoryId = item.HistoryId, Raw = item.Raw, AiText = item.AiText,
            CorrectedText = item.CorrectedText, CreatedAt = item.CreatedAt, Confirmed = true, Enabled = item.Enabled };
        if (!Save(new[] { copy }.Concat(Entries.Where(x => x.Id != copy.Id)).ToList())) return false;
        Pending.RemoveAll(x => x.Id == item.Id || x.HistoryId == item.HistoryId); Changed?.Invoke(); return true;
    }
    public void ClearPending() { Pending.Clear(); Revision++; Changed?.Invoke(); }
    public void Dismiss(string id) { Pending.RemoveAll(x => x.Id == id); Revision++; Changed?.Invoke(); }
    public bool SetEnabled(string id, bool enabled)
    {
        var next = Entries.Select(x => new PreferenceExample { Id=x.Id, HistoryId=x.HistoryId, Raw=x.Raw, AiText=x.AiText,
            CorrectedText=x.CorrectedText, CreatedAt=x.CreatedAt, Confirmed=x.Confirmed, Enabled=x.Id==id?enabled:x.Enabled }).ToList();
        return Save(next);
    }
    public bool Remove(string id) => Save(Entries.Where(x => x.Id != id).ToList());
    public object[] WireExamples => Entries.Where(x => x.Confirmed && x.Enabled).Take(20).Select(x => x.Wire).ToArray();
    public object WirePolicy(IEnumerable<WordEntry>? words=null,bool disabled=false) => new {version=1,disabled};
    private bool Save(List<PreferenceExample> next)
    {
        if(Excluded.Count>512||WordStates.Count>2000||RuleStates.Count>2000){Problem="preferences-limit";return false;}
        if (locked) { Problem = "preferences-unavailable"; return false; }
        byte[]? plain = null;
        try {
            plain = JsonSerializer.SerializeToUtf8Bytes(new PersonalizationArchive {Entries=next,Excluded=Excluded,WordStates=WordStates,RuleStates=RuleStates}, Json.Options);
            var sealedData = protection.Protect(plain);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            File.WriteAllBytes(path + ".tmp", sealedData); File.Move(path + ".tmp", path, true);
            Entries = next; Problem = null; Revision++; Changed?.Invoke(); return true;
        } catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException or PlatformNotSupportedException) { Problem = "preferences-unavailable"; return false; }
        finally { if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
}
