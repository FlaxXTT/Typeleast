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
/// The main window, laid out like the Mac app's: a sidebar (首页, 历史, 词典, 设置) and
/// a content pane. Closing it only hides it; TypeLeast keeps running in the tray.
/// </summary>
internal sealed class MainWindow : Window
{
    public enum Page { Home, History, Dictionary, Settings }

    private readonly AppHost host;
    private readonly Dictionary<Page, Button> nav = new();
    private readonly ContentControl content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly TextBlock badgeText = Theme.Text("", 11.5, Theme.Grey, wrap: false);
    private readonly System.Windows.Shapes.Ellipse badgeDot = new() { Width = 7, Height = 7 };
    private readonly Dictionary<Page, IPage> pages = new();
    private readonly Dictionary<Page, UIElement> pageSurfaces = new();
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
        var modes = ModePicker.Sidebar(host);
        DockPanel.SetDock(modes, Dock.Bottom);
        side.Children.Add(modes);
        root.Children.Add(side);

        var right = new DockPanel();
        content.Margin = new Thickness(36, 28, 36, 28);
        right.Children.Add(content);
        Grid.SetColumn(right, 1);
        root.Children.Add(right);
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
        // A toggle whose change was undone must not keep showing the new value: rebuild the pages with settings.
        host.SettingsReverted += () => Dispatcher.InvokeAsync(() =>
        {
            foreach (var page in new[] { Page.Settings, Page.Home }) { pages.Remove(page); pageSurfaces.Remove(page); }
            ShowPage(current);
        });
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

    /// <summary>Go to a place from the 「设置在哪」 guide.</summary>
    public void Open(SettingsGuide.Entry entry)
    {
        if (entry.Page == "dictionary") ShowPage(Page.Dictionary);
        if (entry.Page != "settings") return;
        ShowPage(Page.Settings);
        if (pages[Page.Settings] is SettingsPage settings) settings.SelectTab(entry.Tab);
    }

