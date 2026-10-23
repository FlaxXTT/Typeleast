using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// "已把「DeepSeek」加入词典 · 撤销" for a few seconds after the edit learner adds a word. Topmost and
/// never activated, so the app being typed into keeps focus; 撤销 removes the word again.
/// </summary>
internal sealed class LearnedToast : Window
{
    private static readonly TimeSpan Duration = TimeSpan.FromSeconds(6);

    private readonly TextBlock message = Theme.Text("", 13, Theme.Ink);
    private readonly DispatcherTimer hideTimer = new() { Interval = Duration };
    private Action? undo;

    public LearnedToast()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Focusable = false;
        SourceInitialized += (_, _) => TypeLeast.Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); Hide(); };

        message.VerticalAlignment = VerticalAlignment.Center;
        message.Margin = new Thickness(0, 0, 12, 0);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(message);
        row.Children.Add(Theme.Secondary(L10n.T("撤销"), () => { hideTimer.Stop(); Hide(); undo?.Invoke(); undo = null; }));
        Content = new Border
        {
            Background = Theme.CardFill,
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18),
            Padding = new Thickness(16, 6, 8, 6),
            Child = row,
        };
    }

    public void Show(string text, Action onUndo)
    {
        message.Text = text;
        undo = onUndo;
        Show();
        UpdateLayout();
        // Bottom-centre, above the recording pill.
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        Top = area.Bottom - ActualHeight - 72;
        hideTimer.Stop();
        hideTimer.Start();
    }
}
