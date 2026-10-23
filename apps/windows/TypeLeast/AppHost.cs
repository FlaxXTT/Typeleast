using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>
/// The app: settings, the local service, the hotkey, the recorder, the windows,
/// and dictation itself (tap -> record -> local service -> paste). Everything
/// that touches the UI runs on the UI thread.
/// </summary>
internal sealed class AppHost
{
    public enum DictationPhase { Idle, Recording, Thinking }

    public AppSettings Settings { get; }
    public LocalHistory History { get; }
    public ActivityLog Activity { get; }
    public ServiceClient Client { get; } = new();
    public ServiceManager Service { get; }
    public HealthResponse? Health { get; private set; }
    public DictationPhase Phase { get; private set; } = DictationPhase.Idle;
    public string Hint { get; private set; } = "";
    public bool? DictionarySynced { get; private set; }
    public string? SettingsSaveError { get; private set; }

    /// <summary>Something the windows show changed (raised on the UI thread).</summary>
    public event Action? Changed;

    private readonly Application app;
    private readonly string settingsPath;
    private string savedSettingsJson = "{}";
    private readonly KeyboardHook hook;
    private readonly AudioRecorder recorder = new();
    private readonly RecordingBar bar;
    private MainWindow? window;
    private Tray? tray;
    private DispatcherTimer? healthTimer;
    private IntPtr targetWindow;
    private string targetApp = "";
    // Prompt Beta questions waiting for a spoken answer, and where the prompt goes.
    private string? betaSession;
    private IntPtr betaWindow;
    private string betaApp = "";
    private BetaPanel? betaPanel;
    // 翻译模式: the target language of the recording in progress (null: ordinary dictation).
    private string? translating;
    private bool dictionaryNeedsSync = true;
    private readonly OperationTracker operations = new();
    private DictationOptions? recordingOptions;
    private bool quitting;
    private bool refreshing;
    private bool syncing;
    private DictationOptions? betaOptions;
    public RetainedAudio RetainedAudio { get; }
    private FieldTarget? targetField;
    private byte[]? recordingContext;
    // Read in the background while recording; never delays opening the microphone.
    private Task<FieldTarget>? targetFieldTask;
    private Task<byte[]?>? recordingContextTask;
    private readonly System.Diagnostics.Stopwatch micClock = new();
    /// <summary>Milliseconds from the hotkey to the first audio of the last recording (null before any).</summary>
    public long? LastMicrophoneStartMs { get; private set; }
    private readonly EditLearner learner = new();
    private FieldTarget? betaField;
    private readonly AudioDucking ducking = new();
    public PromptFileSync PromptFile { get; }
    private IdleBar? idleBar;
    private Onboarding? onboarding;
    private bool started;
    public bool IsMicrophoneTesting { get; private set; }
    public bool? MicrophoneReady { get; private set; }
    public bool? HotkeyReady { get; private set; }
    public double MicrophoneLevel => recorder.Level;

    public ICredentialStore Credentials { get; }
    public AppHost(Application app, ICredentialStore? credentials = null)
    {
        this.app = app;
        Credentials = credentials ?? new WindowsCredentials();
        PrivateStorage.EnsureDirectory(AppPaths.StateDirectory());
        settingsPath = AppPaths.AppSettingsFile();
        Settings = AppSettings.Load(settingsPath);
        savedSettingsJson = System.Text.Json.JsonSerializer.Serialize(Settings, Json.Options);
        L10n.Configure(Settings.InterfaceLanguage);
        Theme.Apply(Settings.Appearance);
        History = new LocalHistory(AppPaths.AppHistoryFile());
        History.ApplyRetention(Settings.HistoryRetention);
        RetainedAudio = new RetainedAudio(System.IO.Path.Combine(AppPaths.StateDirectory(), "recordings"));
        PruneAudio();
        Activity = new ActivityLog(AppPaths.AppActivityFile());
        // The heatmap starts from whatever history is still kept, once.
        Activity.SeedIfNeeded(History.Entries.Where(e => e.Text.Length > 0)
            .Select(e => (e.Time.LocalDateTime, ActivityLog.CountWords(e.Text))));
        Service = new ServiceManager(Client) { NodePathOverride = Settings.NodePath, ModelMirror = Settings.ModelMirror };
        hook = new KeyboardHook(Settings.Hotkey, Settings.TranslateHotkey);
        bar = new RecordingBar(this);
        PromptFile = new PromptFileSync(Client, AppPaths.StateDirectory());
        bar.IsVisibleChanged += (_, _) => UpdateIdleBar();
        if (Settings.PersistenceBlocked) Hint = L10n.T("设置文件无法读取，原文件已保留，已阻止覆盖保存。");
        if (Activity.LastError is not null) Hint = L10n.T("活动计数文件损坏或无法读取，原文件已保留。");
        if (History.LastError is not null) Hint = L10n.T("历史记录无法读取或安全保存，原文件已保留。请检查系统凭据和文件权限。");
    }

