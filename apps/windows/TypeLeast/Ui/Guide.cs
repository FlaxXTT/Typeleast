using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>Help for new users: where the settings people look for live (home-page card and a
/// setup step), and what to do when the speech model cannot be downloaded.</summary>
internal static class GuideViews
{
    /// <summary>What, where, and (when <paramref name="open"/> is given) a button that goes there.</summary>
    public static StackPanel List(Action<SettingsGuide.Entry>? open)
    {
        var list = new StackPanel();
        foreach (var entry in SettingsGuide.Entries)
        {
            var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
            if (open is not null && entry.Page.Length > 0)
            {
                var go = Theme.Secondary(L10n.T("前往"), () => open(entry));
                go.Margin = new Thickness(10, 0, 0, 0);
                DockPanel.SetDock(go, Dock.Right);
                row.Children.Add(go);
            }
            var place = Theme.Text(entry.Place, 12.5, Theme.Grey, wrap: false);
            place.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(place, Dock.Right);
            row.Children.Add(place);
            var title = Theme.Text(entry.Title, 13, bold: true, wrap: false);
            title.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(title);
            list.Children.Add(row);
        }
        return list;
    }

    /// <summary>「设置在哪」 on the home page until the user says they know.</summary>
    public static Border Card(AppHost host, Action<SettingsGuide.Entry> open)
    {
        Border card = null!;
        var dismiss = Theme.Secondary(L10n.T("好"), () =>
        {
            host.Settings.GuideDismissed = true;
            host.SaveSettings();
            card.Visibility = Visibility.Collapsed;
        });
        card = Theme.Card(Theme.Stack(10, Theme.SettingRow(L10n.T("设置位置"), null, dismiss), List(open)));
        card.Visibility = host.Settings.GuideDismissed ? Visibility.Collapsed : Visibility.Visible;
        return card;
    }

    /// <summary>For a failed model download: the likely cause, and a mirror to copy or retry with.</summary>
    public static Border MirrorHint(AppHost host, Func<System.Threading.Tasks.Task> retry)
    {
        var url = Theme.Text(ModelMirror.Suggested, 13, wrap: false);
        url.FontFamily = new FontFamily("Consolas");
        url.VerticalAlignment = VerticalAlignment.Center;
        Button copy = null!;
        copy = Theme.Secondary(L10n.T("复制"), () => { if (Paster.SetText(ModelMirror.Suggested)) copy.Content = L10n.T("已复制"); });
        var use = Theme.Primary(L10n.T("用镜像重试"), () =>
        {
            host.Settings.ModelMirror = ModelMirror.Suggested;
            if (host.SaveSettings()) _ = retry();
        });
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(28, 0xD9, 0x8A, 0x1E)),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12),
            Margin = new Thickness(0, 4, 0, 4),
            Child = Theme.Stack(8, Theme.Text(L10n.T("下载失败？网络可能连不上 Hugging Face，请用镜像："), 12.5), Theme.Row(8, url, copy, use)),
        };
    }
}
