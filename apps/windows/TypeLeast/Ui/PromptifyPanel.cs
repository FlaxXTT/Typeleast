using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// Settings for prompt mode (提示词模式). The default system prompt is locked and
/// shown read-only; the user adds instructions at the end. Replacing the default
/// takes a serious warning, a second confirmation and a typed one-time code; once
/// replaced, "恢复默认" puts it back.
/// </summary>
internal sealed class PromptifyPanel
{
    private readonly AppHost host;
    private readonly StackPanel stack = new();
    private readonly TextBlock state = Theme.Text("正在读取…", 13, bold: true);
    private readonly TextBox current = new()
    {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 180, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = new FontFamily("Consolas, Microsoft YaHei UI"), FontSize = 12, Foreground = Theme.Grey, BorderBrush = Theme.Line,
    };
    private readonly TextBox appendix = new()
    {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 90, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = Theme.Font, FontSize = 13, BorderBrush = Theme.Line,
    };
    private readonly TextBlock status = Theme.Text("", 12, Theme.Grey);
    private readonly Button restore;
    private readonly Button edit;
    private readonly Button save;
    private readonly Button cancel;
    private PromptifySettings? settings;
    private bool editing;

    public Border View { get; }

    public PromptifyPanel(AppHost host)
    {
        this.host = host;
        restore = Theme.Primary("恢复默认", () => _ = RestoreDefault());
        edit = Theme.Secondary("修改默认提示词…", BeginEdit);
        save = Theme.Primary("保存修改", () => _ = SaveOverride());
        cancel = Theme.Secondary("取消", () => { editing = false; Show(); });
        var saveAppendix = Theme.Primary("保存追加内容", () => _ = SaveAppendix());

        stack.Children.Add(Theme.SectionTitle("提示词模式的系统提示词"));
        stack.Children.Add(Theme.Row(10, state, restore, edit, save, cancel));
        current.Margin = new Thickness(0, 8, 0, 0);
        stack.Children.Add(current);
        var label = Theme.Text("追加内容（加在提示词结尾，作为「补充要求」）", 13, bold: true);
        label.Margin = new Thickness(0, 12, 0, 2);
        stack.Children.Add(label);
        stack.Children.Add(Theme.Text("例如：「所有提示词都用英文写」「输出格式一律用 Markdown 表格」。不影响上面的默认内容。", 12, Theme.Grey));
        appendix.Margin = new Thickness(0, 6, 0, 6);
        stack.Children.Add(appendix);
        stack.Children.Add(Theme.Row(10, saveAppendix, status));
        View = Theme.Card(stack);
        View.Margin = new Thickness(0, 14, 0, 0);
        _ = Load();
    }

    private async Task Load()
    {
        try
        {
            Apply(await host.Client.GetPromptifyAsync());
        }
        catch (ServiceException)
        {
            state.Text = "本地服务还没就绪，就绪后再打开设置。";
            Show();
        }
    }

    private void Apply(PromptifySettings s)
    {
        settings = s;
        appendix.Text = s.Appendix;
        editing = false;
        Show();
    }

    private void Show()
    {
        var s = settings;
        var loaded = s is not null;
        state.Text = !loaded ? state.Text : s!.Modified ? "⚠ 默认提示词已被修改" : "🔒 默认提示词（锁定，不能直接删改）";
        state.Foreground = loaded && s!.Modified ? Theme.Warning : Theme.Ink;
        restore.Visibility = loaded && s!.Modified && !editing ? Visibility.Visible : Visibility.Collapsed;
        edit.Visibility = loaded && !editing ? Visibility.Visible : Visibility.Collapsed;
        save.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        cancel.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        current.IsReadOnly = !editing;
        current.AcceptsReturn = editing;
        current.Height = editing ? 260 : 180;
        current.Foreground = editing ? Theme.Ink : Theme.Grey;
        current.BorderBrush = editing ? Theme.Warning : Theme.Line;
        if (loaded && !editing) current.Text = s!.Override ?? s.Default;
    }

    private void Status(string text, bool ok)
    {
        status.Text = text;
        status.Foreground = ok ? Theme.Success : Theme.Warning;
    }

    private async Task SaveAppendix()
    {
        try { Apply(await host.Client.SetPromptifyAsync(appendix: appendix.Text)); Status("追加内容已保存", true); }
        catch (ServiceException e) { Status("保存失败：" + e.Message, false); }
    }

    /// <summary>Three gates: a serious warning, a second confirmation, and a typed code.</summary>
    private void BeginEdit()
    {
        if (settings is null) return;
        var first = MessageBox.Show(
            "默认提示词经过调校：它规定了固定的提示词结构，并要求模型不得编造数字、日期、人名等事实。改动它可能让提示词模式的效果明显变差，甚至输出不可用的内容。\n\n如果只是想加要求，请用下面的「追加内容」，那不会影响默认提示词。\n\n仍要继续吗？",
            "修改默认提示词有风险", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (first != MessageBoxResult.Yes) return;
        var second = MessageBox.Show(
            "修改后，提示词模式会完全使用你的版本。你随时可以点「恢复默认」。\n\n确定要修改默认提示词吗？",
            "再次确认", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (second != MessageBoxResult.Yes) return;
        var code = PromptifyGuard.MakeCode();
        var dialog = new CodeDialog(code) { Owner = Window.GetWindow(View) };
        if (dialog.ShowDialog() != true) return;
        if (!PromptifyGuard.Matches(dialog.Typed, code))
        {
            Status("验证码不对，没有解锁。", false);
            return;
        }
        editing = true;
        current.Text = settings.Override ?? settings.Default;
        Show();
        Status("正在修改默认提示词；保存后提示词模式会用你的版本。", false);
    }

    private async Task SaveOverride()
    {
        if (current.Text.Trim().Length == 0)
        {
            Status("提示词不能为空；想用默认的请点「恢复默认」。", false);
            return;
        }
        try { Apply(await host.Client.SetPromptifyAsync(overrideText: current.Text)); Status("已保存你的提示词", true); }
        catch (ServiceException e) { Status("保存失败：" + e.Message, false); }
    }

    private async Task RestoreDefault()
    {
        if (MessageBox.Show("你修改过的版本会被丢弃，追加内容保留。", "恢复默认提示词？", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        try { Apply(await host.Client.SetPromptifyAsync(restoreDefault: true)); Status("已恢复默认提示词", true); }
        catch (ServiceException e) { Status("保存失败：" + e.Message, false); }
    }
}

/// <summary>Asks the user to type the one-time code shown in the dialog.</summary>
internal sealed class CodeDialog : Window
{
    private readonly TextBox input = new() { Width = 220, FontSize = 16, Padding = new Thickness(6, 4, 6, 4), MaxLength = 6 };
    public string Typed => input.Text;

    public CodeDialog(string code)
    {
        Title = "输入验证码以解锁";
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        FontFamily = Theme.Font;
        var ok = Theme.Primary("解锁", () => DialogResult = true);
        var no = Theme.Secondary("取消", () => DialogResult = false);
        var panel = Theme.Stack(12,
            Theme.Text("请输入下面的 6 位验证码：", 13),
            Theme.Text(code, 28, Theme.Ink, bold: true),
            input,
            Theme.Row(10, ok, no));
        panel.Margin = new Thickness(24);
        Content = panel;
        Loaded += (_, _) => input.Focus();
    }
}
