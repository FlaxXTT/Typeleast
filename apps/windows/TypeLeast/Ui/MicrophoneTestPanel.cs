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
        var text = Theme.Text(L10n.T("测试中，不识别也不保存。"), 13);
        var window = new Window { Title = L10n.T("麦克风测试"), Width = 420, SizeToContent = SizeToContent.Height, Background = Theme.Background,
            WindowStartupLocation = WindowStartupLocation.CenterScreen };
        var startup = Theme.Text(L10n.T("正在打开麦克风…"), 12, Theme.Grey);
        var volume = Theme.Text(L10n.T("用平常音量说几句话。"), 12, Theme.Grey);
        var content = Theme.Stack(16, text, level, startup, volume, Theme.Primary(L10n.T("停止测试"), () => window.Close())); content.Margin = new Thickness(24); window.Content = content;
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) }; var until = DateTime.UtcNow.AddSeconds(15);
        var loudest = 0.0; var heard = DateTime.MaxValue;
        timer.Tick += (_, _) =>
        {
            var loudness = AudioLevel.Loudness(host.MicrophoneLevel);
            level.Value = loudness;
            loudest = Math.Max(loudest, loudness);
            if (host.LastMicrophoneStartMs is { } ms) { startup.Text = Messages.MicrophoneStartup(ms); if (heard == DateTime.MaxValue) heard = DateTime.UtcNow; }
            // After a few seconds of listening, judge the loudest moment (0.43 is about -40 dBFS).
            if (DateTime.UtcNow - heard > TimeSpan.FromSeconds(4))
            {
                volume.Text = loudest < 0.43 ? L10n.T("音量偏低。请在「设置 → 系统 → 声音 → 输入」调高，或靠近麦克风。") : L10n.T("音量正常。");
                volume.Foreground = loudest < 0.43 ? Theme.Warning : Theme.Success;
            }
            if (DateTime.UtcNow >= until || !host.IsMicrophoneTesting) window.Close();
        };
        window.Closed += (_, _) => { timer.Stop(); host.EndMicrophoneTest(); }; window.Show(); timer.Start();
    }
}
