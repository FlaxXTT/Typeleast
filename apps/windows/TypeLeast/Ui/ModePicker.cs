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
        foreach (var code in new[] { "prompt", "promptbrief", "promptbeta", "off" })
        {
            var button = Theme.PillButton(code == "promptbrief" ? L10n.T("提示词模式") : CleanupModes.Title(code), () => {
                if (code != "promptbrief" || host.Settings.Strength != "promptify") host.SetStrength(code);
            });
            buttons.Add((code, button)); pills.Children.Add(button);
        }
        var tiers = new WrapPanel();
        var brief = Theme.PillButton(L10n.T("普通档"), () => host.SetStrength("promptbrief"));
        var standard = Theme.PillButton(L10n.T("标准格式档"), () => host.SetStrength("promptify"));
        tiers.Children.Add(brief); tiers.Children.Add(standard);
        var detail = Theme.Text("", 12.5, Theme.Grey);
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var note = Theme.Text(L10n.T("下一次听写生效"), 12, Theme.Grey, wrap: false);
        DockPanel.SetDock(note, Dock.Right); note.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(note); header.Children.Add(Theme.Text(L10n.T("整理档位"), 14, bold: true));
        void Update()
        {
            var promptMode = host.Settings.Strength is "promptbrief" or "promptify";
            foreach (var (code, button) in buttons) { Theme.SetPillSelected(button, code == host.Settings.Strength || (code == "promptbrief" && promptMode)); button.IsEnabled = host.Phase == DictationPhase.Idle; }
            tiers.Visibility = promptMode ? Visibility.Visible : Visibility.Collapsed;
            Theme.SetPillSelected(brief, host.Settings.Strength == "promptbrief");
            Theme.SetPillSelected(standard, host.Settings.Strength == "promptify");
            brief.IsEnabled = standard.IsEnabled = host.Phase == DictationPhase.Idle;
            note.Text = host.Phase == DictationPhase.Idle ? L10n.T("下一次听写生效") : L10n.T("录音或整理完成后可切换");
            detail.Text = CleanupModes.Detail(host.Settings.Strength);
        }
        host.Changed += Update; Update();
        return Theme.Card(Theme.Stack(4, header, pills, tiers, detail));
    }

}
