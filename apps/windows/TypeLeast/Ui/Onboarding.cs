using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
    private string shownOutput="";
    private readonly string[] titles={"欢迎使用 TypeLeast","准备本地服务和模型","麦克风与权限","Windows 快捷键","麦克风测试","试说一句","设置位置","准备完成"};
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
    /// <summary>Closing the window is the same as 跳过引导.</summary>
    private void OnClosing(object? sender,CancelEventArgs e) {if(!finishing&&!host.QuittingForSetup){finishing=true;host.CompleteOnboarding(true);}}
    public void HandleShortcut(){if(PracticeActive)practice.Toggle();else Activate();}
    public void CancelPractice()=>practice.Cancel();
    private void Refresh(){if(!practice.Busy && step==1)Render();}
    private void PracticeChanged()
    {
        if(shownOutput!=practice.Output)shownOutput=practice.Output;
        if(step==5)Render();
    }
    private bool Complete=>practice.Progress.Complete;
    /// <summary>下一步 waits for what the step is about; 跳过这步 never does.</summary>
    private bool CanContinue=>!practice.Busy&&(step!=5||Complete);
    private void Render()
    {
        content.Children.Clear();content.Children.Add(Theme.Text($"{step+1} / {titles.Length}",12,Theme.Grey));
        content.Children.Add(Theme.Text(L10n.T(titles[step]),25,bold:true));
        var description=step switch {
            1=>host.ServiceSummary,
            2=>L10n.T("需要麦克风权限才能完成真实语音练习。"),
            3=>L10n.T("按听写键开始，再按一下结束。Esc 取消。"),
            5=>L10n.T("按听写键或点下面的录音条，读这句话。"),
            _=>"",
        };
        if(description.Length>0)content.Children.Add(Theme.Text(description,14,Theme.Grey));
        if(step==0)content.Children.Add(Theme.Card(Theme.Text(L10n.T("遇到简称或专名，可补充全称、含义或逐字拼写。听写会结合整段理解，删除只用于确认名称的解释。"),14)));
        if(step==1){speechModels.Refresh();content.Children.Add(speechModels.View);content.Children.Add(Theme.Secondary(L10n.T("打开设置"),()=>host.ShowWindow(MainWindow.Page.Settings)));}
        if(step==2)content.Children.Add(Theme.Secondary(L10n.T("打开麦克风设置"),()=>Shell.Open("ms-settings:privacy-microphone")));
        if(step==4)content.Children.Add(Theme.Secondary(L10n.T("测试麦克风"),()=>MicrophoneTestPanel.Show(host)));
        if(step==5)RenderPractice();
        if(step==6)content.Children.Add(Theme.Card(GuideViews.List(null)));
        var next=Theme.Primary(L10n.T(step==titles.Length-1?"完成":"下一步"),()=>{
            if(!CanContinue)return;
            if(step==titles.Length-1){if(host.CompleteOnboarding(true)){finishing=true;Close();}}
            else{step++;Render();}
        });next.IsEnabled=CanContinue;
        var back=Theme.Secondary(L10n.T("上一步"),()=>{if(step>0&&!practice.Busy){step--;Render();}});back.IsEnabled=step>0&&!practice.Busy;
        // Every step can be skipped, and so can the whole guide.
        var row=Theme.Row(8,back,next);
        if(step<titles.Length-1){
            var skipStep=Theme.Secondary(L10n.T("跳过这步"),()=>{if(!practice.Busy){step++;Render();}});skipStep.IsEnabled=!practice.Busy;
            var skipAll=Theme.Secondary(L10n.T("跳过引导"),()=>{practice.Cancel();if(host.CompleteOnboarding(true)){finishing=true;Close();}});skipAll.IsEnabled=!practice.Busy;
            if(step>0)row.Children.Add(skipStep);
            row.Children.Add(skipAll);
        }
        content.Children.Add(row);
    }
    private void RenderPractice()
    {
        content.Children.Add(Theme.Card(Theme.Text(practice.Sample,14)));
        // The same dark pill as in daily use: click or press the dictation key; ✓ finishes, ✕ cancels.
        var pill=new Border {Background=Theme.Hex("#171717"),CornerRadius=new CornerRadius(20),Padding=new Thickness(4),HorizontalAlignment=HorizontalAlignment.Left,Cursor=System.Windows.Input.Cursors.Hand};
        UIElement Circle(string glyph,bool filled,Action act){
            var b=new Border {Width=30,Height=30,CornerRadius=new CornerRadius(15),Background=filled?Brushes.White:Theme.Hex("#38FFFFFF"),Cursor=System.Windows.Input.Cursors.Hand,
                Child=new TextBlock {Text=glyph,Foreground=filled?Theme.Hex("#171717"):Brushes.White,FontWeight=FontWeights.Bold,FontSize=13,HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center}};
            b.MouseLeftButtonUp+=(_,e)=>{e.Handled=true;act();};return b;
        }
        var inner=new StackPanel {Orientation=Orientation.Horizontal};
        if(practice.Recording){
            inner.Children.Add(Circle("✕",false,practice.Cancel));
            inner.Children.Add(new TextBlock {Text=L10n.T("正在听…"),Foreground=Brushes.White,FontSize=13,Margin=new Thickness(14,0,14,0),VerticalAlignment=VerticalAlignment.Center});
            inner.Children.Add(Circle("✓",true,practice.Toggle));
        } else if(practice.Thinking){
            inner.Children.Add(new TextBlock {Text="• • •",Foreground=Brushes.White,FontSize=14,Margin=new Thickness(22,5,22,5),VerticalAlignment=VerticalAlignment.Center});
        } else {
            inner.Children.Add(Circle("🎤",false,practice.Toggle));
            inner.Children.Add(new TextBlock {Text=L10n.T(Complete?"再试一次":"点这里开始"),Foreground=Brushes.White,FontWeight=FontWeights.SemiBold,FontSize=13,Margin=new Thickness(10,0,12,0),VerticalAlignment=VerticalAlignment.Center});
            pill.MouseLeftButtonUp+=(_,_)=>practice.Toggle();
        }
        pill.Child=inner;content.Children.Add(pill);
        if(practice.Status.Length>0)content.Children.Add(Theme.Text(practice.Status,13,Complete?Theme.Success:Theme.Grey));
        if(practice.Output.Length>0){content.Children.Add(Theme.Text(L10n.T("整理结果"),12,Theme.Grey));content.Children.Add(Theme.Card(Theme.Text(practice.Output,14)));}
    }
}
