using TypeLeast.Core;
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace TypeLeast.Ui;

/// <summary>
/// The floating capsule at the bottom of the screen, drawn like the Mac pill: a small
/// dark capsule with × (cancel), a live waveform and a white finish disc while
/// listening; three breathing dots while the service works; the result for a moment.
/// Until the microphone delivers its first audio the waveform stays dim,
/// so the user can see when speech is really being captured.
/// It never takes focus from the app being dictated into. Everything is drawn in code
/// so the glyphs sit exactly in their circles at any DPI.
/// </summary>
internal sealed class RecordingBar : Window
{
    private readonly PillView pill;
    // Animation runs on every rendered frame (usually 60 per second) while the bar is live.
    private readonly System.Diagnostics.Stopwatch frameClock = new();
    private bool animating;
    private readonly DispatcherTimer hideTimer = new() { Interval = TimeSpan.FromMilliseconds(1800) };
    private AudioRecorder? recorder;
    private DateTime startedAt;
    private System.Windows.Forms.Screen? targetScreen;
    private double screenCheckTime;

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

        hideTimer.Tick += (_, _) => { hideTimer.Stop(); StopAnimation(); Hide(); };
        SourceInitialized += (_, _) => TypeLeast.Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
        SizeChanged += (_, _) => Place();
    }

    /// <summary>Use physical pixels so mixed-DPI displays keep the capsule centred.</summary>
    private void Place(bool followMouse = false)
    {
        if (followMouse || targetScreen is null)
            targetScreen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero || !Native.GetWindowRect(handle, out var rect)) return;
        var area = targetScreen.WorkingArea;
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleY;
        Native.MoveWindow(handle, area.Left + (area.Width - (rect.Right - rect.Left)) / 2,
            area.Bottom - (rect.Bottom - rect.Top) - (int)Math.Round(12 * scale));
    }

    /// <summary>Hide at once (a toast takes its place).</summary>
    public void Dismiss() { hideTimer.Stop(); StopAnimation(); Hide(); }

    private void ShowBar()
    {
        hideTimer.Stop();
        if (!IsVisible)
        {
            Show();
            if (SystemParameters.ClientAreaAnimation)
                BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
        }
        Place(followMouse: true);
    }

    /// <param name="prefix">A short tag beside the waveform, e.g. "→EN " for 翻译模式.</param>
    public void ShowRecording(AudioRecorder rec, string prefix = "")
    {
        recorder = rec;
        startedAt = DateTime.UtcNow;
        pill.SetRecording(prefix.Trim());
        StartAnimation();
        ShowBar();
    }

    public void ShowThinking(string? text = null)
    {
        recorder = null;
        pill.SetThinking(text);
        StartAnimation();
        ShowBar();
    }

    public void ShowResult(string text, bool warning)
    {
        recorder = null;
        pill.SetResult(text, warning);
        StartAnimation();
        ShowBar();
        hideTimer.Interval = TimeSpan.FromMilliseconds(warning ? 3500 : 1600);
        hideTimer.Start();
    }

    private void StartAnimation()
    {
        if (animating) return;
        animating = true;
        frameClock.Restart();
        CompositionTarget.Rendering += OnFrame;
    }

    private void StopAnimation()
    {
        if (!animating) return;
        animating = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        // Seconds since the last frame, capped so a stall does not jump the animation.
        var dt = Math.Min(0.1, frameClock.Elapsed.TotalSeconds);
        frameClock.Restart();
        if (dt <= 0) return;
        screenCheckTime += dt;
        if (screenCheckTime >= 0.1)
        {
            screenCheckTime = 0;
            var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
            if (screen.DeviceName != targetScreen?.DeviceName) Place(followMouse: true);
        }
        if (recorder is { } r)
        {
            var left = AudioRecorder.MaxSeconds - (DateTime.UtcNow - startedAt).TotalSeconds;
            pill.Advance(r.Voice, left <= 15 ? Math.Max(0, (int)Math.Ceiling(left)) : null, dt);
        }
        else pill.Advance(VoiceLevel.Quiet, null, dt);
    }
}

/// <summary>Shared dark surface for the idle and live voice bars.</summary>
internal static class VoiceBarPalette
{
    public static readonly Brush Surface = Brushes.Black;
    public static readonly Pen Edge = new(new SolidColorBrush(Color.FromArgb(82, 255, 255, 255)), 1);
    public static readonly Brush StartingSurface = new SolidColorBrush(Color.FromArgb(128, 0, 0, 0));
    public static readonly Brush Foreground = new SolidColorBrush(Color.FromRgb(247, 247, 247));
    public static readonly Brush FinishSurface = Brushes.White;
    public static readonly Brush FinishHover = Brushes.White;
}

/// <summary>The capsule itself. Body clicks do nothing; only the two button discs act.</summary>
internal sealed class PillView : FrameworkElement
{
    private enum Look { Recording, Thinking, Result }

