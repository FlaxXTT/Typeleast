using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// A short message with 撤销 for a few seconds: "转录已取消" after a cancelled recording,
/// "已把「DeepSeek」加入词典" after the edit learner adds a word. Topmost and never activated, so
/// the app being typed into keeps focus.
/// </summary>
internal sealed class LearnedToast : Window
{
    private static readonly TimeSpan Duration = TimeSpan.FromSeconds(6);

    private readonly TextBlock message = Theme.Text("", 14, Brushes.White, bold: true, wrap: false);
    private readonly DispatcherTimer hideTimer = new() { Interval = Duration };
    private Action? undo;
    /// <summary>Called when the toast goes away without 撤销 (timed out or replaced).</summary>
    private Action? expired;

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
        hideTimer.Tick += (_, _) => Finish();

        var icon = new Grid { Width = 18, Height = 18, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        var blue = Theme.Hex("#7390FF");
        icon.Children.Add(new System.Windows.Shapes.Ellipse { Stroke = blue, StrokeThickness = 1.6 });
        icon.Children.Add(new TextBlock { Text = "i", Foreground = blue, FontWeight = FontWeights.Bold, FontSize = 11,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center });
        message.VerticalAlignment = VerticalAlignment.Center;
        message.Margin = new Thickness(0, 0, 12, 0);
        var undoButton = new Border
        {
            Background = Theme.Hex("#29FFFFFF"),
            CornerRadius = new CornerRadius(15),
            Padding = new Thickness(14, 6, 14, 6),
            Cursor = System.Windows.Input.Cursors.Hand,
            Child = new TextBlock { Text = L10n.T("撤销"), Foreground = Brushes.White, FontSize = 13, FontFamily = Theme.Font },
        };
        undoButton.MouseLeftButtonUp += (_, _) => { var action = undo; undo = null; expired = null; hideTimer.Stop(); Hide(); action?.Invoke(); };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(icon);
        row.Children.Add(message);
        row.Children.Add(undoButton);
        Content = new Border
        {
            Background = Theme.Hex("#1A1A1A"),
            BorderBrush = Theme.Hex("#1FFFFFFF"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 8, 8, 8),
            Child = row,
        };
    }

    public void Show(string text, Action onUndo, Action? onExpired = null)
    {
        Finish();
        message.Text = text;
        undo = onUndo;
        expired = onExpired;
        Show();
        UpdateLayout();
        // Bottom-centre, above the recording pill.
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        Top = area.Bottom - ActualHeight - 72;
        hideTimer.Start();
    }

    /// <summary>Go away now; anything waiting on 撤销 is dropped.</summary>
    public void Finish()
    {
        hideTimer.Stop();
        var done = expired;
        undo = null; expired = null;
        if (IsVisible) Hide();
        done?.Invoke();
    }
}
