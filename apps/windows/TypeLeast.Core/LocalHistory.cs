using System.Text.Json;

namespace TypeLeast.Core;

public sealed class HistoryEntry
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public DateTimeOffset Time { get; set; } = DateTimeOffset.Now;
    public string Text { get; set; } = "";
    public string Raw { get; set; } = "";
    public string App { get; set; } = "";
    public bool Fallback { get; set; }
    public string? Reason { get; set; }
    public double Seconds { get; set; }
    public bool Inserted { get; set; }
}

/// <summary>The app's recent dictations, newest first, in app-history.json.</summary>
public sealed class LocalHistory
{
    public const int MaxEntries = 500;
    private readonly string path;
    public List<HistoryEntry> Entries { get; private set; } = new();

    public LocalHistory(string path)
    {
        this.path = path;
        try
        {
            Entries = JsonSerializer.Deserialize<List<HistoryEntry>>(File.ReadAllText(path), Json.Options) ?? new();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            Entries = new();
        }
    }

    public HistoryEntry? Last => Entries.Count > 0 ? Entries[0] : null;

    public void Add(HistoryEntry entry)
    {
        Entries.Insert(0, entry);
        if (Entries.Count > MaxEntries) Entries.RemoveRange(MaxEntries, Entries.Count - MaxEntries);
        Save();
    }

    public void Remove(string id)
    {
        Entries.RemoveAll(e => e.Id == id);
        Save();
    }

    public void Clear()
    {
        Entries.Clear();
        Save();
    }

    /// <summary>Dictations and characters, for the home page.</summary>
    public (int Count, int Characters, double Seconds) Stats() =>
        (Entries.Count, Entries.Sum(e => e.Text.Length), Entries.Sum(e => e.Seconds));

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Entries, Json.Options));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
