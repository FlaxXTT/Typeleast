using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// The cleanup mode (整理档位), changed often, so it is one click away: a row of pills
/// with the chosen mode's description on the home page, and four option cards in
/// Settings. Both follow changes made elsewhere (tray menu, taskbar jump list).
/// </summary>
internal static class ModePicker
{
    /// <summary>Home: a card with four pills and one line about the chosen mode.</summary>
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
            foreach (var (code, button) in buttons) Theme.SetPillSelected(button, code == host.Settings.Strength);
            detail.Text = CleanupModes.Detail(host.Settings.Strength);
        }
        host.Changed += Update; Update();
        return Theme.Card(Theme.Stack(4, header, pills, detail));
    }

    /// <summary>Settings: four option cards, two per row, each with a title and a description.</summary>
    public static UIElement Cards(AppHost host)
    {
        var grid = new UniformGrid { Columns = 2 };
        var cards = new List<(string Code, Border Card, UIElement Mark)>();
        for (var i = 0; i < CleanupModes.Codes.Length; i++)
        {
            var code = CleanupModes.Codes[i];
            // A drawn check mark: the embedded fonts have no "✓" glyph.
            var mark = new System.Windows.Shapes.Path
            {
                Data = Geometry.Parse("M 1,6 L 5,10 L 13,1"), Stroke = Theme.Ink, StrokeThickness = 1.8, Width = 14, Height = 12,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
                VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0),
            };
            var title = new DockPanel();
            DockPanel.SetDock(mark, Dock.Right); title.Children.Add(mark); title.Children.Add(Theme.Text(CleanupModes.Title(code), 14, bold: true));
            var card = new Border
            {
                CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 12, 14, 12), Cursor = Cursors.Hand,
                Margin = new Thickness(i % 2 == 0 ? 0 : 5, 0, i % 2 == 0 ? 5 : 0, 10),
                Child = Theme.Stack(4, title, Theme.Text(CleanupModes.Detail(code), 12, Theme.Grey)),
            };
            System.Windows.Automation.AutomationProperties.SetName(card, CleanupModes.Title(code));
            card.MouseLeftButtonUp += (_, _) => host.SetStrength(code);
            cards.Add((code, card, mark)); grid.Children.Add(card);
        }
        void Update()
        {
            foreach (var (code, card, mark) in cards)
            {
                var chosen = code == host.Settings.Strength;
                card.Background = chosen ? Theme.Background : Brushes.Transparent;
                card.BorderBrush = chosen ? Theme.Ink : Theme.Line;
                card.BorderThickness = new Thickness(chosen ? 1.5 : 1);
                mark.Visibility = chosen ? Visibility.Visible : Visibility.Hidden;
            }
        }
        host.Changed += Update; Update();
        return grid;
    }
}
