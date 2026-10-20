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
    private readonly OperationTracker operations = new();
    private DictationOptions? recordingOptions;
    private bool quitting;
    private bool refreshing;
    private bool syncing;
    private DictationOptions? betaOptions;
    public RetainedAudio RetainedAudio { get; }
    private FieldTarget? targetField;
    private byte[]? recordingContext;
    private readonly EditLearner learner = new();
    private FieldTarget? betaField;

    public AppHost(Application app)
    {
        this.app = app;
        PrivateStorage.EnsureDirectory(AppPaths.StateDirectory());
        settingsPath = AppPaths.AppSettingsFile();
        Settings = AppSettings.Load(settingsPath);
        L10n.Configure(Settings.InterfaceLanguage);
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
        quitting = true;
        Cancel();
        DropBeta();
        healthTimer?.Stop();
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

    public bool SaveSettings()
    {
        if (!Settings.LearnCorrections) learner.Stop();
        Settings.Words = Settings.DictionaryEntries.Select(e => e.ServiceValue).ToList();
        try { Settings.Save(settingsPath); }
        catch (Exception e) { Log.Write("settings.save.fail", e.GetType().Name); SetHint(L10n.T("设置未能保存，请检查文件权限和可用空间。")); return false; }
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
        if (quitting) return;
        if (!ServiceUp)
        {
            bar.ShowResult(Messages.SpeechProblem(Speech) is { Length: > 0 } p ? p : L10n.T("本地服务还没就绪"), warning: true);
            return;
        }
        var operation = operations.TryBegin();
        if (operation is null) return;
        learner.Stop();
        recordingOptions = new DictationOptions(Settings.Language, Settings.Strength, translating, Settings.VariantsHeader, ActiveRoute, Settings.RestoreClipboard, Settings.InsertionMode, Settings.FormattedLists, Settings.LearnCorrections);
        targetField = FieldTarget.Capture();
        targetWindow = targetField.Window;
        recordingContext = Settings.UseFieldContext ? FieldContextReader.Read(targetField) : null;
        targetApp = Shell.ProcessName(targetWindow);
        try
        {
            recorder.Start(Settings.MicrophoneDevice);
        }
        catch (InvalidOperationException e)
        {
            operations.Complete(operation);
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
        learner.Stop();
        var lease = operations.Active;
        operations.Cancel();
        recorder.Cancel();
        if (Phase == DictationPhase.Recording && lease is not null) lease.Dispose();
        hook.SwallowEscape = false;
        translating = null;
        Phase = DictationPhase.Idle;
        DropBeta();
        bar.ShowResult(L10n.T("已取消"), warning: false);
        Raise();
    }

    private async Task StopAndSend()
    {
        if (operations.Active is not { } operation || recordingOptions is not { } options) return;
        var (wav, seconds) = recorder.Stop();
        hook.SwallowEscape = false;
        var translateTo = options.TranslateTo;
        translating = null;
        if (seconds < 0.3)
        {
            operations.Complete(operation);
            Phase = DictationPhase.Idle;
            bar.ShowResult(L10n.T("录音太短"), warning: true);
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
        try
        {
            var requestOptions = answering is not null ? betaOptions ?? options : options;
            var result = await Client.DictateAsync(wav, requestOptions.Language, targetApp, requestOptions.Strength, requestOptions.Route,
                fieldContext: recordingContext, ct: operation.Token, betaSession: answering, translateTo: translateTo, variants: requestOptions.Variants);
            if (!operations.IsCurrent(operation)) return;
            if (ShowBetaQuestions(result))
            {
                betaOptions = options;
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
            if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; Raise(); }
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
                    : await Paster.PasteAsync(text, targetWindow, options.RestoreClipboard, operation.Token, targetField, options.FormattedLists && TerminalGuard.SafeText("a\nb", targetApp).Contains('\n'));
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
        betaField = targetField;
        betaPanel ??= new BetaPanel(() => _ = FinishBetaWithoutAnswers(), DropBeta);
        betaPanel.ShowQuestions(result.BetaQuestions, HotkeyLabel);
        bar.ShowResult(L10n.T("提示词 Beta：先回答面板里的问题"), warning: false);
        return true;
    }

    /// <summary>"跳过，直接生成": write the prompt now; unanswered points go to 「待确认」.</summary>
    private async Task FinishBetaWithoutAnswers()
    {
        if (Phase != DictationPhase.Idle || betaSession is not { } id || betaOptions is not { } options) return;
        var operation = operations.TryBegin();
        if (operation is null) return;
        targetWindow = betaWindow; targetApp = betaApp; targetField = betaField;
        ClearBeta();
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true;
        bar.ShowThinking(); Raise();
        try
        {
            var result = await Client.BetaAsync(id, true, targetApp, options.Route, operation.Token, options.Variants);
            if (operations.IsCurrent(operation)) await Deliver(result, 0, operation, options);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException e)
        {
            if (operations.IsCurrent(operation)) bar.ShowResult(e.Status == 410 ? L10n.T("问题已过期，请重新说一遍需求") : L10n.T("生成失败，请重试"), true);
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
