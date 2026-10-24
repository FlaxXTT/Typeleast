using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// 扩展: installed plugins and the official catalog. Plugins are data (dictionary packs,
/// styles); before anything is installed the user sees where its data goes. The market tab
/// reads the catalog once each time it is opened, never in the background.
/// </summary>
internal sealed class ExtensionsPage : IPage
{
    private readonly AppHost host;
    private readonly Window owner;
    private readonly StackPanel root = new(), list = new();
    private readonly Button installedTab, marketTab;
    private readonly TextBlock message = Theme.Text("", 12, Theme.Warning);
    private bool market;
    private string shown = "";
    public UIElement View => root;

    public ExtensionsPage(AppHost host, Window owner)
    {
        this.host = host;
        this.owner = owner;
        root.Children.Add(Theme.Text(L10n.T("扩展"), 28, bold: true));
        root.Children.Add(Theme.Text(L10n.T("词库和风格。安装前会告诉你数据会发到哪里。"), 13, Theme.Grey));
        installedTab = Theme.PillButton(L10n.T("已安装"), () => ShowTab(false));
        marketTab = Theme.PillButton(L10n.T("插件市场"), () => ShowTab(true));
        root.Children.Add(Theme.Card(Theme.Stack(10, Theme.Row(8, installedTab, marketTab, Theme.Secondary(L10n.T("导入插件文件…"), Import)), message)));
        root.Children.Add(list);
        host.Plugins.Changed += Refresh;
        ShowTab(false);
        _ = host.Plugins.Refresh();
    }

    private void ShowTab(bool toMarket)
    {
        var entering = toMarket && !market;
        market = toMarket;
        Theme.SetPillSelected(installedTab, !market);
        Theme.SetPillSelected(marketTab, market);
        shown = "";
        Refresh();
        // Each time the market tab is opened: one catalog read.
        if (entering) _ = host.Plugins.OpenMarket();
    }

    public void Refresh()
    {
        var plugins = host.Plugins;
        message.Text = plugins.Message ?? "";
        message.Visibility = message.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        var key = market + "|" + plugins.CatalogLoading + "|" + string.Join(",", plugins.State.Plugins.Select(p => p.Id + p.Version + p.Enabled)) + "|" + plugins.State.Style
            + "|" + string.Join(",", (plugins.Catalog?.Plugins ?? new()).Select(p => p.Id + p.Version + p.InstalledVersion)) + plugins.Catalog?.FetchedAt;
        if (key == shown) return;
        shown = key;
        list.Children.Clear();
        if (market) RenderMarket(); else RenderInstalled();
    }

    private void RenderInstalled()
    {
        var state = host.Plugins.State;
        if (state.Plugins.Count == 0)
        {
            list.Children.Add(Theme.Card(Theme.Stack(10, Theme.Text(L10n.T("还没有插件"), 14, Theme.Grey),
                Theme.Row(8, Theme.Primary(L10n.T("浏览插件市场"), () => ShowTab(true)), Theme.Secondary(L10n.T("导入插件文件…"), Import)))));
            return;
        }
        foreach (var plugin in state.Plugins)
        {
            UIElement action = plugin.IsStyle
                ? Theme.Secondary(state.Style == plugin.Id ? L10n.T("停用") : L10n.T("设为当前风格"), () => _ = host.Plugins.SelectStyle(state.Style == plugin.Id ? null : plugin.Id))
                : Theme.Toggle(plugin.Enabled == true, on => _ = host.Plugins.SetEnabled(plugin.Id, on));
            list.Children.Add(Card(plugin, Theme.Row(8, action, Theme.Secondary(L10n.T("卸载"), () => _ = host.Plugins.Remove(plugin.Id)))));
        }
        if (state.Problems is { Count: > 0 } problems)
            list.Children.Add(Theme.Text(L10n.T("有 {0} 个插件文件损坏，已停用：{1}", problems.Count, string.Join("、", problems)), 12, Theme.Warning));
    }

