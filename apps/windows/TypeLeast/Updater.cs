using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// In-app update for Windows. The newest release with a Windows installer is read from
/// GitHub's public release list (no account needed). The installed copy downloads the
/// installer, checks its SHA-256 against the release's checksum list, runs it silently
/// (per-user, no administrator prompt) and the installer starts the new version again.
/// A portable copy is pointed at the download page instead.
/// </summary>
internal static class Updater
{
    public static string CurrentVersion => typeof(Updater).Assembly.GetName().Version?.ToString(3) ?? "0";

    public static bool IsInstalledCopy => WindowsRelease.IsInstalledCopy(AppContext.BaseDirectory,
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), File.Exists);

    private static HttpClient MakeClient(TimeSpan timeout)
    {
        // GitHub sends release files from its download host through redirects.
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 5 }) { Timeout = timeout };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("TypeLeast/" + CurrentVersion);
        return client;
    }

    /// <summary>The newest release with a Windows installer, or null; throws when the list cannot be read.</summary>
    public static async Task<WindowsReleaseInfo?> NewestAsync(CancellationToken ct = default)
    {
        using var client = MakeClient(TimeSpan.FromSeconds(15));
        using var response = await client.GetAsync(WindowsRelease.ListUrl, ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode) throw new HttpRequestException("release list: HTTP " + (int)response.StatusCode);
        return WindowsRelease.Newest(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
    }

    /// <summary>Download and check the installer; returns its path in a fresh temp folder.</summary>
    public static async Task<string> DownloadAsync(WindowsReleaseInfo release, CancellationToken ct = default,
        Action<UpdateStage, long, long?>? progress = null)
    {
        if (release.SetupUrl is null || release.SumsUrl is null) throw new InvalidOperationException(L10n.T("这个发布没有可校验的 Windows 安装包。"));
        var folder = Path.Combine(Path.GetTempPath(), "TypeLeast-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        using var client = MakeClient(TimeSpan.FromMinutes(10));
        var sums = await client.GetStringAsync(release.SumsUrl, ct).ConfigureAwait(false);
        var expected = WindowsRelease.Checksum(release.SetupName, sums)
            ?? throw new InvalidOperationException(L10n.T("发布的校验文件里没有这个安装包。"));
        var setup = Path.Combine(folder, release.SetupName);
        using (var response = await client.GetAsync(release.SetupUrl, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
        {
            response.EnsureSuccessStatusCode();
            var total = response.Content.Headers.ContentLength;
            await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
            await using var file = File.Create(setup);
            var buffer = new byte[81920];
            long received = 0;
            int read;
            progress?.Invoke(UpdateStage.Downloading, 0, total);
            while ((read = await stream.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await file.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                received += read;
                progress?.Invoke(UpdateStage.Downloading, received, total);
            }
        }
        progress?.Invoke(UpdateStage.Verifying, 0, null);
        string actual;
        await using (var file = File.OpenRead(setup))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(file, ct).ConfigureAwait(false)).ToLowerInvariant();
        if (actual != expected)
        {
            try { Directory.Delete(folder, true); } catch (IOException) { }
            throw new InvalidOperationException(L10n.T("下载的安装包和发布页记录的 SHA-256 不一致，已放弃更新。"));
        }
        return setup;
    }

    /// <summary>Run the checked installer silently; it closes this app and starts the new one.</summary>
    public static void RunInstaller(string setup)
    {
        var start = new ProcessStartInfo(setup) { UseShellExecute = false };
        foreach (var arg in new[] { "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS", "/RELAUNCH=1" }) start.ArgumentList.Add(arg);
        Process.Start(start);
    }
}
