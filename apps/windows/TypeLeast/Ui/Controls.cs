using System;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;
namespace TypeLeast.Ui;

internal static class Controls
{
    public static ComboBox Retention(AppHost host)
    {
        var codes = new[] { "forever", "year", "month", "week", "day", "never" };
        var labels = new[] { "永久", "1 年", "1 月", "1 周", "24 小时", "从不" }; var choice = Theme.Choice(180);
        foreach (var label in labels) choice.Items.Add(L10n.T(label)); choice.SelectedIndex = Array.IndexOf(codes, host.Settings.HistoryRetention);
        choice.SelectionChanged += (_, _) => { if (choice.SelectedIndex >= 0) { host.Settings.HistoryRetention = codes[choice.SelectedIndex]; host.SaveSettings(); } };
        return choice;
    }
}
