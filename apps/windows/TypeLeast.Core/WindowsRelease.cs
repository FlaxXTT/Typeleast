using System.Text.Json;
using System.Text.RegularExpressions;

namespace TypeLeast.Core;

// WindowsRelease.cs - finds the newest release that ships a Windows installer.
// Mac and Windows publish separately: GitHub's single "latest" flag belongs to the
// Mac releases (the Mac updater reads it), so Windows reads the release list and
// takes the version from its own asset name, not from the tag.
public sealed record WindowsReleaseInfo(string Version, string Tag, string PageUrl);

public static class WindowsRelease
{
    public const string ListUrl = "https://api.github.com/repos/FlaxXTT/Typeleast/releases?per_page=30";

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
            foreach (var asset in assets.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() ?? "" : "";
                var match = SetupAsset.Match(name);
                if (!match.Success) continue;
                var version = match.Groups[1].Value;
                if (best is null || IsNewer(version, best.Version))
                    best = new WindowsReleaseInfo(version, Text(release, "tag_name"), Text(release, "html_url"));
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

    private static bool Bool(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;

    private static string Text(JsonElement e, string name)
    {
        var s = e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        return s.Length <= 200 ? s : "";
    }
}
