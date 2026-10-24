using System.Linq;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// What a plugin is, what it contains and where its data goes, before it is installed.
/// ShowDialog: Choice is null (cancel), false (install only) or true (install and turn on).
/// </summary>
internal sealed class PluginConfirmWindow : Window
{
    public bool? Choice { get; private set; }

    public PluginConfirmWindow(PluginSummary plugin, bool fromCatalog, string? installedVersion)
    {
        Title = "TypeLeast";
        Width = 480; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Theme.Background; FontFamily = Theme.Font;
        var content = new StackPanel { Margin = new Thickness(24) };
        content.Children.Add(Theme.Text(installedVersion is null ? L10n.T("安装「{0}」？", plugin.Title) : L10n.T("把「{0}」更新到 {1}？", plugin.Title, plugin.Version), 18, bold: true));
        content.Children.Add(Spaced(Theme.Text(plugin.Summary, 13, Theme.Grey)));
        content.Children.Add(Spaced(Theme.Text("v" + plugin.Version + " · " + plugin.Author + " · " + plugin.License, 12, Theme.Grey)));
        content.Children.Add(Spaced(Theme.Text(fromCatalog ? L10n.T("来自 TypeLeast 官方目录，已审核。") : "⚠ " + L10n.T("来自本地文件，未经审核。只安装你信任的人给的插件。"),
            12.5, fromCatalog ? Theme.Ink : Theme.Warning)));
        if (plugin.IsStyle)
        {
            content.Children.Add(Spaced(Theme.Text(L10n.T("会附加的说明："), 12.5, bold: true)));
            content.Children.Add(new TextBox
            {
                Text = plugin.Instructions ?? "", IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Height = 120,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 0),
                FontFamily = Theme.Font, FontSize = 12.5, Background = Theme.CardFill, Foreground = Theme.Ink, BorderBrush = Theme.Line,
            });
        }
        else
        {
            content.Children.Add(Spaced(Theme.Text(L10n.T("共 {0} 个词，例如：", plugin.TermCount ?? 0), 12.5, bold: true)));
            content.Children.Add(Spaced(Theme.Text(string.Join("、", (plugin.TermsPreview ?? new()).Take(12)), 12.5, Theme.Grey)));
        }
        content.Children.Add(Spaced(Theme.Text(plugin.IsStyle
            ? L10n.T("数据去向：选中后，这段说明会随每次标准、精简整理请求发给你选择的模型，影响写法和格式。不会多调用模型；原话转写、翻译和提示词 Beta 不受影响。")
            : L10n.T("数据去向：启用后，这些词里与某次听写相关的，会随那次整理请求发给你选择的模型；无关的不发送。不会多调用模型。"), 12.5)));
        var buttons = Theme.Row(8,
            Theme.Secondary(L10n.T("取消"), Close),
            Theme.Secondary(L10n.T("仅安装"), () => { Choice = false; Close(); }),
            Theme.Primary(plugin.IsStyle ? L10n.T("安装并使用") : L10n.T("安装并启用"), () => { Choice = true; Close(); }));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 18, 0, 0);
        content.Children.Add(buttons);
        Content = content;
    }

    private static UIElement Spaced(FrameworkElement element) { element.Margin = new Thickness(0, 10, 0, 0); return element; }
}
