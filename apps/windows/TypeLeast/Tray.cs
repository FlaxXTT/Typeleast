using TypeLeast.Core;
using System;
using System.Drawing;
using System.Windows.Forms;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>The notification-area icon (WinForms; WPF has no tray icon). Its right-click menu is the WPF TrayMenu.</summary>
internal sealed class Tray : IDisposable
{
    private readonly NotifyIcon icon;
    private readonly AppHost host;

    public Tray(AppHost host)
    {
        this.host = host;
        icon = new NotifyIcon
        {
            Icon = AppIcon(),
            Text = "TypeLeast",
            Visible = true,
        };
        icon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) host.ShowWindow(MainWindow.Page.Home);
            else if (e.Button == MouseButtons.Right) TrayMenu.ShowAt(host, Cursor.Position);
        };
        host.Changed += Update;
        Update();
    }

    private static Icon AppIcon()
    {
        try
        {
            if (Environment.ProcessPath is { } exe && Icon.ExtractAssociatedIcon(exe) is { } ico) return ico;
        }
        catch (Exception) { }
        return SystemIcons.Application;
    }

    private void Update()
    {
        var tip = "TypeLeast · " + (host.ServiceUp ? L10n.T("就绪") : L10n.T("未就绪"));
        icon.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
