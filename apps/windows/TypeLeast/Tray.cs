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
        StyleMenu(menu);
        status.Font = new Font("Segoe UI", 9f);
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

    /// <summary>The app's look for a WinForms menu: palette colours, roomy rows, Windows 11 rounded corners.</summary>
    internal static void StyleMenu(ContextMenuStrip menu)
    {
        menu.Renderer = new MenuRenderer();
        menu.ShowImageMargin = false;
        menu.Padding = new Padding(4, 6, 4, 6);
        menu.Font = new Font("Segoe UI", 9.75f);
        foreach (ToolStripItem item in menu.Items)
            if (item is ToolStripMenuItem) item.Padding = new Padding(10, 6, 22, 6);
        menu.HandleCreated += (_, _) => Native.RoundCorners(menu.Handle, small: false);
        menu.Opening += (_, _) => menu.BackColor = MenuRenderer.Palette(Theme.Background);
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

    /// <summary>
    /// Draws the tray menu in the app's palette (light or dark, as the main window):
    /// flat background, a thin border, rounded hover rows, no icon gutter.
    /// </summary>
    private sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        public MenuRenderer() { RoundedEdges = false; }

        public static Color Palette(System.Windows.Media.SolidColorBrush brush) => Color.FromArgb(brush.Color.A, brush.Color.R, brush.Color.G, brush.Color.B);

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using var fill = new SolidBrush(Palette(Theme.Background));
            e.Graphics.FillRectangle(fill, e.AffectedBounds);
        }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            using var pen = new Pen(Palette(Theme.Line));
            var r = e.AffectedBounds;
            e.Graphics.DrawRectangle(pen, r.X, r.Y, r.Width - 1, r.Height - 1);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (!e.Item.Selected || !e.Item.Enabled) return;
            var visible = Math.Min(e.Item.Width, (e.ToolStrip?.Width ?? e.Item.Width) - 2 * e.Item.Bounds.Left);
            var r = new Rectangle(2, 1, visible - 5, e.Item.Height - 3);
            using var path = Rounded(r, 6);
            using var fill = new SolidBrush(Palette(Theme.Selected));
            e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            e.Graphics.FillPath(fill, path);
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.TextColor = Palette(e.Item.Enabled ? Theme.Ink : Theme.Grey);
            base.OnRenderItemText(e);
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            using var pen = new Pen(Palette(Theme.Line));
            var y = e.Item.Height / 2;
            e.Graphics.DrawLine(pen, 10, y, e.Item.Width - 10, y);
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            e.ArrowColor = Palette(Theme.Grey);
            base.OnRenderArrow(e);
        }

        private static System.Drawing.Drawing2D.GraphicsPath Rounded(Rectangle r, int radius)
        {
            var d = radius * 2;
            var path = new System.Drawing.Drawing2D.GraphicsPath();
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
