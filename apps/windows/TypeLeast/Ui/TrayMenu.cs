using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// The tray icon's right-click menu, drawn in WPF so it uses the app's fonts and
/// palette: a header with the service state, then rows with an icon, a label and
/// the shortcut. It opens above the pointer (below it when the taskbar is at the
/// top), stays inside the screen's work area, and closes when it loses focus.
/// </summary>
internal sealed class TrayMenu : Window
{
    private const double MenuWidth = 264;
    // Icons from the system icon font: Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on Windows 10.
    private static readonly FontFamily Icons = new("Segoe Fluent Icons, Segoe MDL2 Assets");
    // Without either font the glyphs cannot be drawn at all; the rows then go without icons.
    private static readonly bool HasIcons = HasFont("Segoe Fluent Icons") || HasFont("Segoe MDL2 Assets");

    private static bool HasFont(string name)
    {
        foreach (var family in Fonts.SystemFontFamilies)
            if (string.Equals(family.Source, name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }
    private readonly StackPanel rows = new();
    private bool closing;

    private TrayMenu(AppHost host)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        SizeToContent = SizeToContent.WidthAndHeight;
        Opacity = 0;
        UseLayoutRounding = true;

        var dot = new System.Windows.Shapes.Ellipse { Width = 7, Height = 7, Fill = host.ServiceUp ? Theme.Success : Theme.Warning, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 1, 6, 0) };
        var state = Theme.Text(host.ServiceUp ? L10n.T("就绪 · 按 {0} 听写", host.HotkeyLabel) : host.ServiceSummary, 12, Theme.Grey, wrap: false);
        state.TextTrimming = TextTrimming.CharacterEllipsis;
        var stateRow = new DockPanel { Margin = new Thickness(0, 2, 0, 0) };
        stateRow.Children.Add(dot); stateRow.Children.Add(state);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(Theme.Text("TypeLeast", 14, bold: true, wrap: false));
        titles.Children.Add(stateRow);
        var header = new DockPanel { Margin = new Thickness(10, 8, 10, 8) };
        var icon = MainWindow.BrandIcon(28);
        if (icon is FrameworkElement brand) brand.Margin = new Thickness(0, 0, 10, 0);
        header.Children.Add(icon); header.Children.Add(titles);
        rows.Children.Add(header);

        var recording = host.Phase == DictationPhase.Recording;
        var busy = host.Phase != DictationPhase.Idle;
        Separator();
        Item("\uE720", recording ? L10n.T("结束听写") : L10n.T("开始听写"), host.HotkeyLabel, host.Phase != DictationPhase.Thinking, host.Toggle);
        Item("\uE774", L10n.T("开始翻译"), host.Settings.TranslateHotkey is { } t ? TapDetector.Label(t) : "", !busy, host.ToggleTranslate);
        Item("\uE711", L10n.T("取消"), "Esc", busy, host.Cancel);
        Separator();
        Item("", L10n.T("提示词模式"), "", true, () => host.ToggleAssistant());
        Separator();
        Item("\uE77F", L10n.T("粘贴上一条"), PasteShortcut(host.Settings.PasteLastShortcut), !busy, () => _ = host.PasteLast());
        Item("\uE8C8", L10n.T("复制上一条"), "", true, host.CopyLast);
        Separator();
        Item("\uE80F", L10n.T("打开 TypeLeast"), "", true, () => host.ShowWindow(MainWindow.Page.Home));
        Item("\uE81C", L10n.T("历史"), "", true, () => host.ShowWindow(MainWindow.Page.History));
        Item("\uE713", L10n.T("设置"), "", true, () => host.ShowWindow(MainWindow.Page.Settings));
        Separator();
        Item("\uE72C", L10n.T("重启本地服务"), "", true, host.RestartService);
        Item("\uE7E8", L10n.T("退出 TypeLeast"), "", true, host.Quit);

        Content = new Border
        {
            Width = MenuWidth,
            Margin = new Thickness(14),
            Padding = new Thickness(5),
            CornerRadius = new CornerRadius(12),
            Background = Theme.Background,
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { BlurRadius = 22, ShadowDepth = 5, Direction = 270, Opacity = Theme.IsDark ? 0.45 : 0.16, Color = Colors.Black },
            Child = rows,
        };

        Deactivated += (_, _) => Dismiss();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Dismiss(); };
    }

    private static string PasteShortcut(string code) => code switch
    {
        "CtrlAltV" => "Ctrl+Alt+V",
        "CtrlShiftV" => "Ctrl+Shift+V",
        "off" => "",
        _ => "Ctrl+Shift+Alt+V",
    };

    /// <summary>Open the menu by the pointer, in physical pixels.</summary>
    public static void ShowAt(AppHost host, System.Drawing.Point pointer)
    {
        var menu = new TrayMenu(host);
        menu.Left = -10000; menu.Top = -10000;
        menu.Show();
        menu.UpdateLayout();
        var hwnd = new WindowInteropHelper(menu).Handle;
        var area = System.Windows.Forms.Screen.FromPoint(pointer).WorkingArea;
        var scale = VisualTreeHelper.GetDpi(menu).DpiScaleX;
        // The window includes a transparent margin for the shadow; place the visible card.
        var margin = (int)Math.Round(14 * scale);
        var width = (int)Math.Ceiling(menu.ActualWidth * scale);
        var height = (int)Math.Ceiling(menu.ActualHeight * scale);
        var x = pointer.X - width / 2;
        var y = pointer.Y >= area.Top + area.Height / 2 ? pointer.Y - height + margin / 2 : pointer.Y - margin / 2;
        x = Math.Clamp(x, area.Left - margin + 4, area.Right - width + margin - 4);
        y = Math.Clamp(y, area.Top - margin + 4, area.Bottom - height + margin - 4);
        TypeLeast.Native.MoveWindow(hwnd, x, y);
        menu.Opacity = 1;
        menu.Activate();
        TypeLeast.Native.SetForegroundWindow(hwnd);
    }

    private void Dismiss()
    {
        if (closing) return;
        closing = true;
        Close();
    }

    private void Separator() => rows.Children.Add(new Border { Height = 1, Background = Theme.Line, Margin = new Thickness(10, 5, 10, 5) });

    private void Heading(string text)
    {
        var label = Theme.Text(text, 11.5, Theme.Grey, wrap: false);
        label.Margin = new Thickness(10, 4, 10, 2);
        rows.Children.Add(label);
    }

    private void Item(string glyph, string label, string shortcut, bool enabled, Action action, bool chosen = false)
    {
        var grid = new Grid { Height = 34 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = new TextBlock { Text = glyph, FontFamily = Icons, FontSize = 15, Foreground = Theme.Grey, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left };
        var text = Theme.Text(label, 13.5, Theme.Ink, bold: chosen, wrap: false);
        if (chosen) icon.Foreground = Theme.Ink;
        text.VerticalAlignment = VerticalAlignment.Center;
        if (HasIcons) grid.Children.Add(icon);
        Grid.SetColumn(text, 1); grid.Children.Add(text);
        if (shortcut.Length > 0)
        {
            var hint = Theme.Text(shortcut, 11.5, Theme.Grey, wrap: false);
            hint.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(hint, 2); grid.Children.Add(hint);
        }
        var row = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 0, 12, 0), Background = Brushes.Transparent, Child = grid, Opacity = enabled ? 1 : 0.4 };
        if (enabled)
        {
            row.Cursor = Cursors.Hand;
            row.MouseEnter += (_, _) => row.Background = Theme.Selected;
            row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
            row.MouseLeftButtonUp += (_, _) => { Dismiss(); Dispatcher.BeginInvoke(action); };
        }
        rows.Children.Add(row);
    }
}
