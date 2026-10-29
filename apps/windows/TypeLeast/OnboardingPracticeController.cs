using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Security.Cryptography;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>A separate recording workflow: no target window, clipboard, history or dictionary writes.</summary>
internal sealed class OnboardingPracticeController
{
    private readonly AppHost host;
    private readonly Dispatcher dispatcher;
    private readonly AudioRecorder recorder=new();
    private CancellationTokenSource? request;
    private int generation;
    public PracticeProgress Progress { get; private set; } = new();
    /// <summary>The language to translate into while the translation step is shown; null for plain dictation.</summary>
    public string? TranslateTo { get; set; }
    public string TranslateSample => L10n.Culture.TwoLetterISOLanguageName=="en" ? "Let's meet tomorrow at three and bring the report." : "明天下午三点开会，记得带上报告。";
    public bool Recording { get; private set; }
    public bool Thinking { get; private set; }
    public bool Busy => Recording||Thinking;
    public string Raw { get; private set; }="";
    public string Output { get; private set; }="";
    public string Status { get; private set; }="";
    public event Action? Changed;
    public OnboardingPracticeController(AppHost host,Dispatcher dispatcher)
    {
        this.host=host;this.dispatcher=dispatcher;
        recorder.LimitReached+=()=>dispatcher.InvokeAsync(()=>_ = Stop());
        recorder.RecordingFailed+=()=>dispatcher.InvokeAsync(()=>{Cancel();Status=L10n.T("打不开麦克风，请检查设备和权限。");Changed?.Invoke();});
    }
    public string Sample => L10n.Culture.TwoLetterISOLanguageName=="en"
        ? "Send the report on Tuesday, no wait, on Thursday. Keep it under 3 pages."
        : "嗯，把报告周三发，不对，改成周四，不超过三页。";
    public void Toggle()
    {
        if(Recording){_ = Stop();return;}if(Thinking)return;
        if(host.ActiveRoute is null){Status=L10n.T("请先配置可用的整理模型。");Changed?.Invoke();return;}
        try {Raw="";Output="";recorder.Start(host.Settings.MicrophoneDevice);Recording=true;Status="";}
        catch(InvalidOperationException){Status=L10n.T("打不开麦克风，请检查设备和权限。");Recording=false;}
        Changed?.Invoke();
    }
    private async Task Stop()
    {
        if(!Recording)return;
        var(wav,seconds)=recorder.Stop();Recording=false;Thinking=true;Status=L10n.T("正在整理…");Changed?.Invoke();
        var token=generation;
        request=new CancellationTokenSource();var cancellation=request;
        try {
            var result=await host.Client.DictateAsync(wav,host.Settings.Language,"tutorial","concise",host.ActiveRoute,
                ct:cancellation.Token,translateTo:TranslateTo);
            if(generation!=token)return;
            Raw=result.Raw;Output=result.Text;
            Output=result.InsertableText;
            Status=Progress.Accept(result,seconds) switch {
                PracticeProgress.Outcome.Passed=>L10n.T("通过了。点「继续」。"),
                PracticeProgress.Outcome.TooShort=>L10n.T("录音太短，请再说一次。"),
                PracticeProgress.Outcome.NothingHeard=>L10n.T("没听清，请再说一次。"),
                _=>L10n.T("识别到了，但整理没完成。请检查整理模型和 API Key。"),
            };
        } catch(OperationCanceledException)when(cancellation.IsCancellationRequested){}
        catch(ServiceException e){if(generation==token)Status=L10n.T("没有完成：")+DiagnosticEvent.SafeReason(e.Code);}
        finally {
            CryptographicOperations.ZeroMemory(wav);cancellation.Dispose();
            if(generation==token){request=null;Thinking=false;Changed?.Invoke();}
        }
    }
    public void Cancel(){generation++;request?.Cancel();request=null;recorder.Cancel();Recording=false;Thinking=false;Raw="";Output="";Changed?.Invoke();}
}
