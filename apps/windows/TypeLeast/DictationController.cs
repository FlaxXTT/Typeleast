using System;
using System.Threading.Tasks;
using System.Windows;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

internal enum DictationPhase { Idle, Recording, Thinking }

/// <summary>Application resources used by the recording workflow; contains no workflow state.</summary>
internal interface IDictationHost
{
    AppSettings Settings { get; }
    DictionaryController Dictionary { get; }
    LocalHistory History { get; }
    PreferenceExamples Preferences { get; }
    ActivityLog Activity { get; }
    ServiceClient Client { get; }
    bool ServiceUp { get; }
    SpeechStatus? Speech { get; }
    string HotkeyLabel { get; }
    LlmRoute? ActiveRoute { get; }
    RetainedAudio RetainedAudio { get; }
    bool Quitting { get; }
    bool SaveSettings();
    bool CanRetry(HistoryEntry entry);
    void SetHint(string text);
    void Changed();
    void PruneAudio();
}

/// <summary>Owns recording, cancellation, service calls, retry and delivery on the UI thread.</summary>
internal sealed class DictationController
{
    private readonly IDictationHost host;
    private readonly System.Windows.Threading.Dispatcher dispatcher;
    private readonly KeyboardHook hook;
    private readonly RecordingBar bar;
    private readonly AudioRecorder recorder = new();
    private readonly AudioDucking ducking = new();
    private readonly OperationTracker operations = new();
    private readonly BetaController beta;
    private IntPtr targetWindow;
    private string targetApp = "";
    private string? translating;
    private bool assistantRecording;
    private DictationOptions? recordingOptions;
    private FieldTarget? targetField;
    private byte[]? recordingContext;
    private Task<FieldTarget>? targetFieldTask;
    private Task<byte[]?>? recordingContextTask;
    private readonly System.Diagnostics.Stopwatch micClock = new();
    public DictationPhase Phase { get; private set; } = DictationPhase.Idle;
    public bool IsMicrophoneTesting { get; private set; }
    public bool? MicrophoneReady { get; set; }
    public long? LastMicrophoneStartMs { get; private set; }
    public double MicrophoneLevel => recorder.Level;
    public bool HasBeta => beta.Session is not null;
    private bool quitting => host.Quitting;
    private AppSettings Settings => host.Settings;
    private DictionaryController Dictionary => host.Dictionary;
    private LocalHistory History => host.History;
    private PreferenceExamples Preferences => host.Preferences;
    private ActivityLog Activity => host.Activity;
    private ServiceClient Client => host.Client;
    private bool ServiceUp => host.ServiceUp;
    private SpeechStatus? Speech => host.Speech;
    private string HotkeyLabel => host.HotkeyLabel;
    private LlmRoute? ActiveRoute => host.ActiveRoute;
    private RetainedAudio RetainedAudio => host.RetainedAudio;
    private void Raise() => host.Changed();
    private void SetHint(string text) => host.SetHint(text);
    private bool SaveSettings() => host.SaveSettings();
    private void PruneAudio() => host.PruneAudio();
    private bool CanRetry(HistoryEntry entry) => host.CanRetry(entry);

    public DictationController(IDictationHost host, System.Windows.Threading.Dispatcher dispatcher, KeyboardHook hook, RecordingBar bar)
    {
        this.host = host; this.dispatcher = dispatcher; this.hook = hook; this.bar = bar;
        beta = new BetaController(Client, () => _ = FinishBetaWithoutAnswers(), ToggleAssistant);
        recorder.AudioStarted += OnAudioStarted;
        recorder.LimitReached += () => dispatcher.InvokeAsync(() => { if (Phase == DictationPhase.Recording) _ = StopAndSend(); });
        recorder.RecordingFailed += () => dispatcher.InvokeAsync(() => { Cancel(); MicrophoneReady = false; SetHint(L10n.T("麦克风断开或录音出错，请重新选择设备。")); });
    }
    private (string Source, IntPtr Window, string App, FieldTarget? Field, byte[]? Context, DictationOptions Options, string Evidence)? clarificationPending;
    private bool resumeClarification;

    public void Shutdown() { operations.Cancel(); recorder.Cancel(); clarificationPending = null; }

