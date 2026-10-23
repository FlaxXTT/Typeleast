using System.Text.Json;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

// WindowsRelease.cs - finds the newest release that ships a Windows installer.
// Mac and Windows publish separately: GitHub's single "latest" flag belongs to the
// Mac releases (the Mac updater reads it), so Windows reads the release list and
// takes the version from its own asset name, not from the tag.
public sealed record WindowsReleaseInfo(string Version, string Tag, string PageUrl,
    string SetupName = "", string? SetupUrl = null, string? SumsUrl = null);

public static class WindowsRelease
{
    public const string ListUrl = "https://api.github.com/repos/FlaxXTT/Typeleast/releases?per_page=30";
    /// Downloads are taken only from this repository's own release files.
    public const string DownloadPrefix = "https://github.com/FlaxXTT/Typeleast/releases/download/";

    private static readonly Regex SetupAsset = new(@"^TypeLeast-(\d+(?:\.\d+){1,3})-Windows-x64-Setup\.exe$", RegexOptions.CultureInvariant);

    /// The newest published (not draft, not pre-release) release with a Windows Setup.exe, or null.
    public static WindowsReleaseInfo? Newest(string releasesJson)
    {
        using var document = JsonDocument.Parse(releasesJson);
        if (document.RootElement.ValueKind != JsonValueKind.Array) return null;
        WindowsReleaseInfo? best = null;
        foreach (var release in document.RootElement.EnumerateArray())
        {
            if (Bool(release, "draft") || Bool(release, "prerelease")) continue;
            if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) continue;
            string? sums = null;
            foreach (var asset in assets.EnumerateArray())
            {
                var name = Text(asset, "name");
                // A Windows-only list wins over the combined one when a release has both.
                if (name == "SHA256SUMS-Windows.txt" || (name == "SHA256SUMS.txt" && sums is null)) sums = DownloadUrl(asset);
            }
            foreach (var asset in assets.EnumerateArray())
            {
                var name = Text(asset, "name");
                var match = SetupAsset.Match(name);
                if (!match.Success) continue;
                var version = match.Groups[1].Value;
                if (best is null || IsNewer(version, best.Version))
                    best = new WindowsReleaseInfo(version, Text(release, "tag_name"), Text(release, "html_url"), name, DownloadUrl(asset), sums);
            }
        }
        return best;
    }

    /// Numeric, component by component: 1.10.0 is newer than 1.9.3; 1.3 equals 1.3.0.
    public static bool IsNewer(string remote, string local)
    {
        static int[] Parts(string v) => v.Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var x) ? x : 0).ToArray();
        var a = Parts(remote);
        var b = Parts(local);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    /// The hash recorded for `name` in a sha256sum-style list ("<hex>  <name>" or "<hex> *<name>").
    public static string? Checksum(string name, string sums)
    {
        foreach (var line in sums.Split('\n'))
        {
            var fields = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length < 2) continue;
            var file = fields[^1].TrimStart('*');
            if (file == name && Regex.IsMatch(fields[0], "^[0-9a-fA-F]{64}$")) return fields[0].ToLowerInvariant();
        }
        return null;
    }

    /// True for the copy the installer put in %LOCALAPPDATA%\Programs\TypeLeast (it can be
    /// updated in place); a portable copy is updated by downloading it again.
    public static bool IsInstalledCopy(string appDir, string localAppData, Func<string, bool> exists)
    {
        var installed = Path.Combine(localAppData, "Programs", "TypeLeast");
        return string.Equals(Path.GetFullPath(appDir).TrimEnd('\\', '/'), Path.GetFullPath(installed).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase)
            && exists(Path.Combine(installed, "unins000.exe"));
    }

    private static string? DownloadUrl(JsonElement asset)
    {
        var url = asset.TryGetProperty("browser_download_url", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null;
        return url is not null && url.StartsWith(DownloadPrefix, StringComparison.Ordinal) && url.Length < 400 ? url : null;
    }

    private static bool Bool(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static string Text(JsonElement e, string name)
    {
        var s = e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        return s.Length <= 200 ? s : "";
    }
}

/// <summary>Where an in-app update is, for the progress window.</summary>
public enum UpdateStage { Downloading, Verifying, Installing }

public static class UpdateProgressText
{
    public static string Describe(UpdateStage stage, long received = 0, long? total = null) => stage switch
    {
        UpdateStage.Downloading when total is > 0 => L10n.T("正在下载 {0} / {1} MB", Mb(received), Mb(total.Value)),
        UpdateStage.Downloading => L10n.T("正在下载 {0} MB", Mb(received)),
        UpdateStage.Verifying => L10n.T("正在核对校验值…"),
        _ => L10n.T("正在安装，TypeLeast 会自动重新打开…"),
    };

    /// <summary>0…1 while the size is known; null shows a moving bar.</summary>
    public static double? Fraction(UpdateStage stage, long received, long? total) =>
        stage == UpdateStage.Downloading && total is > 0 ? Math.Clamp((double)received / total.Value, 0, 1) : null;

    private static string Mb(long bytes) => (bytes / 1048576.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
}
