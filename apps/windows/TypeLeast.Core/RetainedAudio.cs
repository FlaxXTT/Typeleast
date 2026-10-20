using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

/// <summary>Only explicitly retained retry audio, sealed with current-user DPAPI, expires after 24h.</summary>
public sealed class RetainedAudio
{
    private readonly string directory;
    private readonly IHistoryProtection protection;
    public RetainedAudio(string directory, IHistoryProtection? protection = null)
    { this.directory = directory; this.protection = protection ?? new DpapiHistoryProtection(); }
    private string PathFor(string id)
    {
        if (!Regex.IsMatch(id, "^[a-f0-9]{32}$", RegexOptions.CultureInvariant)) throw new InvalidDataException("Invalid audio ID");
        return Path.Combine(directory, id + ".audio");
    }
    public void Save(string id, byte[] wav)
    {
        if (!Wav.IsCanonical(wav) || wav.Length > 44 + 120 * Wav.BytesPerSecond) throw new InvalidDataException("Invalid audio");
        Directory.CreateDirectory(directory);
        if (new DirectoryInfo(directory).Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UnauthorizedAccessException("Audio link rejected");
        var path = PathFor(id); var sealedAudio = protection.Protect(wav);
        File.WriteAllBytes(path + ".tmp", sealedAudio); File.Move(path + ".tmp", path, true);
    }
    public bool Available(string? id) => id is not null && File.Exists(PathFor(id)) && File.GetLastWriteTimeUtc(PathFor(id)) > DateTime.UtcNow.AddHours(-24);
    public byte[] Load(string id)
    {
        if (!Available(id)) throw new IOException("Audio expired or unavailable");
        var path = PathFor(id);
        if (new FileInfo(path).Length > 4_000_000 || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new InvalidDataException("Invalid retained file");
        var bytes = protection.Unprotect(File.ReadAllBytes(path));
        if (!Wav.IsCanonical(bytes)) { CryptographicOperations.ZeroMemory(bytes); throw new InvalidDataException("Invalid audio"); }
        return bytes;
    }
    public void Prune(IEnumerable<string> activeIds)
    {
        if (!Directory.Exists(directory)) return;
        if (new DirectoryInfo(directory).Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UnauthorizedAccessException("Audio link rejected");
        var active = activeIds.ToHashSet(StringComparer.Ordinal);
        foreach (var path in Directory.EnumerateFiles(directory, "*.audio"))
        {
            var id = Path.GetFileNameWithoutExtension(path);
            if (Regex.IsMatch(id, "^[a-f0-9]{32}$") && (!active.Contains(id) || File.GetLastWriteTimeUtc(path) <= DateTime.UtcNow.AddHours(-24))) File.Delete(path);
        }
    }
}
