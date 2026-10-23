using System;
using System.Threading.Tasks;
using System.Windows.Threading;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>
/// In-app updates as one piece: the check on every launch and window open (installing by itself
/// when 自动更新 is on, UpdatePolicy), 检查更新 in settings, and the download, check and install
/// with the progress window. The app is reached only through the delegates it is given.
/// </summary>
internal sealed class UpdateController(AppSettings settings, Dispatcher dispatcher,
    Func<string?> busyReason, Func<bool> quitting, Action<string> setHint, Action changed, Action quit)
{
    /// <summary>A newer Windows release found by the last check, or null.</summary>
    public WindowsReleaseInfo? Available { get; private set; }
    public bool Updating { get; private set; }

    private bool checking;
    /// <summary>A version whose automatic download or install failed in this run: it is not
    /// downloaded again on every window open (检查更新 in settings still can).</summary>
    private string? autoFailed;

    /// <summary>On every launch and every time the window is opened.</summary>
    public async Task AutoCheck()
    {
        if (checking || Updating || quitting() || Environment.GetEnvironmentVariable("TYPELEAST_HOME") is not null) return;
        checking = true;
        try
        {
            try
            {
                var newest = await Updater.NewestAsync();
                if (newest is not null && WindowsRelease.IsNewer(newest.Version, Updater.CurrentVersion) && Available?.Version != newest.Version)
                {
                    Available = newest;
                    changed();
                    if (!(settings.AutoUpdate && Updater.IsInstalledCopy)) setHint(L10n.T("有新版本 {0}，可在「设置 → 服务与更新」中更新。", newest.Version));
                }
            }
            catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or System.Text.Json.JsonException) { }
            // Not while a dictation or Prompt Beta's questions are open: the next window open tries again.
            if (UpdatePolicy.AutoInstall(Available, settings.AutoUpdate, Updater.IsInstalledCopy, autoFailed, busyReason() is not null))
            {
                var update = Available!;
                Log.Write("update.auto", update.Version);
                setHint(L10n.T("正在自动更新到 {0}，完成后会自动重新打开。", update.Version));
                if (await Install() is { } error)
                {
                    autoFailed = update.Version;
                    setHint(error);
                }
            }
        }
        finally { checking = false; }
    }

    /// <summary>检查更新 in settings: a line saying what was found.</summary>
    public async Task<string> Check()
    {
        try
        {
            var newest = await Updater.NewestAsync();
            Available = newest is not null && WindowsRelease.IsNewer(newest.Version, Updater.CurrentVersion) ? newest : null;
            changed();
            return newest is null ? L10n.T("没有找到带 Windows 安装包的发布。")
                : Available is not null ? L10n.T("有新版本 {0}。", newest.Version) + (newest.Summary.Length > 0 ? "\n" + L10n.T("本次更新") + "\n" + newest.Summary : "")
                : L10n.T("已是最新的 Windows 版本（{0}）。", Updater.CurrentVersion);
        }
        catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            return L10n.T("无法访问发布页。请检查网络；如果发布页还没公开，请在浏览器中登录后下载。");
        }
    }

    /// <summary>Download, check and install the available update; returns an error message, or null when the installer started.</summary>
    public async Task<string?> Install()
    {
        if (Available is not { } release || Updating) return null;
        if (busyReason() is { } busy) return busy;
        if (!Updater.IsInstalledCopy) { Shell.Open(release.PageUrl.Length > 0 ? release.PageUrl : "https://github.com/FlaxXTT/Typeleast/releases"); return L10n.T("便携版请在发布页下载新版本。"); }
        Updating = true;
        changed();
        var progress = new UpdateProgressWindow();
        progress.Start(release.Version, release.Summary);
        var lastReport = DateTime.MinValue;
        try
        {
            var setup = await Updater.DownloadAsync(release, mode: settings.UpdateSource, progress: (stage, received, total, source) =>
            {
                // From the download thread; a few updates a second are plenty.
                var now = DateTime.UtcNow;
                if (stage == UpdateStage.Downloading && received > 0 && received != total && now - lastReport < TimeSpan.FromMilliseconds(100)) return;
                lastReport = now;
                dispatcher.InvokeAsync(() => progress.Report(stage, received, total, source));
            });
            // The download takes a while: never quit in the middle of a dictation, or a Prompt Beta
            // clarification, started meanwhile.
            while (busyReason() is not null) await Task.Delay(1000);
            if (quitting()) { progress.Close(); return null; }
            Log.Write("update.install", release.Version);
            progress.Report(UpdateStage.Installing, 0, null);
            Updater.RunInstaller(setup);
            quit();
            return null;
        }
        catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or InvalidOperationException or System.IO.IOException)
        {
            progress.Close();
            Log.Write("update.fail", e.GetType().Name);
            return e is InvalidOperationException ? e.Message : L10n.T("下载更新失败，请稍后再试。");
        }
        finally { Updating = false; changed(); }
    }
}