    public bool ServiceUp => Health?.Ok == true && Health.Service == "typeleast";
    public SpeechModelCatalog? SpeechCatalog { get; private set; }
    public SpeechStatus? Speech => Health?.Speech;
    public string HotkeyLabel => TapDetector.Label(Settings.Hotkey);
    public LlmRoute? ActiveRoute => Settings.ActiveRoute(Credentials.Read);
    public bool LlmConfigured => ActiveRoute is not null;

    public string ModelSummary
    {
        get
        {
            if (!LlmConfigured) return L10n.T("整理模型未设置（只去口水词，不改写）");
            var preset = Settings.Preset;
            return preset.Name + " · " + Settings.LlmModel + (preset.Id == "ollama" ? L10n.T("（本机）") : L10n.T("（自己的 Key）"));
        }
    }

    public string ServiceSummary => Service.State switch
    {
        ServiceManager.Phase.Running => ServiceUp ? L10n.T("本地服务已就绪") : (Messages.SpeechProblem(Speech) is { Length: > 0 } p ? p : L10n.T("本地服务运行中")),
        ServiceManager.Phase.Starting => L10n.T("本地服务启动中…"),
        ServiceManager.Phase.Stopped => L10n.T("本地服务未启动"),
        _ => Service.Detail,
    };

    // ---- lifecycle

    // ---- updates

    /// <summary>A newer Windows release found by the last check, or null.</summary>
    public WindowsReleaseInfo? AvailableUpdate { get; private set; }
    public bool Updating { get; private set; }

    private bool checkingUpdate;
    /// <summary>A version whose automatic download or install failed in this run: it is not
    /// downloaded again on every window open (检查更新 in settings still can).</summary>
    private string? autoUpdateFailed;