    private void RenderMarket()
    {
        var plugins = host.Plugins;
        var header = plugins.CatalogLoading ? L10n.T("正在读取插件目录…")
            : plugins.Catalog?.FetchedAt is { } time ? (plugins.Catalog.Ok ? L10n.T("目录更新于 ") : L10n.T("离线，显示上次的目录：")) + Time(time) : "";
        var refresh = Theme.Secondary(L10n.T("刷新"), () => _ = host.Plugins.OpenMarket());
        refresh.IsEnabled = !plugins.CatalogLoading;
        list.Children.Add(Theme.Row(12, refresh, Theme.Text(header, 12, Theme.Grey, wrap: false)));
        if (plugins.Catalog is not { } catalog) return;
        if (catalog.Plugins.Count == 0) list.Children.Add(Theme.Text(L10n.T("目录里还没有插件"), 13, Theme.Grey));
        foreach (var plugin in catalog.Plugins)
        {
            UIElement action = plugin.InstalledVersion == plugin.Version
                ? Theme.Text(L10n.T("已安装"), 12.5, Theme.Grey, wrap: false)
                : Theme.Primary(plugin.InstalledVersion is null ? L10n.T("安装") : L10n.T("更新到 {0}", plugin.Version), () => Confirm(plugin, true, plugin.InstalledVersion, enable => host.Plugins.InstallFromCatalog(plugin.Id, enable)));
            list.Children.Add(Card(plugin, action));
        }
    }

    private static Border Card(PluginSummary plugin, UIElement action)
    {
        var meta = (plugin.IsStyle ? L10n.T("风格") : L10n.T("词库")) + " · v" + plugin.Version + " · " + plugin.Author;
        var source = plugin.Source is null ? null : Theme.Text(plugin.Source == "catalog" ? L10n.T("官方目录") : L10n.T("本地导入，未审核"), 12, plugin.Source == "catalog" ? Theme.Grey : Theme.Warning);
        var stack = Theme.Stack(6, Theme.Text(plugin.Title, 15, bold: true), Theme.Text(meta, 12, Theme.Grey));
        if (source is not null) stack.Children.Add(source);
        stack.Children.Add(Theme.Text(plugin.Summary, 13, Theme.Grey));
        if (!plugin.IsStyle && plugin.TermCount is { } count) stack.Children.Add(Theme.Text(L10n.T("{0} 个词", count), 12, Theme.Grey));
        stack.Children.Add(action);
        return Theme.Card(stack);
    }

    private void Import()
    {
        var picker = new Microsoft.Win32.OpenFileDialog { Title = L10n.T("选择 .typeleast-plugin 插件文件"), Filter = "TypeLeast plugin|*.typeleast-plugin;*.json", CheckFileExists = true };
        if (picker.ShowDialog(owner) != true) return;
        byte[] file;
        try
        {
            if (new FileInfo(picker.FileName).Length > 256 * 1024) throw new InvalidDataException();
            file = File.ReadAllBytes(picker.FileName);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException) { message.Text = L10n.T("这不是有效的插件文件"); message.Visibility = Visibility.Visible; return; }
        _ = InspectAndConfirm(file);
    }

    private async System.Threading.Tasks.Task InspectAndConfirm(byte[] file)
    {
        if (await host.Plugins.Inspect(file) is not { } inspection) return;
        Confirm(inspection.Plugin, false, inspection.InstalledVersion, enable => host.Plugins.InstallFile(file, enable));
    }

    private void Confirm(PluginSummary plugin, bool fromCatalog, string? installedVersion, Func<bool, System.Threading.Tasks.Task> install)
    {
        var dialog = new PluginConfirmWindow(plugin, fromCatalog, installedVersion) { Owner = owner };
        dialog.ShowDialog();
        if (dialog.Choice is { } enable) _ = install(enable);
    }

    private static string Time(string iso) =>
        DateTimeOffset.TryParse(iso, out var time) ? time.ToLocalTime().ToString("g", L10n.Culture) : iso;
}
