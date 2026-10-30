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
    LocalHistory History { get; }
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
    /// <summary>提示词模式's draft: the text selected when a new conversation starts.</summary>
    private Task<string?>? baselineTask;
    private readonly System.Diagnostics.Stopwatch micClock = new();
    /// <summary>A dictation cancelled a moment ago, kept in memory until 撤销 sends it on or the toast goes away.</summary>
    private (byte[] Wav, double Seconds, DictationOptions Options, IntPtr Window, string App, Task<FieldTarget>? Field, Task<byte[]?>? Context)? cancelled;
    private LearnedToast? cancelToast;
    public DictationPhase Phase { get; private set; } = DictationPhase.Idle;
    public bool IsMicrophoneTesting { get; private set; }
    public bool? MicrophoneReady { get; set; }
    public long? LastMicrophoneStartMs { get; private set; }
    public double MicrophoneLevel => recorder.Level;
    public bool HasBeta => beta.Session is not null;
    private bool quitting => host.Quitting;
    private AppSettings Settings => host.Settings;
    private LocalHistory History => host.History;
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
        beta = new BetaController(Client, () => _ = FinishBetaWithoutAnswers(), ToggleAssistant, text => _ = AnswerBeta(text));
        recorder.AudioStarted += OnAudioStarted;
        recorder.LimitReached += () => dispatcher.InvokeAsync(() => { if (Phase == DictationPhase.Recording) _ = StopAndSend(); });
        recorder.RecordingFailed += () => dispatcher.InvokeAsync(() => { Cancel(); MicrophoneReady = false; SetHint(L10n.T("麦克风断开或录音出错，请重新选择设备。")); });
    }
    public void Shutdown() { operations.Cancel(); recorder.Cancel(); cancelToast?.Finish(); DropCancelled(); }

    public bool StartMicrophoneTest()
    {
        if (Phase != DictationPhase.Idle || operations.TryBegin() is not { } operation) return false;
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
        var app = Shell.ProcessName(field.Window);
        var text = TerminalGuard.IsTerminal(app) ? TerminalGuard.SafeText(last.Text, app)
            : FormattedText.SeparatingList(last.Text, await Within(Task.Run(() => FieldContextReader.Before(field)), 300));
        var result = await Paster.PasteAsync(text, field.Window, true);
        if (result != Paster.Outcome.Pasted) SetHint(Paster.Message(result));
    }

    public async Task RetryHistory(HistoryEntry entry)
    {
        if (Phase != DictationPhase.Idle || entry.Request is not { } request || !CanRetry(entry)) return;
        var operation = operations.TryBegin(); if (operation is null) return;
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true; bar.ShowThinking(); Raise();
        byte[]? wav = null;
        try
        {
            wav = RetainedAudio.Load(entry.AudioId!);
            var result = await Client.DictateAsync(wav, request.Language, entry.App, request.Strength, ActiveRoute,
                ct: operation.Token, translateTo: request.TranslateTo, variants: request.Variants, profile: History.Profile);
            if (!operations.IsCurrent(operation)) return;
            targetWindow = Native.GetForegroundWindow(); targetApp = entry.App; targetField = null; recordingContext = null;
            Paster.SetText(result.InsertableText);
            History.Add(new HistoryEntry { Task = result.Task, Text = result.InsertableText, Raw = result.Raw, App = entry.App,
                Fallback = result.Fallback, Reason = result.FallbackReason, Seconds = entry.Seconds,
                Corrections = result.Corrections, Intention = result.Intention,
                Request = request, AudioId = entry.AudioId });
            bar.ShowResult(L10n.T("已复制"), result.Fallback);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (Exception e) when (e is ServiceException or System.IO.IOException or System.Security.Cryptography.CryptographicException)
        { if (operations.IsCurrent(operation)) bar.ShowResult(L10n.T("重试失败，原记录保留"), true); }
        finally { if (wav is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(wav); if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; } operations.Complete(operation); Raise(); }
    }

    public void Toggle() => Toggle(null);

    /// <summary>翻译's key: with text selected, the selection is translated and replaces itself;
    /// otherwise a recording starts whose text is inserted translated.</summary>
    public async Task ToggleTranslate()
    {
        if (Phase == DictationPhase.Idle && !IsMicrophoneTesting)
        {
            var window = Native.GetForegroundWindow();
            var selection = await Within(Task.Run(() => FieldContextReader.Selection(window)), 400);
            if (selection is not null && Phase == DictationPhase.Idle) { await TranslateSelection(selection, window); return; }
        }
        Toggle(Settings.TranslateTarget);
    }

    private async Task TranslateSelection(string text, IntPtr window)
    {
        if (ActiveRoute is null) { SetHint(L10n.T("请先配置可用的整理模型。")); return; }
        var operation = operations.TryBegin();
        if (operation is null) return;
        var options = new DictationOptions(Settings.Language, "prompt", Settings.TranslateTarget, Settings.VariantsHeader, ActiveRoute, "autoPaste");
        targetWindow = window; targetApp = Shell.ProcessName(window); targetField = null; recordingContext = null;
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true; bar.ShowThinking(L10n.T("正在翻译…")); Raise();
        try
        {
            var result = await Client.PolishAsync(text, options.Language, "prompt", options.Route, options.TranslateTo, options.Variants,
                operation.Token, profile: History.Profile);
            if (operations.IsCurrent(operation)) await Deliver(result, 0, operation, options);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException) { if (operations.IsCurrent(operation)) bar.ShowResult(L10n.T("翻译失败"), true); }
        finally
        {
            if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; Raise(); }
            operations.Complete(operation);
        }
    }
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
            case DictationPhase.Recording:
                // A second press right after the first (a double tap) turns this recording into 提示词模式.
                if (!assistantRecording && translating is null && translateTo is null && micClock.Elapsed < DoubleTapWindow && recordingOptions is { } options)
                {
                    assistantRecording = true;
                    recordingOptions = options with { Strength = "promptbeta" };
                    bar.ShowRecording(recorder, L10n.T("提示词模式"));
                    return;
                }
                _ = StopAndSend(); break;
            default: break; // still cleaning up the last one
        }
    }

    /// <summary>Two presses within this time are a double tap.</summary>
    private static readonly TimeSpan DoubleTapWindow = TimeSpan.FromMilliseconds(400);

    /// <summary>拆解提示词: a prompt starts 提示词模式 as its first input; the finished prompt is copied, not pasted.</summary>
    public async Task StartBreakdown(string text)
    {
        if (Phase != DictationPhase.Idle || ActiveRoute is null) { if (ActiveRoute is null) SetHint(L10n.T("请先配置可用的整理模型。")); return; }
        var operation = operations.TryBegin();
        if (operation is null) return;
        if (beta.Session is not null) beta.Drop();
        var options = new DictationOptions(Settings.Language, "promptbeta", null, Settings.VariantsHeader, ActiveRoute, "clipboardOnly");
        targetWindow = IntPtr.Zero; targetApp = "tutorial"; targetField = null;
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true; bar.ShowThinking(); Raise();
        try
        {
            var result = await Client.PolishAsync(text, options.Language, "promptbeta", options.Route, null, options.Variants,
                operation.Token, source: "selection");
            if (operations.IsCurrent(operation) && !ShowBetaQuestions(result, options)) bar.ShowResult(L10n.T("没有完成，请重试"), true);
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException) { if (operations.IsCurrent(operation)) bar.ShowResult(L10n.T("没有完成，请重试"), true); }
        finally
        {
            if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; Raise(); }
            operations.Complete(operation);
        }
    }

    /// <summary>A chosen answer to the open questions (the quick choices in the panel), sent without recording.</summary>
    public async Task AnswerBeta(string text)
    {
        if (Phase != DictationPhase.Idle || beta.Session is not { } id || beta.Options is not { } options) return;
        var operation = operations.TryBegin();
        if (operation is null) return;
        beta.SetBusy(L10n.T("正在更新…"));
        Phase = DictationPhase.Thinking; hook.SwallowEscape = true; Raise();
        try
        {
            var result = await Client.PolishAsync(text, options.Language, "promptbeta", options.Route, null, options.Variants,
                operation.Token, betaSession: id);
            if (operations.IsCurrent(operation) && !ShowBetaQuestions(result, options)) beta.Resume();
        }
        catch (OperationCanceledException) when (operation.Token.IsCancellationRequested) { }
        catch (ServiceException e)
        {
            if (operations.IsCurrent(operation)) {
                if (e.Status == 410) ClearBeta(); else beta.Resume();
                bar.ShowResult(e.Status == 410 ? L10n.T("问题已过期，请重新说需求") : L10n.T("没有完成，请重试"), true);
            }
        }
        finally
        {
            if (operations.IsCurrent(operation)) { Phase = DictationPhase.Idle; hook.SwallowEscape = false; Raise(); }
            operations.Complete(operation);
        }
    }

    private void StartRecording()
    {
        if (quitting) return;
        cancelToast?.Finish();
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
            bar.ShowResult(L10n.T("打不开麦克风。请在「设置 → 隐私和安全性 → 麦克风」允许桌面应用"), warning: true);
            return;
        }
        Phase = DictationPhase.Recording;
        // An answer to Prompt Beta: the questions stay visible so the user can answer them one by one.
        if (assistantRecording && beta.Session is not null) beta.SetBusy(L10n.T("正在听。说完按 {0}。", HotkeyLabel));
        hook.SwallowEscape = true;
        bar.ShowRecording(recorder, translating is { } target
            ? L10n.T("翻译") + " →" + target.ToUpperInvariant()
            : assistantRecording ? L10n.T("提示词模式") : "");
        Raise();
        recordingOptions = new DictationOptions(Settings.Language, assistantRecording ? "promptbeta" : "prompt", translating, Settings.VariantsHeader, ActiveRoute, "autoPaste");
        targetApp = Shell.ProcessName(targetWindow);
        var window = targetWindow;
        targetFieldTask = Task.Run(() => FieldTarget.CaptureFor(window));
        // A new 提示词模式 conversation starts from the selected text, revised by what is said.
        baselineTask = assistantRecording && beta.Session is null ? Task.Run(() => FieldContextReader.Selection(window)) : null;
        recordingContextTask = Settings.UseFieldContext ? targetFieldTask.ContinueWith(t => FieldContextReader.Read(t.Result), TaskScheduler.Default) : null;
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
        var wasTesting = IsMicrophoneTesting;
        ducking.Dispose(); IsMicrophoneTesting = false;
        var preserveBeta = Phase == DictationPhase.Recording && beta.Session is not null;
        // A dictation can be taken back for a few seconds; an assistant answer cannot.
        var keep = Phase == DictationPhase.Recording && !wasTesting && recordingOptions is { Strength: "prompt" };
        var lease = operations.Active;
        operations.Cancel();
        byte[]? wav = null; double seconds = 0;
        if (keep) (wav, seconds) = recorder.Stop(); else recorder.Cancel();
        if (Phase == DictationPhase.Recording && lease is not null) lease.Dispose();
        hook.SwallowEscape = false;
        translating = null;
        Phase = DictationPhase.Idle;
        if (preserveBeta) beta.Resume(); else DropBeta();
        if (wav is not null && seconds >= 0.3 && recordingOptions is { } options)
        {
            cancelled = (wav, seconds, options, targetWindow, targetApp, targetFieldTask, recordingContextTask);
            bar.Dismiss();
            cancelToast ??= new LearnedToast();
            cancelToast.Show(L10n.T("转录已取消"), ResumeCancelled, DropCancelled);
        }
        else
        {
            if (wav is not null) System.Security.Cryptography.CryptographicOperations.ZeroMemory(wav);
            bar.ShowResult(L10n.T("已取消"), warning: false);
        }
        Raise();
    }

    /// <summary>撤销 on 「转录已取消」: the kept recording is transcribed as if it had been finished.</summary>
    private void ResumeCancelled()
    {
        if (cancelled is not { } held) return;
        cancelled = null;
        if (Phase != DictationPhase.Idle || quitting || operations.TryBegin() is not { } operation)
        { System.Security.Cryptography.CryptographicOperations.ZeroMemory(held.Wav); return; }
        targetWindow = held.Window; targetApp = held.App; targetField = null; recordingContext = null;
        targetFieldTask = held.Field; recordingContextTask = held.Context;
        _ = Send(operation, held.Options, held.Wav, held.Seconds);
    }

    /// <summary>The toast went away, a new recording started or the app quits: the kept recording is wiped.</summary>
    public void DropCancelled()
    {
        if (cancelled is not { } held) return;
        cancelled = null;
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(held.Wav);
    }

    private async Task StopAndSend()
    {
        if (operations.Active is not { } operation || recordingOptions is not { } options) return;
        var (wav, seconds) = recorder.Stop();
        ducking.Dispose();
        if (Settings.PlaySounds) Sounds.Stop();
        await Send(operation, options, wav, seconds);
    }

    private async Task Send(OperationTracker.Lease operation, DictationOptions options, byte[] wav, double seconds)
    {
        hook.SwallowEscape = false;
        var translateTo = options.TranslateTo;
        translating = null;
        if (seconds < 0.3)
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(wav);
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
        bar.ShowThinking(translateTo is null ? L10n.T(options.Strength == "promptbeta" ? "提示词模式" : "正在整理…") : L10n.T("正在翻译…"));
        Raise();
        targetField = await Within(targetFieldTask, 300);
        recordingContext = await Within(recordingContextTask, 300);
        var baseline = answering is null && options.Strength == "promptbeta" && translateTo is null ? await Within(baselineTask, 300) : null;
        targetFieldTask = null; recordingContextTask = null; baselineTask = null;
        if (!operations.IsCurrent(operation)) return;
        try
        {
            var requestOptions = answering is not null ? beta.Options ?? options : options;
            var result = await Client.DictateAsync(wav, requestOptions.Language, targetApp, requestOptions.Strength, requestOptions.Route,
                fieldContext: recordingContext, ct: operation.Token, betaSession: answering, translateTo: translateTo, variants: requestOptions.Variants,
                profile: History.Profile, baseline: baseline,
                onProgress: progress => dispatcher.InvokeAsync(() => { if (operations.IsCurrent(operation) && Phase == DictationPhase.Thinking) bar.ShowThinking(progress.Label); }));
            if (!operations.IsCurrent(operation)) return;
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
        }
    }

    private async Task Deliver(DictateResponse result, double seconds, OperationTracker.Lease operation, DictationOptions options, byte[]? wav = null)
    {
        if (!operations.IsCurrent(operation) || quitting) return;
        Log.Write("operation.complete", new DiagnosticEvent(result.Translated is null ? "dictation" : "translation", "complete",
            result.FallbackReason, result.Ms?.Total, Characters: result.Text.Length).Format());
        {
            // A terminal gets one line without control characters: this reduces accidental command execution.
            // Elsewhere a list never starts right after the text the cursor follows (read on this computer only).
            var pasting = options.InsertionMode != "clipboardOnly" && !TerminalGuard.IsTerminal(targetApp);
            var before = pasting && targetField is { } field ? await Within(Task.Run(() => FieldContextReader.Before(field)), 300) : null;
            if (!operations.IsCurrent(operation)) return;
            var text = pasting ? FormattedText.SeparatingList(result.InsertableText.Trim(), before)
                : TerminalGuard.SafeText(result.InsertableText.Trim(), targetApp);
            if (text.Length == 0)
            {
                bar.ShowResult(L10n.T("没有听到内容"), warning: true);
            }
            else
            {
                var outcome = options.InsertionMode == "clipboardOnly" ? (Paster.SetText(text) ? Paster.Outcome.CopiedOnly : Paster.Outcome.Failed)
                    : await Paster.PasteAsync(text, targetWindow, true, operation.Token, TerminalGuard.SafeText("a\nb", targetApp).Contains('\n'));
                if (!operations.IsCurrent(operation)) return;
                var entry = new HistoryEntry
                {
                    Task = result.Task,
                    Corrections = result.Corrections,
                    Intention = result.Intention,
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
                    catch (Exception e) when (e is System.IO.IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException) { SetHint(L10n.T("录音未能保留，文字仍可用。")); }
                }
                History.Add(entry); PruneAudio();
                // The clipboard could not be written: nothing was pasted, but the text is kept in History.
                if (outcome == Paster.Outcome.Failed) { bar.ShowResult(L10n.T("无法写入剪贴板，文字在历史里"), true); return; }
                if (History.LastError is not null) SetHint(L10n.T("历史无法读写，文件已保留。请检查文件权限。"));
                Activity.Record(ActivityLog.CountWords(text), DateTime.Now);
                var note = Messages.FallbackNote(result.FallbackReason);
                var done = Paster.Message(outcome);
                bar.ShowResult(note is null ? done : done + " · " + note, warning: note is not null);
            }
        }
    }

    private bool ShowBetaQuestions(DictateResponse result, DictationOptions options)
    {
        if (!beta.Show(result, options, targetWindow, targetApp, targetField, Settings.AssistantHotkey is { } key ? TapDetector.Label(key) : L10n.T("继续补充按钮"))) return false;
        bar.ShowResult(L10n.T("提示词模式：继续补充或生成"), warning: false);
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
