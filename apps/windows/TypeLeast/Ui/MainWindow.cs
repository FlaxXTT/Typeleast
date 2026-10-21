using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// The main window, laid out like Reference: a sidebar (首页, 历史, 词典, 设置) and
/// a content pane. Closing it only hides it; TypeLeast keeps running in the tray.
/// </summary>
internal sealed class MainWindow : Window
{
    public enum Page { Home, History, Dictionary, Settings }

    private readonly AppHost host;
    private readonly Dictionary<Page, Button> nav = new();
    private readonly ContentControl content = new();
    private readonly TextBlock badgeText = Theme.Text("", 11.5, Theme.Grey, wrap: false);
    private readonly System.Windows.Shapes.Ellipse badgeDot = new() { Width = 7, Height = 7 };
    private readonly Dictionary<Page, IPage> pages = new();
    private Page current = Page.Home;

    public MainWindow(AppHost host)
    {
        this.host = host;
        Title = "TypeLeast";
        Width = double.IsFinite(host.Settings.WindowWidth) ? Math.Clamp(host.Settings.WindowWidth, Math.Min(836, SystemParameters.WorkArea.Width), SystemParameters.WorkArea.Width) : Math.Min(956, SystemParameters.WorkArea.Width);
        Height = double.IsFinite(host.Settings.WindowHeight) ? Math.Clamp(host.Settings.WindowHeight, Math.Min(599, SystemParameters.WorkArea.Height), SystemParameters.WorkArea.Height) : Math.Min(679, SystemParameters.WorkArea.Height);
        MinWidth = Math.Min(836, SystemParameters.WorkArea.Width);
        MinHeight = Math.Min(599, SystemParameters.WorkArea.Height);
        ShowInTaskbar = host.Settings.ShowInTaskbar;
        Background = Theme.Background;
        FontFamily = Theme.Font;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid { Background = Theme.Background };
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(214) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var side = new DockPanel { Background = Theme.Sidebar, LastChildFill = false };
        var brand = Theme.Row(9, BrandIcon(), Theme.Text("TypeLeast", 17, bold: true));
        brand.Margin = new Thickness(20, 22, 0, 18);
        DockPanel.SetDock(brand, Dock.Top);
        side.Children.Add(brand);
        foreach (var (page, label) in new[] { (Page.Home, L10n.T("首页")), (Page.History, L10n.T("历史")), (Page.Dictionary, L10n.T("词典")) })
        {
            var b = NavButton(label, () => ShowPage(page));
            DockPanel.SetDock(b, Dock.Top);
            nav[page] = b;
            side.Children.Add(b);
        }
        var settings = NavButton(L10n.T("设置"), () => ShowPage(Page.Settings));
        nav[Page.Settings] = settings; settings.Margin = new Thickness(10, 4, 10, 16);
        DockPanel.SetDock(settings, Dock.Bottom); side.Children.Add(settings);
        var badge = new Border
        {
            Background = Theme.CardFill,
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(12),
            Child = Theme.Row(7, badgeDot, badgeText),
        };
        DockPanel.SetDock(badge, Dock.Bottom);
        side.Children.Add(badge);
        root.Children.Add(side);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = content, Padding = new Thickness(36, 28, 36, 28) };
        Grid.SetColumn(scroll, 1);
        root.Children.Add(scroll);
        Content = root;

