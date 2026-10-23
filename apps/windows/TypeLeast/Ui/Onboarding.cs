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
    private readonly string[] titles = { "欢迎使用 TypeLeast", "准备本地服务和模型", "麦克风与权限", "Windows 快捷键", "麦克风测试", "首次尝试", "设置在哪", "准备完成" };
    public Onboarding(AppHost host)
    {
        this.host = host; Title = "TypeLeast"; Width = 560; Height = 460; MinWidth = 400; MinHeight = 360; Background = Theme.Background;
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
            0 => "语音在本机识别，整理用你配置的模型。引导可在设置里重新打开。",
            1 => host.ServiceSummary,
            2 => "需要允许桌面应用使用麦克风。粘贴失败时文字会留在剪贴板。",
            3 => "按一下听写键开始，再按一下结束；Esc 取消。右 Alt 可能是 AltGr，可在设置里换键。",
            4 => "最长 15 秒，不识别也不保存。",
            5 => "打开任意输入框，用快捷键说一句话，文字会出现在光标处。",
            6 => "首页也有这张表，点一下就能过去。",
            _ => "关闭窗口后仍在托盘运行，从托盘菜单退出。"
        };
        content.Children.Add(Theme.Card(Theme.Text(L10n.T(description), 14)));
        if (step == 1)
        {
            if (host.Speech is { ModelsMissing: true } or { Phase: "error" })
                content.Children.Add(Theme.Primary(L10n.T("下载（约 241 MB）"), () => _ = host.DownloadModels()));
            if (ModelMirror.NetworkFailure(host.Speech)) content.Children.Add(GuideViews.MirrorHint(host, host.RetryModelDownload));
            content.Children.Add(Theme.Secondary(L10n.T("打开设置"), () => host.ShowWindow(MainWindow.Page.Settings)));
        }
        if (step == 6) content.Children.Add(Theme.Card(GuideViews.List(null)));
        if (step == 2) content.Children.Add(Theme.Secondary(L10n.T("打开麦克风权限"), () => Shell.Open("ms-settings:privacy-microphone")));
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
