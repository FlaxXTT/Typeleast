using System;
using System.Linq;
using System.Threading;
using System.Windows;

namespace TypeLeast;

/// <summary>
/// Entry point. One copy runs at a time: starting TypeLeast again just brings the
/// running copy's window forward. "--autostart" (used by the Run key) starts it
/// quietly in the tray. "--strength &lt;mode&gt;" (the taskbar jump list) switches the
/// running copy's cleanup mode instead of showing its window.
/// </summary>
internal static class Program
{
    private const string MutexName = "TypeLeast.SingleInstance";
    private const string ShowEventName = "TypeLeast.ShowWindow";
    private const string ModeEventPrefix = "TypeLeast.Strength.";

    [STAThread]
    private static int Main(string[] args)
    {
        // The uninstaller asks whether to remove the user's data and runs this with the app closed.
        if (args.Contains(TypeLeast.Core.UserData.RemoveArgument)) return RemoveUserData();
        var mode = JumpList.ModeFrom(args);
        using var mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            try
            {
                using var signal = EventWaitHandle.OpenExisting(mode is null ? ShowEventName : ModeEventPrefix + mode);
                signal.Set();
            }
            catch (Exception) { }
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var host = new AppHost(app);
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("ui.error", e.Exception.GetType().Name);
            host.Cancel();
            e.Handled = true;
        };
        app.Startup += (_, _) =>
        {
            host.Start(autostart: args.Contains("--autostart") || mode is not null);
            if (mode is not null) host.SetStrength(mode, announce: true);
            // A second launch signals one of these events: show the window, or switch the cleanup mode.
            var codes = TypeLeast.Core.CleanupModes.Codes;
            var signals = new WaitHandle[codes.Length + 1];
            signals[0] = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            for (var i = 0; i < codes.Length; i++) signals[i + 1] = new EventWaitHandle(false, EventResetMode.AutoReset, ModeEventPrefix + codes[i]);
            var thread = new Thread(() =>
            {
                while (true)
                {
                    var which = WaitHandle.WaitAny(signals);
                    if (which == 0) app.Dispatcher.InvokeAsync(() => host.ShowWindow(Ui.MainWindow.Page.Home));
                    else { var code = codes[which - 1]; app.Dispatcher.InvokeAsync(() => host.SetStrength(code, announce: true)); }
                }
            }) { IsBackground = true, Name = "TypeLeast.ShowSignal" };
            thread.Start();
        };
        return app.Run();
    }

    /// <summary>Delete the saved API keys, the start-with-Windows entry and TypeLeast's data
    /// folders (settings, history, recordings, speech models). 0 when everything is gone.</summary>
    private static int RemoveUserData()
    {
        var failed = 0;
        try { CredentialStore.DeleteAll(); } catch (Exception) { failed++; }
        Autostart.Apply(false);
        foreach (var folder in TypeLeast.Core.UserData.Folders(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)))
        {
            try { if (System.IO.Directory.Exists(folder)) System.IO.Directory.Delete(folder, recursive: true); }
            catch (Exception) { failed++; }
        }
        return failed == 0 ? 0 : 1;
    }
}
