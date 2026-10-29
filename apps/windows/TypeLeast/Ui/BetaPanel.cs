using System;
using System.Collections.Generic;
using System.Linq;
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
    private readonly UIElement cancelButton, skipButton, continueButton;
    private string hintText = "";
    private readonly Action<string>? answer;
    private readonly Dictionary<string, string> chosen = new();
    private readonly Button sendButton;

    public BetaPanel(Action skip, Action cancel, Action? resume = null, Action<string>? answer = null)
    {
        this.answer = answer;
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
        title.Children.Add(Theme.Text(L10n.T("提示词模式"), 12, Theme.Accent, bold: true));
        title.Children.Add(roundLabel);
        hint = Theme.Text("", 11.5, Theme.Grey);
        hint.Margin = new Thickness(0, 10, 0, 12);
        var buttons = new DockPanel { LastChildFill = false };
        cancelButton = Theme.Secondary(L10n.T("取消"), cancel);
        continueButton = Theme.Secondary(L10n.T("语音补充"), () => resume?.Invoke());
        sendButton = Theme.Secondary(L10n.T("发送选择"), SendChoices);
        sendButton.Visibility = Visibility.Collapsed;
        skipButton = Theme.Primary(L10n.T("生成"), skip);
        DockPanel.SetDock(cancelButton, Dock.Left);
        DockPanel.SetDock(skipButton, Dock.Right);
        buttons.Children.Add(cancelButton);
        buttons.Children.Add(continueButton);
        buttons.Children.Add(sendButton);
        buttons.Children.Add(skipButton);

        var content = new StackPanel();
        content.Children.Add(title);
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

    private List<string> questions = new();

    /// <summary>One-click answers for the boundary questions the service asks first.</summary>
    private static string[] Choices(string question)
    {
        if (question.Contains("联网") || question.Contains("search the web")) return new[] { L10n.T("全部文件，可联网"), L10n.T("全部文件，仅本地"), L10n.T("只读我指定的文件") };
        if (question.Contains("创新") || question.Contains("new ideas")) return new[] { L10n.T("创新探索"), L10n.T("重复执行") };
        if (question.Contains("轮子") || question.Contains("existing projects")) return new[] { L10n.T("先找已有项目"), L10n.T("不用找") };
        return Array.Empty<string>();
    }

    private void UpdateSend()
    {
        sendButton.Visibility = chosen.Count > 0 && answer is not null ? Visibility.Visible : Visibility.Collapsed;
        continueButton.Visibility = chosen.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SendChoices()
    {
        var text = string.Join("\n", questions.Where(chosen.ContainsKey).Select(q => q + " " + chosen[q]));
        chosen.Clear(); UpdateSend();
        if (text.Length > 0) answer?.Invoke(text);
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
        chosen.Clear(); questions = info.Questions ?? new List<string>(); UpdateSend();
        if (info.Goals is { Count: > 0 })
        {
            list.Children.Add(Theme.Text(L10n.T("核心目的"), 12, bold: true));
            foreach (var item in info.Goals) list.Children.Add(Theme.Text("• " + item, 12.5, Theme.Ink));
        }
        if (info.Confirmed is { Count: > 0 })
        {
            list.Children.Add(Theme.Text(info.Goals is { Count: > 0 } ? L10n.T("关键细节") : L10n.T("我的理解，请核对"), 12, bold: true));
            foreach (var item in info.Confirmed) list.Children.Add(Theme.Text("• " + item, 12.5, Theme.Ink));
        }
        if (info.Questions is { Count: > 0 })
        {
            list.Children.Add(Theme.Text(L10n.T("需要你说明"), 12, bold: true));
            for (var i = 0; i < info.Questions.Count; i++)
            {
                var question = info.Questions[i];
                var line = Theme.Text((i + 1) + ".  " + question, 13.5, Theme.Ink);
                line.Margin = new Thickness(0, 0, 0, 4); list.Children.Add(line);
                var options = Choices(question);
                if (options.Length == 0) continue;
                var row = new WrapPanel { Margin = new Thickness(0, 0, 0, 8) };
                foreach (var option in options)
                {
                    var chip = Theme.Secondary(option, () => { });
                    chip.Margin = new Thickness(0, 0, 6, 4);
                    chip.Tag = option;
                    chip.Click += (_, _) =>
                    {
                        if (chosen.TryGetValue(question, out var old) && old == option) chosen.Remove(question); else chosen[question] = option;
                        foreach (Button other in row.Children) other.FontWeight = chosen.GetValueOrDefault(question) == other.Tag as string ? FontWeights.Bold : FontWeights.Normal;
                        UpdateSend();
                    };
                    row.Children.Add(chip);
                }
                list.Children.Add(row);
            }
        }
        if (info.Notice is { } notice) list.Children.Add(Theme.Text(Messages.BetaNotice(notice), 12, Theme.Warning));
        hintText = L10n.T("点选或按 {0} 语音补充，点「生成」结束。", hotkey);
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
        cancelButton.IsEnabled = true;
        continueButton.IsEnabled = skipButton.IsEnabled = status is null;
    }

    /// <summary>Back to waiting for the next answer, with the same questions.</summary>
    public void Resume()
    {
        SetBusy(null);
        Show();
    }
}