    private const double PillHeight = 34, Button = 26, Inset = 4, BarCount = VoiceWaveform.Count, BarWidth = 2, BarGap = 2;
    private static readonly Brush Capsule = VoiceBarPalette.Surface;
    private static readonly Pen Edge = VoiceBarPalette.Edge;
    private static readonly Brush White = Brushes.White;
    private static readonly Brush SoftWhite = Theme.Hex("#474747");
    private static readonly Brush HoverWhite = Theme.Hex("#575757");
    private static readonly Brush FinishGlyph = Brushes.Black;
    private static readonly Brush Badge = Theme.Hex("#20FFFFFF");
    private static readonly Brush Orange = Theme.Hex("#F0A04B");
    private static readonly Brush StopDisc = VoiceBarPalette.FinishSurface;
    private static readonly Brush Glyph = Theme.Hex("#D9FFFFFF");
    private static readonly Typeface Face = new(Theme.Font, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);
    private static readonly Typeface Bold = new(Theme.Font, FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    private readonly Action onCancel;
    private readonly Action onStop;
    private readonly VoiceWaveform waveform = new();
    private double displayWidth;
    private Look look = Look.Recording;
    private string badge = "";
    private string text = "";
    private bool warning;
    private bool openingMicrophone;
    private int? countdown;
    private double phase;
    private Geometry? processingText;
    private Rect cancelRect, stopRect;
    private bool overCancel, overStop;

    public PillView(Action onCancel, Action onStop)
    {
        this.onCancel = onCancel;
        this.onStop = onStop;
        Focusable = false;
        SnapsToDevicePixels = true;

    }

    public void SetRecording(string tag)
    {
        displayWidth = 0;
        openingMicrophone = false;
        look = Look.Recording; badge = tag; countdown = null; phase = 0; waveform.Reset();
        Refresh();
    }

    public void SetThinking(string? label, bool startingMicrophone = false) { look = Look.Thinking; openingMicrophone = startingMicrophone; text = label ?? ""; phase = 0; processingText = null; Refresh(); }

    public void SetResult(string message, bool isWarning)
    {
        openingMicrophone = false;
        look = Look.Result; warning = isWarning;
        var flat = string.Join(' ', (message ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        text = flat.Length > 40 ? flat[..40] + "…" : flat.Length == 0 ? L10n.T("（无内容）") : flat;
        Refresh();
    }

    /// <summary>Rendering consumes the FFT snapshot; audio analysis stays on the capture callback.</summary>
    public void Advance(VoiceLevel voice, int? secondsLeft, double dt)
    {
        var animate = SystemParameters.ClientAreaAnimation;
        if (animate) phase += dt;
        var dirty = look == Look.Recording && waveform.Advance(voice, dt, !animate);
        var resized = countdown != secondsLeft;
        countdown = secondsLeft;
        var targetWidth = ContentWidth;
        if (displayWidth <= 0 || !animate) displayWidth = targetWidth;
        else if (Math.Abs(displayWidth - targetWidth) > 0.1)
        {
            displayWidth += (targetWidth - displayWidth) * (1 - Math.Exp(-dt / 0.07));
            resized = true;
        }
        else if (displayWidth != targetWidth) { displayWidth = targetWidth; resized = true; }
        if (resized) InvalidateMeasure();
        if (dirty || resized || look == Look.Thinking) InvalidateVisual();
    }

    // Used by the existing media renderer for illustrative input levels.
    public void Advance(double loudness, int? secondsLeft, bool audio, double dt) =>
        Advance(new VoiceLevel(loudness, loudness, VoiceResponse.Height(loudness), audio), secondsLeft, dt);

    private void Refresh() { overCancel = overStop = false; Cursor = null; InvalidateMeasure(); InvalidateVisual(); }

    private double WaveWidth => BarCount * BarWidth + (BarCount - 1) * BarGap;
    private double BadgeWidth => badge.Length == 0 ? 0 : Text(badge, 10, Bold, White).Width + 12;

    private double ContentWidth => look switch
    {
        Look.Recording => Inset + Button + 10 + WaveWidth + (badge.Length > 0 ? 8 + BadgeWidth : 0) + (countdown is null ? 0 : 8 + 30) + 10 + Button + Inset,
        Look.Thinking => Inset + Button + 14 + 26 + (text.Length > 0 ? 10 + Math.Min(200, Text(text, 12, Face, White).Width) : 0) + 16,
        _ => Math.Min(340, 36 + Text(text, 12, Face, White).Width + 16),
    };

    protected override Size MeasureOverride(Size available) => new(Math.Ceiling(displayWidth > 0 ? displayWidth : ContentWidth), PillHeight);

    protected override void OnRender(DrawingContext dc)
    {
        var w = ActualWidth;
        var mid = PillHeight / 2;
        dc.DrawRoundedRectangle(openingMicrophone ? VoiceBarPalette.StartingSurface : Capsule, Edge, new Rect(0.5, 0.5, w - 1, PillHeight - 1), mid - 0.5, mid - 0.5);
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        double Snap(double v) => Math.Round(v * scale) / scale;

        dc.PushClip(new RectangleGeometry(new Rect(1, 1, w - 2, PillHeight - 2), mid - 1, mid - 1));
        cancelRect = stopRect = Rect.Empty;
        switch (look)
        {
            case Look.Recording:
            {
                cancelRect = new Rect(Inset, mid - Button / 2, Button, Button);
                stopRect = new Rect(w - Inset - Button, mid - Button / 2, Button, Button);
                DrawCancel(dc);
                // White finish disc and black check, matching the supplied reference in every appearance.
                var stopCentre = Centre(stopRect);
                dc.DrawEllipse(overStop ? VoiceBarPalette.FinishHover : StopDisc, null, stopCentre, Button / 2, Button / 2);
                var tick = new StreamGeometry();
                using (var g = tick.Open())
                {
                    g.BeginFigure(new Point(stopCentre.X - 6, stopCentre.Y - 0.2), false, false);
                    g.LineTo(new Point(stopCentre.X - 2, stopCentre.Y + 4), true, true);
                    g.LineTo(new Point(stopCentre.X + 6.2, stopCentre.Y - 4.6), true, true);
                }
                dc.DrawGeometry(null, new Pen(FinishGlyph, 2.4) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round }, tick);
                // waveform: mirrored bars, one colour, snapped to whole device pixels
                var x = cancelRect.Right + 10;
                var barWidth = Math.Max(1 / scale, Snap(BarWidth));
                for (var i = 0; i < VoiceWaveform.Count; i++)
                {
                    var h = Math.Max(barWidth, Snap(waveform.Height(i)));
                    var left = Snap(x + i * (BarWidth + BarGap));
                    dc.PushOpacity(waveform.Opacity(i));
                    dc.DrawRoundedRectangle(White, null, new Rect(left, Snap(mid - h / 2), barWidth, h), barWidth / 2, barWidth / 2);
                    dc.Pop();
                }
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
                    var label = Text("0:" + s.ToString("00", CultureInfo.InvariantCulture), 11, Bold, Orange);
                    dc.DrawText(label, new Point(right + (30 - label.Width) / 2, mid - label.Height / 2));
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
                    var wave = SystemParameters.ClientAreaAnimation ? 0.35 + 0.65 * (0.5 + 0.5 * Math.Sin(phase * 3.6 - i * 0.9)) : 0.7;
                    dc.PushOpacity(wave);
                    dc.DrawEllipse(White, null, new Point(start + i * 10, mid - (SystemParameters.ClientAreaAnimation ? Math.Sin(phase * 3.6 - i * 0.9) * 2 : 0)), 2.4, 2.4);
                    dc.Pop();
                }
                if (text.Length > 0)
                {
                    var label = Text(text, 12, Face, Glyph, 200);
                    var origin = new Point(start + 26 + 10 - 3, mid - label.Height / 2);
                    if (!SystemParameters.ClientAreaAnimation) dc.DrawText(label, origin);
                    else
                    {
                        processingText ??= label.BuildGeometry(new Point(0, 0));
                        var textWidth = Math.Min(200, label.Width);
                        var travel = textWidth + 70;
                        var position = travel - ((phase * 55) % travel) - 35;
                        var shimmer = new LinearGradientBrush
                        {
                            MappingMode = BrushMappingMode.Absolute,
                            StartPoint = new Point(position - 35, 0), EndPoint = new Point(position + 35, 0),
                            SpreadMethod = GradientSpreadMethod.Pad,
                        };
                        shimmer.GradientStops.Add(new GradientStop(Color.FromRgb(150, 150, 150), 0));
                        shimmer.GradientStops.Add(new GradientStop(Colors.White, 0.5));
                        shimmer.GradientStops.Add(new GradientStop(Color.FromRgb(150, 150, 150), 1));
                        dc.PushTransform(new TranslateTransform(origin.X, origin.Y));
                        dc.DrawGeometry(shimmer, null, processingText);
                        dc.Pop();
                    }
                }
                break;
            }
            default:
            {
                var tint = warning ? Orange : VoiceBarPalette.Foreground;
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
        dc.Pop();
    }

    /// <summary>A grey disc with a white × made of two strokes, both centred on the disc.</summary>
    private void DrawCancel(DrawingContext dc)
    {
        var c = Centre(cancelRect);
        dc.DrawEllipse(overCancel ? HoverWhite : SoftWhite, null, c, Button / 2, Button / 2);
        var pen = new Pen(White, 1.6) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        const double arm = 4.6;
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
