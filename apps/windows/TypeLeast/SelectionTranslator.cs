using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>
/// 选中即翻译: select text with the mouse in any app and a small 「翻译」 button appears next to it;
/// a click shows the translation in a bubble. The selection is read on this computer (UI Automation)
/// and sent to the model only after the click. Nothing is inserted or recorded. A low-level mouse
/// hook sees only button presses and where they happen. Both windows never take focus, so the app
/// being read keeps its focus and its selection.
/// </summary>
internal sealed class SelectionTranslator : IDisposable
{
    private static readonly TimeSpan ButtonTime = TimeSpan.FromSeconds(6);
    /// <summary>Longest selection translated at once, in characters.</summary>
    public const int Limit = 5000;

    private readonly Dispatcher dispatcher;
    private readonly Native.LowLevelKeyboardProc proc;
    private IntPtr handle;
    private readonly SelectionPopup popup = new();
    private readonly DispatcherTimer buttonTimer = new() { Interval = ButtonTime };
    private Native.MSLLHOOKSTRUCT downAt;
    private uint lastUpTime;
    private Native.MSLLHOOKSTRUCT lastUpAt;
    private int generation;

    public Func<bool> Enabled { get; set; } = () => true;
    public Func<string> PreferredTarget { get; set; } = () => "en";
    /// <summary>Translate (text, target); null on failure. Runs off the UI thread.</summary>
    public Func<string, string, Task<string?>>? Translate { get; set; }

    public SelectionTranslator(Dispatcher dispatcher)
    {
        this.dispatcher = dispatcher;
        proc = Callback; // keep the delegate alive for as long as the hook is installed
        buttonTimer.Tick += (_, _) => { buttonTimer.Stop(); if (popup.ShowsButton) Hide(); };
        popup.CloseRequested += Hide;
    }

    public bool Install()
    {
        if (handle != IntPtr.Zero) return true;
        using var module = Process.GetCurrentProcess().MainModule;
        handle = Native.SetWindowsHookExW(Native.WH_MOUSE_LL, proc, Native.GetModuleHandleW(module?.ModuleName), 0);
        if (handle == IntPtr.Zero) Log.Write("mousehook.fail", "error " + Marshal.GetLastWin32Error());
        return handle != IntPtr.Zero;
    }

    public void Dispose()
    {
        if (handle != IntPtr.Zero) Native.UnhookWindowsHookEx(handle);
        handle = IntPtr.Zero;
        popup.Close();
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var message = wParam.ToInt32();
            if (message is Native.WM_LBUTTONDOWN or Native.WM_LBUTTONUP)
            {
                var info = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
                // The work is posted: a hook must return quickly.
                if (message == Native.WM_LBUTTONDOWN) { downAt = info; dispatcher.InvokeAsync(() => { if (!popup.Contains(info.X, info.Y)) Hide(); }); }
                else
                {
                    var dragged = Math.Abs(info.X - downAt.X) > 6 || Math.Abs(info.Y - downAt.Y) > 6;
                    var doubleClick = info.time - lastUpTime <= Native.GetDoubleClickTime()
                        && Math.Abs(info.X - lastUpAt.X) <= 4 && Math.Abs(info.Y - lastUpAt.Y) <= 4;
                    lastUpTime = info.time; lastUpAt = info;
                    if ((dragged || doubleClick) && !popup.Contains(info.X, info.Y)) dispatcher.InvokeAsync(() => _ = Selected(info.X, info.Y));
                }
            }
        }
        return Native.CallNextHookEx(handle, nCode, wParam, lParam);
    }

    public void Hide()
    {
        generation++;
        buttonTimer.Stop();
        popup.HideAll();
    }

    private async Task Selected(int x, int y)
    {
        var window = Native.GetForegroundWindow();
        if (!Enabled() || window == IntPtr.Zero || Shell.ProcessName(window).Equals("TypeLeast", StringComparison.OrdinalIgnoreCase)) return;
        var token = ++generation;
        // Give the app a moment to update its selection.
        await Task.Delay(150);
        var text = await Task.Run(() => FieldContextReader.Selection(window));
        if (token != generation || text is null) return;
        popup.ShowButton(x, y, () => _ = Run(text, token));
        buttonTimer.Stop(); buttonTimer.Start();
    }

    private async Task Run(string text, int token)
    {
        if (token != generation) return;
        buttonTimer.Stop();
        popup.ShowBubble(L10n.T("正在翻译…"), loading: true);
        var source = text.Length > Limit ? text[..Limit] : text;
        string? translated = null;
        if (Translate is { } translate)
        {
            try { translated = await translate(source, SelectionLanguage.Target(source, PreferredTarget())); }
            catch (Exception e) when (e is ServiceException or OperationCanceledException or System.Net.Http.HttpRequestException) { }
        }
        if (token != generation) return;
        if (Translate is null) popup.ShowBubble(L10n.T("请先配置可用的整理模型。"), failed: true);
        else if (string.IsNullOrWhiteSpace(translated)) popup.ShowBubble(L10n.T("翻译失败"), failed: true);
        else popup.ShowBubble(translated);
    }
}

