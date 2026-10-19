using System.Text.Json;
using System.Security.Cryptography;

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
            if (!encrypted) Save(); // Replace legacy plaintext only after protection succeeds.
        } catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) {
        } catch (Exception e) when (IsStorageError(e)) {
            locked = true;
            LastError = "history-unavailable";
        } finally { if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }

    private static bool IsStorageError(Exception e) => e is IOException or JsonException
        or UnauthorizedAccessException or CryptographicException or PlatformNotSupportedException;

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
        try {
            File.Delete(path); // Only the explicit Delete All History action calls this.
            Entries.Clear(); locked = false; LastError = null;
        } catch (Exception e) when (IsStorageError(e)) { LastError = "history-unavailable"; }
    }

    /// <summary>Dictations and characters, for the home page.</summary>
    public (int Count, int Characters, double Seconds) Stats() =>
        (Entries.Count, Entries.Sum(e => e.Text.Length), Entries.Sum(e => e.Seconds));

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
            LastError = null;
        } catch (Exception e) when (IsStorageError(e)) { LastError = "history-unavailable"; }
        finally { if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
    }
}
