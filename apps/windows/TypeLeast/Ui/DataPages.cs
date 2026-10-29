using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class HistoryPage : IPage
{
    private readonly AppHost host;
    private readonly StackPanel root = new(), list = new();
    private readonly TextBox search = Theme.Input("", 280);
    private readonly ComboBox filter = Theme.Choice(180);
    private long revision = -1;
    public UIElement View => root;
    public HistoryPage(AppHost host)
    {
        this.host = host;
        root.Children.Add(Theme.Text(L10n.T("历史"), 28, bold: true));
        var retention = Controls.Retention(host);
        foreach (var label in new[] { "全部", "已整理", "已用原文" }) filter.Items.Add(L10n.T(label));
        filter.SelectedIndex = 0;
        search.ToolTip = L10n.T("搜索历史"); System.Windows.Automation.AutomationProperties.SetName(search, L10n.T("搜索历史"));
        root.Children.Add(Theme.Card(Theme.Stack(12, Theme.SettingRow(L10n.T("保留时长"), null, retention),
            Theme.Row(8, filter, search, Theme.Secondary(L10n.T("清空全部历史"), () =>
            {
                if (MessageBox.Show(L10n.T("删除全部历史、统计和录音？无法撤销。"), "TypeLeast", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK) host.ClearHistory();
            })))));
        root.Children.Add(list);
        search.TextChanged += (_, _) => Render(); filter.SelectionChanged += (_, _) => Render();
        Refresh();
    }
    public void Refresh() { if (revision != host.History.Revision) Render(); }
    private void Render()
    {
        revision = host.History.Revision; list.Children.Clear();
        var query = search.Text.Trim();
        var entries = host.History.Entries.Where(e => (filter.SelectedIndex != 1 || !e.Fallback && e.Reason != "strength-off")
            && (filter.SelectedIndex != 2 || e.Fallback || e.Reason == "strength-off")
            && (query.Length == 0 || e.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase) || e.Raw.Contains(query, StringComparison.CurrentCultureIgnoreCase))).ToList();
        if (entries.Count == 0) list.Children.Add(Theme.Card(Theme.Text(L10n.T("没有匹配的记录。"), 14, Theme.Grey)));
        foreach (var group in entries.GroupBy(e => e.Time.LocalDateTime.Date))
        {
            list.Children.Add(Theme.SectionTitle(group.Key.ToString("D", L10n.Culture)));
            foreach (var entry in group)
            {
                var actions = Theme.Row(8, Theme.Secondary(L10n.T("复制结果"), () => Paster.SetText(entry.Text)),
                    Theme.Secondary(L10n.T("复制原话"), () => Paster.SetText(entry.Raw.Length > 0 ? entry.Raw : entry.Text)),
                    Theme.Secondary(L10n.T("删除"), () => host.DeleteHistory(entry.Id)));
                var retry = Theme.Secondary(L10n.T("用录音重试"), () => _ = host.RetryHistory(entry));
                retry.IsEnabled = host.Phase == DictationPhase.Idle && host.CanRetry(entry);
                retry.ToolTip = L10n.T("需要 5 分钟内的录音。Beta 记录不能重试。结果复制到剪贴板。"); actions.Children.Add(retry);
                var reason = Messages.FallbackNote(entry.Reason);
                var meta = entry.Time.ToLocalTime().ToString("t", L10n.Culture) + (entry.App.Length > 0 ? " · " + entry.App : "")
                    + (reason is not null ? " · " + reason + " (" + DiagnosticEvent.SafeReason(entry.Reason) + ")" : "");
                var badges = new WrapPanel();
                void Badge(string title, System.Windows.Media.SolidColorBrush color) {
                    var badge=Theme.Badge(title,color);badge.Margin=new Thickness(0,0,6,4);badges.Children.Add(badge);
                }
                if (entry.Task is { } task) Badge(L10n.T(task=="assistant"?"提示词模式":task=="translation"?"翻译":"听写"),task=="assistant"?Theme.Style:Theme.Accent);
                else if(entry.Request is {Strength:var stored} && stored!="off" && new[]{"prompt","concise","promptbeta","promptbrief","promptify","conservative","maximal"}.Contains(stored)) {
                    var mode=CleanupModes.Stored(stored);
                    Badge(CleanupModes.Title(mode),mode=="concise"?Theme.Accent:mode=="promptbeta"?Theme.Style:Theme.Success);
                }
                if(entry.Fallback)Badge(L10n.T("已用原文"),Theme.Warning);
                list.Children.Add(Theme.Card(Theme.Stack(10, Theme.Text(meta, 12, Theme.Grey),
                    SelectableEntry(entry.Text), badges, actions)));
            }
        }
    }

    /// <summary>The entry's text, selectable; right-click a selected name or term to add it to the dictionary.</summary>
    private TextBox SelectableEntry(string text)
    {
        var box = new TextBox { Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Background = Theme.CardFill,
            Foreground = Theme.Ink, BorderThickness = new Thickness(0), FontFamily = Theme.Font, FontSize = 14, MaxHeight = 240,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var add = new MenuItem();
        var copy = new MenuItem { Header = L10n.T("复制"), Command = ApplicationCommands.Copy };
        add.Click += (_, _) => host.Dictionary.AddFromHistory(box.SelectedText);
        box.ContextMenu = new ContextMenu { Items = { add, new Separator(), copy } };
        box.ContextMenuOpening += (_, _) =>
        {
            var word = box.SelectedText.Trim();
            var usable = word.Length is > 0 and <= 40 && !word.Contains('\n');
            add.Header = usable ? L10n.T("把「{0}」加入词典", word) : L10n.T("选中一个词即可加入");
            add.IsEnabled = usable;
        };
        return box;
    }
}

internal sealed class ManualDictionaryPage : IPage
{
    private readonly AppHost host;
    private readonly StackPanel root = new(), list = new();
    private readonly TextBox search = Theme.Input("", 280);
    private readonly ComboBox filter = Theme.Choice(180);
    private readonly TextBlock status = Theme.Text("", 12, Theme.Warning);
    private string shown = "";
    public UIElement View => root;
    public ManualDictionaryPage(AppHost host)
    {
        this.host = host;
        root.Children.Add(Theme.Text(L10n.T("词典"), 28, bold: true));
        root.Children.Add(Theme.Text(L10n.T("说过的名称写对。你改过的词会自动加入。"), 12, Theme.Grey));
        foreach (var label in new[] { "全部", "自动添加", "手动添加" }) filter.Items.Add(L10n.T(label)); filter.SelectedIndex = 0;
        search.ToolTip = L10n.T("搜索词典"); System.Windows.Automation.AutomationProperties.SetName(search, L10n.T("搜索词典"));
        root.Children.Add(Theme.Card(Theme.Stack(12, Theme.Row(8, filter, search), Theme.Row(8,
            Theme.Primary(L10n.T("新增词条"), () => Edit(null)), Theme.Secondary(L10n.T("导入 CSV"), Import)), status)));
        root.Children.Add(list); search.TextChanged += (_, _) => Render(); filter.SelectionChanged += (_, _) => Render(); Refresh();
    }
    public void Refresh()
    {
        var key = string.Join("\n", host.Settings.DictionaryEntries.Select(e => e.Id + e.ServiceValue + e.Source));
        if (key != shown) { shown = key; Render(); }
    }
    private void Render()
    {
        list.Children.Clear();
        foreach (var entry in host.Settings.DictionaryEntries.Where(e => (filter.SelectedIndex != 1 || e.Source == "auto")
            && (filter.SelectedIndex != 2 || e.Source != "auto") && (e.Word.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase) || e.HeardAs.Contains(search.Text, StringComparison.CurrentCultureIgnoreCase))))
        {
            list.Children.Add(Theme.Card(Theme.Stack(8, Theme.Text(entry.Word, 16, bold: true),
                Theme.Text((entry.Source == "auto" ? L10n.T("自动添加") : L10n.T("手动添加")) + (entry.HeardAs.Length > 0 ? " · " + L10n.T("识别成") + ": " + entry.HeardAs : "")
                    + (entry.LocalOnly ? " · " + L10n.T("不发给模型") : ""), 12, Theme.Grey),
                Theme.Row(8, Theme.Secondary(L10n.T("编辑"), () => Edit(entry)), Theme.Secondary(L10n.T("删除"), () => host.Dictionary.RemoveWord(entry.Id))))));
        }
        if (list.Children.Count == 0) list.Children.Add(Theme.Text(L10n.T("没有匹配的词条。"), 14, Theme.Grey));
    }
    private void Edit(WordEntry? original)
    {
        var word = Theme.Input(original?.Word ?? "", 300); var heard = Theme.Input(original?.HeardAs ?? "", 300);
        var localOnly = new CheckBox { Content = L10n.T("不发给模型"), IsChecked = original?.LocalOnly == true, Foreground = Theme.Ink };
        var error = Theme.Text("", 12, Theme.Warning);
        var caseOnly = Theme.Text(L10n.T("没填识别成时，只修正英文大小写。"), 12, Theme.Grey);
        void ShowCaseOnly() => caseOnly.Visibility = localOnly.IsChecked == true && heard.Text.Trim().Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        localOnly.Checked += (_, _) => ShowCaseOnly(); localOnly.Unchecked += (_, _) => ShowCaseOnly(); heard.TextChanged += (_, _) => ShowCaseOnly();
        ShowCaseOnly();
        var dialog = new Window { Title = L10n.T(original is null ? "新增词条" : "编辑词条"), Width = 420, SizeToContent = SizeToContent.Height,
            Background = Theme.Background, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        var form = Theme.Stack(12, Theme.Text(L10n.T("正确写法")), word, Theme.Text(L10n.T("识别成（可选）")), heard,
            localOnly, caseOnly, error,
            Theme.Row(8, Theme.Primary(L10n.T("保存"), () =>
            {
                var entry = WordEntry.Parse(word.Text, heard.Text, "manual");
                if (entry is null) { error.Text = L10n.T("输入无效：合计最多 120 字，不能有换行或等号。"); return; }
                if (original is not null) entry.Id = original.Id;
                entry.LocalOnly = localOnly.IsChecked == true;
                if (host.Dictionary.SaveWord(entry)) dialog.Close(); else error.Text = host.Hint;
            }), Theme.Secondary(L10n.T("取消"), () => dialog.Close())));
        form.Margin = new Thickness(24); dialog.Content = form; dialog.Show(); word.Focus();
    }
    private void Import()
    {
        var picker = new Microsoft.Win32.OpenFileDialog { Filter = "CSV|*.csv", CheckFileExists = true };
        if (picker.ShowDialog() != true) return;
        try
        {
            if (new FileInfo(picker.FileName).Length > 2 * 1024 * 1024) throw new InvalidDataException();
            var preview = WordImport.Preview(File.ReadAllText(picker.FileName, System.Text.Encoding.UTF8), host.Settings.DictionaryEntries);
            var message = L10n.T("有效 {0}，重复 {1}，无效 {2}。导入有效词条？", preview.Valid.Count, preview.Duplicates, string.Join(", ", preview.InvalidLines.Take(20)));
            if (preview.Valid.Count == 0 || MessageBox.Show(message, L10n.T("CSV 导入预览"), MessageBoxButton.OKCancel) != MessageBoxResult.OK) { status.Text = message; return; }
            var previous = host.Settings.DictionaryEntries.ToList(); host.Settings.DictionaryEntries.AddRange(preview.Valid);
            if (!host.SaveSettings()) host.Settings.DictionaryEntries = previous;
            Render();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { status.Text = L10n.T("导入失败。请检查文件格式、大小和权限。"); }
    }
}
