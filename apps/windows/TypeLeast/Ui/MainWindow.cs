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
/// The main window, laid out like Typeless: a sidebar (首页, 历史, 词典, 设置) and
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
        Width = 940;
        Height = 660;
        MinWidth = 760;
        MinHeight = 520;
        Background = Theme.Background;
        FontFamily = Theme.Font;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(210) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var side = new DockPanel { Background = Theme.Sidebar, LastChildFill = false };
        var brand = Theme.Text("TypeLeast", 17, bold: true);
        brand.Margin = new Thickness(20, 22, 0, 18);
        DockPanel.SetDock(brand, Dock.Top);
        side.Children.Add(brand);
        foreach (var (page, label) in new[] { (Page.Home, L10n.T("首页")), (Page.History, L10n.T("历史")), (Page.Dictionary, L10n.T("词典")), (Page.Settings, L10n.T("设置")) })
        {
            var b = NavButton(label, () => ShowPage(page));
            DockPanel.SetDock(b, Dock.Top);
            nav[page] = b;
            side.Children.Add(b);
        }
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
        Hide();
    }

    public void ShowPage(Page page)
    {
        current = page;
        foreach (var (p, b) in nav) b.Background = p == page ? Theme.Selected : Brushes.Transparent;
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
    private readonly TextBlock stats = Theme.Text("", 13, Theme.Grey);

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
        root.Children.Add(Theme.Card(stats));
    }

    public void Refresh()
    {
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
        checklist.Children.Add(Item(speech?.Ready == true, L10n.T("语音模型（SenseVoice）"), problem.Length == 0 ? L10n.T("已就绪，识别完全在本机进行") : problem, download));
        Action openSettings = () => host.ShowWindow(MainWindow.Page.Settings);
        Action openPrivacy = () => Shell.Open("ms-settings:privacy-microphone");
        checklist.Children.Add(Item(host.LlmConfigured, L10n.T("整理模型（自己的 API Key）"),
            host.LlmConfigured ? host.ModelSummary : L10n.T("填上 Key 才会整理成通顺的书面语；不填也能用，只去口水词。"),
            (L10n.T("去设置"), openSettings)));
        checklist.Children.Add(Item(true, L10n.T("麦克风"), L10n.T("如果录不到声音：设置 → 隐私和安全性 → 麦克风 → 允许桌面应用访问麦克风"),
            (L10n.T("打开设置"), openPrivacy), showActionWhenDone: true));
        setupCard.Visibility = running && speech?.Ready == true && host.LlmConfigured ? Visibility.Collapsed : Visibility.Visible;

        var (count, chars, seconds) = host.History.Stats();
        stats.Text = L10n.T("已听写 {0} 次 · 共 {1} 字 · 说了 {2} 分钟", count, chars, Math.Round(seconds / 60, 1));
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

/// <summary>Recent dictations with copy and delete.</summary>
internal sealed class HistoryPage : IPage
{
    private readonly AppHost host;
    private readonly StackPanel root = new();
    private readonly StackPanel list = new();
    private string shownFirst = "";
    private int shownCount = -1;

    public UIElement View => root;

    public HistoryPage(AppHost host)
    {
        this.host = host;
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var clear = Theme.Secondary(L10n.T("清空"), () =>
        {
            if (MessageBox.Show(L10n.T("清空全部历史？"), "TypeLeast", MessageBoxButton.OKCancel) == MessageBoxResult.OK)
            {
                host.History.Clear();
                Refresh();
            }
        });
        DockPanel.SetDock(clear, Dock.Right);
        header.Children.Add(clear);
        header.Children.Add(Theme.Text(L10n.T("历史"), 22, bold: true));
        root.Children.Add(header);
        root.Children.Add(Theme.Text(L10n.T("只保存在这台电脑上（最近 500 条）。"), 12, Theme.Grey));
        list.Margin = new Thickness(0, 12, 0, 0);
        root.Children.Add(list);
    }

    public void Refresh()
    {
        var entries = host.History.Entries;
        var first = entries.FirstOrDefault()?.Id ?? "";
        if (first == shownFirst && entries.Count == shownCount) return;
        shownFirst = first;
        shownCount = entries.Count;
        list.Children.Clear();
        if (entries.Count == 0) list.Children.Add(Theme.Text(L10n.T("还没有听写记录。"), 13, Theme.Grey));
        foreach (var e in entries.Take(200))
        {
            var meta = e.Time.ToLocalTime().ToString(L10n.T("M月d日 HH:mm")) + (e.App.Length > 0 ? " · " + e.App : "")
                + (Messages.FallbackNote(e.Reason) is { } note ? " · " + note : "");
            var actions = Theme.Row(8,
                Theme.Secondary(L10n.T("复制"), () => Paster.SetText(e.Text)),
                Theme.Secondary(L10n.T("复制原话"), () => Paster.SetText(e.Raw.Length > 0 ? e.Raw : e.Text)),
                Theme.Secondary(L10n.T("删除"), () => { host.History.Remove(e.Id); Refresh(); }));
            list.Children.Add(Theme.Card(Theme.Stack(8,
                Theme.Text(meta, 11.5, e.Fallback && e.Reason != "strength-off" ? Theme.Warning : Theme.Tertiary),
                new TextBox { Text = e.Text, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, TextWrapping = TextWrapping.Wrap, FontFamily = Theme.Font, FontSize = 14 },
                actions), 14));
        }
    }
}

/// <summary>Words the model must spell exactly, and "heard=word" rules.</summary>
internal sealed class DictionaryPage : IPage
{
    private readonly AppHost host;
    private readonly StackPanel root = new();
    private readonly WrapPanel words = new();
    private readonly TextBlock status = Theme.Text("", 12, Theme.Warning);
    private string shown = "\u0001";

    public UIElement View => root;

    public DictionaryPage(AppHost host)
    {
        this.host = host;
        root.Children.Add(Theme.Text(L10n.T("词典"), 22, bold: true));
        root.Children.Add(Theme.Text(L10n.T("整理时一定按这里的写法输出。写成「听成=正确写法」可以纠正固定的识别错误，例如「德普西克=DeepSeek」。"), 12.5, Theme.Grey));
        var input = Theme.Input("", 320);
        void Add()
        {
            host.AddWord(input.Text);
            input.Text = "";
            Refresh();
        }
        input.KeyDown += (_, e) => { if (e.Key == Key.Enter) Add(); };
        var row = Theme.Row(8, input, Theme.Primary(L10n.T("添加"), Add));
        row.Margin = new Thickness(0, 14, 0, 10);
        root.Children.Add(row);
        root.Children.Add(status);
        words.Margin = new Thickness(0, 10, 0, 0);
        root.Children.Add(words);
    }

    public void Refresh()
    {
        status.Text = host.DictionarySynced == false ? L10n.T("本地服务暂时没有收到最新词典，服务就绪后会自动同步。") : "";
        var key = string.Join("\n", host.Settings.Words);
        if (key == shown) return;
        shown = key;
        words.Children.Clear();
        if (host.Settings.Words.Count == 0) words.Children.Add(Theme.Text(L10n.T("还没有词条。"), 13, Theme.Grey));
        foreach (var w in host.Settings.Words)
        {
            var remove = new Button { Content = "✕", Margin = new Thickness(8, 0, 0, 0), Background = Brushes.Transparent, BorderThickness = new Thickness(0), Cursor = Cursors.Hand, Foreground = Theme.Grey, ToolTip = L10n.T("删除") };
            remove.Click += (_, _) => { host.RemoveWord(w); Refresh(); };
            words.Children.Add(new Border
            {
                Background = Theme.CardFill,
                BorderBrush = Theme.Line,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10, 5, 6, 5),
                Margin = new Thickness(0, 0, 8, 8),
                Child = Theme.Row(0, Theme.Text(w, 13, wrap: false), remove),
            });
        }
    }
}