    public void ShowPage(Page page)
    {
        if(host.Settings.NeedsPractice && page != Page.Settings){host.ShowOnboarding();return;}
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
            pageSurfaces[page] = page == Page.Settings ? view.View : new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = view.View };
        }
        content.Content = pageSurfaces[page];
        Refresh();
    }

    private void Refresh()
    {
        badgeDot.Fill = host.ServiceUp ? Theme.Success : Theme.Warning;
        badgeText.Text = host.ServiceUp ? L10n.T("本地服务就绪") : host.ServiceSummary;
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
    private readonly MainWindow window;
    private readonly StackPanel root = new();
    private readonly Button tryButton;
    private readonly TextBlock heroTitle = Theme.Text("", 15, bold: true, wrap: false);
    private readonly TextBlock hint = Theme.Text("", 12.5, Theme.Grey);
    private readonly StackPanel checklist = new();
    private readonly Border setupCard;
    private readonly ContentControl insights = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 0, 0, 12) };
    private readonly StackPanel recent = new();
    private readonly TextBlock engine = Theme.Text("", 12, Theme.Grey);
    private readonly ContentControl keycaps = new();

    public UIElement View => root;

    public HomePage(AppHost host, MainWindow window)
    {
        this.host = host;
        this.window = window;
        tryButton = Theme.Primary(L10n.T("试一下"), host.Toggle);
        // One line: what to press, then 分享 and 试一下.
        var hero = new DockPanel { LastChildFill = true };
        var actions = Theme.Row(8, ActivityView.ShareButton(), tryButton);
        DockPanel.SetDock(actions, Dock.Right); hero.Children.Add(actions);
        heroTitle.VerticalAlignment = VerticalAlignment.Center;
        hero.Children.Add(Theme.Stack(2, heroTitle, hint));
        root.Children.Add(Theme.Card(hero, 14));
        setupCard = Theme.Card(Theme.Stack(10, Theme.Text(L10n.T("设置位置"), 14, bold: true), checklist));
        root.Children.Add(setupCard);
        root.Children.Add(insights);
        root.Children.Insert(0, Theme.Text(L10n.T(DateTime.Now.Hour is >= 5 and < 12 ? "早上好" : DateTime.Now.Hour is >= 12 and < 18 ? "下午好" : "晚上好"), 28, bold: true));
        root.Children.Insert(1, keycaps);
        root.Children.Add(Theme.Card(Theme.Stack(12, Theme.SettingRow(L10n.T("最近历史"), null,
            Theme.Secondary(L10n.T("查看全部"), () => window.ShowPage(MainWindow.Page.History))), recent)));
        root.Children.Add(Theme.Card(engine));
    }

    public void Refresh()
    {
        keycaps.Content = Theme.Keycaps(host.HotkeyLabel);
        engine.Text = (host.Speech?.DisplayName ?? L10n.T("未选择语音模型")) + " · " + host.ServiceSummary + " · " + host.ModelSummary;
        heroTitle.Text = L10n.T("按 ") + host.HotkeyLabel + L10n.T(" 说话，再按一次结束");
        tryButton.Content = host.Phase == DictationPhase.Recording ? L10n.T("结束听写") : L10n.T("试一下");
        tryButton.IsEnabled = host.Phase != DictationPhase.Thinking;
        hint.Text = host.Hint;

        checklist.Children.Clear();
        var running = host.Service.State == ServiceManager.Phase.Running;
        Action openNode = () => Shell.Open("https://nodejs.org/zh-cn/download");
        Action restart = host.RestartService;
        var serviceAction = host.Service.State == ServiceManager.Phase.NoNode ? (L10n.T("下载 Node.js"), openNode) : (L10n.T("重新启动"), restart);
        checklist.Children.Add(Item(running, L10n.T("本地服务"), running ? L10n.T("运行中") : host.ServiceSummary, serviceAction));
        var speech = host.Speech;
        var problem = Messages.SpeechProblem(speech);
        Action startDownload = () => { _ = host.DownloadModels(); };
        (string, Action)? download = null;
        if (speech is { ModelsMissing: true } or { Phase: "error" }) download = (L10n.T("选择语音模型"), startDownload);
        checklist.Children.Add(Item(speech?.Ready == true, host.Speech?.DisplayName ?? L10n.T("未选择语音模型"), problem.Length == 0 ? L10n.T("就绪，本机识别") : problem, download));
        if (ModelMirror.NetworkFailure(speech)) checklist.Children.Add(GuideViews.MirrorHint(host, host.RetryModelDownload));
        Action openSettings = () => window.Open(SettingsGuide.Entries[1]);
        Action openPrivacy = () => Shell.Open("ms-settings:privacy-microphone");
        checklist.Children.Add(Item(host.LlmConfigured, L10n.T("整理模型（你的 API Key）"),
            host.LlmConfigured ? host.ModelSummary : "",
            (L10n.T("打开设置"), openSettings)));
        checklist.Children.Add(Item(host.MicrophoneReady == true, L10n.T("麦克风"), L10n.T("录不到声音？请在「设置 → 隐私和安全性 → 麦克风」允许桌面应用"),
            (L10n.T("打开设置"), openPrivacy)));
        // Only what is not set up yet; the card disappears once everything works.
        foreach (var done in checklist.Children.OfType<Grid>().Where(g => g.Tag is true).ToList()) checklist.Children.Remove(done);
        setupCard.Visibility = running && speech?.Ready == true && host.LlmConfigured && host.MicrophoneReady == true ? Visibility.Collapsed : Visibility.Visible;

        insights.Content = ActivityView.Insights(host.Activity, host.History.Stats(), DateTime.Now);
        recent.Children.Clear();
        foreach (var entry in host.History.Entries.Take(3)) recent.Children.Add(Theme.Text(entry.Time.ToLocalTime().ToString("g", L10n.Culture) + "  " + entry.Text, 13));
        if (recent.Children.Count == 0) recent.Children.Add(Theme.Text(L10n.T("没有听写记录。"), 13, Theme.Grey));
    }

    private static Grid Item(bool done, string title, string detail, (string Label, Action Run)? action, bool showActionWhenDone = false)
    {
        var grid = new Grid { Margin = new Thickness(0, 2, 0, 2), Tag = done };
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

