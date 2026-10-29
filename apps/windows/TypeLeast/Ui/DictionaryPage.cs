using System.Linq;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>词典: the user's words, and the switch for the bundled 「技术术语」 pack.</summary>
internal sealed class DictionaryPage : IPage
{
    private const string TechTerms = "typeleast.tech-terms";
    private readonly AppHost host;
    private readonly ManualDictionaryPage manual;
    private readonly StackPanel root = new(), techRow = new();
    private string shown = "";
    public UIElement View => root;

    public DictionaryPage(AppHost host)
    {
        this.host = host;
        manual = new ManualDictionaryPage(host);
        root.Children.Add(manual.View);
        root.Children.Add(techRow);
        host.Plugins.Changed += Refresh;
        _ = host.Plugins.Refresh();
    }

    public void Refresh()
    {
        manual.Refresh();
        var pack = host.Plugins.State.Plugins.FirstOrDefault(p => p.Id == TechTerms);
        var key = pack is null ? "" : pack.Enabled + "|" + host.Plugins.Revision + "|" + host.Plugins.Message;
        if (key == shown) return;
        shown = key;
        techRow.Children.Clear();
        if (pack is null) return;
        var problem = host.Plugins.Message is { } message ? Theme.Text(message, 12, Theme.Warning) : null;
        techRow.Children.Add(Theme.Card(Theme.SettingRow(L10n.T("技术术语"), problem,
            Theme.Toggle(pack.Enabled == true, on => _ = host.Plugins.SetEnabled(TechTerms, on)))));
    }
}
