using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>No prompt editor in Settings. Changing the config requires three confirmations.</summary>
internal sealed class PromptifyPanel
{
    private readonly AppHost host;
    private readonly TextBlock state = Theme.Text(L10n.T("正在读取…"), 13, bold: true);
    private readonly TextBlock status = Theme.Text("", 12, Theme.Grey);
    private readonly Button restore;
    public UIElement[] Rows { get; }

    public PromptifyPanel(AppHost host)
    {
        this.host = host;
        restore = Theme.Secondary(L10n.T("恢复默认"), () => _ = RestoreDefault());
        var open = Theme.Secondary(L10n.T("打开配置文件…"), () => _ = OpenConfiguration());
        Rows = new UIElement[] { state,
            Theme.Text(L10n.T("默认提示词不建议修改。需要调整时，在配置文件中编辑；保存后下一次整理生效。"), 12, Theme.Grey),
            Theme.Text(L10n.T("配置文件仅影响标准格式档；普通档使用内置规则。"), 12, Theme.Grey),
            Theme.Row(8, open, restore, Theme.Secondary(L10n.T("重新读取"), () => _ = Load())), status };
        host.PromptFile.Status += (text, ok) => { status.Text = text; status.Foreground = ok ? Theme.Success : Theme.Warning; _ = Load(); };
        _ = Load();
    }

    private async Task Load()
    {
        try
        {
            var s = await host.Client.GetPromptifyAsync();
            state.Text = s.Modified ? L10n.T("默认提示词已被修改") : L10n.T("正在使用默认提示词");
            state.Foreground = s.Modified ? Theme.Warning : Theme.Grey;
            restore.Visibility = s.Modified ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (ServiceException) { state.Text = L10n.T("本地服务还没就绪，就绪后再打开设置。"); }
    }

    private async Task OpenConfiguration()
    {
        var owner = Window.GetWindow(state);
        if (MessageBox.Show(owner,
            L10n.T("默认提示词用于忠实保留你的意思，不建议修改。改动可能使结果偏离原意。只需补充要求时，请只修改配置文件中的 appendix，保留 override。"),
            L10n.T("修改默认提示词有风险"), MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
        if (MessageBox.Show(owner, L10n.T("修改后，提示词模式会完全使用你的版本。你随时可以在这里点「恢复默认」。"),
            L10n.T("再次确认：要修改默认提示词吗？"), MessageBoxButton.OKCancel, MessageBoxImage.Warning, MessageBoxResult.Cancel) != MessageBoxResult.OK) return;
        var code = PromptifyGuard.MakeCode();
        var dialog = new Window { Title = L10n.T("输入验证码以解锁"), Owner = owner, Width = 420,
            SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Theme.Background };
        var field = Theme.Input("", 180);
        var confirm = Theme.Primary(L10n.T("打开配置文件…"), () => dialog.DialogResult = true);
        confirm.IsEnabled = false; confirm.IsDefault = true;
        field.TextChanged += (_, _) => confirm.IsEnabled = PromptifyGuard.Matches(field.Text, code);
        var cancel = Theme.Secondary(L10n.T("取消"), () => dialog.DialogResult = false);
        cancel.IsCancel = true;
        var content = Theme.Stack(12, Theme.Text(L10n.T("请输入下面的 6 位验证码：\n\n") + code, 13), field, Theme.Row(8, cancel, confirm));
        content.Margin = new Thickness(24); dialog.Content = content;
        dialog.Loaded += (_, _) => field.Focus();
        if (dialog.ShowDialog() == true) await host.PromptFile.OpenAsync();
    }

    private async Task RestoreDefault()
    {
        if (MessageBox.Show(L10n.T("你修改过的版本会被丢弃，追加内容保留。"), L10n.T("恢复默认提示词？"), MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        await host.PromptFile.RestoreDefaultAsync();
    }
}
