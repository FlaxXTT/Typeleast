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
/// and composition of the feature controllers. Everything
/// that touches the UI runs on the UI thread.
/// </summary>
internal sealed class AppHost : IDictationHost
{

    public AppSettings Settings { get; }
    /// <summary>The dictionary: editing, learning, suggestions (DictionaryController).</summary>
    public DictionaryController Dictionary { get; }
    /// <summary>In-app updates (UpdateController).</summary>
    public UpdateController Updates { get; }
    /// <summary>Installed plugins and the official catalog (Extensions page, style picker).</summary>
    public PluginController Plugins { get; }

    /// <summary>Why an update must wait (a dictation, Prompt Beta's questions), or null.</summary>
    private string? UpdateBlocker() =>
        onboarding?.PracticeBusy == true ? L10n.T("练习结束后再更新。") :
        Phase != DictationPhase.Idle ? L10n.T("听写结束后再更新。")
        // Quitting would drop the questions and the answers given so far.
        : dictation.HasBeta ? L10n.T("更新前，请先生成或取消需求助手。") : null;
    public LocalHistory History { get; }
    public ActivityLog Activity { get; }
    public ServiceClient Client { get; } = new();
    public ServiceManager Service { get; }
    public HealthResponse? Health { get; private set; }
    public DictationPhase Phase => dictation.Phase;
    public string Hint { get; private set; } = "";
    public string? SettingsSaveError { get; private set; }

    /// <summary>Something the windows show changed (raised on the UI thread).</summary>
    public event Action? Changed;
    /// <summary>A setting change could not be saved and was undone: pages showing it are rebuilt.</summary>
    public event Action? SettingsReverted;

    private readonly Application app;
    private readonly string settingsPath;
    private string savedSettingsJson = "{}";
    private readonly KeyboardHook hook;
    private readonly RecordingBar bar;
    private readonly DictationController dictation;
    private MainWindow? window;
    private Tray? tray;
    private DispatcherTimer? healthTimer;
    private DateTime lastHousekeeping = DateTime.MinValue;
    private bool quitting;
    public bool QuittingForSetup => quitting;
    private bool refreshing;
    public PreferenceExamples Preferences { get; }
    public RetainedAudio RetainedAudio { get; }
    public long? LastMicrophoneStartMs => dictation.LastMicrophoneStartMs;
    private IdleBar? idleBar;
    private Onboarding? onboarding;
    private bool started;
    public bool IsMicrophoneTesting => dictation.IsMicrophoneTesting;
    public bool? MicrophoneReady { get => dictation.MicrophoneReady; private set => dictation.MicrophoneReady = value; }
    public bool? HotkeyReady { get; private set; }
    public double MicrophoneLevel => dictation.MicrophoneLevel;

