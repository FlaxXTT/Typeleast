using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class Onboarding : Window
{
    private readonly StackPanel content = new();
    private readonly AppHost host;
    private readonly SpeechModelsPanel speechModels;
    private readonly OnboardingPracticeController practice;
    private int step;
    private bool finishing;
    private string reviewDraft="",shownOutput="",shownMarker="";
    private readonly string[] titles={"欢迎使用 TypeLeast","准备本地服务和模型","麦克风与权限","Windows 快捷键","麦克风测试","完成三组真实语音练习","设置位置","准备完成"};
    public bool PracticeActive => IsVisible&&step==5;
    public bool PracticeBusy => practice.Busy;
    public Onboarding(AppHost host)
    {
        this.host=host;speechModels=new SpeechModelsPanel(host);practice=new OnboardingPracticeController(host,Dispatcher);
        Title="TypeLeast";Width=640;Height=660;MinWidth=480;MinHeight=480;Background=Theme.Background;
        WindowStartupLocation=WindowStartupLocation.CenterScreen;
        Content=new ScrollViewer {Content=content,Padding=new Thickness(28),VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        practice.Changed+=PracticeChanged;host.Changed+=Refresh;
        Closing+=OnClosing;
        Closed+=(_,_)=>{host.Changed-=Refresh;practice.Changed-=PracticeChanged;practice.Cancel();};
        Render();
    }
    private void OnClosing(object? sender,CancelEventArgs e) {if(host.Settings.NeedsPractice&&!finishing&&!host.QuittingForSetup)e.Cancel=true;}
    public void HandleShortcut(){if(PracticeActive)practice.Toggle();else Activate();}
    public void CancelPractice()=>practice.Cancel();
    private void Refresh(){if(!practice.Busy && (step==1 || (step==5 && shownMarker!=host.Settings.ExplanationMarkers)))Render();}
    private void PracticeChanged()
    {
        if(shownOutput!=practice.Output){shownOutput=practice.Output;reviewDraft=practice.Output;}
        if(step==5)Render();
    }
    private bool Complete=>practice.Progress.Complete&&practice.Progress.MarkerId==host.Settings.ExplanationMarkers;
    private bool CanContinue=>!practice.Busy&&(!host.Settings.NeedsPractice||step switch {
        1=>host.LlmConfigured&&host.Speech?.Ready==true,
        5 or 7=>Complete&&!string.IsNullOrEmpty(host.Settings.ExplanationMarkers),
        _=>true,
    });
    private void Render()
    {
        shownMarker=host.Settings.ExplanationMarkers;
        content.Children.Clear();content.Children.Add(Theme.Text($"{step+1} / {titles.Length}",12,Theme.Grey));
        content.Children.Add(Theme.Text(L10n.T(titles[step]),25,bold:true));
        var description=step switch {
            1=>host.ServiceSummary,
            2=>L10n.T("需要麦克风权限才能完成真实语音练习。"),
            3=>L10n.T("按听写键开始，再按一下结束。Esc 取消。"),
            5=>L10n.T("需要真实识别和整理通过。练习只在此显示，不粘贴、不保存历史，也不加入正式偏好。"),
            _=>"",
        };
        if(description.Length>0)content.Children.Add(Theme.Text(description,14,Theme.Grey));
        if(step==0)content.Children.Add(Theme.Card(Theme.Text(L10n.T("遇到简称或专名，可以补一句全称、用途或拼写。AI 整理会合并补充信息；有歧义时先确认。"),14)));
        if(step==1){speechModels.Refresh();content.Children.Add(speechModels.View);content.Children.Add(Theme.Secondary(L10n.T("打开设置"),()=>host.ShowWindow(MainWindow.Page.Settings)));}
        if(step==2)content.Children.Add(Theme.Secondary(L10n.T("打开麦克风设置"),()=>Shell.Open("ms-settings:privacy-microphone")));
        if(step==4)content.Children.Add(Theme.Secondary(L10n.T("测试麦克风"),()=>MicrophoneTestPanel.Show(host)));
        if(step==5)RenderPractice();
        if(step==6)content.Children.Add(Theme.Card(GuideViews.List(null)));
        var next=Theme.Primary(L10n.T(step==titles.Length-1?"完成":"下一步"),()=>{
            if(!CanContinue)return;
            if(step==titles.Length-1){if(host.CompleteOnboarding(Complete)){finishing=true;Close();}}
            else{step++;Render();}
        });next.IsEnabled=CanContinue;
        var back=Theme.Secondary(L10n.T("上一步"),()=>{if(step>0&&!practice.Busy){step--;Render();}});back.IsEnabled=step>0&&!practice.Busy;
        content.Children.Add(Theme.Row(8,back,next));
        if(host.Settings.NeedsPractice)content.Children.Add(Theme.Row(8,Theme.Secondary(L10n.T("打开设置"),()=>host.ShowWindow(MainWindow.Page.Settings)),Theme.Secondary(L10n.T("退出应用"),host.Quit)));
    }
    private void RenderPractice()
    {
        var markers=DictionaryPage.MarkerPicker(host);markers.IsEnabled=!practice.Busy;content.Children.Add(markers);
        var exercise=Theme.Choice(300);
        foreach(var title in new[]{"1. 改口与条件","2. 解释与正文","3. 确认修改"})exercise.Items.Add(L10n.T(title));
        exercise.SelectedIndex=practice.Exercise;exercise.IsEnabled=!practice.Busy;
        exercise.SelectionChanged+=(_,_)=>{practice.Exercise=exercise.SelectedIndex;Render();};content.Children.Add(exercise);
        content.Children.Add(Theme.Card(Theme.Text(practice.Sample,14)));
        var record=Theme.Primary(L10n.T(practice.Recording?"停止并整理":"开始录音"),practice.Toggle);record.IsEnabled=!practice.Thinking;
        var cancel=Theme.Secondary(L10n.T("取消"),practice.Cancel);cancel.IsEnabled=practice.Busy;
        content.Children.Add(Theme.Row(8,record,cancel));
        content.Children.Add(Theme.Text(practice.Status,12,Theme.Grey));
        if(practice.Raw.Length>0){content.Children.Add(Theme.Text(L10n.T("识别原文"),12,Theme.Grey));content.Children.Add(Theme.Text(practice.Raw,13));}
        if(practice.Output.Length>0){content.Children.Add(Theme.Text(L10n.T("整理结果"),12,Theme.Grey));content.Children.Add(Theme.Text(practice.Output,13));}
        if(practice.Exercise==2&&practice.Output.Length>0){
            content.Children.Add(Theme.Text(L10n.T("修改至少一处表达，再确认。此处只演示偏好确认，不保存练习资料。"),12,Theme.Grey));
            var editor=new TextBox {Text=reviewDraft,AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,MinHeight=80,MaxHeight=160,MaxLength=4000,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
            editor.TextChanged+=(_,_)=>reviewDraft=editor.Text;content.Children.Add(editor);
            var confirm=Theme.Secondary(L10n.T("确认修改"),()=>practice.ConfirmReview(reviewDraft));confirm.IsEnabled=!practice.Busy;content.Children.Add(confirm);
        }
        content.Children.Add(Theme.Text(L10n.T("已完成 {0} / 3",practice.Progress.Completed.Count),13,bold:true));
    }
}
