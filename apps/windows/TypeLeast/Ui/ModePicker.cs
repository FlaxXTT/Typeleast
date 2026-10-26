using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// The cleanup mode (整理档位), changed often, so it sits in the sidebar: one click away on
/// every page and apart from Settings. The chosen mode shows what it does in a few words.
/// Follows changes made elsewhere (tray menu, taskbar jump list).
/// </summary>
internal static class ModePicker
{
    public static StackPanel Sidebar(AppHost host)
    {
        var list = new StackPanel { Margin = new Thickness(10, 0, 10, 0) };
        var header = Theme.Text(L10n.T("整理模式"), 11.5, Theme.Grey, bold: true, wrap: false);
        header.Margin = new Thickness(14, 0, 0, 4);
        list.Children.Add(header);
        var rows = new List<(string Code, Button Button, TextBlock Dot, TextBlock Title)>();
        foreach (var code in CleanupModes.Codes)
        {
            var dot = Theme.Text("○", 12, Theme.Grey, wrap: false);
            dot.Margin = new Thickness(0, 1, 9, 0);
            dot.VerticalAlignment = VerticalAlignment.Top;
            var title = Theme.Text(CleanupModes.Title(code) + (code == "concise" ? " ★" : ""), 13, wrap: false);
            var row = new DockPanel();
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);
            row.Children.Add(title);
            var button = Theme.Secondary("", () => host.SetStrength(code));
            button.Content = row;
            if (code == "concise") button.ToolTip = L10n.T("推荐：重组表达，保留事实与条件。");
            button.BorderBrush = Brushes.Transparent;
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            button.Margin = new Thickness(0, 1, 0, 1);
            rows.Add((code, button, dot, title));
            list.Children.Add(button);
        }
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
            foreach (var (code, button, dot, title) in rows)
            {
                var selected = code == host.Settings.Strength;
                button.Background = selected ? Theme.Selected : Brushes.Transparent;
                button.IsEnabled = idle;
                dot.Text = selected ? "●" : "○";
                dot.Foreground = title.Foreground = selected ? Theme.Ink : Theme.Grey;
                title.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
            }
            list.ToolTip = idle ? null : L10n.T("说完再切换");
            var styles = host.Plugins.Styles.ToList();
            styleRow.Visibility = styles.Count > 0 && host.Settings.Strength is "prompt" or "concise" ? Visibility.Visible : Visibility.Collapsed;
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
