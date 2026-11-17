using System;
using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>A resting voice capsule that expands to show the current shortcut.</summary>
internal sealed class IdleBar : Window
{
    private readonly IdleVoiceView voice;

    public IdleBar(AppHost host)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        ResizeMode = ResizeMode.NoResize;
        SizeToContent = SizeToContent.WidthAndHeight;
        UseLayoutRounding = true;
        voice = new IdleVoiceView(host.Toggle, () => L10n.T("开始听写") + "  " + host.HotkeyLabel)
        {
            Margin = new Thickness(12),
        };
        Content = voice;
        SourceInitialized += (_, _) => Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
        SizeChanged += (_, _) => Place();
        IsVisibleChanged += (_, _) => { if (!IsVisible) voice.Reset(); };
    }

    private void Place()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - ActualWidth) / 2;
        Top = area.Bottom - ActualHeight - 12;
    }
}

internal sealed class IdleVoiceView : FrameworkElement
{
    private readonly Action onClick;
    private readonly Func<string> hint;
    private readonly Stopwatch clock = new();
    private bool hovering, animating;
    private double expansion;
    private static readonly Typeface Face = new(Theme.Font, FontStyles.Normal, FontWeights.Medium, FontStretches.Normal);

    public IdleVoiceView(Action onClick, Func<string> hint)
    {
        this.onClick = onClick;
        this.hint = hint;
        Focusable = false;
        SnapsToDevicePixels = true;
        Cursor = Cursors.Hand;
        ToolTip = L10n.T("开始听写");
        Unloaded += (_, _) => StopAnimation();
    }

    public void Reset()
    {
        StopAnimation();
        hovering = false;
        expansion = 0;
        InvalidateMeasure();
        InvalidateVisual();
    }

    private FormattedText Label => new(hint(), CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
        Face, 11.5, VoiceBarPalette.Foreground, VisualTreeHelper.GetDpi(this).PixelsPerDip)
    { MaxLineCount = 1, Trimming = TextTrimming.CharacterEllipsis, MaxTextWidth = 260 };

    protected override Size MeasureOverride(Size available)
    {
        var expandedWidth = Math.Max(176, Label.Width + 62);
        return new Size(56 + (expandedWidth - 56) * expansion, 16 + 18 * expansion);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var mid = ActualHeight / 2;
        dc.DrawRoundedRectangle(VoiceBarPalette.Surface, VoiceBarPalette.Edge,
            new Rect(0.5, 0.5, ActualWidth - 1, ActualHeight - 1), mid - 0.5, mid - 0.5);
        var symbolX = ActualWidth / 2 + (28 - ActualWidth / 2) * expansion;
        double[] heights = { 6, 11, 16, 11, 6 };
        for (var i = 0; i < heights.Length; i++)
        {
            var delay = i * 0.06;
            var progress = Math.Clamp((expansion - delay) / (1 - delay), 0, 1);
            var height = 3.2 + (heights[i] - 3.2) * progress;
            dc.PushOpacity(0.6 + expansion * 0.35);
            dc.DrawRoundedRectangle(VoiceBarPalette.Foreground, null,
                new Rect(symbolX + (i - 2) * 5 - 1.6, mid - height / 2, 3.2, height), 1.6, 1.6);
            dc.Pop();
        }
        var opacity = Math.Clamp((expansion - 0.35) / 0.65, 0, 1);
        var labelX = 48 + (1 - opacity) * 5;
        if (opacity > 0 && ActualWidth > labelX + 10)
        {
            var label = Label;
            label.MaxTextWidth = ActualWidth - labelX - 10;
            dc.PushOpacity(opacity);
            dc.DrawText(label, new Point(labelX, mid - label.Height / 2));
            dc.Pop();
        }
    }

    private void SetHover(bool value)
    {
        hovering = value;
        if (!SystemParameters.ClientAreaAnimation)
        {
            expansion = value ? 1 : 0;
            StopAnimation();
            InvalidateMeasure();
            InvalidateVisual();
            return;
        }
        if (animating) return;
        animating = true;
        clock.Restart();
        CompositionTarget.Rendering += OnFrame;
    }

    private void OnFrame(object? sender, EventArgs e)
    {
        var dt = Math.Min(0.1, clock.Elapsed.TotalSeconds);
        clock.Restart();
        var target = hovering ? 1.0 : 0.0;
        expansion += (target - expansion) * (1 - Math.Exp(-dt / 0.065));
        if (Math.Abs(target - expansion) < 0.002)
        {
            expansion = target;
            StopAnimation();
        }
        InvalidateMeasure();
        InvalidateVisual();
    }

    private void StopAnimation()
    {
        if (!animating) return;
        CompositionTarget.Rendering -= OnFrame;
        animating = false;
        clock.Stop();
    }

    protected override void OnMouseEnter(MouseEventArgs e) { base.OnMouseEnter(e); SetHover(true); }
    protected override void OnMouseLeave(MouseEventArgs e) { base.OnMouseLeave(e); SetHover(false); }
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { onClick(); e.Handled = true; }
}
