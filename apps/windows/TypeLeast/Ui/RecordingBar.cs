using TypeLeast.Core;
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace TypeLeast.Ui;

/// <summary>
/// The floating capsule at the bottom of the screen, drawn like the Mac pill: a small
/// dark capsule with × (cancel), a red live dot, a waveform and a stop disc while
/// listening; three breathing dots while the service works; the result for a moment.
/// Until the microphone delivers its first audio the dot is grey and the waveform dim,
/// so the user can see when speech is really being captured.
/// It never takes focus from the app being dictated into. Everything is drawn in code
/// so the glyphs sit exactly in their circles at any DPI.
/// </summary>
internal sealed class RecordingBar : Window
{
    private readonly PillView pill;
    private readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly DispatcherTimer hideTimer = new() { Interval = TimeSpan.FromMilliseconds(1800) };
    private AudioRecorder? recorder;
    private DateTime startedAt;
    private readonly AudioLevel level = new();

    public RecordingBar(AppHost host)
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
        UseLayoutRounding = true;

        pill = new PillView(host.Cancel, host.Toggle) { Margin = new Thickness(12) };
        Content = pill;

        tick.Tick += (_, _) => Animate();
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); tick.Stop(); Hide(); };
        SourceInitialized += (_, _) => TypeLeast.Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
        SizeChanged += (_, _) => Place();
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

    /// <param name="prefix">A short tag beside the waveform, e.g. "→EN " for 翻译模式.</param>
    public void ShowRecording(AudioRecorder rec, string prefix = "")
    {
        recorder = rec;
        startedAt = DateTime.UtcNow;
        level.Reset();
        pill.SetRecording(prefix.Trim());
        tick.Start();
        ShowBar();
    }

    public void ShowThinking(string? text = null)
    {
        recorder = null;
        pill.SetThinking(text);
        tick.Start();
        ShowBar();
    }

    public void ShowResult(string text, bool warning)
    {
        recorder = null;
        tick.Stop();
        pill.SetResult(text, warning);
        ShowBar();
        hideTimer.Interval = TimeSpan.FromMilliseconds(warning ? 3500 : 1600);
        hideTimer.Start();
    }

    private void Animate()
    {
        if (recorder is { } r)
        {
            var left = AudioRecorder.MaxSeconds - (DateTime.UtcNow - startedAt).TotalSeconds;
            pill.Advance(level.Next(r.Level), left <= 15 ? Math.Max(0, (int)Math.Ceiling(left)) : null, r.HasAudio);
        }
        else pill.Advance(0, null, true);
    }
}

/// <summary>The capsule itself. Body clicks do nothing; only the two button discs act.</summary>
internal sealed class PillView : FrameworkElement
{
    private enum Look { Recording, Thinking, Result }

