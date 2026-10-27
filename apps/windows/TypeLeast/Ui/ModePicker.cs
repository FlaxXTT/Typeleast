using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>Independent assistant action and optional style selection. No cleanup tiers.</summary>
internal static class ModePicker
{
    public static StackPanel Sidebar(AppHost host)
    {
        var list = new StackPanel { Margin = new Thickness(10, 0, 10, 0) };
        list.Children.Add(Theme.Secondary(L10n.T("需求助手"), () => host.ToggleAssistant()));
        // A style plugin applies to 标准 and 精简 only.
        var style = Theme.Choice(150);
        var styleRow = Theme.Row(6, Theme.Text(L10n.T("风格："), 12, Theme.Grey, wrap: false), style);
        styleRow.Margin = new Thickness(36, 4, 0, 0);
        list.Children.Add(styleRow);
        var filling = false;
        style.SelectionChanged += (_, _) =>
        {
            if (filling || style.SelectedItem is not ComboBoxItem { Tag: var tag }) return;
            _ = host.Plugins.SelectStyle(tag as string);
        };
        void Update()
        {
            var idle = host.Phase == DictationPhase.Idle;
            list.ToolTip = idle ? null : L10n.T("说完再切换");
            var styles = host.Plugins.Styles.ToList();
            styleRow.Visibility = styles.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            filling = true;
            style.Items.Clear();
            style.Items.Add(new ComboBoxItem { Content = L10n.T("不用风格"), Tag = null });
            foreach (var s in styles) style.Items.Add(new ComboBoxItem { Content = s.Title, Tag = s.Id });
            style.SelectedIndex = Math.Max(0, styles.FindIndex(s => s.Id == host.Plugins.State.Style) + 1);
            style.IsEnabled = idle;
            filling = false;
        }
        host.Changed += Update; host.Plugins.Changed += Update; Update();
        return list;
    }
}
