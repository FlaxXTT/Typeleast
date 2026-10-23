using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

/// <summary>
/// A small window while an in-app update runs: what it is doing (下载 → 核对 → 安装) with a
/// progress bar, so it never looks stuck. Shown for manual and automatic updates alike.
/// </summary>
internal sealed class UpdateProgressWindow : Window
{
    private readonly TextBlock title = Theme.Text("", 13.5, Theme.Ink, bold: true);
    private readonly TextBlock status = Theme.Text("", 12, Theme.Grey);
    private readonly ProgressBar bar = new() { Height = 6, Minimum = 0, Maximum = 1, Margin = new Thickness(0, 12, 0, 10) };

    public UpdateProgressWindow()
    {
        Title = L10n.T("更新 TypeLeast");
        Width = 380;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        Topmost = true;
        Background = Theme.CardFill;
        var content = new StackPanel { Margin = new Thickness(20) };
        content.Children.Add(title);
        content.Children.Add(bar);
        content.Children.Add(status);
        Content = content;
    }

    public void Start(string version)
    {
        title.Text = L10n.T("正在更新到 {0}", version);
        Report(UpdateStage.Downloading, 0, null);
        Show();
    }

    public void Report(UpdateStage stage, long received, long? total)
    {
        status.Text = UpdateProgressText.Describe(stage, received, total);
        var fraction = UpdateProgressText.Fraction(stage, received, total);
        bar.IsIndeterminate = fraction is null;
        if (fraction is { } f) bar.Value = f;
    }
}
