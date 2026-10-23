using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// The cleanup mode (整理档位), changed often, so it is one click away: a row of pills
/// with the chosen mode's description above every page. Follows changes made
/// elsewhere (tray menu, taskbar jump list).
/// </summary>
internal static class ModePicker
{
    /// <summary>A pinned card with four pills and the chosen mode description.</summary>
    public static Border Pills(AppHost host)
    {
        var pills = new WrapPanel();
        var buttons = new List<(string Code, Button Button)>();
        foreach (var code in CleanupModes.Codes)
        {
            var button = Theme.PillButton(CleanupModes.Title(code), () => host.SetStrength(code));
            buttons.Add((code, button)); pills.Children.Add(button);
        }
        var detail = Theme.Text("", 12.5, Theme.Grey);
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var note = Theme.Text(L10n.T("下一次听写生效"), 12, Theme.Grey, wrap: false);
        DockPanel.SetDock(note, Dock.Right); note.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(note); header.Children.Add(Theme.Text(L10n.T("整理档位"), 14, bold: true));
        void Update()
        {
            foreach (var (code, button) in buttons) { Theme.SetPillSelected(button, code == host.Settings.Strength); button.IsEnabled = host.Phase == DictationPhase.Idle; }
            note.Text = host.Phase == DictationPhase.Idle ? L10n.T("下一次听写生效") : L10n.T("录音或整理完成后可切换");
            detail.Text = CleanupModes.Detail(host.Settings.Strength);
        }
        host.Changed += Update; Update();
        return Theme.Card(Theme.Stack(4, header, pills, detail));
    }

}
