using System.Text.Json;
using System.Security.Cryptography;

namespace TypeLeast.Core;

public sealed class HistoryEntry
{
    public string? Task { get; set; }
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public DateTimeOffset Time { get; set; } = DateTimeOffset.Now;
    public string Text { get; set; } = "";
    public string Raw { get; set; } = "";
    public string App { get; set; } = "";
    public bool Fallback { get; set; }
    public string? Reason { get; set; }
    public double Seconds { get; set; }
    public bool Inserted { get; set; }
    public HistoryRequest? Request { get; set; }
    public string? AudioId { get; set; }
    public PersonalizationTrace? Personalization { get; set; }
}

public sealed record HistoryRequest(string Language, string Strength, string? TranslateTo, string? Variants, string? ExplanationMarkers = null);

/// <summary>Recent dictations, protected at rest with DPAPI; migrates legacy JSON.</summary>
public sealed class LocalHistory
{
    public const int MaxEntries = 500;
    private readonly string path;
    public List<HistoryEntry> Entries { get; private set; } = new();

    private static readonly byte[] Marker = "TLH1\n"u8.ToArray();
    private readonly IHistoryProtection protection;
    private bool locked;
    public string? LastError { get; private set; }
    public long Revision { get; private set; }
    public string Retention { get; private set; } = "forever";
    private HistoryEntry? lastSession;

    public LocalHistory(string path, IHistoryProtection? protection = null)
    {
        this.path = path;
        this.protection = protection ?? new DpapiHistoryProtection();
        byte[]? plain = null;
        try {
            var stored = File.ReadAllBytes(path);
            var encrypted = stored.AsSpan().StartsWith(Marker);
            plain = encrypted ? this.protection.Unprotect(stored[Marker.Length..]) : stored;
            Entries = JsonSerializer.Deserialize<List<HistoryEntry>>(plain, Json.Options) ?? new();
            if (Entries.Any(e => e is null || e.Id is null || e.Text is null || e.Raw is null || e.App is null)) throw new JsonException("Invalid history entries");
            if (!encrypted) { Save(); if (LastError is not null) locked = true; }
        } catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) {
        } catch (Exception e) when (IsStorageError(e)) {
            Entries = new();
            locked = true;
            LastError = "history-unavailable";
        } finally { if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }

    private static bool IsStorageError(Exception e) => e is IOException or JsonException
        or UnauthorizedAccessException or CryptographicException or PlatformNotSupportedException;

    public HistoryEntry? Last => lastSession ?? Entries.FirstOrDefault();

    public void Add(HistoryEntry entry)
    {
        lastSession = entry;
        if (Retention == "never") return;
        Entries.Insert(0, entry);
        if (Entries.Count > MaxEntries) Entries.RemoveRange(MaxEntries, Entries.Count - MaxEntries);
        Save();
    }

    public void ApplyRetention(string retention, DateTimeOffset? now = null)
    {
        Retention = retention;
        var days = retention switch { "year" => 365, "month" => 30, "week" => 7, "day" => 1, "never" => 0, _ => -1 };
        if (days < 0) return;
        var cutoff = (now ?? DateTimeOffset.Now).AddDays(-days);
        if (Entries.RemoveAll(e => retention == "never" || e.Time < cutoff) > 0) Save();
    }

    public void Update(HistoryEntry entry)
    {
        var index = Entries.FindIndex(e => e.Id == entry.Id);
        if (index < 0) return;
        Entries[index] = entry; Save();
    }

    public void Remove(string id)
    {
        if (lastSession?.Id == id) lastSession = null;
        Entries.RemoveAll(e => e.Id == id);
        Save();
    }

    public void Clear()
    {
        try {
            File.Delete(path); // Only the explicit Delete All History action calls this.
            Entries.Clear(); lastSession = null; locked = false; LastError = null; Revision++;
        } catch (Exception e) when (IsStorageError(e)) { LastError = "history-unavailable"; }
    }

    /// <summary>Dictations and characters, for the home page.</summary>
    public (int Count, int Characters, double Seconds) Stats() =>
        (Entries.Count, Entries.Sum(e => ActivityLog.CountWords(e.Text)), Entries.Sum(e => e.Seconds));

    private void Save()
    {
        if (locked) { LastError = "history-unavailable"; return; }
        byte[]? plain = null;
        var temp = path + ".tmp";
        try {
            plain = JsonSerializer.SerializeToUtf8Bytes(Entries, Json.Options);
            var sealedData = protection.Protect(plain); // No plaintext fallback, including temporary files.
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            using (var file = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None)) {
                file.Write(Marker); file.Write(sealedData); file.Flush(true);
            }
            File.Move(temp, path, overwrite: true);
            LastError = null; Revision++;
        } catch (Exception e) when (IsStorageError(e)) { LastError = "history-unavailable"; }
        finally { if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
}
