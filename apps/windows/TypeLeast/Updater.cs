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

    /// <summary>Download and check the installer; returns its path in a fresh temp folder. The checksum
    /// list comes from GitHub; the installer from GitHub or a public mirror (UpdateSources), moving on to
    /// the next source when one fails, stalls or delivers a file that does not match the checksum.</summary>
    public static async Task<string> DownloadAsync(WindowsReleaseInfo release, CancellationToken ct = default,
        Action<UpdateStage, long, long?, string>? progress = null, string mode = "auto")
    {
        if (release.SetupUrl is null || release.SumsUrl is null) throw new InvalidOperationException(L10n.T("这个发布没有可校验的 Windows 安装包。"));
        var folder = Path.Combine(Path.GetTempPath(), "TypeLeast-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        using var client = MakeClient(Timeout.InfiniteTimeSpan);
        string sums;
        using (var sumsTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            sumsTimeout.CancelAfter(TimeSpan.FromSeconds(60));
            sums = await client.GetStringAsync(release.SumsUrl, sumsTimeout.Token).ConfigureAwait(false);
        }
        var expected = WindowsRelease.Checksum(release.SetupName, sums)
            ?? throw new InvalidOperationException(L10n.T("发布的校验文件里没有这个安装包。"));
        var setup = Path.Combine(folder, release.SetupName);
        foreach (var (url, source) in UpdateSources.For(release.SetupUrl, mode))
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                await DownloadFrom(client, url, setup, (received, total) => progress?.Invoke(UpdateStage.Downloading, received, total, source), ct).ConfigureAwait(false);
            }
            catch (Exception e) when (!ct.IsCancellationRequested && e is HttpRequestException or OperationCanceledException or IOException)
            {
                Log.Write("update.source.fail", source + " " + e.GetType().Name);
                continue;
            }
            progress?.Invoke(UpdateStage.Verifying, 0, null, source);
            string actual;
            await using (var file = File.OpenRead(setup))
                actual = Convert.ToHexString(await SHA256.HashDataAsync(file, ct).ConfigureAwait(false)).ToLowerInvariant();
            if (actual == expected) return setup;
            Log.Write("update.source.mismatch", source);
        }
        try { Directory.Delete(folder, true); } catch (IOException) { }
        throw new InvalidOperationException(L10n.T("所有下载线路都失败了，请检查网络后重试。"));
    }

    /// <summary>One source: no response or no new data for UpdateSources.Stall gives up on it.</summary>
    private static async Task DownloadFrom(HttpClient client, string url, string path, Action<long, long?> progress, CancellationToken ct)
    {
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        stall.CancelAfter(UpdateSources.Stall);
        using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, stall.Token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength;
        await using var stream = await response.Content.ReadAsStreamAsync(stall.Token).ConfigureAwait(false);
        await using var file = File.Create(path);
        var buffer = new byte[81920];
        long received = 0;
        int read;
        progress(0, total);
        stall.CancelAfter(UpdateSources.Stall);
        while ((read = await stream.ReadAsync(buffer, stall.Token).ConfigureAwait(false)) > 0)
        {
            stall.CancelAfter(UpdateSources.Stall);
            await file.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
            received += read;
            progress(received, total);
        }
    }

    /// <summary>Run the checked installer silently; it closes this app and starts the new one.</summary>
    public static void RunInstaller(string setup)
    {
        var start = new ProcessStartInfo(setup) { UseShellExecute = false };
        foreach (var arg in new[] { "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS", "/RELAUNCH=1" }) start.ArgumentList.Add(arg);
        Process.Start(start);
    }
}
