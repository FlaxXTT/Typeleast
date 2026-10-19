using System;
using System.Linq;
using System.Threading;
using System.Windows;

namespace TypeLeast;

/// <summary>
/// Entry point. One copy runs at a time: starting TypeLeast again just brings the
/// running copy's window forward. "--autostart" (used by the Run key) starts it
/// quietly in the tray.
/// </summary>
internal static class Program
{
    private const string MutexName = "TypeLeast.SingleInstance";
    private const string ShowEventName = "TypeLeast.ShowWindow";

    [STAThread]
    private static int Main(string[] args)
    {
        using var mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            try
            {
                using var show = EventWaitHandle.OpenExisting(ShowEventName);
                show.Set();
            }
            catch (Exception) { }
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var host = new AppHost(app);
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("ui.error", e.Exception.GetType().Name);
            e.Handled = true;
        };
        app.Startup += (_, _) =>
        {
            host.Start(autostart: args.Contains("--autostart"));
            // A second launch signals this event: show the window.
            var show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            var thread = new Thread(() =>
            {
                while (show.WaitOne()) app.Dispatcher.InvokeAsync(() => host.ShowWindow(Ui.MainWindow.Page.Home));
            }) { IsBackground = true, Name = "TypeLeast.ShowSignal" };
            thread.Start();
        };
        return app.Run();
    }
}
