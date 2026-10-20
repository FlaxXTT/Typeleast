using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using TypeLeast.Core;

namespace TypeLeast.Ui;

internal sealed class IdleBar : Window
{
    public IdleBar(AppHost host)
    {
        WindowStyle = WindowStyle.None; AllowsTransparency = true; Background = Brushes.Transparent; Topmost = true;
        ShowInTaskbar = false; ShowActivated = false; Focusable = false; ResizeMode = ResizeMode.NoResize; SizeToContent = SizeToContent.WidthAndHeight;
        var button = Theme.Secondary("●", host.Toggle); button.Focusable = false; button.ToolTip = L10n.T("开始听写");
        button.MouseEnter += (_, _) => button.Content = "●  " + L10n.T("开始听写") + "  " + host.HotkeyLabel;
        button.MouseLeave += (_, _) => button.Content = "●";
        Content = new Border { Padding = new Thickness(4), Child = button };
        SourceInitialized += (_, _) => Native.MakeNoActivate(new WindowInteropHelper(this).Handle);
        SizeChanged += (_, _) => { Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - ActualWidth) / 2; Top = SystemParameters.WorkArea.Bottom - ActualHeight - 16; };
    }
}
