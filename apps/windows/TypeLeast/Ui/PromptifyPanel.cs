using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// Settings for prompt mode (提示词模式). Additions are typed here and kept at the end
/// of the prompt. The prompt itself is edited as a file, like a configuration file:
/// "打开提示词文件" opens promptify-system.md in Notepad, and saving it takes effect on
/// the next dictation. "恢复默认" removes the file and the replacement.
/// </summary>
internal sealed class PromptifyPanel
{
    private readonly AppHost host;
    private readonly TextBlock state = Theme.Text(L10n.T("正在读取…"), 13, bold: true);
    private readonly TextBox appendix = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 90, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = Theme.Font, FontSize = 13, BorderBrush = Theme.Line, Padding = new Thickness(8, 6, 8, 6),
    };
    private readonly TextBlock status = Theme.Text("", 12, Theme.Grey);
    private readonly Button restore;

    /// <summary>The rows, to place inside a settings card.</summary>
    public UIElement[] Rows { get; }

    public PromptifyPanel(AppHost host)
    {
        this.host = host;
        restore = Theme.Secondary(L10n.T("恢复默认"), () => _ = RestoreDefault());
        var open = Theme.Secondary(L10n.T("打开提示词文件"), () => _ = host.PromptFile.OpenAsync());
        var saveAppendix = Theme.Primary(L10n.T("保存补充要求"), () => _ = SaveAppendix());

        var fileRow = Theme.SettingRow(L10n.T("提示词模式的系统提示词"),
            Theme.Text(L10n.T("在记事本中编辑，保存后下一次整理生效。默认提示词经过调校，改动可能让效果变差；只想加要求时，用下面的「补充要求」。"), 12, Theme.Grey),
            Theme.Row(8, open, restore));
        var label = Theme.Text(L10n.T("补充要求（加在提示词结尾）"), 13, bold: true);
        label.Margin = new Thickness(0, 10, 0, 2);
        appendix.Margin = new Thickness(0, 6, 0, 6);
        Rows = new UIElement[]
        {
            fileRow, state, label,
            Theme.Text(L10n.T("例如：「所有提示词都用英文写」「输出格式一律用 Markdown 表格」。"), 12, Theme.Grey),
            appendix, Theme.Row(10, saveAppendix, status),
        };
        host.PromptFile.Status += (text, ok) => { Status(text, ok); _ = Load(); };
        _ = Load();
    }

    private async Task Load()
    {
        try { Apply(await host.Client.GetPromptifyAsync(), keepAppendix: appendix.IsKeyboardFocusWithin); }
        catch (ServiceException)
        {
            state.Text = L10n.T("本地服务还没就绪，就绪后再打开设置。");
            restore.Visibility = Visibility.Collapsed;
        }
    }

    private void Apply(PromptifySettings s, bool keepAppendix = false)
    {
        if (!keepAppendix) appendix.Text = s.Appendix;
        state.Text = s.Modified ? L10n.T("⚠ 正在使用你修改的提示词") : L10n.T("正在使用默认提示词");
        state.Foreground = s.Modified ? Theme.Warning : Theme.Grey;
        state.FontWeight = s.Modified ? FontWeights.SemiBold : FontWeights.Normal;
        restore.Visibility = s.Modified || System.IO.File.Exists(host.PromptFile.FilePath) ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Status(string text, bool ok)
    {
        status.Text = text;
        status.Foreground = ok ? Theme.Success : Theme.Warning;
    }

    private async Task SaveAppendix()
    {
        try { Apply(await host.Client.SetPromptifyAsync(appendix: appendix.Text)); Status(L10n.T("补充要求已保存"), true); }
        catch (ServiceException e) { Status(L10n.T("保存失败：") + e.Message, false); }
    }

    private async Task RestoreDefault()
    {
        if (MessageBox.Show(L10n.T("删除提示词文件，改回默认提示词？补充要求会保留。"), L10n.T("恢复默认提示词？"), MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        await host.PromptFile.RestoreDefaultAsync();
    }
}
