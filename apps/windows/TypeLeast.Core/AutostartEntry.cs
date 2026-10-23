namespace TypeLeast.Core;

// AutostartEntry.cs - the per-user Run value that starts TypeLeast with Windows, and the
// mark Windows keeps when the user switches a startup app off (Task Manager or
// Settings → Apps → Startup). The registry itself is read and written by the app.
public static class AutostartEntry
{
    public const string Argument = "--autostart";

    public static string Command(string exe) => "\"" + exe + "\" " + Argument;

    /// <summary>The program a Run value starts, or null when it is not in the form <see cref="Command"/> writes.</summary>
    public static string? ExePath(string? value)
    {
        if (value is null || value.Length < 3 || value[0] != '"') return null;
        var end = value.IndexOf('"', 1);
        return end > 1 ? value[1..end] : null;
    }

    /// <summary>True when the StartupApproved value says the user switched the entry off:
    /// its first byte is odd (02 and 06 are on, 03 and 07 off).</summary>
    public static bool SwitchedOff(byte[]? approved) => approved is { Length: > 0 } && (approved[0] & 1) == 1;
}
