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
    private readonly string[] titles = { "欢迎使用 TypeLeast", "准备本地服务和模型", "麦克风与权限", "Windows 快捷键", "麦克风测试", "首次尝试", "准备完成" };
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
        content.Children.Clear(); content.Children.Add(Theme.Text($"{step + 1} / 7", 12, Theme.Grey));
        content.Children.Add(Theme.Text(L10n.T(titles[step]), 25, bold: true));
        var description = step switch
        {
            0 => "说话在本机识别，整理使用你配置的模型。你可以随时在设置中重新打开引导。",
            1 => host.ServiceSummary,
            2 => "Windows 桌面应用需要麦克风访问。键盘钩子通常不需要管理员权限；跨权限粘贴可能受系统限制，失败时复制结果。",
            3 => "单击听写键开始，再按结束；Esc 取消。右 Alt 可能是 AltGr，可在设置中换键。Windows 不要求配置 Fn 或 Globe 键。",
            4 => "点击按钮才开启麦克风。测试最长 15 秒，不发送给服务商。",
            5 => "打开一个普通输入框，用快捷键说一句虚构内容。结果会插入，目标变化时改为复制。也可以先选择原话转写。",
            _ => "关闭主窗口会留在后台；托盘可恢复窗口，退出菜单会停止服务与麦克风。"
        };
        content.Children.Add(Theme.Card(Theme.Text(L10n.T(description), 14)));
        if (step == 1) content.Children.Add(Theme.Secondary(L10n.T("打开设置"), () => host.ShowWindow(MainWindow.Page.Settings)));
        if (step == 2) content.Children.Add(Theme.Secondary(L10n.T("打开麦克风权限"), () => Shell.Open("ms-settings:privacy-microphone")));
        if (step == 4) content.Children.Add(Theme.Primary(L10n.T("测试麦克风"), () => MicrophoneTestPanel.Show(host)));
        var next = Theme.Primary(L10n.T(step == 6 ? "完成" : "下一步"), () =>
        {
            if (step == 6) { host.Settings.OnboardingDone = true; if (host.SaveSettings()) Close(); }
            else { step++; Render(); }
        });
        next.IsEnabled = step != 1 || host.ServiceUp;
        content.Children.Add(Theme.Row(8, Theme.Secondary(L10n.T("上一步"), () => { if (step > 0) { step--; Render(); } }), next));
    }
}
