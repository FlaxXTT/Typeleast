using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
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
        title.Children.Add(Theme.Text("  " + L10n.T("先回答几个问题"), 12, Theme.Grey));
        hint = Theme.Text("", 11.5, Theme.Grey);
        hint.Margin = new Thickness(0, 10, 0, 12);
        var buttons = new DockPanel { LastChildFill = false };
        var cancelButton = Theme.Secondary(L10n.T("取消"), cancel);
        var skipButton = Theme.Primary(L10n.T("跳过，直接生成"), skip);
        DockPanel.SetDock(cancelButton, Dock.Left);
        DockPanel.SetDock(skipButton, Dock.Right);
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(skipButton);

        var content = new StackPanel();
        content.Children.Add(title);
        content.Children.Add(list);
        content.Children.Add(hint);
        content.Children.Add(buttons);
        Content = new Border
        {
            Background = Theme.CardFill,
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(18),
            Child = content,
        };
    }

    public void ShowQuestions(IReadOnlyList<string> questions, string hotkey)
    {
        list.Children.Clear();
        for (var i = 0; i < questions.Count; i++)
        {
            var line = Theme.Text((i + 1) + ".  " + questions[i], 13.5, Theme.Ink);
            line.Margin = new Thickness(0, 0, 0, 6);
            list.Children.Add(line);
        }
        hint.Text = L10n.T("按 {0} 口头回答，一次说完所有问题即可；没回答的会列进「待确认」。", hotkey);
        var area = SystemParameters.WorkArea;
        Left = area.Right - Width - 24;
        Top = area.Top + 24;
        Show();
    }
}