    /// <summary>On every launch and every time the window is opened. With 自动更新 on, the installed
    /// copy installs a new version by itself; otherwise only the hint changes.</summary>
    private async Task AutoUpdateCheck()
    {
        if (checkingUpdate || Updating || quitting || Environment.GetEnvironmentVariable("TYPELEAST_HOME") is not null) return;
        checkingUpdate = true;
        try
        {
            try
            {
                var newest = await Updater.NewestAsync();
                if (newest is not null && WindowsRelease.IsNewer(newest.Version, Updater.CurrentVersion) && AvailableUpdate?.Version != newest.Version)
                {
                    AvailableUpdate = newest;
                    Raise();
                    if (!(Settings.AutoUpdate && Updater.IsInstalledCopy)) SetHint(L10n.T("有新版本 {0}，可在「设置 → 服务与更新」中更新。", newest.Version));
                }
            }
            catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or System.Text.Json.JsonException) { }
            // Not while Prompt Beta's questions are open: the next window open tries again.
            if (AvailableUpdate is { } update && Settings.AutoUpdate && Updater.IsInstalledCopy
                && autoUpdateFailed != update.Version && betaSession is null && Phase == DictationPhase.Idle)
            {
                Log.Write("update.auto", update.Version);
                SetHint(L10n.T("正在自动更新到 {0}，完成后会自动重新打开。", update.Version));
                if (await InstallUpdate() is { } error)
                {
                    autoUpdateFailed = update.Version;
                    SetHint(error);
                }
            }
        }
        finally { checkingUpdate = false; }
    }

    public async Task<string> CheckForUpdate()
    {
        try
        {
            var newest = await Updater.NewestAsync();
            AvailableUpdate = newest is not null && WindowsRelease.IsNewer(newest.Version, Updater.CurrentVersion) ? newest : null;
            Raise();
            return newest is null ? L10n.T("没有找到带 Windows 安装包的发布。")
                : AvailableUpdate is not null ? L10n.T("有新版本 {0}。", newest.Version)
                : L10n.T("已是最新的 Windows 版本（{0}）。", Updater.CurrentVersion);
        }
        catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            return L10n.T("无法访问发布页。请检查网络；如果发布页还没公开，请在浏览器中登录后下载。");
        }
    }

    /// <summary>Download, check and install the available update; returns an error message, or null when the installer started.</summary>
    public async Task<string?> InstallUpdate()
    {
        if (AvailableUpdate is not { } release || Updating) return null;
        if (Phase != DictationPhase.Idle) return L10n.T("听写结束后再更新。");
        // Quitting would drop the questions and the answers given so far.
        if (betaSession is not null) return L10n.T("生成或取消这次提示词 Beta 后再更新。");
        if (!Updater.IsInstalledCopy) { Shell.Open(release.PageUrl.Length > 0 ? release.PageUrl : "https://github.com/FlaxXTT/Typeleast/releases"); return L10n.T("便携版请在发布页下载新版本。"); }
        Updating = true;
        Raise();
        try
        {
            var setup = await Updater.DownloadAsync(release);
            // The download takes a while: never quit in the middle of a dictation, or a Prompt Beta
            // clarification, started meanwhile.
            while (Phase != DictationPhase.Idle || betaSession is not null) await Task.Delay(1000);
            if (quitting) return null;
            Log.Write("update.install", release.Version);
            Updater.RunInstaller(setup);
            Quit();
            return null;
        }
        catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or InvalidOperationException or System.IO.IOException)
        {
            Log.Write("update.fail", e.GetType().Name);
            return e is InvalidOperationException ? e.Message : L10n.T("下载更新失败，请稍后再试。");
        }
        finally { Updating = false; Raise(); }
    }

    public void Start(bool autostart)
    {
        if (started) return;
        started = true;
        _ = AutoUpdateCheck();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemAppearanceChanged;
        Log.Write("app.start", "version=" + typeof(AppHost).Assembly.GetName().Version);
        Service.Changed += () => app.Dispatcher.InvokeAsync(() =>
        {
            if (Service.State == ServiceManager.Phase.Running) { _ = RefreshHealth(); PromptFile.ServiceReady(); }
            Raise();
        });
        Service.Start();
        PromptFile.Start();

        hook.Tapped += () => app.Dispatcher.InvokeAsync(() => Toggle());
        hook.PasteLast += () => app.Dispatcher.InvokeAsync(() => _ = PasteLast());
        hook.CopyShortcut = Settings.PasteLastShortcut;
        hook.TranslateTapped += () => app.Dispatcher.InvokeAsync(() => ToggleTranslate());
        hook.Escape += () => app.Dispatcher.InvokeAsync(Cancel);
        HotkeyReady = hook.Install();
        if (HotkeyReady != true) Hint = L10n.T("无法注册快捷键，可以用托盘菜单开始听写");
        recorder.AudioStarted += OnAudioStarted;
        recorder.LimitReached += () => app.Dispatcher.InvokeAsync(() => { if (Phase == DictationPhase.Recording) _ = StopAndSend(); });
        recorder.RecordingFailed += () => app.Dispatcher.InvokeAsync(() => { Cancel(); MicrophoneReady = false; SetHint(L10n.T("麦克风已断开或录音异常，请重新选择设备后重试。")); });

        tray = new Tray(this);
        JumpList.Update(Settings.Strength);
        healthTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        healthTimer.Tick += async (_, _) => await RefreshHealth();
        healthTimer.Start();

        // The 开机自动启动 switch shows what Windows will do at login, also after a change in Task Manager.
        if (Autostart.Check() is bool startsWithWindows && startsWithWindows != Settings.LaunchAtLogin)
        {
            Settings.LaunchAtLogin = startsWithWindows;
            SaveSettings();
        }
        if (!Settings.OnboardingDone || !autostart) ShowWindow(MainWindow.Page.Home);
        if (!Settings.OnboardingDone) ShowOnboarding();
        UpdateIdleBar();
    }

    public void Quit()
    {
        quitting = true;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemAppearanceChanged;
        idleBar?.Hide();
        onboarding?.Close();
        Cancel();
        DropBeta();
        healthTimer?.Stop();
        PromptFile.Dispose();
        recorder.Cancel();
        hook.Dispose();
        Service.Stop();
        tray?.Dispose();
        app.Shutdown();
    }

    public void ShowWindow(MainWindow.Page page)
    {
        window ??= new MainWindow(this);
        window.ShowPage(page);
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        _ = AutoUpdateCheck();
    }

    private void Raise() { UpdateIdleBar(); Changed?.Invoke(); }
    private void SystemAppearanceChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e)
        => app.Dispatcher.InvokeAsync(() => { if (!quitting && Settings.Appearance == "system") Theme.Apply("system"); });
    private void UpdateIdleBar()
    {
        if (!started || quitting) return;
        if (Settings.ShowIdleBar && Phase == DictationPhase.Idle && !bar.IsVisible)
        { idleBar ??= new IdleBar(this); if (!idleBar.IsVisible) idleBar.Show(); }
        else idleBar?.Hide();
    }
    public void ShowOnboarding()
    {
        if (onboarding is null) { onboarding = new Onboarding(this); onboarding.Closed += (_, _) => onboarding = null; }
        onboarding.Show(); onboarding.Activate();
    }
    public bool StartMicrophoneTest()
    {
        if (Phase != DictationPhase.Idle || operations.TryBegin() is not { } operation) return false;
        learner.Stop();
        try { micClock.Restart(); LastMicrophoneStartMs = null; recorder.Start(Settings.MicrophoneDevice); MicrophoneReady = true; IsMicrophoneTesting = true; Phase = DictationPhase.Recording; hook.SwallowEscape = true; Raise(); return true; }
        catch (InvalidOperationException) { operations.Complete(operation); MicrophoneReady = false; SetHint(L10n.T("无法打开麦克风，请检查设备和 Windows 麦克风权限。")); return false; }
    }
    public void EndMicrophoneTest() { if (IsMicrophoneTesting) Cancel(); }
    public async Task PasteLast()
    {
        if (Phase != DictationPhase.Idle || History.Last is not { } last) return;
        var field = FieldTarget.Capture();
        for (var i = 0; i < 40 && (Native.GetAsyncKeyState(0x11) < 0 || Native.GetAsyncKeyState(0x10) < 0 || Native.GetAsyncKeyState(0x12) < 0); i++) await Task.Delay(25);
        if (quitting || field.Window == IntPtr.Zero || !Paster.SameWindow(field.Window, Native.GetForegroundWindow())) return;
        var text = TerminalGuard.SafeText(last.Text, Shell.ProcessName(field.Window));
        var result = await Paster.PasteAsync(text, field.Window, Settings.RestoreClipboard);
        if (result != Paster.Outcome.Pasted) SetHint(Paster.Message(result));
    }

    public bool SaveSettings()
    {
        if (!Settings.LearnCorrections) learner.Stop();
        Settings.Words = Settings.DictionaryEntries.Select(e => e.ServiceValue).ToList();
        try { Settings.Save(settingsPath); savedSettingsJson = System.Text.Json.JsonSerializer.Serialize(Settings, Json.Options); }
        catch (Exception e) {
            var restored = System.Text.Json.JsonSerializer.Deserialize<AppSettings>(savedSettingsJson, Json.Options)!;
            foreach (var property in typeof(AppSettings).GetProperties().Where(p => p.SetMethod?.IsPublic == true && !p.IsDefined(typeof(System.Text.Json.Serialization.JsonIgnoreAttribute), true))) property.SetValue(Settings, property.GetValue(restored));
            SettingsSaveError = L10n.T("设置未能保存，请检查文件权限和可用空间。");
            Log.Write("settings.save.fail", e.GetType().Name); SetHint(L10n.T("设置未能保存，请检查文件权限和可用空间。")); return false; }
        SettingsSaveError = null;
        Theme.Apply(Settings.Appearance);
        if (window is not null) window.ShowInTaskbar = Settings.ShowInTaskbar;
        hook.CopyShortcut = Settings.PasteLastShortcut;
        hook.SetKey(Settings.Hotkey);
        hook.SetTranslateKey(Settings.TranslateHotkey);
        Service.NodePathOverride = Settings.NodePath;
        Service.ModelMirror = Settings.ModelMirror;
        if (Settings.Strength != "promptbeta" && betaSession is not null) DropBeta();
        History.ApplyRetention(Settings.HistoryRetention); PruneAudio();
        Raise(); return true;
    }

    public void SetHint(string text)
    {
        Hint = text;
        Raise();
    }

    // ---- health and the service

    public async Task RefreshHealth()
    {
        if (refreshing || quitting) return;
        History.ApplyRetention(Settings.HistoryRetention); PruneAudio();
        refreshing = true;
        try
        {
            Health = await Client.HealthAsync();
            try { SpeechCatalog = await Client.GetSpeechModelsAsync(); } catch (ServiceException) { SpeechCatalog = null; }
            if (dictionaryNeedsSync && Health.Service == "typeleast") _ = SyncDictionary();
        }
        catch (ServiceException)
        {
            Health = null;
        }
        finally { refreshing = false; }
        Raise();
    }

    public void RestartService()
    {
        Cancel();
        DropBeta();
        Health = null;
        Service.NodePathOverride = Settings.NodePath;
        Service.ModelMirror = Settings.ModelMirror;
        Service.Restart();
        SetHint(L10n.T("正在重新启动本地服务…"));
    }

    public async Task DownloadModels()
    {
        try
        {
            await Client.DownloadModelsAsync(Settings.ModelMirror);
            await RefreshHealth();
        }
        catch (ServiceException e)
        {
            SetHint(L10n.T("无法开始下载：") + e.Message);
        }
    }

    public async Task ManageSpeechModel(string id, bool download = false, bool cancel = false)
    {
        if (!cancel && Phase != DictationPhase.Idle) return;
        try { await Client.SpeechModelActionAsync(id, download, cancel, Settings.ModelMirror); await RefreshHealth(); }
        catch (ServiceException) { SetHint(L10n.T("模型操作失败，请重试。当前模型保留。")); }
    }

    public async Task SyncDictionary()
    {
        if (syncing || quitting) return;
        syncing = true;
        var snapshot = Settings.Words.ToArray();
        try
        {
            await Client.PutDictionaryAsync(snapshot);
            DictionarySynced = true;
            dictionaryNeedsSync = !snapshot.SequenceEqual(Settings.Words);
        }
        catch (ServiceException)
        {
            DictionarySynced = false;
            dictionaryNeedsSync = true;
        }
        finally { syncing = false; }
        Raise();
    }

    public void AddWord(string entry)
    {
        if (WordEntry.FromLegacy(entry) is { } word) SaveWord(word);
    }
    public bool SaveWord(WordEntry entry, bool synchronize = true)
    {
        if (WordEntry.Parse(entry.Word, entry.HeardAs, entry.Source) is null) return false;
        if (Settings.DictionaryEntries.Any(e => e.Id != entry.Id && string.Equals(e.ServiceValue, entry.ServiceValue, StringComparison.OrdinalIgnoreCase)))
        { SetHint(L10n.T("词条已存在或输入无效")); return false; }
        var previous = Settings.DictionaryEntries.ToList();
        var index = Settings.DictionaryEntries.FindIndex(e => e.Id == entry.Id);
        if (index < 0) Settings.DictionaryEntries.Add(entry); else Settings.DictionaryEntries[index] = entry;
        if (!SaveSettings()) { Settings.DictionaryEntries = previous; return false; }
        dictionaryNeedsSync = true; if (synchronize) _ = SyncDictionary(); return true;
    }
    private async Task LearnWord(WordEntry entry)
    {
        if (!Settings.LearnCorrections || quitting || !SaveWord(entry, false)) return;
        try { await Client.LearnCorrectionAsync(entry.HeardAs, entry.Word); dictionaryNeedsSync = false; DictionarySynced = true; }
        catch (ServiceException) { dictionaryNeedsSync = true; DictionarySynced = false; }
        Raise();
    }
    public void RemoveWord(string entry)
    {
        var previous = Settings.DictionaryEntries.ToList();
        Settings.DictionaryEntries.RemoveAll(e => e.Id == entry || e.ServiceValue == entry);
        if (!SaveSettings()) { Settings.DictionaryEntries = previous; return; }
        dictionaryNeedsSync = true; _ = SyncDictionary();
    }
    private void PruneAudio()
    {
        try { RetainedAudio.Prune(Settings.KeepAudio24h && Settings.HistoryRetention != "never" ? History.Entries.Select(e => e.AudioId).OfType<string>() : Array.Empty<string>()); }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { SetHint(L10n.T("保留录音无法清理，请检查文件权限。")); }
    }
    public void DeleteHistory(string id) { History.Remove(id); PruneAudio(); Raise(); }
    public bool CanRetry(HistoryEntry entry)
    {
        try { return Settings.KeepAudio24h && entry.Request is { Strength: not "promptbeta" } && RetainedAudio.Available(entry.AudioId); }
        catch (Exception) { return false; }
    }
    public async Task RetryHistory(HistoryEntry entry)
    {
        if (Phase != DictationPhase.Idle || !CanRetry(entry) || entry.Request is not { } request) return;
        var operation = operations.TryBegin(); if (operation is null) return;
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true; bar.ShowThinking(); Raise();
        byte[]? wav = null;
        try
        {
            wav = RetainedAudio.Load(entry.AudioId!);
            if (request.Strength == "promptify") await PromptFile.PrepareAsync();
            var result = await Client.DictateAsync(wav, request.Language, entry.App, request.Strength, ActiveRoute,
                ct: operation.Token, translateTo: request.TranslateTo, variants: request.Variants);
            if (!operations.IsCurrent(operation)) return;
            Paster.SetText(result.InsertableText);
            History.Add(new HistoryEntry { Text = result.InsertableText, Raw = result.Raw, App = entry.App,
                Fallback = result.Fallback, Reason = result.FallbackReason, Seconds = entry.Seconds,
                Request = request, AudioId = entry.AudioId });
            bar.ShowResult(L10n.T("已复制"), result.Fallback);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (Exception e) when (e is ServiceException or System.IO.IOException or System.Security.Cryptography.CryptographicException)
        { if (operations.IsCurrent(operation)) bar.ShowResult(L10n.T("重试失败，原始记录已保留"), true); }
        finally { if (wav is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(wav); if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; } operations.Complete(operation); Raise(); }
    }

    // ---- dictation

    public void Toggle() => Toggle(null);

    /// <summary>翻译模式's key: starts a recording inserted in the target language; while recording, either key finishes.</summary>
    public void ToggleTranslate() => Toggle(Settings.TranslateTarget);

    /// <summary>Change the cleanup mode (整理档位) from any entry: home, settings, tray or the taskbar
    /// jump list. It applies to the next recording. <paramref name="announce"/> shows the new mode on the
    /// recording bar for entries outside the main window.</summary>
    public void SetStrength(string code, bool announce = false)
    {
        if (!CleanupModes.IsKnown(code) || Phase != DictationPhase.Idle) return;
        if (betaSession is not null && code != "promptbeta") {
            if (MessageBox.Show(L10n.T("切换模式会结束这次 Beta 对话，尚未生成的内容不会插入。"),
                L10n.T("结束本次信息补充？"), MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
            DropBeta();
        }
        if (Settings.Strength != code)
        {
            Settings.Strength = code;
            if (!SaveSettings()) return;
            JumpList.Update(Settings.Strength);
        }
        if (announce && Phase == DictationPhase.Idle) bar.ShowResult(L10n.T("整理档位：") + CleanupModes.Title(code), warning: false);
    }

    private void Toggle(string? translateTo)
    {
        if (IsMicrophoneTesting) return;
        switch (Phase)
        {
            case DictationPhase.Idle:
                translating = translateTo;
                StartRecording();
                break;
            case DictationPhase.Recording: _ = StopAndSend(); break;
            default: break; // still cleaning up the last one
        }
    }

    private void StartRecording()
    {
        if (quitting) return;
        if (!ServiceUp || Speech?.Ready != true)
        {
            bar.ShowResult(Messages.SpeechProblem(Speech) is { Length: > 0 } p ? p : L10n.T("本地服务还没就绪"), warning: true);
            return;
        }
        var operation = operations.TryBegin();
        if (operation is null) return;
        // The microphone opens first: anything slow before it (UI Automation, ducking) would cut
        // the start of what the user says. Only the foreground window, which is instant, is read before.
        micClock.Restart();
        targetWindow = Native.GetForegroundWindow();
        targetField = null; recordingContext = null;
        try
        {
            recorder.Start(Settings.MicrophoneDevice);
            MicrophoneReady = true;
        }
        catch (InvalidOperationException e)
        {
            operations.Complete(operation);
            ducking.Dispose(); MicrophoneReady = false;
            Log.Write("mic.fail", e.GetType().Name);
            bar.ShowResult(L10n.T("无法打开麦克风：请在 设置 → 隐私和安全性 → 麦克风 中允许桌面应用访问麦克风"), warning: true);
            return;
        }
        Phase = DictationPhase.Recording;
        if (translating is null && betaSession is not null) betaPanel?.Hide();
        hook.SwallowEscape = true;
        bar.ShowRecording(recorder, translating is { } target ? "→" + target.ToUpperInvariant() + " " : "");
        Raise();
        learner.Stop();
        recordingOptions = new DictationOptions(Settings.Language, Settings.Strength, translating, Settings.VariantsHeader, ActiveRoute, Settings.RestoreClipboard, Settings.InsertionMode, Settings.FormattedLists, Settings.LearnCorrections);
        targetApp = Shell.ProcessName(targetWindow);
        var window = targetWindow;
        targetFieldTask = Task.Run(() => FieldTarget.CaptureFor(window));
        recordingContextTask = Settings.UseFieldContext ? targetFieldTask.ContinueWith(t => FieldContextReader.Read(t.Result), TaskScheduler.Default) : null;
        if (Settings.MuteOtherAudio) ducking.Start();
    }

    /// <summary>First audio of a recording: record how long the microphone took, and give the "speak now" cue.</summary>
    private void OnAudioStarted()
    {
        var ms = micClock.ElapsedMilliseconds;
        app.Dispatcher.InvokeAsync(() =>
        {
            if (Phase != DictationPhase.Recording) return;
            LastMicrophoneStartMs = ms;
            Log.Write("mic.ready", ms.ToString(System.Globalization.CultureInfo.InvariantCulture));
            if (Settings.PlaySounds && !IsMicrophoneTesting) Sounds.Start();
            Raise();
        });
    }

    /// <summary>A background read, or null if it is not done within <paramref name="ms"/>.</summary>
    private static async Task<T?> Within<T>(Task<T>? task, int ms) where T : class?
    {
        if (task is null) return null;
        if (await Task.WhenAny(task, Task.Delay(ms)) != task || !task.IsCompletedSuccessfully) return null;
        return task.Result;
    }

    public void Cancel()
    {
        learner.Stop();
        ducking.Dispose(); IsMicrophoneTesting = false;
        var preserveBeta = Phase == DictationPhase.Recording && betaSession is not null;
        var lease = operations.Active;
        operations.Cancel();
        recorder.Cancel();
        if (Phase == DictationPhase.Recording && lease is not null) lease.Dispose();
        hook.SwallowEscape = false;
        translating = null;
        Phase = DictationPhase.Idle;
        if (preserveBeta) betaPanel?.Show(); else DropBeta();
        bar.ShowResult(L10n.T("已取消"), warning: false);
        Raise();
    }

    private async Task StopAndSend()
    {
        if (operations.Active is not { } operation || recordingOptions is not { } options) return;
        var (wav, seconds) = recorder.Stop();
        ducking.Dispose();
        if (Settings.PlaySounds) Sounds.Stop();
        hook.SwallowEscape = false;
        var translateTo = options.TranslateTo;
        translating = null;
        if (seconds < 0.3)
        {
            operations.Complete(operation);
            Phase = DictationPhase.Idle;
            bar.ShowResult(L10n.T("录音太短"), warning: true);
            if (betaSession is not null) betaPanel?.Show();
            Raise();
            return;
        }
        // A recording made while Prompt Beta's questions are open is the answer to them;
        // a translation is not, and leaves the questions waiting.
        if (translateTo is null && options.Strength != "promptbeta" && betaSession is not null) DropBeta();
        var answering = translateTo is null && options.Strength == "promptbeta" ? betaSession : null;
        Phase = DictationPhase.Thinking;
        hook.SwallowEscape = true;
        bar.ShowThinking(translateTo is null ? null : L10n.T("翻译中…"));
        Raise();
        targetField = await Within(targetFieldTask, 300);
        recordingContext = await Within(recordingContextTask, 300);
        targetFieldTask = null; recordingContextTask = null;
        if (!operations.IsCurrent(operation)) return;
        try
        {
            var requestOptions = answering is not null ? betaOptions ?? options : options;
            if (requestOptions.Strength == "promptify") await PromptFile.PrepareAsync();
            var result = await Client.DictateAsync(wav, requestOptions.Language, targetApp, requestOptions.Strength, requestOptions.Route,
                fieldContext: recordingContext, ct: operation.Token, betaSession: answering, translateTo: translateTo, variants: requestOptions.Variants);
            if (!operations.IsCurrent(operation)) return;
            if (ShowBetaQuestions(result))
            {
                betaOptions = requestOptions;
                return;
            }
            if (answering is not null)
            {
                targetWindow = betaWindow;
                targetApp = betaApp;
                targetField = betaField;
                ClearBeta();
            }
            await Deliver(result, seconds, operation, requestOptions, answering is null ? wav : null);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException e) when (e.Status == 410 && answering is not null)
        {
            if (!operations.IsCurrent(operation)) return;
            DropBeta();
            bar.ShowResult(L10n.T("问题已过期，请重新说一遍需求"), warning: true);
        }
        catch (ServiceException e)
        {
            if (!operations.IsCurrent(operation)) return;
            Log.Write("operation.failed", new DiagnosticEvent("dictation", "transport", e.Code, HttpStatus: e.Status).Format());
            bar.ShowResult(e.Code == "speech-not-ready" ? Messages.SpeechProblem(Speech) : L10n.T("听写失败：") + (e.ServiceUnavailable ? L10n.T("本地服务未就绪") : DiagnosticEvent.SafeReason(e.Code)), warning: true);
        }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(wav);
            if (operations.IsCurrent(operation)) {
                Phase = DictationPhase.Idle; hook.SwallowEscape = false;
                if (betaSession is not null) betaPanel?.Show();
                Raise();
            }
            operations.Complete(operation);
        }
    }

    /// <summary>Paste a finished result into the target window and record it.</summary>
    private async Task Deliver(DictateResponse result, double seconds, OperationTracker.Lease operation, DictationOptions options, byte[]? wav = null)
    {
        if (!operations.IsCurrent(operation) || quitting) return;
        Log.Write("operation.complete", new DiagnosticEvent(result.Translated is null ? "dictation" : "translation", "complete",
            result.FallbackReason, result.Ms?.Total, Characters: result.Text.Length).Format());
        {
            // A terminal gets one line without control characters: this reduces accidental command execution.
            var text = TerminalGuard.SafeText(result.InsertableText.Trim(), targetApp);
            if (text.Length == 0)
            {
                bar.ShowResult(L10n.T("没有听到内容"), warning: true);
            }
            else
            {
                if (options.InsertionMode == "preview")
                {
                    var preview = await PreviewPanel.Show(text, operation.Token);
                    if (preview is null || !operations.IsCurrent(operation)) return;
                    text = TerminalGuard.SafeText(preview, targetApp);
                    Native.SetForegroundWindow(targetWindow);
                    await Task.Delay(100, operation.Token);
                }
                var outcome = options.InsertionMode == "clipboardOnly" ? (Paster.SetText(text) ? Paster.Outcome.CopiedOnly : Paster.Outcome.Failed)
                    : await Paster.PasteAsync(text, targetWindow, options.RestoreClipboard, operation.Token, options.FormattedLists && TerminalGuard.SafeText("a\nb", targetApp).Contains('\n'));
                if (outcome == Paster.Outcome.Failed) { bar.ShowResult(L10n.T("无法写入剪贴板，请重试"), true); return; }
                if (!operations.IsCurrent(operation)) return;
                var entry = new HistoryEntry
                {
                    Text = text,
                    Raw = result.Raw,
                    App = targetApp,
                    Fallback = result.Fallback,
                    Reason = result.FallbackReason,
                    Seconds = seconds,
                    Inserted = outcome == Paster.Outcome.Pasted,
                    Request = new HistoryRequest(options.Language, options.Strength, options.TranslateTo, options.Variants),
                };
                if (wav is not null && Settings.KeepAudio24h && Settings.HistoryRetention != "never" && options.Strength != "promptbeta")
                {
                    try { RetainedAudio.Save(entry.Id, wav); entry.AudioId = entry.Id; }
                    catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException) { SetHint(L10n.T("录音未能安全保留，文字结果仍可使用。")); }
                }
                History.Add(entry); PruneAudio();
                if (outcome == Paster.Outcome.Pasted && options.LearnCorrections && Settings.LearnCorrections && targetField is { } field)
                    learner.Start(field, text, word => _ = LearnWord(word));
                if (History.LastError is not null) SetHint(L10n.T("历史记录无法读取或安全保存，原文件已保留。请检查系统凭据和文件权限。"));
                Activity.Record(ActivityLog.CountWords(text), DateTime.Now);
                var note = Messages.FallbackNote(result.FallbackReason);
                var done = Paster.Message(outcome);
                bar.ShowResult(note is null ? done : done + " · " + note, warning: note is not null);
            }
        }
    }

    /// <summary>Prompt Beta asked questions: show them and keep the session. True when shown.</summary>
    private bool ShowBetaQuestions(DictateResponse result)
    {
        if (result.Beta?.SessionId is not { } id) return false;
        if (betaSession is null) { betaWindow = targetWindow; betaApp = targetApp; betaField = targetField; }
        betaSession = id;
        betaPanel ??= new BetaPanel(() => _ = FinishBetaWithoutAnswers(), DropBeta);
        betaPanel.ShowQuestions(result.Beta!, HotkeyLabel);
        bar.ShowResult(L10n.T("提示词 Beta：可继续补充或结束生成"), warning: false);
        return true;
    }

    /// <summary>Explicitly finish clarification; unanswered points stay unconfirmed.</summary>
    private async Task FinishBetaWithoutAnswers()
    {
        if (Phase != DictationPhase.Idle || betaSession is not { } id || betaOptions is not { } options) return;
        var operation = operations.TryBegin();
        if (operation is null) return;
        targetWindow = betaWindow; targetApp = betaApp; targetField = betaField;
        betaPanel?.Hide();
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true;
        bar.ShowThinking(); Raise();
        try
        {
            var result = await Client.BetaAsync(id, true, targetApp, options.Route, operation.Token, options.Variants);
            if (operations.IsCurrent(operation)) {
                if (ShowBetaQuestions(result)) return;
                ClearBeta();
                await Deliver(result, 0, operation, options);
            }
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException e)
        {
            if (operations.IsCurrent(operation)) {
                if (e.Status == 410) ClearBeta(); else betaPanel?.Show();
                bar.ShowResult(e.Status == 410 ? L10n.T("问题已过期，请重新说一遍需求") : L10n.T("生成失败，请重试"), true);
            }
        }
        finally
        {
            if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; Raise(); }
            operations.Complete(operation);
        }
    }

    private void DropBeta()
    {
        if (betaSession is not { } id) return;
        var app = betaApp;
        var route = betaOptions?.Route;
        ClearBeta();
        _ = Task.Run(async () => { try { await Client.BetaAsync(id, skip: false, app, route); } catch (ServiceException) { } });
    }

    private void ClearBeta()
    {
        betaSession = null;
        betaOptions = null;
        betaField = null;
        betaPanel?.Hide();
    }

    /// <summary>"删除全部历史": the per-day activity goes with it.</summary>
    public void ClearHistory()
    {
        History.Clear();
        if (History.LastError is not null) { SetHint(L10n.T("历史记录无法读取或安全保存，原文件已保留。请检查系统凭据和文件权限。")); return; }
        Activity.Clear();
        PruneAudio();
        Raise();
    }

    public void CopyLast()
    {
        if (History.Last is { } last) Paster.SetText(last.Text);
    }
}
