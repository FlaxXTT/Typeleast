using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace TypeLeast.Ui;

/// <summary>
/// The floating capsule at the bottom of the screen: ✕, live waveform, time, ■
/// while listening; "整理中…" while the service works; the result for a moment.
/// It never takes focus from the app being dictated into.
/// </summary>
internal sealed class RecordingBar : Window
{
    private readonly AppHost host;
    private readonly Rectangle[] bars = new Rectangle[14];
    private readonly TextBlock label;
    private readonly Button cancel;
    private readonly Button stop;
    private readonly StackPanel wave;
    private readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(50) };
    private readonly DispatcherTimer hideTimer = new() { Interval = TimeSpan.FromMilliseconds(1800) };
    private AudioRecorder? recorder;
    private DateTime startedAt;
    private readonly double[] history = new double[14];

    public RecordingBar(AppHost host)
    {
        this.host = host;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        Focusable = false;

        cancel = RoundButton("✕", "取消（Esc）", () => host.Cancel());
        stop = RoundButton("■", "结束并整理", () => host.Toggle());
        wave = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        for (var i = 0; i < bars.Length; i++)
        {
            bars[i] = new Rectangle { Width = 3, Height = 4, RadiusX = 1.5, RadiusY = 1.5, Fill = Brushes.White, Margin = new Thickness(1.5, 0, 1.5, 0), VerticalAlignment = VerticalAlignment.Center };
            wave.Children.Add(bars[i]);
        }
        label = new TextBlock { Foreground = Brushes.White, FontFamily = Theme.Font, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(4, 0, 8, 0) };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(cancel);
        row.Children.Add(wave);
        row.Children.Add(label);
        row.Children.Add(stop);
        Content = new Border
        {
            Background = Theme.Pill,
            CornerRadius = new CornerRadius(22),
            Padding = new Thickness(8, 6, 8, 6),
            Child = row,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 3, Opacity = 0.25 },
            Margin = new Thickness(12),
        };

        tick.Tick += (_, _) => Animate();
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); Hide(); };
        SourceInitialized += (_, _) => TypeLeast.Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
        SizeChanged += (_, _) => Place();
    }

    private static Button RoundButton(string glyph, string tip, Action onClick)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = glyph, Foreground = Brushes.White, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            Width = 28,
            Height = 28,
            ToolTip = tip,
            Cursor = Cursors.Hand,
            Focusable = false,
            Background = Theme.Hex("#3A3A3C"),
            BorderThickness = new Thickness(0),
        };
        var template = new ControlTemplate(typeof(Button));
        var ellipse = new FrameworkElementFactory(typeof(Border));
        ellipse.SetValue(Border.CornerRadiusProperty, new CornerRadius(14));
        ellipse.SetBinding(Border.BackgroundProperty, new System.Windows.Data.Binding("Background") { RelativeSource = System.Windows.Data.RelativeSource.TemplatedParent });
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
        ellipse.AppendChild(presenter);
        template.VisualTree = ellipse;
        b.Template = template;
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Bottom centre of the screen's work area.</summary>
    private void Place()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        Top = area.Bottom - ActualHeight - 16;
    }

    private void ShowBar()
    {
        hideTimer.Stop();
        if (!IsVisible) Show();
        Place();
    }

    public void ShowRecording(AudioRecorder rec)
    {
        recorder = rec;
        startedAt = DateTime.UtcNow;
        Array.Clear(history);
        cancel.Visibility = Visibility.Visible;
        stop.Visibility = Visibility.Visible;
        wave.Visibility = Visibility.Visible;
        label.Text = "0:00";
        tick.Start();
        ShowBar();
    }

    public void ShowThinking()
    {
        recorder = null;
        cancel.Visibility = Visibility.Collapsed;
        stop.Visibility = Visibility.Collapsed;
        wave.Visibility = Visibility.Visible;
        label.Text = "整理中…";
        ShowBar();
    }

    public void ShowResult(string text, bool warning)
    {
        recorder = null;
        tick.Stop();
        cancel.Visibility = Visibility.Collapsed;
        stop.Visibility = Visibility.Collapsed;
        wave.Visibility = Visibility.Collapsed;
        label.Text = text;
        label.Foreground = warning ? Theme.Hex("#FFC66D") : Brushes.White;
        ShowBar();
        hideTimer.Interval = TimeSpan.FromMilliseconds(warning ? 3500 : 1600);
        hideTimer.Start();
    }

    private void Animate()
    {
        label.Foreground = Brushes.White;
        if (recorder is { } r)
        {
            Array.Copy(history, 1, history, 0, history.Length - 1);
            history[^1] = r.Level;
            var elapsed = DateTime.UtcNow - startedAt;
            var left = AudioRecorder.MaxSeconds - elapsed.TotalSeconds;
            label.Text = left <= 15 ? "还剩 " + Math.Max(0, (int)left) + " 秒" : $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
        }
        else
        {
            // Thinking: a gentle travelling pulse.
            var t = DateTime.UtcNow.TimeOfDay.TotalSeconds;
            for (var i = 0; i < history.Length; i++) history[i] = 0.25 + 0.2 * Math.Sin(t * 6 - i * 0.6);
        }
        for (var i = 0; i < bars.Length; i++) bars[i].Height = 4 + history[i] * 20;
    }
}