    public bool StartMicrophoneTest()
    {
        if (Phase != DictationPhase.Idle || operations.TryBegin() is not { } operation) return false;
        Dictionary.StopWatching();
        try { micClock.Restart(); LastMicrophoneStartMs = null; recorder.Start(Settings.MicrophoneDevice); MicrophoneReady = true; IsMicrophoneTesting = true; Phase = DictationPhase.Recording; hook.SwallowEscape = true; Raise(); return true; }
        catch (InvalidOperationException) { operations.Complete(operation); MicrophoneReady = false; SetHint(L10n.T("打不开麦克风。请检查设备和权限。")); return false; }
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

    public async Task RetryHistory(HistoryEntry entry, bool withoutPersonalization = false)
    {
        if (Phase != DictationPhase.Idle || entry.Request is not { } request || (withoutPersonalization ? string.IsNullOrEmpty(entry.Raw)||request.Strength=="promptbeta" : !CanRetry(entry))) return;
        if(withoutPersonalization&&ActiveRoute is null){SetHint(L10n.T("请先配置可用的整理模型。"));return;}
        var operation = operations.TryBegin(); if (operation is null) return;
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true; bar.ShowThinking(); Raise();
        byte[]? wav = null;
        try
        {
            DictateResponse result;
            if(withoutPersonalization)result=await Client.PolishAsync(entry.Raw,request.Language,request.Strength,ActiveRoute,request.TranslateTo,request.Variants,Array.Empty<string>(),Array.Empty<string>(),operation.Token,
                explanationMarkers:request.ExplanationMarkers??"",personalization:new {version=1,disabled=true});
            else {
            wav = RetainedAudio.Load(entry.AudioId!);
            result = await Client.DictateAsync(wav, request.Language, entry.App, request.Strength, ActiveRoute,
                ct: operation.Token, translateTo: request.TranslateTo, variants: request.Variants, dictionary: Dictionary.ServiceEntries, localOnly: Dictionary.LocalEntries, explanationMarkers: request.ExplanationMarkers ?? "", preferenceExamples: Preferences.WireExamples, personalization: Preferences.WirePolicy(Settings.DictionaryEntries, withoutPersonalization));
            }
            if (!operations.IsCurrent(operation)) return;
            targetWindow = Native.GetForegroundWindow(); targetApp = entry.App; targetField = null; recordingContext = null;
            var options = new DictationOptions(request.Language, request.Strength, request.TranslateTo, request.Variants, ActiveRoute,
                Settings.RestoreClipboard, "clipboardOnly", ExplanationMarkers: request.ExplanationMarkers ?? "", WithoutPersonalization: withoutPersonalization);
            var confirmed = await ConfirmName(result, options, operation);
            if (confirmed is null) return;
            result = confirmed;
            if (result.ContextOnly) { bar.ShowResult(L10n.T("这次只有解释信息，没有正文，未插入。"), false); return; }
            Paster.SetText(result.InsertableText);
            History.Add(new HistoryEntry { Task = result.Task, Text = result.InsertableText, Raw = result.Raw, App = entry.App,
                Fallback = result.Fallback, Reason = result.FallbackReason, Seconds = entry.Seconds, Personalization=result.Personalization,
                Request = request, AudioId = entry.AudioId });
            bar.ShowResult(L10n.T("已复制"), result.Fallback);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (Exception e) when (e is ServiceException or System.IO.IOException or System.Security.Cryptography.CryptographicException)
        { if (operations.IsCurrent(operation)) bar.ShowResult(L10n.T("重试失败，原记录保留"), true); }
        finally { if (wav is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(wav); if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; } operations.Complete(operation); Raise();
            if (resumeClarification && !quitting) { resumeClarification = false; _ = dispatcher.InvokeAsync(() => Toggle(clarificationPending?.Options.TranslateTo)); }
        }
    }

    public void Toggle() => Toggle(null);

    public void ToggleTranslate() => Toggle(Settings.TranslateTarget);
    public void ToggleAssistant() => Toggle(null, true);

    public void SetStrength(string code, bool announce = false)
    {
        if (code == "promptbeta") ToggleAssistant();
    }

    private void Toggle(string? translateTo, bool assistant = false)
    {
        if (IsMicrophoneTesting) return;
        switch (Phase)
        {
            case DictationPhase.Idle:
                assistantRecording = assistant;
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
            bar.ShowResult(Messages.SpeechProblem(Speech) is { Length: > 0 } p ? p : L10n.T("本地服务未就绪"), warning: true);
            return;
        }
        var operation = operations.TryBegin();
        if (operation is null) return;
        // The microphone opens first: anything slow before it (UI Automation, ducking) would cut
        // the start of what the user says. Only the foreground window, which is instant, is read before.
        micClock.Restart();
        targetWindow = clarificationPending?.Window ?? Native.GetForegroundWindow();
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
            bar.ShowResult(L10n.T("打不开麦克风。请在「设置 → 隐私和安全性 → 麦克风」允许桌面应用"), warning: true);
            return;
        }
        Phase = DictationPhase.Recording;
        // An answer to Prompt Beta: the questions stay visible so the user can answer them one by one.
        if (assistantRecording && beta.Session is not null) beta.SetBusy(L10n.T("正在听。说完按 {0}。", HotkeyLabel));
        hook.SwallowEscape = true;
        bar.ShowRecording(recorder, translating is { } target
            ? L10n.T("翻译") + " →" + target.ToUpperInvariant()
            : L10n.T(assistantRecording ? "需求助手" : "听写"));
        Raise();
        Dictionary.DictationStarting();
        recordingOptions = new DictationOptions(Settings.Language, assistantRecording ? "promptbeta" : "prompt", translating, Settings.VariantsHeader, ActiveRoute, Settings.RestoreClipboard, Settings.InsertionMode, Settings.FormattedLists, Settings.LearnCorrections, Settings.ExplanationMarkers);
        targetApp = Shell.ProcessName(targetWindow);
        var window = targetWindow;
        if (clarificationPending is not null) { targetFieldTask = null; recordingContextTask = null; }
        else {
            targetFieldTask = Task.Run(() => FieldTarget.CaptureFor(window));
            recordingContextTask = Settings.UseFieldContext ? targetFieldTask.ContinueWith(t => FieldContextReader.Read(t.Result), TaskScheduler.Default) : null;
        }
        if (Settings.MuteOtherAudio) ducking.Start();
    }

    private void OnAudioStarted()
    {
        var ms = micClock.ElapsedMilliseconds;
        dispatcher.InvokeAsync(() =>
        {
            if (Phase != DictationPhase.Recording) return;
            LastMicrophoneStartMs = ms;
            Log.Write("mic.ready", ms.ToString(System.Globalization.CultureInfo.InvariantCulture));
            if (Settings.PlaySounds && !IsMicrophoneTesting) Sounds.Start();
            Raise();
        });
    }

    private static async Task<T?> Within<T>(Task<T>? task, int ms) where T : class?
    {
        if (task is null) return null;
        if (await Task.WhenAny(task, Task.Delay(ms)) != task || !task.IsCompletedSuccessfully) return null;
        return task.Result;
    }

    public void Cancel()
    {
        clarificationPending = null; resumeClarification = false;
        Dictionary.StopWatching();
        ducking.Dispose(); IsMicrophoneTesting = false;
        var preserveBeta = Phase == DictationPhase.Recording && beta.Session is not null;
        var lease = operations.Active;
        operations.Cancel();
        recorder.Cancel();
        if (Phase == DictationPhase.Recording && lease is not null) lease.Dispose();
        hook.SwallowEscape = false;
        translating = null;
        Phase = DictationPhase.Idle;
        if (preserveBeta) beta.Resume(); else DropBeta();
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
        var held = clarificationPending;
        clarificationPending = null;
        if (held is { } prior) {
            options = prior.Options;
            targetWindow = prior.Window; targetApp = prior.App; targetField = prior.Field;
        }
        var translateTo = options.TranslateTo;
        translating = null;
        if (seconds < 0.3)
        {
            operations.Complete(operation);
            Phase = DictationPhase.Idle;
            bar.ShowResult(L10n.T("录音太短"), warning: true);
            if (beta.Session is not null) beta.Resume();
            Raise();
            return;
        }
        // A recording made while Prompt Beta's questions are open is the answer to them;
        // a translation is not, and leaves the questions waiting.
        var answering = translateTo is null && options.Strength == "promptbeta" ? beta.Session : null;
        if (answering is not null) beta.SetBusy(L10n.T("正在更新…"));
        Phase = DictationPhase.Thinking;
        hook.SwallowEscape = true;
        bar.ShowThinking(translateTo is null ? L10n.T(options.Strength == "promptbeta" ? "需求助手" : "正在整理…") : L10n.T("正在翻译…"));
        Raise();
        targetField = held is { } original ? original.Field : await Within(targetFieldTask, 300);
        recordingContext = held is { } originalContext ? originalContext.Context : await Within(recordingContextTask, 300);
        targetFieldTask = null; recordingContextTask = null;
        if (!operations.IsCurrent(operation)) return;
        try
        {
            var requestOptions = answering is not null ? beta.Options ?? options : options;
            var result = await Client.DictateAsync(wav, requestOptions.Language, targetApp, requestOptions.Strength, requestOptions.Route,
                fieldContext: recordingContext, ct: operation.Token, betaSession: answering, translateTo: translateTo, variants: requestOptions.Variants,
                dictionary: Dictionary.ServiceEntries, localOnly: Dictionary.LocalEntries, clarificationSource: held?.Source, clarificationEvidence: held?.Evidence, explanationMarkers: requestOptions.ExplanationMarkers, preferenceExamples: Preferences.WireExamples, personalization: Preferences.WirePolicy(Settings.DictionaryEntries, requestOptions.WithoutPersonalization),
                onProgress: progress => dispatcher.InvokeAsync(() => { if (operations.IsCurrent(operation) && Phase == DictationPhase.Thinking) bar.ShowThinking(progress.Label); }));
            if (!operations.IsCurrent(operation)) return;
            if (result.ContextOnly) { bar.ShowResult(L10n.T("这次只有解释信息，没有正文，未插入。"), false); return; }
            var confirmed = await ConfirmName(result, requestOptions, operation);
            if (confirmed is null) return;
            result = confirmed;
            if (result.ContextOnly) { bar.ShowResult(L10n.T("这次只有解释信息，没有正文，未插入。"), false); return; }
            if (ShowBetaQuestions(result, requestOptions)) return;
            if (answering is not null)
            {
                targetWindow = beta.Window;
                targetApp = beta.App;
                targetField = beta.Field;
                ClearBeta();
            }
            await Deliver(result, seconds, operation, requestOptions, answering is null ? wav : null);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException e) when (e.Status == 410 && answering is not null)
        {
            if (!operations.IsCurrent(operation)) return;
            DropBeta();
            bar.ShowResult(L10n.T("问题已过期，请重新说需求"), warning: true);
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
                if (beta.Session is not null) beta.Resume();
                Raise();
            }
            operations.Complete(operation);
            if (resumeClarification && !quitting) {
                resumeClarification = false;
                _ = dispatcher.InvokeAsync(() => Toggle(clarificationPending?.Options.TranslateTo));
            }
        }
    }

