using System.Windows;
using System.Windows.Controls;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// A newer version was found: 立即更新 or 稍后. Nothing is downloaded or installed until the user
/// chooses; ShowDialog, then read UpdateNow.
/// </summary>
internal sealed class UpdateOfferWindow : Window
{
    public bool UpdateNow { get; private set; }

    public UpdateOfferWindow(WindowsReleaseInfo release, string currentVersion, bool installedCopy)
    {
        Title = "TypeLeast";
        Width = 440; SizeToContent = SizeToContent.Height; ResizeMode = ResizeMode.NoResize;
        // The main window is often hidden in the tray, so this stands on its own.
        WindowStartupLocation = WindowStartupLocation.CenterScreen; Topmost = true;
        Background = Theme.Background; FontFamily = Theme.Font;
        var content = new StackPanel { Margin = new Thickness(24) };
        content.Children.Add(Theme.Text(L10n.T("有新版本 {0}", release.Version), 18, bold: true));
        content.Children.Add(Spaced(Theme.Text(installedCopy
            ? L10n.T("当前版本 {0}。更新后重新打开，设置和 Key 保留。", currentVersion)
            : L10n.T("当前版本 {0}。便携版请到发布页下载。", currentVersion), 13, Theme.Grey)));
        if (release.Summary.Length > 0)
        {
            content.Children.Add(Spaced(Theme.Text(L10n.T("更新内容"), 12.5, bold: true)));
            content.Children.Add(new TextBox
            {
                Text = release.Summary, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 160,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(0, 6, 0, 0), Padding = new Thickness(6, 4, 6, 4),
                FontFamily = Theme.Font, FontSize = 12.5, Background = Theme.CardFill, Foreground = Theme.Ink, BorderBrush = Theme.Line,
            });
        }
        var buttons = Theme.Row(8,
            Theme.Secondary(L10n.T("稍后"), Close),
            Theme.Primary(installedCopy ? L10n.T("立即更新") : L10n.T("下载新版本"), () => { UpdateNow = true; Close(); }));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 18, 0, 0);
        content.Children.Add(buttons);
        Content = content;
    }

    private static UIElement Spaced(FrameworkElement element) { element.Margin = new Thickness(0, 10, 0, 0); return element; }
}
