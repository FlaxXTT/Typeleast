using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal static class MicrophoneTestPanel
{
    public static void Show(AppHost host)
    {
        if (!host.StartMicrophoneTest()) return;
        var level = new ProgressBar { Minimum = 0, Maximum = 1, Height = 10, Foreground = Theme.Accent };
        var text = Theme.Text(L10n.T("正在测试麦克风；不会识别、整理或保留录音。"), 13);
        var window = new Window { Title = L10n.T("麦克风测试"), Width = 420, SizeToContent = SizeToContent.Height, Background = Theme.Background,
            WindowStartupLocation = WindowStartupLocation.CenterScreen };
        var startup = Theme.Text(L10n.T("正在打开麦克风…"), 12, Theme.Grey);
        var content = Theme.Stack(16, text, level, startup, Theme.Primary(L10n.T("停止测试"), () => window.Close())); content.Margin = new Thickness(24); window.Content = content;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) }; var until = DateTime.UtcNow.AddSeconds(15);
        timer.Tick += (_, _) =>
        {
            level.Value = host.MicrophoneLevel;
            if (host.LastMicrophoneStartMs is { } ms) startup.Text = Messages.MicrophoneStartup(ms);
            if (DateTime.UtcNow >= until || !host.IsMicrophoneTesting) window.Close();
        };
        window.Closed += (_, _) => { timer.Stop(); host.EndMicrophoneTest(); }; window.Show(); timer.Start();
    }
}
