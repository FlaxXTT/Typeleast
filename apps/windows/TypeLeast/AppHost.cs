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
    private bool dictionaryNeedsSync = true;

    public AppHost(Application app)
    {
        this.app = app;
        settingsPath = AppPaths.AppSettingsFile();
        Settings = AppSettings.Load(settingsPath);
        L10n.Configure(Settings.InterfaceLanguage);
        History = new LocalHistory(AppPaths.AppHistoryFile());
        Service = new ServiceManager(Client) { NodePathOverride = Settings.NodePath, ModelMirror = Settings.ModelMirror };
        hook = new KeyboardHook(Settings.Hotkey);
        bar = new RecordingBar(this);
    }

    public bool ServiceUp => Health?.Ok == true;
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

        hook.Tapped += () => app.Dispatcher.InvokeAsync(Toggle);
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

    public void Toggle()
    {
        switch (Phase)
        {
            case DictationPhase.Idle: StartRecording(); break;
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
        bar.ShowRecording(recorder);
        Raise();
    }

    public void Cancel()
    {
        if (Phase != DictationPhase.Recording) return;
        recorder.Cancel();
        hook.SwallowEscape = false;
        Phase = DictationPhase.Idle;
        bar.ShowResult(L10n.T("已取消"), warning: false);
        Raise();
    }

    private async Task StopAndSend()
    {
        var (wav, seconds) = recorder.Stop();
        hook.SwallowEscape = false;
        if (seconds < 0.3)
        {
            Phase = DictationPhase.Idle;
            bar.ShowResult(L10n.T("录音太短"), warning: true);
            Raise();
            return;
        }
        Phase = DictationPhase.Thinking;
        bar.ShowThinking();
        Raise();
        try
        {
            var result = await Client.DictateAsync(wav, Settings.Language, targetApp, Settings.Strength, ActiveRoute);
            var text = result.InsertableText.Trim();
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
                var note = Messages.FallbackNote(result.FallbackReason);
                var done = outcome == Paster.Outcome.Pasted ? L10n.T("已粘贴") : L10n.T("窗口已切换，已复制到剪贴板");
                bar.ShowResult(note is null ? done : done + " · " + note, warning: note is not null);
            }
        }
        catch (ServiceException e)
        {
            Log.Write("dictate.fail", (e.Code ?? e.Kind.ToString()) + " " + e.Status);
            bar.ShowResult(e.Code == "speech-not-ready" ? Messages.SpeechProblem(Speech) : L10n.T("听写失败：") + (e.ServiceUnavailable ? L10n.T("本地服务未就绪") : e.Message), warning: true);
        }
        Phase = DictationPhase.Idle;
        Raise();
    }

    public void CopyLast()
    {
        if (History.Last is { } last) Paster.SetText(last.Text);
    }
}
