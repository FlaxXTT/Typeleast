using System;
using System.Windows;
using System.Windows.Shell;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// The taskbar button's right-click list: one task per cleanup mode, the current one
/// marked. A task starts TypeLeast.exe with "--strength &lt;mode&gt;"; Program passes it to
/// the running copy, which switches the mode.
/// </summary>
internal static class JumpList
{
    public const string Argument = "--strength";

    public static void Update(string current)
    {
        if (Environment.ProcessPath is not { } exe || Application.Current is not { } app) return;
        try
        {
            var list = new System.Windows.Shell.JumpList { ShowFrequentCategory = false, ShowRecentCategory = false };
            foreach (var code in new[] { "promptbeta" })
                list.JumpItems.Add(new JumpTask
                {
                    Title = L10n.T("需求助手"),
                    ApplicationPath = exe,
                    IconResourcePath = exe,
                    Arguments = Argument + " " + code,
                    CustomCategory = "TypeLeast",
                });
            System.Windows.Shell.JumpList.SetJumpList(app, list);
            list.Apply();
        }
        catch (Exception e) { Log.Write("jumplist.fail", e.GetType().Name); }
    }

    /// <summary>The mode named on the command line, if any.</summary>
    public static string? ModeFrom(string[] args)
    {
        var i = Array.IndexOf(args, Argument);
        return i >= 0 && i + 1 < args.Length && CleanupModes.IsKnown(args[i + 1]) ? args[i + 1] : null;
    }
}
