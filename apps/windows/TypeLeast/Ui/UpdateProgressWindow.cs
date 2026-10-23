using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// A small window while an in-app update runs, so it never looks stuck: a ring that fills with the
/// download (percentage and MB in the middle), then turns while the update is checked and installed,
/// with the three steps underneath. Shown for manual and automatic updates alike.
/// </summary>
internal sealed class UpdateProgressWindow : Window
{
    private const double Size = 136, Thickness = 10;
    private readonly TextBlock title = Theme.Text("", 14, Theme.Ink, bold: true);
    private readonly TextBlock status = Theme.Text("", 12, Theme.Grey);
    private readonly TextBlock percent = new() { FontSize = 30, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock amount = Theme.Text("", 11, Theme.Grey);
    private readonly TextBlock stepWord = new() { FontSize = 18, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Path arc = new() { StrokeThickness = Thickness, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly Path spinner = new() { StrokeThickness = Thickness, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly RotateTransform spin = new(0, Size / 2, Size / 2);
    private readonly StackPanel steps = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock summary = Theme.Text("", 12, Theme.Grey);

    public UpdateProgressWindow()
    {
        Title = L10n.T("更新 TypeLeast");
        Width = 360;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Topmost = true;
        Background = Theme.CardFill;

        var accent = Theme.Accent;
        var track = new Ellipse { Width = Size, Height = Size, StrokeThickness = Thickness, Stroke = new SolidColorBrush(Color.FromArgb(34, 0, 0, 0)) };
        if (accent is SolidColorBrush solid) track.Stroke = new SolidColorBrush(Color.FromArgb(36, solid.Color.R, solid.Color.G, solid.Color.B));
        arc.Stroke = accent;
        spinner.Stroke = accent;
        spinner.Data = ArcData(0.24);
        spinner.RenderTransform = spin;
        percent.Foreground = Theme.Ink;
        stepWord.Foreground = accent;
        amount.HorizontalAlignment = HorizontalAlignment.Center;
        var middle = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        middle.Children.Add(percent);
        middle.Children.Add(amount);
        middle.Children.Add(stepWord);
        var ring = new Grid { Width = Size, Height = Size, Margin = new Thickness(0, 6, 0, 18), HorizontalAlignment = HorizontalAlignment.Center };
        ring.Children.Add(track);
        ring.Children.Add(arc);
        ring.Children.Add(spinner);
        ring.Children.Add(middle);
        // Always turning while there is no percentage, so an update that takes a while never looks stuck.
        spin.BeginAnimation(RotateTransform.AngleProperty,
            new DoubleAnimation(0, 360, new Duration(TimeSpan.FromSeconds(1.4))) { RepeatBehavior = RepeatBehavior.Forever });

        title.HorizontalAlignment = HorizontalAlignment.Center;
        status.HorizontalAlignment = HorizontalAlignment.Center;
        status.Margin = new Thickness(0, 4, 0, 18);
        status.TextTrimming = TextTrimming.CharacterEllipsis;
        var content = new StackPanel { Margin = new Thickness(28, 26, 28, 24) };
        content.Children.Add(ring);
        content.Children.Add(title);
        content.Children.Add(status);
        content.Children.Add(steps);
        summary.Margin = new Thickness(0, 16, 0, 0);
        summary.Visibility = Visibility.Collapsed;
        content.Children.Add(summary);
        Content = content;
    }

    public void Start(string version, string notes = "")
    {
        SetVersion(version, notes);
        Report(UpdateStage.Downloading, 0, null);
        Show();
    }

    public void SetVersion(string version, string notes = "")
    {
        title.Text = L10n.T("正在更新到 {0}", version);
        summary.Text = notes.Length > 0 ? L10n.T("本次更新") + "\n" + notes : "";
        summary.Visibility = notes.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public void Report(UpdateStage stage, long received, long? total, string source = "GitHub")
    {
        status.Text = UpdateProgressText.Describe(stage, received, total, source);
        var fraction = UpdateProgressText.Fraction(stage, received, total);
        var known = fraction is not null;
        arc.Visibility = percent.Visibility = amount.Visibility = known ? Visibility.Visible : Visibility.Collapsed;
        spinner.Visibility = stepWord.Visibility = known ? Visibility.Collapsed : Visibility.Visible;
        if (fraction is { } f)
        {
            arc.Data = ArcData(Math.Max(0.004, f));
            percent.Text = ((int)Math.Floor(f * 100)).ToString(System.Globalization.CultureInfo.InvariantCulture) + "%";
            amount.Text = total is > 0 ? Mb(received) + " / " + Mb(total.Value) + " MB" : "";
        }
        stepWord.Text = L10n.T(UpdatePolicy.Steps[UpdatePolicy.Step(stage)]);
        DrawSteps(UpdatePolicy.Step(stage));
    }

    /// <summary>From 12 o'clock clockwise to <paramref name="fraction"/> of the ring.</summary>
    private static Geometry ArcData(double fraction)
    {
        var r = (Size - Thickness) / 2;
        var (x, y) = RingGeometry.ArcEnd(fraction, r, Size / 2, Size / 2);
        var figure = new PathFigure { StartPoint = new Point(Size / 2, Size / 2 - r), IsClosed = false };
        figure.Segments.Add(new ArcSegment(new Point(x, y), new Size(r, r), 0, RingGeometry.IsLargeArc(fraction), SweepDirection.Clockwise, true));
        return new PathGeometry([figure]);
    }

    /// <summary>下载 · 核对 · 安装: done steps filled, the current one ringed.</summary>
    private void DrawSteps(int current)
    {
        steps.Children.Clear();
        for (var i = 0; i < UpdatePolicy.Steps.Length; i++)
        {
            var dot = new Ellipse
            {
                Width = 14, Height = 14,
                Fill = i < current ? Theme.Accent : Brushes.Transparent,
                Stroke = i <= current ? Theme.Accent : Theme.Grey,
                StrokeThickness = i == current ? 2.5 : 1.5,
            };
            var label = Theme.Text(L10n.T(UpdatePolicy.Steps[i]), 11.5, i <= current ? Theme.Ink : Theme.Grey, bold: i == current);
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.Margin = new Thickness(0, 6, 0, 0);
            var column = new StackPanel { Width = 52 };
            dot.HorizontalAlignment = HorizontalAlignment.Center;
            column.Children.Add(dot);
            column.Children.Add(label);
            steps.Children.Add(column);
            if (i < UpdatePolicy.Steps.Length - 1)
                steps.Children.Add(new Rectangle { Width = 36, Height = 1.5, Margin = new Thickness(0, 6, 0, 0), VerticalAlignment = VerticalAlignment.Top, Fill = i < current ? Theme.Accent : Theme.Grey, Opacity = i < current ? 1 : 0.4 });
        }
    }

    private static string Mb(long bytes) => (bytes / 1048576.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
}
