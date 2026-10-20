using TypeLeast.Core;
using System;
using System.Drawing;
using System.Windows.Forms;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>The notification-area icon and its menu (WinForms; WPF has no tray icon).</summary>
internal sealed class Tray : IDisposable
{
    private readonly NotifyIcon icon;
    private readonly ToolStripMenuItem status;
    private readonly ToolStripMenuItem toggle;
    private readonly AppHost host;

    public Tray(AppHost host)
    {
        this.host = host;
        status = new ToolStripMenuItem("TypeLeast") { Enabled = false };
        toggle = new ToolStripMenuItem(L10n.T("开始听写"), null, (_, _) => host.Toggle());
        var menu = new ContextMenuStrip();
        menu.Items.Add(status);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(toggle);
        menu.Items.Add(new ToolStripMenuItem(L10n.T("开始翻译"), null, (_, _) => host.ToggleTranslate()));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("取消"), null, (_, _) => host.Cancel()));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("粘贴上一条"), null, (_, _) => _ = host.PasteLast()));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("复制上一条"), null, (_, _) => host.CopyLast()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(L10n.T("打开 TypeLeast"), null, (_, _) => host.ShowWindow(MainWindow.Page.Home)));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("历史"), null, (_, _) => host.ShowWindow(MainWindow.Page.History)));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("词典"), null, (_, _) => host.ShowWindow(MainWindow.Page.Dictionary)));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("设置"), null, (_, _) => host.ShowWindow(MainWindow.Page.Settings)));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("重新启动本地服务"), null, (_, _) => host.RestartService()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(L10n.T("退出 TypeLeast"), null, (_, _) => host.Quit()));
        menu.Opening += (_, _) => Update();

        icon = new NotifyIcon
        {
            Icon = AppIcon(),
            Text = "TypeLeast",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) host.ShowWindow(MainWindow.Page.Home); };
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
        status.Text = host.ServiceUp ? L10n.T("就绪 · 按 ") + host.HotkeyLabel + L10n.T(" 听写") : host.ServiceSummary;
        toggle.Text = host.Phase == AppHost.DictationPhase.Recording ? L10n.T("结束听写") : L10n.T("开始听写");
        toggle.Enabled = host.Phase != AppHost.DictationPhase.Thinking;
        var tip = "TypeLeast · " + (host.ServiceUp ? L10n.T("就绪") : L10n.T("未就绪"));
        icon.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
