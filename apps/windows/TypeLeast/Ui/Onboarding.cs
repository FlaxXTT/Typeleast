using System;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class Onboarding : Window
{
    private readonly StackPanel content = new();
    private readonly AppHost host;
    private int step;
    private readonly SpeechModelsPanel speechModels;
    private readonly string[] titles = { "欢迎使用 TypeLeast", "准备本地服务和模型", "麦克风与权限", "Windows 快捷键", "麦克风测试", "首次听写", "设置位置", "准备完成" };
    public Onboarding(AppHost host)
    {
        this.host = host; speechModels = new SpeechModelsPanel(host); Title = "TypeLeast"; Width = 560; Height = 460; MinWidth = 400; MinHeight = 360; Background = Theme.Background;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = new ScrollViewer { Content = content, Padding = new Thickness(28), VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Render(); host.Changed += Refresh; Closed += (_, _) => host.Changed -= Refresh;
    }
    private void Refresh() { if (step == 1) Render(); }
    private void Render()
    {
        content.Children.Clear(); content.Children.Add(Theme.Text($"{step + 1} / {titles.Length}", 12, Theme.Grey));
        content.Children.Add(Theme.Text(L10n.T(titles[step]), 25, bold: true));
        var description = step switch
        {
            1 => host.ServiceSummary,
            2 => "请允许桌面应用使用麦克风。",
            3 => "按听写键开始，再按一下结束。Esc 取消。",
            5 => "点一个输入框，按快捷键说话。",
            _ => ""
        };
        if (description.Length > 0) content.Children.Add(Theme.Card(Theme.Text(L10n.T(description), 14)));
        if (step == 0) content.Children.Add(Theme.Card(Theme.Text(L10n.T("遇到简称或专名，可以补一句全称、用途或拼写。AI 整理会合并补充信息；有歧义时先确认。"), 14)));
        if (step == 1)
        {
            speechModels.Refresh();
            content.Children.Add(speechModels.View);
            content.Children.Add(Theme.Secondary(L10n.T("打开设置"), () => host.ShowWindow(MainWindow.Page.Settings)));
        }
        if (step == 6) content.Children.Add(Theme.Card(GuideViews.List(null)));
        if (step == 2) content.Children.Add(Theme.Secondary(L10n.T("打开麦克风设置"), () => Shell.Open("ms-settings:privacy-microphone")));
        if (step == 4) content.Children.Add(Theme.Primary(L10n.T("测试麦克风"), () => MicrophoneTestPanel.Show(host)));
        var last = titles.Length - 1;
        var next = Theme.Primary(L10n.T(step == last ? "完成" : "下一步"), () =>
        {
            if (step == last) { host.Settings.OnboardingDone = true; if (host.SaveSettings()) Close(); }
            else { step++; Render(); }
        });
        next.IsEnabled = step != 1 || host.ServiceUp;
        content.Children.Add(Theme.Row(8, Theme.Secondary(L10n.T("上一步"), () => { if (step > 0) { step--; Render(); } }), next));
    }
}