/// <summary>The button and the bubble: one topmost window that is never activated.</summary>
internal sealed class SelectionPopup : Window
{
    private Native.MSLLHOOKSTRUCT anchor;
    public bool ShowsButton { get; private set; }
    public event Action? CloseRequested;

    public SelectionPopup()
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
        SourceInitialized += (_, _) => Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
    }

    /// <summary>Whether a screen point (physical pixels) is on this window.</summary>
    public bool Contains(int x, int y)
    {
        if (!IsVisible) return false;
        var hwnd = new WindowInteropHelper(this).Handle;
        return hwnd != IntPtr.Zero && Native.GetWindowRect(hwnd, out var r) && x >= r.Left && x < r.Right && y >= r.Top && y < r.Bottom;
    }

    public void ShowButton(int x, int y, Action click)
    {
        anchor = new Native.MSLLHOOKSTRUCT { X = x, Y = y };
        ShowsButton = true;
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        label.Children.Add(Theme.Text(L10n.T("翻译"), 13, Brushes.White, bold: true, wrap: false));
        var button = new Border
        {
            Background = Theme.Hex("#171717"),
            BorderBrush = Theme.Hex("#1FFFFFFF"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(15),
            Padding = new Thickness(14, 6, 14, 6),
            Margin = new Thickness(4),
            Cursor = Cursors.Hand,
            Child = label,
        };
        button.MouseLeftButtonUp += (_, _) => click();
        Present(button);
    }

    public void ShowBubble(string text, bool loading = false, bool failed = false)
    {
        ShowsButton = false;
        var body = new StackPanel { Width = 340 };
        var message = Theme.Text(text, 13.5, failed ? Theme.Hex("#B45309") : null);
        message.TextWrapping = TextWrapping.Wrap;
        body.Children.Add(new ScrollViewer { Content = message, MaxHeight = 260, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        if (!loading)
        {
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
            if (!failed)
            {
                var copy = Action(L10n.T("复制"));
                copy.MouseLeftButtonUp += (_, _) => { if (Paster.SetText(text)) ((TextBlock)copy.Child).Text = L10n.T("已复制"); };
                buttons.Children.Add(copy);
            }
            var close = Action(L10n.T("关闭"));
            close.MouseLeftButtonUp += (_, _) => CloseRequested?.Invoke();
            buttons.Children.Add(close);
            body.Children.Add(buttons);
        }
        Present(new Border
        {
            Background = Theme.Background,
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14),
            Margin = new Thickness(4),
            Child = body,
        });
    }

    private static Border Action(string text) => new()
    {
        Background = Theme.Hex("#14000000"),
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(10, 4, 10, 4),
        Margin = new Thickness(6, 0, 0, 0),
        Cursor = Cursors.Hand,
        Child = Theme.Text(text, 12.5, null, wrap: false),
    };

    public void HideAll()
    {
        ShowsButton = false;
        if (IsVisible) Hide();
    }

    private void Present(UIElement content)
    {
        Content = content;
        if (!IsVisible) Show();
        UpdateLayout();
        // Below and to the right of the mouse, in physical pixels; above it near the bottom of the screen.
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleY;
        var height = (int)(ActualHeight * scale);
        var bottom = (int)((SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight) * scale);
        var y = anchor.Y + 14 + height > bottom ? anchor.Y - height - 10 : anchor.Y + 14;
        Native.MoveWindow(new WindowInteropHelper(this).Handle, anchor.X + 6, y);
    }
}
