using System.Text.Json;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

// WindowsRelease.cs - finds the newest release that ships a Windows installer.
// Mac and Windows publish separately: GitHub's single "latest" flag belongs to the
// Mac releases (the Mac updater reads it), so Windows reads the release list and
// takes the version from its own asset name, not from the tag.
public sealed record WindowsReleaseInfo(string Version, string Tag, string PageUrl,
    string SetupName = "", string? SetupUrl = null, string? SumsUrl = null, string Summary = "");

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
                    best = new WindowsReleaseInfo(version, Text(release, "tag_name"), Text(release, "html_url"), name, DownloadUrl(asset), sums, ReleaseSummary.Text(Text(release, "body")));
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
    public static string Describe(UpdateStage stage, long received = 0, long? total = null, string source = "GitHub") => stage switch
    {
        UpdateStage.Downloading when total is > 0 => L10n.T("正在从 {0} 下载 {1} / {2} MB", source, Mb(received), Mb(total.Value)),
        UpdateStage.Downloading => L10n.T("正在从 {0} 下载 {1} MB", source, Mb(received)),
        UpdateStage.Verifying => L10n.T("正在核对校验值…"),
        _ => L10n.T("正在安装，TypeLeast 会自动重新打开…"),
    };

    /// <summary>0…1 while the size is known; null shows a moving bar.</summary>
    public static double? Fraction(UpdateStage stage, long received, long? total) =>
        stage == UpdateStage.Downloading && total is > 0 ? Math.Clamp((double)received / total.Value, 0, 1) : null;

    private static string Mb(long bytes) => (bytes / 1048576.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>
/// Where an update's installer is downloaded from. GitHub's release files are slow or cut off from
/// some networks (mainland China), so public GitHub download mirrors are tried too. The checksum list
/// always comes from GitHub itself and every file is checked against it, so a mirror can only make a
/// download faster, never change what is installed.
/// </summary>
public static class UpdateSources
{
    /// <summary>Settings values: auto (GitHub, then mirrors), github (GitHub only), mirror (mirrors first).</summary>
    public static readonly string[] Modes = ["auto", "github", "mirror"];

    /// <summary>Public GitHub download mirrors, tried in this order; each takes the full GitHub URL after its address.</summary>
    public static readonly string[] Mirrors = ["https://ghfast.top/", "https://gh-proxy.com/", "https://gh-proxy.org/", "https://gh.llkk.cc/"];

    /// <summary>No new data for this long: give up on this source and try the next.</summary>
    public static readonly TimeSpan Stall = TimeSpan.FromSeconds(15);

    /// <summary>The URLs to try for a release file of this repository, in order, each with a name to show.</summary>
    public static List<(string Url, string Source)> For(string officialUrl, string mode)
    {
        var official = (officialUrl, "GitHub");
        if (!officialUrl.StartsWith(WindowsRelease.DownloadPrefix, StringComparison.Ordinal) || mode == "github") return [official];
        var mirrors = Mirrors.Select(m => (m + officialUrl, new Uri(m).Host)).ToList();
        return mode == "mirror" ? [.. mirrors, official] : [official, .. mirrors];
    }
}

/// <summary>When an update installs by itself: the installed copy, 自动更新 on, not a version that
/// already failed in this run, and nothing in the way (a dictation, Prompt Beta's questions).</summary>
public static class UpdatePolicy
{
    public static bool AutoInstall(WindowsReleaseInfo? available, bool autoUpdate, bool installedCopy, string? failedVersion, bool busy) =>
        available is not null && autoUpdate && installedCopy && failedVersion != available.Version && !busy;

    /// <summary>The ring's three steps (下载 · 核对 · 安装), and which one a stage is.</summary>
    public static readonly string[] Steps = ["下载", "核对", "安装"];

    public static int Step(UpdateStage stage) => stage switch { UpdateStage.Downloading => 0, UpdateStage.Verifying => 1, _ => 2 };
}

/// <summary>The progress ring's arc: from 12 o'clock clockwise to <c>fraction</c> of the circle.</summary>
public static class RingGeometry
{
    /// <summary>The end point of the arc on a circle of <paramref name="radius"/> around (cx, cy).</summary>
    public static (double X, double Y) ArcEnd(double fraction, double radius, double cx, double cy)
    {
        var angle = Math.Clamp(fraction, 0, 0.9999) * 2 * Math.PI;
        return (cx + radius * Math.Sin(angle), cy - radius * Math.Cos(angle));
    }

    /// <summary>More than half the circle needs the large arc.</summary>
    public static bool IsLargeArc(double fraction) => fraction > 0.5;
}
