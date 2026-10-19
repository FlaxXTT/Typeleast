using System;
using System.Linq;
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

    /// <summary>Something the windows show changed (raised on the UI thread).</summary>
    public event Action? Changed;

    private readonly Application app;
    private readonly string settingsPath;
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

    public AppHost(Application app)
    {
        this.app = app;
        settingsPath = AppPaths.AppSettingsFile();
        Settings = AppSettings.Load(settingsPath);
        L10n.Configure(Settings.InterfaceLanguage);
        History = new LocalHistory(AppPaths.AppHistoryFile());
        Activity = new ActivityLog(AppPaths.AppActivityFile());
        // The heatmap starts from whatever history is still kept, once.
        Activity.SeedIfNeeded(History.Entries.Where(e => e.Text.Length > 0)
            .Select(e => (e.Time.LocalDateTime, ActivityLog.CountWords(e.Text))));
        Service = new ServiceManager(Client) { NodePathOverride = Settings.NodePath, ModelMirror = Settings.ModelMirror };
        hook = new KeyboardHook(Settings.Hotkey, Settings.TranslateHotkey);
        bar = new RecordingBar(this);
        if (History.LastError is not null) Hint = L10n.T("历史记录无法读取或安全保存，原文件已保留。请检查系统凭据和文件权限。");
    }

    public bool ServiceUp => Health?.Ok == true;
    public SpeechModelCatalog? SpeechCatalog { get; private set; }
    public SpeechStatus? Speech => Health?.Speech;
    public string HotkeyLabel => TapDetector.Label(Settings.Hotkey);
    public LlmRoute? ActiveRoute => Settings.ActiveRoute(CredentialStore.Read);
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

    public void Start(bool autostart)
    {
        Log.Write("app.start", "version=" + typeof(AppHost).Assembly.GetName().Version);
        Service.Changed += () => app.Dispatcher.InvokeAsync(() =>
        {
            if (Service.State == ServiceManager.Phase.Running) _ = RefreshHealth();
            Raise();
        });
        Service.Start();

        hook.Tapped += () => app.Dispatcher.InvokeAsync(() => Toggle());
        hook.TranslateTapped += () => app.Dispatcher.InvokeAsync(() => ToggleTranslate());
        hook.Escape += () => app.Dispatcher.InvokeAsync(Cancel);
        if (!hook.Install()) Hint = L10n.T("无法注册快捷键，可以用托盘菜单开始听写");
        recorder.LimitReached += () => app.Dispatcher.InvokeAsync(() => { if (Phase == DictationPhase.Recording) _ = StopAndSend(); });

        tray = new Tray(this);
        healthTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        healthTimer.Tick += async (_, _) => await RefreshHealth();
        healthTimer.Start();

        if (!Settings.OnboardingDone || !autostart) ShowWindow(MainWindow.Page.Home);
    }

    public void Quit()
    {
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
    }

    private void Raise() => Changed?.Invoke();

    public void SaveSettings()
    {
        try { Settings.Save(settingsPath); }
        catch (Exception e) { Log.Write("settings.save.fail", e.GetType().Name); }
        hook.SetKey(Settings.Hotkey);
        hook.SetTranslateKey(Settings.TranslateHotkey);
        Service.NodePathOverride = Settings.NodePath;
        Service.ModelMirror = Settings.ModelMirror;
        Raise();
    }

    public void SetHint(string text)
    {
        Hint = text;
        Raise();
    }

    // ---- health and the service

    public async Task RefreshHealth()
    {
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
        Raise();
    }

    public void RestartService()
    {
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
        try
        {
            await Client.PutDictionaryAsync(Settings.Words);
            DictionarySynced = true;
            dictionaryNeedsSync = false;
        }
        catch (ServiceException)
        {
            DictionarySynced = false;
            dictionaryNeedsSync = true;
        }
        Raise();
    }

    public void AddWord(string entry)
    {
        var word = entry.Trim();
        if (word.Length == 0 || Settings.Words.Contains(word)) return;
        Settings.Words.Add(word);
        SaveSettings();
        _ = SyncDictionary();
    }

    public void RemoveWord(string entry)
    {
        Settings.Words.Remove(entry);
        SaveSettings();
        _ = SyncDictionary();
    }

    // ---- dictation

    public void Toggle() => Toggle(null);

    /// <summary>翻译模式's key: starts a recording inserted in the target language; while recording, either key finishes.</summary>
    public void ToggleTranslate() => Toggle(Settings.TranslateTarget);

    private void Toggle(string? translateTo)
    {
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
        if (!ServiceUp)
        {
            bar.ShowResult(Messages.SpeechProblem(Speech) is { Length: > 0 } p ? p : L10n.T("本地服务还没就绪"), warning: true);
            return;
        }
        targetWindow = Native.GetForegroundWindow();
        targetApp = Shell.ProcessName(targetWindow);
        try
        {
            recorder.Start(Settings.MicrophoneDevice);
        }
        catch (InvalidOperationException e)
        {
            Log.Write("mic.fail", e.GetType().Name);
            bar.ShowResult(L10n.T("无法打开麦克风：请在 设置 → 隐私和安全性 → 麦克风 中允许桌面应用访问麦克风"), warning: true);
            return;
        }
        Phase = DictationPhase.Recording;
        hook.SwallowEscape = true;
        bar.ShowRecording(recorder, translating is { } target ? "→" + target.ToUpperInvariant() + " " : "");
        Raise();
    }

    public void Cancel()
    {
        if (Phase != DictationPhase.Recording) return;
        recorder.Cancel();
        hook.SwallowEscape = false;
        translating = null;
        Phase = DictationPhase.Idle;
        bar.ShowResult(L10n.T("已取消"), warning: false);
        Raise();
    }

    private async Task StopAndSend()
    {
        var (wav, seconds) = recorder.Stop();
        hook.SwallowEscape = false;
        var translateTo = translating;
        translating = null;
        if (seconds < 0.3)
        {
            Phase = DictationPhase.Idle;
            bar.ShowResult(L10n.T("录音太短"), warning: true);
            Raise();
            return;
        }
        // A recording made while Prompt Beta's questions are open is the answer to them;
        // a translation is not, and leaves the questions waiting.
        if (translateTo is null && Settings.Strength != "promptbeta" && betaSession is not null) DropBeta();
        var answering = translateTo is null && Settings.Strength == "promptbeta" ? betaSession : null;
        Phase = DictationPhase.Thinking;
        bar.ShowThinking(translateTo is null ? null : L10n.T("翻译中…"));
        Raise();
        try
        {
            var result = await Client.DictateAsync(wav, Settings.Language, targetApp, Settings.Strength, ActiveRoute,
                betaSession: answering, translateTo: translateTo, variants: Settings.VariantsHeader);
            if (ShowBetaQuestions(result))
            {
                Phase = DictationPhase.Idle;
                Raise();
                return;
            }
            if (answering is not null)
            {
                targetWindow = betaWindow;
                targetApp = betaApp;
                ClearBeta();
            }
            await Deliver(result, seconds);
        }
        catch (ServiceException e) when (e.Status == 410 && answering is not null)
        {
            DropBeta();
            bar.ShowResult(L10n.T("问题已过期，请重新说一遍需求"), warning: true);
        }
        catch (ServiceException e)
        {
            Log.Write("dictate.fail", (e.Code ?? e.Kind.ToString()) + " " + e.Status);
            bar.ShowResult(e.Code == "speech-not-ready" ? Messages.SpeechProblem(Speech) : L10n.T("听写失败：") + (e.ServiceUnavailable ? L10n.T("本地服务未就绪") : e.Message), warning: true);
        }
        Phase = DictationPhase.Idle;
        Raise();
    }

    /// <summary>Paste a finished result into the target window and record it.</summary>
    private async Task Deliver(DictateResponse result, double seconds)
    {
        {
            // A terminal gets one line without control characters: this reduces accidental command execution.
            var text = TerminalGuard.SafeText(result.InsertableText.Trim(), targetApp);
            if (text.Length == 0)
            {
                bar.ShowResult(L10n.T("没有听到内容"), warning: true);
            }
            else
            {
                var outcome = await Paster.PasteAsync(text, targetWindow, Settings.RestoreClipboard);
                History.Add(new HistoryEntry
                {
                    Text = text,
                    Raw = result.Raw,
                    App = targetApp,
                    Fallback = result.Fallback,
                    Reason = result.FallbackReason,
                    Seconds = seconds,
                    Inserted = outcome == Paster.Outcome.Pasted,
                });
                if (History.LastError is not null) SetHint(L10n.T("历史记录无法读取或安全保存，原文件已保留。请检查系统凭据和文件权限。"));
                Activity.Record(ActivityLog.CountWords(text), DateTime.Now);
                var note = Messages.FallbackNote(result.FallbackReason);
                var done = outcome == Paster.Outcome.Pasted ? L10n.T("已粘贴") : L10n.T("窗口已切换，已复制到剪贴板");
                bar.ShowResult(note is null ? done : done + " · " + note, warning: note is not null);
            }
        }
    }

    /// <summary>Prompt Beta asked questions: show them and keep the session. True when shown.</summary>
    private bool ShowBetaQuestions(DictateResponse result)
    {
        if (result.Beta?.SessionId is not { } id || result.BetaQuestions.Count == 0) return false;
        betaSession = id;
        betaWindow = targetWindow;
        betaApp = targetApp;
        betaPanel ??= new BetaPanel(() => _ = FinishBetaWithoutAnswers(), DropBeta);
        betaPanel.ShowQuestions(result.BetaQuestions, HotkeyLabel);
        bar.ShowResult(L10n.T("提示词 Beta：先回答面板里的问题"), warning: false);
        return true;
    }

    /// <summary>"跳过，直接生成": write the prompt now; unanswered points go to 「待确认」.</summary>
    private async Task FinishBetaWithoutAnswers()
    {
        if (Phase != DictationPhase.Idle || betaSession is not { } id) return;
        targetWindow = betaWindow;
        targetApp = betaApp;
        ClearBeta();
        Phase = DictationPhase.Thinking;
        bar.ShowThinking();
        Raise();
        try
        {
            await Deliver(await Client.BetaAsync(id, skip: true, targetApp, ActiveRoute, variants: Settings.VariantsHeader), 0);
        }
        catch (ServiceException e)
        {
            Log.Write("beta.fail", (e.Code ?? e.Kind.ToString()) + " " + e.Status);
            bar.ShowResult(e.Status == 410 ? L10n.T("问题已过期，请重新说一遍需求") : L10n.T("听写失败：") + e.Message, warning: true);
        }
        Phase = DictationPhase.Idle;
        Raise();
    }

    /// <summary>Close the questions; the service forgets the session too.</summary>
    private void DropBeta()
    {
        if (betaSession is not { } id) return;
        var app = betaApp;
        var route = ActiveRoute;
        ClearBeta();
        _ = Task.Run(async () => { try { await Client.BetaAsync(id, skip: false, app, route); } catch (ServiceException) { } });
    }

    private void ClearBeta()
    {
        betaSession = null;
        betaPanel?.Hide();
    }

    /// <summary>"删除全部历史": the per-day activity goes with it.</summary>
    public void ClearHistory()
    {
        History.Clear();
        if (History.LastError is not null) { SetHint(L10n.T("历史记录无法读取或安全保存，原文件已保留。请检查系统凭据和文件权限。")); return; }
        Activity.Clear();
        Raise();
    }

    public void CopyLast()
    {
        if (History.Last is { } last) Paster.SetText(last.Text);
    }
}
