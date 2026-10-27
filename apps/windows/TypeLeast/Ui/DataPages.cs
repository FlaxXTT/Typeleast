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
    private long revision = -1, preferenceRevision=-1;
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
    public void Refresh() { if (revision != host.History.Revision || preferenceRevision!=host.Preferences.Revision) Render(); }
    private void Render()
    {
        revision = host.History.Revision; preferenceRevision=host.Preferences.Revision; list.Children.Clear();
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
                if (!string.IsNullOrEmpty(entry.Raw)) actions.Children.Add(Theme.Secondary(L10n.T("记录偏好"), () => {
                    host.Preferences.Prepare(entry.Id, entry.Raw, entry.Text); host.ShowWindow(MainWindow.Page.Dictionary);
                }));
                var plainRetry=Theme.Secondary(L10n.T("仅本次关闭个性化重试"),()=>_ = host.RetryHistory(entry,true));
                plainRetry.IsEnabled=host.Phase==DictationPhase.Idle&&!string.IsNullOrEmpty(entry.Raw)&&entry.Request is {Strength:not "promptbeta"};plainRetry.ToolTip=L10n.T("会再次调用整理模型，结果复制到剪贴板。");actions.Children.Add(plainRetry);
                retry.ToolTip = L10n.T("需要 5 分钟内的录音。Beta 记录不能重试。结果复制到剪贴板。"); actions.Children.Add(retry);
                var reason = Messages.FallbackNote(entry.Reason);
                var meta = entry.Time.ToLocalTime().ToString("t", L10n.Culture) + (entry.App.Length > 0 ? " · " + entry.App : "")
                    + (reason is not null ? " · " + reason + " (" + DiagnosticEvent.SafeReason(entry.Reason) + ")" : "");
                var badges = new WrapPanel();
                void Badge(string title, System.Windows.Media.SolidColorBrush color) {
                    var badge=Theme.Badge(title,color);badge.Margin=new Thickness(0,0,6,4);badges.Children.Add(badge);
                }
                if (entry.Task is { } task) Badge(L10n.T(task=="assistant"?"需求助手":task=="translation"?"翻译":"听写"),task=="assistant"?Theme.Style:Theme.Accent);
                else if(entry.Request is {Strength:var stored} && stored!="off" && new[]{"prompt","concise","promptbeta","promptbrief","promptify","conservative","maximal"}.Contains(stored)) {
                    var mode=CleanupModes.Stored(stored);
                    Badge(CleanupModes.Title(mode),mode=="concise"?Theme.Accent:mode=="promptbeta"?Theme.Style:Theme.Success);
                }
                if(entry.Fallback)Badge(L10n.T("已用原文"),Theme.Warning);
                list.Children.Add(Theme.Card(Theme.Stack(10, Theme.Text(meta, 12, Theme.Grey),
                    SelectableEntry(entry.Text), PersonalizationViews.Details(host,entry), badges, actions)));
            }
        }
    }

    /// <summary>The entry's text, selectable; right-click a selected name or term to add it to the dictionary.</summary>
    private TextBox SelectableEntry(string text)
    {
        var box = new TextBox { Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Background = Theme.CardFill,
            Foreground = Theme.Ink, BorderThickness = new Thickness(0), FontFamily = Theme.Font, FontSize = 14, MaxHeight = 240,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        box.ContextMenu = new ContextMenu { Items = {new MenuItem {Header=L10n.T("复制"),Command=ApplicationCommands.Copy}} };
        return box;
    }
}