    public ICredentialStore Credentials { get; }
    public AppHost(Application app, ICredentialStore? credentials = null)
    {
        this.app = app;
        Credentials = credentials ?? new WindowsCredentials();
        PrivateStorage.EnsureDirectory(AppPaths.StateDirectory());
        settingsPath = AppPaths.AppSettingsFile();
        Settings = AppSettings.Load(settingsPath);
        Preferences = new PreferenceExamples(System.IO.Path.Combine(AppPaths.StateDirectory(), "app-preferences.sealed"));
        var vocabularyCleanupFailed = false;
        if (Preferences.VocabularyRemovalComplete && !Settings.PersistenceBlocked) {
            try { Settings.Save(settingsPath); }
            catch { vocabularyCleanupFailed = true; }
        }
        Dictionary = new DictionaryController(Settings);
        Plugins = new PluginController(Client, () => Settings.UpdateSource);
        Updates = new UpdateController(Settings, app.Dispatcher, UpdateBlocker, () => quitting, SetHint, Raise, Quit);
        savedSettingsJson = System.Text.Json.JsonSerializer.Serialize(Settings, Json.Options);
        L10n.Configure(Settings.InterfaceLanguage);
        Theme.Apply(Settings.Appearance);
        Preferences.Changed += Raise;
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
        hook.SetAssistantKey(Settings.AssistantHotkey);
        bar = new RecordingBar(this);
        dictation = new DictationController(this, app.Dispatcher, hook, bar);
        bar.IsVisibleChanged += (_, _) => UpdateIdleBar();
        if (vocabularyCleanupFailed) {
            SettingsSaveError = L10n.T("设置未保存。请检查文件权限和磁盘空间。");
            Hint = SettingsSaveError;
        }
        if (Settings.PersistenceBlocked) Hint = L10n.T("设置文件无法读取，文件已保留，暂不覆盖。");
        if (Activity.LastError is not null) Hint = L10n.T("活动文件无法读取，文件已保留。");
        if (History.LastError is not null) Hint = L10n.T("历史无法读写，文件已保留。请检查文件权限。");
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
            if (!LlmConfigured) return L10n.T("没有整理模型（只去口头禅）");
            var preset = Settings.Preset;
            return preset.Name + " · " + Settings.LlmModel + (preset.Id == "ollama" ? L10n.T("（本机）") : L10n.T("（你的 Key）"));
        }
    }

    public string ServiceSummary => Service.State switch
    {
        ServiceManager.Phase.Running => ServiceUp ? L10n.T("本地服务就绪") : (Messages.SpeechProblem(Speech) is { Length: > 0 } p ? p : L10n.T("本地服务运行中")),
        ServiceManager.Phase.Starting => L10n.T("本地服务启动中…"),
        ServiceManager.Phase.Stopped => L10n.T("本地服务已停止"),
        _ => Service.Detail,
    };

    // ---- lifecycle

    public void Start(bool autostart)
    {
        if (started) return;
        started = true;
        _ = Updates.AutoCheck();
        Microsoft.Win32.SystemEvents.UserPreferenceChanged += SystemAppearanceChanged;
        Microsoft.Win32.SystemEvents.PowerModeChanged += PowerModeChanged;
        Log.Write("app.start", "version=" + typeof(AppHost).Assembly.GetName().Version);
        Service.Changed += () => app.Dispatcher.InvokeAsync(() =>
        {
            if (Service.State == ServiceManager.Phase.Running) { _ = RefreshHealth(); _ = Plugins.Refresh(); }
            Raise();
        });
        Service.Start();

        hook.Tapped += () => app.Dispatcher.InvokeAsync(() => Toggle());
        hook.PasteLast += () => app.Dispatcher.InvokeAsync(() => _ = PasteLast());
        hook.CopyShortcut = Settings.PasteLastShortcut;
        hook.AssistantTapped += () => app.Dispatcher.InvokeAsync(() => ToggleAssistant());
        hook.TranslateTapped += () => app.Dispatcher.InvokeAsync(() => ToggleTranslate());
        hook.Escape += () => app.Dispatcher.InvokeAsync(Cancel);
        HotkeyReady = hook.Install();
        if (HotkeyReady != true) Hint = L10n.T("无法注册快捷键，请用托盘菜单听写");

        tray = new Tray(this);
        JumpList.Update(Settings.Strength);
        healthTimer = new DispatcherTimer { Interval = HealthPolling.Busy };
        healthTimer.Tick += async (_, _) => await RefreshHealth();
        healthTimer.Start();

        // The 登录启动 switch shows what Windows will do at login, also after a change in Task Manager.
        if (Autostart.Check() is bool startsWithWindows && startsWithWindows != Settings.LaunchAtLogin)
        {
            Settings.LaunchAtLogin = startsWithWindows;
            SaveSettings();
        }
        Dictionary.Received(Array.Empty<SuggestionCandidate>());
        if (!Settings.NeedsPractice && (!Settings.OnboardingDone || !autostart)) ShowWindow(MainWindow.Page.Home);
        if (!Settings.OnboardingDone) ShowOnboarding();
        UpdateIdleBar();
    }

    public void Quit()
    {
        quitting = true;
        Microsoft.Win32.SystemEvents.UserPreferenceChanged -= SystemAppearanceChanged;
        Microsoft.Win32.SystemEvents.PowerModeChanged -= PowerModeChanged;
        // Retry recordings do not outlive the app.
        try { RetainedAudio.Prune(Array.Empty<string>()); } catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { }
        idleBar?.Hide();
        onboarding?.Close();
        Cancel();
        dictation.DropBeta();
        healthTimer?.Stop();
        dictation.Shutdown();
        hook.Dispose();
        Service.Stop();
        tray?.Dispose();
        app.Shutdown();
    }

    public void ShowWindow(MainWindow.Page page)
    {
        if (Settings.NeedsPractice && page != MainWindow.Page.Settings) { ShowOnboarding(); return; }
        window ??= new MainWindow(this);
        _ = RefreshHealth();
        window.ShowPage(page);
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        _ = Updates.AutoCheck();
    }

    private void Raise() { UpdateIdleBar(); Changed?.Invoke(); }
    /// <summary>Asleep, the regular check did not run: drop the retry recordings that expired meanwhile.</summary>
    private void PowerModeChanged(object sender, Microsoft.Win32.PowerModeChangedEventArgs e)
    {
        if (e.Mode == Microsoft.Win32.PowerModes.Resume) app.Dispatcher.InvokeAsync(() => { if (!quitting) PruneAudio(); });
    }

    private void SystemAppearanceChanged(object sender, Microsoft.Win32.UserPreferenceChangedEventArgs e)
        => app.Dispatcher.InvokeAsync(() => { if (!quitting && Settings.Appearance == "system") Theme.Apply("system"); });
    private void UpdateIdleBar()
    {
        if (!started || quitting) return;
        if (!Settings.NeedsPractice && Settings.ShowIdleBar && Phase == DictationPhase.Idle && !bar.IsVisible)
        { idleBar ??= new IdleBar(this); if (!idleBar.IsVisible) idleBar.Show(); }
        else idleBar?.Hide();
    }
    public bool CompleteOnboarding(bool practiced)
    {
        if(Settings.NeedsPractice&&(!practiced||string.IsNullOrEmpty(Settings.ExplanationMarkers)))return false;
        var previous=Settings.OnboardingDone;var gate=Settings.PracticeGateRequired;
        Settings.OnboardingDone=true;Settings.PracticeGateRequired=false;
        if(!SaveSettings()){Settings.OnboardingDone=previous;Settings.PracticeGateRequired=gate;return false;}
        ShowWindow(MainWindow.Page.Home);return true;
    }

    public void ShowOnboarding()
    {
        if (onboarding is null) { onboarding = new Onboarding(this); onboarding.Closed += (_, _) => onboarding = null; }
        onboarding.Show(); onboarding.Activate();
    }

    public bool SaveSettings()
    {
        if (!Settings.LearnCorrections) Dictionary.StopWatching();
        try { Settings.Save(settingsPath); savedSettingsJson = System.Text.Json.JsonSerializer.Serialize(Settings, Json.Options); }
        catch (Exception e) {
            var restored = System.Text.Json.JsonSerializer.Deserialize<AppSettings>(savedSettingsJson, Json.Options)!;
            foreach (var property in typeof(AppSettings).GetProperties().Where(p => p.SetMethod?.IsPublic == true && !p.IsDefined(typeof(System.Text.Json.Serialization.JsonIgnoreAttribute), true))) property.SetValue(Settings, property.GetValue(restored));
            SettingsSaveError = L10n.T("设置未保存。请检查文件权限和磁盘空间。");
            Log.Write("settings.save.fail", e.GetType().Name); SetHint(L10n.T("设置未保存。请检查文件权限和磁盘空间。"));
            SettingsReverted?.Invoke(); return false; }
        SettingsSaveError = null;
        Theme.Apply(Settings.Appearance);
        if (window is not null) window.ShowInTaskbar = Settings.ShowInTaskbar;
        hook.CopyShortcut = Settings.PasteLastShortcut;
        hook.SetKey(Settings.Hotkey);
        if (Settings.AssistantHotkey == Settings.Hotkey || Settings.AssistantHotkey == Settings.TranslateHotkey) Settings.AssistantHotkey = null;
        hook.SetAssistantKey(Settings.AssistantHotkey);
        hook.SetTranslateKey(Settings.TranslateHotkey);
        Service.NodePathOverride = Settings.NodePath;
        Service.ModelMirror = Settings.ModelMirror;
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
        // Retry recordings live five minutes; this runs at least every 30 seconds.
        if (Settings.KeepAudio24h) PruneAudio();
        if (DateTime.UtcNow - lastHousekeeping >= HealthPolling.Housekeeping)
        {
            lastHousekeeping = DateTime.UtcNow;
            History.ApplyRetention(Settings.HistoryRetention); PruneAudio();
        }
        refreshing = true;
        try
        {
            Health = await Client.HealthAsync();
            try { SpeechCatalog = await Client.GetSpeechModelsAsync(); } catch (ServiceException) { SpeechCatalog = null; }
        }
        catch (ServiceException)
        {
            Health = null;
        }
        finally { refreshing = false; }
        if (healthTimer is not null)
            healthTimer.Interval = HealthPolling.Interval(Health is not null, Health?.Speech?.Phase, SpeechCatalog?.Operation?.Phase);
        Raise();
    }

    public void RestartService()
    {
        Cancel();
        dictation.DropBeta();
        Health = null;
        Service.NodePathOverride = Settings.NodePath;
        Service.ModelMirror = Settings.ModelMirror;
        Service.Restart();
        SetHint(L10n.T("正在重启本地服务…"));
    }

    public Task DownloadModels()
    {
        ShowWindow(MainWindow.Page.Settings);
        window?.Open(SettingsGuide.Entries[3]);
        return Task.CompletedTask;
    }

    /// <summary>Download again after a failure: the model whose download failed, else the default one.</summary>
    public Task RetryModelDownload() =>
        (Speech?.Operation ?? SpeechCatalog?.Operation) is { Phase: "error" } op ? ManageSpeechModel(op.ModelId, download: true) : DownloadModels();

    public async Task ManageSpeechModel(string id, bool download = false, bool cancel = false)
    {
        if (!cancel && Phase != DictationPhase.Idle) return;
        try { await Client.SpeechModelActionAsync(id, download, cancel, Settings.ModelMirror); await RefreshHealth(); }
        catch (ServiceException) { SetHint(L10n.T("模型操作失败，请重试。当前模型保留。")); }
    }

    private void PruneAudio()
    {
        try { RetainedAudio.Prune(Settings.KeepAudio24h && Settings.HistoryRetention != "never" ? History.Entries.Select(e => e.AudioId).OfType<string>() : Array.Empty<string>()); }
        catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException) { SetHint(L10n.T("无法删除保留的录音。请检查文件权限。")); }
    }
    public void DeleteHistory(string id) { History.Remove(id); PruneAudio(); Raise(); }
    public bool CanRetry(HistoryEntry entry)
    {
        try { return Settings.KeepAudio24h && entry.Request is { Strength: not "promptbeta" } && RetainedAudio.Available(entry.AudioId); }
        catch (Exception) { return false; }
    }

    public bool StartMicrophoneTest() => onboarding?.PracticeBusy != true && dictation.StartMicrophoneTest();
    public void EndMicrophoneTest() => dictation.EndMicrophoneTest();
    public Task PasteLast() { if(onboarding?.PracticeActive==true || onboarding?.PracticeBusy==true)return Task.CompletedTask; if(Settings.NeedsPractice){ShowOnboarding();return Task.CompletedTask;}return dictation.PasteLast(); }
    public Task RetryHistory(HistoryEntry entry, bool withoutPersonalization = false) { if(Settings.NeedsPractice){ShowOnboarding();return Task.CompletedTask;}return dictation.RetryHistory(entry, withoutPersonalization); }
    public void Toggle() {
        if(onboarding?.PracticeActive==true){onboarding.HandleShortcut();return;}
        if(Settings.NeedsPractice){ShowOnboarding();return;}dictation.Toggle();
    }
    public void ToggleTranslate() { if(onboarding?.PracticeActive==true || onboarding?.PracticeBusy==true)return; if(Settings.NeedsPractice){ShowOnboarding();return;}dictation.ToggleTranslate(); }
    public void ToggleAssistant() { if(onboarding?.PracticeActive==true || onboarding?.PracticeBusy==true)return; if(Settings.NeedsPractice){ShowOnboarding();return;}dictation.ToggleAssistant(); }
    public void SetStrength(string code, bool announce = false) => dictation.SetStrength(code, announce);
    public void Cancel() { if(onboarding?.PracticeBusy==true)onboarding.CancelPractice();else dictation.Cancel(); }
    bool IDictationHost.Quitting => quitting;
    void IDictationHost.Changed() => Raise();
    void IDictationHost.PruneAudio() => PruneAudio();

    /// <summary>"删除全部历史": the per-day activity goes with it.</summary>
    public void UndoReplacement(HistoryEntry entry) {
        if(entry.Personalization?.BeforeReplacements is not {} original)return;
        entry.Text=original;entry.Personalization.BeforeReplacements=null;entry.Personalization.Restored=true;History.Update(entry);Paster.SetText(original);
        SetHint(L10n.T("已恢复历史结果并复制；其他程序中已粘贴的文字需自行替换。"));
    }
    public void ClearHistory()
    {
        History.Clear();
        Preferences.ClearPending();
        if (History.LastError is not null) { SetHint(L10n.T("历史无法读写，文件已保留。请检查文件权限。")); return; }
        Activity.Clear();
        PruneAudio();
        Raise();
    }

    public void CopyLast()
    {
        if (History.Last is { } last) Paster.SetText(last.Text);
    }
}