        Activated += (_, _) => _ = host.RefreshHealth();
        Loaded += (_, _) =>
        {
            if (host.Settings.WindowLeft is { } left && host.Settings.WindowTop is { } top && double.IsFinite(left) && double.IsFinite(top))
            {
                Left = Math.Clamp(left, SystemParameters.VirtualScreenLeft, Math.Max(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - ActualWidth));
                Top = Math.Clamp(top, SystemParameters.VirtualScreenTop, Math.Max(SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - ActualHeight));
            }
        };
        host.Changed += Refresh;
        ShowPage(Page.Home);
    }

    private static Button NavButton(string label, Action onClick)
    {
        var b = Theme.Secondary(label, onClick);
        b.Background = Brushes.Transparent;
        b.BorderBrush = Brushes.Transparent;
        b.HorizontalAlignment = HorizontalAlignment.Stretch;
        b.HorizontalContentAlignment = HorizontalAlignment.Left;
        b.Margin = new Thickness(10, 1, 10, 1);
        return b;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // The app lives in the tray; the window only hides.
        e.Cancel = true;
        if (WindowState == WindowState.Normal)
        { host.Settings.WindowLeft = Left; host.Settings.WindowTop = Top; host.Settings.WindowWidth = ActualWidth; host.Settings.WindowHeight = ActualHeight; host.SaveSettings(); }
        Hide();
    }
    internal static UIElement BrandIcon(int size = 26)
    {
        try
        {
            using var resource = typeof(MainWindow).Assembly.GetManifestResourceStream("TypeLeast.Icon");
            using var icon = resource is not null ? new System.Drawing.Icon(resource) : System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
            var bitmap = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(icon!.Handle, Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromWidthAndHeight(size, size));
            bitmap.Freeze(); return new Image { Width = size, Height = size, Source = bitmap };
        }
        catch (Exception) { return Theme.Text("◉", size - 2); }
    }

    public void ShowPage(Page page)
    {
        current = page;
        foreach (var (p, b) in nav) { b.Background = p == page ? Theme.Selected : Brushes.Transparent; b.FontWeight = p == page ? FontWeights.SemiBold : FontWeights.Normal; }
        if (!pages.TryGetValue(page, out var view))
        {
            view = page switch
            {
                Page.Home => new HomePage(host, this),
                Page.History => new HistoryPage(host),
                Page.Dictionary => new DictionaryPage(host),
                _ => new SettingsPage(host),
            };
            pages[page] = view;
        }
        content.Content = view.View;
        Refresh();
    }

    private void Refresh()
    {
        badgeDot.Fill = host.ServiceUp ? Theme.Success : Theme.Warning;
        badgeText.Text = host.ServiceUp ? L10n.T("本地服务已就绪") : host.ServiceSummary;
        if (pages.TryGetValue(current, out var view)) view.Refresh();
    }
}

internal interface IPage
{
    UIElement View { get; }
    void Refresh();
}

/// <summary>Hero, setup checklist and counts.</summary>
internal sealed class HomePage : IPage
{
    private readonly AppHost host;
    private readonly StackPanel root = new();
    private readonly Button tryButton;
    private readonly TextBlock heroTitle = Theme.Text("", 22, bold: true);
    private readonly TextBlock hint = Theme.Text("", 12.5, Theme.Grey);
    private readonly StackPanel checklist = new();
    private readonly Border setupCard;
    private readonly System.Windows.Controls.Primitives.UniformGrid stats = new() { Columns = 4 };
    private readonly StackPanel recent = new();
    private readonly TextBlock engine = Theme.Text("", 12, Theme.Grey);
    private readonly ContentControl keycaps = new();
    private readonly System.Windows.Controls.Border activityCard = Theme.Card(new StackPanel());

    public UIElement View => root;

    public HomePage(AppHost host, MainWindow window)
    {
        this.host = host;
        tryButton = Theme.Primary(L10n.T("试一下"), host.Toggle);
        var hero = Theme.Stack(8,
            heroTitle,
            Theme.Text(L10n.T("在任何输入框里按一下开始说话，再按一下结束。识别在这台电脑上完成，整理好的文字会直接出现在光标处。"), 13, Theme.Grey),
            Theme.Row(10, tryButton, hint));
        root.Children.Add(Theme.Card(hero, 24));
        setupCard = Theme.Card(Theme.Stack(10, Theme.Text(L10n.T("完成设置"), 14, bold: true), checklist));
        root.Children.Add(setupCard);
        root.Children.Add(stats);
        root.Children.Add(Theme.Text(L10n.T("根据保留的历史估算；假设键盘输入每分钟 40 字。并非精确测量或完整终身累计。"), 11, Theme.Grey));
        root.Children.Insert(0, Theme.Text(L10n.T(DateTime.Now.Hour is >= 5 and < 12 ? "早上好" : DateTime.Now.Hour is >= 12 and < 18 ? "下午好" : "晚上好"), 28, bold: true));
        root.Children.Insert(1, keycaps);
        root.Children.Add(activityCard);
        root.Children.Add(Theme.Card(Theme.Stack(12, Theme.SettingRow(L10n.T("最近历史"), null,
            Theme.Secondary(L10n.T("查看全部"), () => window.ShowPage(MainWindow.Page.History))), recent)));
        root.Children.Add(Theme.Card(engine));
        stats.SizeChanged += (_, _) => LayoutStats();
    }