    private const double PillHeight = 34, Button = 22, Inset = 6, BarCount = 17, BarWidth = 2, BarGap = 3, WaveHeight = 18;
    private static readonly Brush Capsule = Theme.Hex("#EB161616");
    private static readonly Pen Edge = new(Theme.Hex("#26FFFFFF"), 1);
    private static readonly Brush White = Brushes.White;
    private static readonly Brush SoftWhite = Theme.Hex("#1FFFFFFF");
    private static readonly Brush HoverWhite = Theme.Hex("#33FFFFFF");
    private static readonly Brush Ink = Theme.Hex("#161616");
    private static readonly Brush Live = Theme.Hex("#FF453A");
    private static readonly Brush Waiting = Theme.Hex("#8C8C8C");
    private static readonly Brush Badge = Theme.Hex("#3E9BE9");
    private static readonly Brush Orange = Theme.Hex("#F0A04B");
    private static readonly Brush Green = Theme.Hex("#4CC27A");
    private static readonly Brush StopDisc = Theme.Hex("#F2FFFFFF");
    private static readonly Brush Glyph = Theme.Hex("#D9FFFFFF");
    private static readonly Typeface Face = new(Theme.Font, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);
    private static readonly Typeface Bold = new(Theme.Font, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    private readonly Action onCancel;
    private readonly Action onStop;
    private readonly double[] bars = new double[(int)BarCount];
    private readonly double[] seeds = new double[(int)BarCount];
    private Look look = Look.Recording;
    private string badge = "";
    private string text = "";
    private bool warning;
    private int? countdown;
    private double level;
    private bool listening;
    private double phase;
    private Rect cancelRect, stopRect;
    private bool overCancel, overStop;

    public PillView(Action onCancel, Action onStop)
    {
        this.onCancel = onCancel;
        this.onStop = onStop;
        Focusable = false;
        SnapsToDevicePixels = true;
        var random = new Random(7);
        for (var i = 0; i < seeds.Length; i++) seeds[i] = random.NextDouble() * Math.PI * 2;
    }

    public void SetRecording(string tag)
    {
        look = Look.Recording; badge = tag; countdown = null; level = 0; listening = false; Array.Clear(bars);
        Refresh();
    }

    public void SetThinking(string? label) { look = Look.Thinking; text = label ?? ""; Refresh(); }

    public void SetResult(string message, bool isWarning)
    {
        look = Look.Result; warning = isWarning;
        var flat = string.Join(' ', (message ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        text = flat.Length > 40 ? flat[..40] + "…" : flat.Length == 0 ? L10n.T("（无内容）") : flat;
        Refresh();
    }

    /// <summary>One animation step: bars rise fast and fall gently towards the live level (0..1, from AudioLevel).</summary>
    public void Advance(double loudness, int? secondsLeft, bool audio)
    {
        listening = audio;
        phase += 0.12;
        if (phase > Math.PI * 2000) phase = 0;
        level += (loudness - level) * (loudness > level ? 0.6 : 0.25);
        for (var i = 0; i < bars.Length; i++)
        {
            var target = Target(i);
            bars[i] += (target - bars[i]) * (target > bars[i] ? 0.55 : 0.2);
        }
        if (countdown != secondsLeft) { countdown = secondsLeft; Refresh(); }
        else InvalidateVisual();
    }

    /// <summary>Taller in the middle, shorter at the ends, each bar moving a little on its own.</summary>
    private double Target(int i)
    {
        var centre = (bars.Length - 1) / 2.0;
        var distance = Math.Abs(i - centre) / centre;
        var envelope = 0.35 + 0.65 * Math.Pow(Math.Cos(distance * Math.PI / 2), 1.5);
        var motion = 0.7 + 0.3 * Math.Sin(phase * (1.1 + (i % 5) * 0.23) + seeds[i]);
        var shaped = level; // already scaled to the speaker by AudioLevel
        return Math.Max(0.11, shaped * envelope * motion);
    }

    private void Refresh() { overCancel = overStop = false; Cursor = null; InvalidateMeasure(); InvalidateVisual(); }

    private double WaveWidth => BarCount * BarWidth + (BarCount - 1) * BarGap;
    private double BadgeWidth => badge.Length == 0 ? 0 : Text(badge, 10, Bold, White).Width + 12;

    protected override Size MeasureOverride(Size available)
    {
        double width = look switch
        {
            // ×, gap, live dot, gap, waveform, [badge], [countdown], gap, stop
            Look.Recording => Inset + Button + 10 + 6 + 10 + WaveWidth + (badge.Length > 0 ? 8 + BadgeWidth : 0) + (countdown is null ? 0 : 8 + 22) + 12 + Button + Inset,
            Look.Thinking => Inset + Button + 14 + 26 + (text.Length > 0 ? 10 + Math.Min(200, Text(text, 12, Face, White).Width) : 0) + 16,
            _ => Math.Min(340, 36 + Text(text, 12, Face, White).Width + 16),
        };
        return new Size(Math.Ceiling(width), PillHeight);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var mid = PillHeight / 2;
        dc.DrawRoundedRectangle(Capsule, Edge, new Rect(0.5, 0.5, w - 1, PillHeight - 1), mid - 0.5, mid - 0.5);
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        double Snap(double v) => Math.Round(v * scale) / scale;

        cancelRect = stopRect = Rect.Empty;
        switch (look)
        {
            case Look.Recording:
            {
                cancelRect = new Rect(Inset, mid - Button / 2, Button, Button);
                stopRect = new Rect(w - Inset - Button, mid - Button / 2, Button, Button);
                DrawCancel(dc);
                // stop: a white disc with a small dark rounded square, exactly centred
                var stopCentre = Centre(stopRect);
                dc.DrawEllipse(overStop ? White : StopDisc, null, stopCentre, Button / 2, Button / 2);
                dc.DrawRoundedRectangle(Ink, null, new Rect(stopCentre.X - 3.5, stopCentre.Y - 3.5, 7, 7), 1.6, 1.6);
                // the microphone is on: a small red dot that brightens with the voice
                var dot = new Point(cancelRect.Right + 10 + 3, mid);
                dc.PushOpacity(listening ? 0.55 + 0.45 * Math.Min(1, level * 1.4) : 1);
                dc.DrawEllipse(listening ? Live : Waiting, null, dot, 3, 3);
                dc.Pop();
                if (!listening) dc.PushOpacity(0.4);
                // waveform: mirrored bars, one colour, snapped to whole device pixels
                var x = dot.X + 3 + 10;
                var barWidth = Math.Max(1 / scale, Snap(BarWidth));
                for (var i = 0; i < bars.Length; i++)
                {
                    var h = Math.Max(barWidth, Snap(bars[i] * WaveHeight));
                    var left = Snap(x + i * (BarWidth + BarGap));
                    dc.DrawRoundedRectangle(White, null, new Rect(left, Snap(mid - h / 2), barWidth, h), barWidth / 2, barWidth / 2);
                }
                if (!listening) dc.Pop();
                var right = x + WaveWidth + 8;
                if (badge.Length > 0)
                {
                    var label = Text(badge, 10, Bold, White);
                    dc.DrawRoundedRectangle(Badge, null, new Rect(right, mid - 8, BadgeWidth, 16), 5, 5);
                    dc.DrawText(label, new Point(right + (BadgeWidth - label.Width) / 2, mid - label.Height / 2));
                    right += BadgeWidth + 8;
                }
                if (countdown is { } s)
                {
                    var label = Text(s.ToString(CultureInfo.InvariantCulture), 11, Bold, Orange);
                    dc.DrawText(label, new Point(right + (22 - label.Width) / 2, mid - label.Height / 2));
                }
                break;
            }
            case Look.Thinking:
            {
                cancelRect = new Rect(Inset, mid - Button / 2, Button, Button);
                DrawCancel(dc);
                var start = cancelRect.Right + 14 + 3;
                for (var i = 0; i < 3; i++)
                {
                    var wave = 0.35 + 0.65 * (0.5 + 0.5 * Math.Sin(phase * 1.5 - i * 0.9));
                    dc.PushOpacity(wave);
                    dc.DrawEllipse(White, null, new Point(start + i * 10, mid), 2.6 + wave * 0.7, 2.6 + wave * 0.7);
                    dc.Pop();
                }
                if (text.Length > 0)
                {
                    var label = Text(text, 12, Face, Glyph, 200);
                    dc.DrawText(label, new Point(start + 26 + 10 - 3, mid - label.Height / 2));
                }
                break;
            }
            default:
            {
                var tint = warning ? Orange : Green;
                var c = new Point(18, mid);
                dc.PushOpacity(0.22); dc.DrawEllipse(tint, null, c, 8, 8); dc.Pop();
                var pen = new Pen(tint, 1.8) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
                if (warning)
                {
                    dc.DrawLine(pen, new Point(c.X, c.Y - 3.6), new Point(c.X, c.Y + 0.8));
                    dc.DrawEllipse(tint, null, new Point(c.X, c.Y + 3.2), 1, 1);
                }
                else
                {
                    var check = new StreamGeometry();
                    using (var g = check.Open())
                    {
                        g.BeginFigure(new Point(c.X - 3.8, c.Y - 0.2), false, false);
                        g.LineTo(new Point(c.X - 1.0, c.Y + 2.6), true, true);
                        g.LineTo(new Point(c.X + 4.2, c.Y - 3.2), true, true);
                    }
                    dc.DrawGeometry(null, pen, check);
                }
                var label = Text(text, 12, Face, White, w - 36 - 16);
                dc.DrawText(label, new Point(34, mid - label.Height / 2));
                break;
            }
        }
    }

    /// <summary>A soft disc with an × made of two strokes, both centred on the disc.</summary>
    private void DrawCancel(DrawingContext dc)
    {
        var c = Centre(cancelRect);
        dc.DrawEllipse(overCancel ? HoverWhite : SoftWhite, null, c, Button / 2, Button / 2);
        var pen = new Pen(Glyph, 1.5) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        const double arm = 3.4;
        dc.DrawLine(pen, new Point(c.X - arm, c.Y - arm), new Point(c.X + arm, c.Y + arm));
        dc.DrawLine(pen, new Point(c.X - arm, c.Y + arm), new Point(c.X + arm, c.Y - arm));
    }

    private static Point Centre(Rect r) => new(r.X + r.Width / 2, r.Y + r.Height / 2);

    private System.Windows.Media.FormattedText Text(string s, double size, Typeface face, Brush brush, double maxWidth = 0)
    {
        var f = new System.Windows.Media.FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, face, size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip)
        { MaxLineCount = 1, Trimming = TextTrimming.CharacterEllipsis };
        if (maxWidth > 0) f.MaxTextWidth = maxWidth;
        return f;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var p = e.GetPosition(this);
        var cancel = cancelRect.Contains(p);
        var stop = stopRect.Contains(p);
        if (cancel == overCancel && stop == overStop) return;
        overCancel = cancel; overStop = stop;
        Cursor = cancel || stop ? Cursors.Hand : null;
        ToolTip = cancel ? L10n.T("取消（Esc）") : stop ? L10n.T("结束并整理") : null;
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        if (!overCancel && !overStop) return;
        overCancel = overStop = false; Cursor = null; ToolTip = null; InvalidateVisual();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        var p = e.GetPosition(this);
        if (cancelRect.Contains(p)) onCancel();
        else if (stopRect.Contains(p)) onStop();
        e.Handled = true;
    }

    protected override HitTestResult HitTestCore(PointHitTestParameters hit) => new PointHitTestResult(this, hit.HitPoint);
}