    private async Task<DictateResponse?> ConfirmName(DictateResponse result, DictationOptions options, OperationTracker.Lease operation)
    {
        while (result.Clarification is { } clarification) {
            options = options with {WithoutPersonalization=clarification.PersonalizationDisabled??options.WithoutPersonalization};
            bar.Hide();
            var choice = await NameConfirmationPanel.Show(clarification.Kind=="quality"?CleanupIssue.Message(clarification.Reason):L10n.T("需要确认：{0}", clarification.Evidence), clarification.Kind=="quality"?(clarification.Candidate??result.Raw):result.Raw, operation.Token, clarification.Kind);
            if (!operations.IsCurrent(operation)) return null;
            if (choice.Kind == "cancel") { bar.ShowResult(L10n.T("已取消"), false); return null; }
            if (choice.Kind == "supplement") {
                clarificationPending = (result.Raw, targetWindow, targetApp, targetField, recordingContext, options, clarification.Evidence);
                resumeClarification = true;
                return null;
            }
            if (choice.Kind == "original") {
                result.Text = result.Raw; result.Clarification = null; result.Suggestions.Clear(); break;
            }
            if(clarification.Kind=="quality"&&choice.Kind=="edit") {result.Text=choice.Text;result.Clarification=null;result.Fallback=false;result.FallbackReason=null;break;}
            result = await Client.PolishAsync(choice.Kind=="retry"?result.Raw:choice.Text, options.Language, options.Strength, options.Route,
                clarification.Target, options.Variants, Dictionary.ServiceEntries, Dictionary.LocalEntries, operation.Token, fieldContext: recordingContext, explanationMarkers: clarification.MarkerId ?? options.ExplanationMarkers, preferenceExamples: Preferences.WireExamples, personalization: Preferences.WirePolicy(Settings.DictionaryEntries, options.WithoutPersonalization));
            if (!operations.IsCurrent(operation)) return null;
        }
        return result;
    }

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
                    if (!operations.IsCurrent(operation)) return;
                    // Closing the preview cancels: replace the "thinking" pill, which would otherwise stay on screen.
                    if (preview is null) { bar.ShowResult(L10n.T("已取消"), warning: false); return; }
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
                    Task = result.Task,
                    Personalization = result.Personalization,
                    Text = text,
                    Raw = result.Raw,
                    App = targetApp,
                    Fallback = result.Fallback,
                    Reason = result.FallbackReason,
                    Seconds = seconds,
                    Inserted = outcome == Paster.Outcome.Pasted,
                    Request = new HistoryRequest(options.Language, options.Strength, options.TranslateTo, options.Variants, options.ExplanationMarkers),
                };
                if (wav is not null && Settings.KeepAudio24h && Settings.HistoryRetention != "never" && options.Strength != "promptbeta")
                {
                    try { RetainedAudio.Save(entry.Id, wav); entry.AudioId = entry.Id; }
                    catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException) { SetHint(L10n.T("录音未能保留，文字仍可用。")); }
                }
                History.Add(entry); PruneAudio();
                // Terms the cleanup model corrected become suggestions on the Dictionary page.
                if (!result.Fallback && options.TranslateTo is null) Dictionary.Received(result.Suggestions);
                if (outcome == Paster.Outcome.Pasted && options.LearnCorrections && targetField is { } field)
                    Dictionary.Pasted(field, text, corrected => Preferences.Offer(entry.Id, entry.Raw, result.Text, corrected));
                if (History.LastError is not null) SetHint(L10n.T("历史无法读写，文件已保留。请检查文件权限。"));
                Activity.Record(ActivityLog.CountWords(text), DateTime.Now);
                var note = result.Uncertain ? L10n.T("已插入，可能有误，可在历史中修改") : Messages.FallbackNote(result.FallbackReason);
                var done = Paster.Message(outcome);
                bar.ShowResult(note is null ? done : done + " · " + note, warning: note is not null);
            }
        }
    }

    private bool ShowBetaQuestions(DictateResponse result, DictationOptions options)
    {
        if (!beta.Show(result, options, targetWindow, targetApp, targetField, Settings.AssistantHotkey is { } key ? TapDetector.Label(key) : L10n.T("继续补充按钮"))) return false;
        bar.ShowResult(L10n.T("需求助手：继续补充或生成"), warning: false);
        return true;
    }

    private async Task FinishBetaWithoutAnswers()
    {
        if (Phase != DictationPhase.Idle || beta.Session is not { } id || beta.Options is not { } options) return;
        var operation = operations.TryBegin();
        if (operation is null) return;
        targetWindow = beta.Window; targetApp = beta.App; targetField = beta.Field;
        beta.Hide();
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true;
        bar.ShowThinking(); Raise();
        try
        {
            var result = await Client.BetaAsync(id, true, targetApp, options.Route, operation.Token, options.Variants);
            if (operations.IsCurrent(operation)) {
                if (ShowBetaQuestions(result, options)) return;
                ClearBeta();
                await Deliver(result, 0, operation, options);
            }
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException e)
        {
            if (operations.IsCurrent(operation)) {
                if (e.Status == 410) ClearBeta(); else beta.Resume();
                bar.ShowResult(e.Status == 410 ? L10n.T("问题已过期，请重新说需求") : L10n.T("生成失败，请重试"), true);
            }
        }
        finally
        {
            if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; Raise(); }
            operations.Complete(operation);
        }
    }

    public void DropBeta() => beta.Drop();

    private void ClearBeta() => beta.Clear();
}
