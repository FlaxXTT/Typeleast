using System;
using System.Collections.Generic;
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
        var header = Theme.Text(L10n.T("整理档位"), 11.5, Theme.Grey, bold: true, wrap: false);
        header.Margin = new Thickness(14, 0, 0, 4);
        list.Children.Add(header);
        var rows = new List<(string Code, Button Button, TextBlock Dot, TextBlock Title, TextBlock Detail)>();
        foreach (var code in CleanupModes.Codes)
        {
            var dot = Theme.Text("○", 12, Theme.Grey, wrap: false);
            dot.Margin = new Thickness(0, 1, 9, 0);
            dot.VerticalAlignment = VerticalAlignment.Top;
            var title = Theme.Text(CleanupModes.Title(code), 13, wrap: false);
            var detail = Theme.Text(CleanupModes.Detail(code), 11.5, Theme.Grey);
            var row = new DockPanel();
            DockPanel.SetDock(dot, Dock.Left);
            row.Children.Add(dot);
            row.Children.Add(Theme.Stack(1, title, detail));
            var button = Theme.Secondary("", () => host.SetStrength(code));
            button.Content = row;
            button.BorderBrush = Brushes.Transparent;
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            button.Margin = new Thickness(0, 1, 0, 1);
            rows.Add((code, button, dot, title, detail));
            list.Children.Add(button);
        }
        void Update()
        {
            var idle = host.Phase == DictationPhase.Idle;
            foreach (var (code, button, dot, title, detail) in rows)
            {
                var selected = code == host.Settings.Strength;
                button.Background = selected ? Theme.Selected : Brushes.Transparent;
                button.IsEnabled = idle;
                dot.Text = selected ? "●" : "○";
                dot.Foreground = title.Foreground = selected ? Theme.Ink : Theme.Grey;
                title.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Normal;
                detail.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
            }
            list.ToolTip = idle ? null : L10n.T("说完再切换");
        }
        host.Changed += Update; Update();
        return list;
    }
}