    public void Refresh()
    {
        keycaps.Content = Theme.Keycaps(host.HotkeyLabel);
        engine.Text = (host.Speech?.ModelName ?? "SenseVoice Small") + " · " + host.ServiceSummary + " · " + host.ModelSummary;
        heroTitle.Text = L10n.T("按 ") + host.HotkeyLabel + L10n.T(" 开始听写");
        tryButton.Content = host.Phase == AppHost.DictationPhase.Recording ? L10n.T("结束听写") : L10n.T("试一下");
        tryButton.IsEnabled = host.Phase != AppHost.DictationPhase.Thinking;
        hint.Text = host.Hint;

        checklist.Children.Clear();
        var running = host.Service.State == ServiceManager.Phase.Running;
        Action openNode = () => Shell.Open("https://nodejs.org/zh-cn/download");
        Action restart = host.RestartService;
        var serviceAction = host.Service.State == ServiceManager.Phase.NoNode ? (L10n.T("下载 Node.js"), openNode) : (L10n.T("重新启动"), restart);
        checklist.Children.Add(Item(running, L10n.T("本地服务"), running ? L10n.T("已启动") : host.ServiceSummary, serviceAction));
        var speech = host.Speech;
        var problem = Messages.SpeechProblem(speech);
        Action startDownload = () => { _ = host.DownloadModels(); };
        (string, Action)? download = null;
        if (speech is { ModelsMissing: true } or { Phase: "error" }) download = (L10n.T("下载（约 241 MB）"), startDownload);
        checklist.Children.Add(Item(speech?.Ready == true, host.Speech?.ModelName ?? "SenseVoice Small", problem.Length == 0 ? L10n.T("已就绪，识别完全在本机进行") : problem, download));
        Action openSettings = () => host.ShowWindow(MainWindow.Page.Settings);
        Action openPrivacy = () => Shell.Open("ms-settings:privacy-microphone");
        checklist.Children.Add(Item(host.LlmConfigured, L10n.T("整理模型（自己的 API Key）"),
            host.LlmConfigured ? host.ModelSummary : L10n.T("填上 Key 才会整理成通顺的书面语；不填也能用，只去口水词。"),
            (L10n.T("去设置"), openSettings)));
        checklist.Children.Add(Item(host.MicrophoneReady == true, L10n.T("麦克风"), L10n.T("如果录不到声音：设置 → 隐私和安全性 → 麦克风 → 允许桌面应用访问麦克风"),
            (L10n.T("打开设置"), openPrivacy), showActionWhenDone: true));
        setupCard.Visibility = running && speech?.Ready == true && host.LlmConfigured && host.MicrophoneReady == true ? Visibility.Collapsed : Visibility.Visible;

        var (count, chars, seconds) = host.History.Stats();
        stats.Children.Clear();
        foreach (var (title, value) in new[] { (L10n.T("听写字数"), chars.ToString("N0")),
            (L10n.T("估算节省时间"), Math.Max(0, chars / 40.0 - seconds / 60).ToString("F1") + " " + L10n.T("分钟")),
            (L10n.T("平均说话速度"), (seconds > 0 ? chars * 60 / seconds : 0).ToString("F0") + " " + L10n.T("字/分钟")),
            (L10n.T("听写次数"), count.ToString("N0")) })
        {
            var tile = Theme.Card(Theme.Stack(8, Theme.Text(title, 12, Theme.Grey), Theme.Text(value, 21, bold: true)));
            stats.Children.Add(tile);
        }
        LayoutStats();
        stats.ToolTip = L10n.T("根据保留的历史估算；假设键盘输入每分钟 40 字。并非精确测量或完整终身累计。");
        recent.Children.Clear();
        foreach (var entry in host.History.Entries.Take(3)) recent.Children.Add(Theme.Text(entry.Time.ToLocalTime().ToString("g", L10n.Culture) + "  " + entry.Text, 13));
        if (recent.Children.Count == 0) recent.Children.Add(Theme.Text(L10n.T("还没有听写记录。"), 13, Theme.Grey));
        activityCard.Child = ActivityView.Build(host.Activity, DateTime.Now);
    }

    /// <summary>Two or four equal tiles (two in English, or when narrow) with 8 px gaps, filling the row.</summary>
    private void LayoutStats()
    {
        var columns = L10n.Language == "en" || (stats.ActualWidth > 0 && stats.ActualWidth < 650) ? 2 : 4;
        stats.Columns = columns;
        for (var i = 0; i < stats.Children.Count; i++)
            if (stats.Children[i] is FrameworkElement tile)
                tile.Margin = new Thickness(i % columns == 0 ? 0 : 4, 0, i % columns == columns - 1 ? 0 : 4, 12);
    }

    private static Grid Item(bool done, string title, string detail, (string Label, Action Run)? action, bool showActionWhenDone = false)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var mark = Theme.Check(done);
        grid.Children.Add(mark);
        var texts = Theme.Stack(2, Theme.Text(title, 13, bold: true), Theme.Text(detail, 12, Theme.Grey));
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        if (action is { } a && (!done || showActionWhenDone))
        {
            var b = Theme.Secondary(a.Label, a.Run);
            b.Margin = new Thickness(12, 0, 0, 0);
            Grid.SetColumn(b, 2);
            grid.Children.Add(b);
        }
        return grid;
    }
}

