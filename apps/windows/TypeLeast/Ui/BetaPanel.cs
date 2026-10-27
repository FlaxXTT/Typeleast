using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// Prompt Beta's questions. Topmost and never activated, so the window the user dictated
/// into keeps focus and the finished prompt is pasted back there.
/// </summary>
internal sealed class BetaPanel : Window
{
    private readonly StackPanel list = new();
    private readonly TextBlock hint;
    private readonly TextBlock roundLabel = Theme.Text("", 12, Theme.Grey);
    private readonly UIElement cancelButton, skipButton;
    private string hintText = "";

    public BetaPanel(Action skip, Action cancel)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.Height;
        Width = 420;
        Focusable = false;
        SourceInitialized += (_, _) => TypeLeast.Native.MakeNoActivate(new WindowInteropHelper(this).Handle);

        var title = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        title.Children.Add(Theme.Text(L10n.T("提示词 Beta"), 12, Theme.Accent, bold: true));
        title.Children.Add(roundLabel);
        hint = Theme.Text("", 11.5, Theme.Grey);
        hint.Margin = new Thickness(0, 10, 0, 12);
        var buttons = new DockPanel { LastChildFill = false };
        cancelButton = Theme.Secondary(L10n.T("取消"), cancel);
        skipButton = Theme.Primary(L10n.T("生成"), skip);
        DockPanel.SetDock(cancelButton, Dock.Left);
        DockPanel.SetDock(skipButton, Dock.Right);
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(skipButton);

        var content = new StackPanel();
        content.Children.Add(title);
        content.Children.Add(Theme.Text(L10n.T("不使用表达示例、光标上下文和英式拼写。"), 11, Theme.Grey));
        content.Children.Add(new ScrollViewer { Content = list, MaxHeight = 300, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        content.Children.Add(hint);
        content.Children.Add(buttons);
        var card = new Border
        {
            Background = Theme.CardFill,
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(18),
            Child = content,
        };
        // Drag it anywhere but the buttons, out of the way of what it covers. The window never
        // activates, so the app being dictated into keeps focus and the conversation goes on.
        card.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject source && FindButton(source)) return;
            try { DragMove(); } catch (InvalidOperationException) { }
        };
        Content = card;
    }

    private static bool FindButton(DependencyObject? node)
    {
        for (; node is not null; node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
            if (node is ButtonBase) return true;
        return false;
    }

    public void ShowQuestions(BetaInfo info, string hotkey)
    {
        list.Children.Clear();
        roundLabel.Text = "  " + L10n.T("第 {0} 轮", info.Round ?? 1);
        list.Children.Add(Theme.Text(info.Ready == true ? L10n.T("已清楚。可继续补充或生成。") : L10n.T("先说清信息"), 12, Theme.Grey));
        if (info.Confirmed is { Count: > 0 })
        {
            list.Children.Add(Theme.Text(L10n.T("我的理解，请核对"), 12, bold: true));
            foreach (var item in info.Confirmed) list.Children.Add(Theme.Text("• " + item, 12.5, Theme.Ink));
        }
        if (info.Questions is { Count: > 0 })
        {
            list.Children.Add(Theme.Text(L10n.T("缺少的信息"), 12, bold: true));
            for (var i = 0; i < info.Questions.Count; i++)
            {
                var line = Theme.Text((i + 1) + ".  " + info.Questions[i], 13.5, Theme.Ink);
                line.Margin = new Thickness(0, 0, 0, 6); list.Children.Add(line);
            }
        }
        if (info.Notice is { } notice) list.Children.Add(Theme.Text(Messages.BetaNotice(notice), 12, Theme.Warning));
        hintText = L10n.T("按 {0} 继续补充，点「生成」结束。", hotkey);
        SetBusy(null);
        var area = SystemParameters.WorkArea;
        MaxHeight = Math.Max(240, area.Height - 48);
        // Placed only when it appears: a new round keeps the place the user dragged it to.
        if (!IsVisible) { Left = area.Right - Width - 24; Top = area.Top + 24; }
        Show();
    }

    /// <summary>While an answer is being recorded or checked the questions stay on screen (the user reads
    /// them while speaking); the status replaces the hint and the buttons wait.</summary>
    public void SetBusy(string? status)
    {
        hint.Text = status ?? hintText;
        hint.Foreground = status is null ? Theme.Grey : Theme.Accent;
        cancelButton.IsEnabled = skipButton.IsEnabled = status is null;
    }

    /// <summary>Back to waiting for the next answer, with the same questions.</summary>
    public void Resume()
    {
        SetBusy(null);
        Show();
    }
}
