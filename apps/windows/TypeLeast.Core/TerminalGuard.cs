using System.Text;

namespace TypeLeast.Core;

/// <summary>
/// Text bound for a terminal is pasted as one line. A newline in pasted text runs a
/// command in many shells, and the text comes from a model that also read the field's
/// surroundings: a prompt injection there must not become a command that runs on paste.
/// Control characters (escape sequences) are dropped for the same reason.
/// </summary>
public static class TerminalGuard
{
    private static readonly HashSet<string> Terminals = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal", "OpenConsole", "conhost", "cmd", "powershell", "pwsh", "wsl", "bash",
        "wezterm-gui", "alacritty", "mintty", "putty", "kitty", "Tabby", "Hyper", "ConEmu64", "ConEmu",
    };

    /// <param name="processName">The target window's process name, with or without ".exe".</param>
    public static bool IsTerminal(string processName) =>
        Terminals.Contains(processName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? processName[..^4] : processName);

    public static string SafeText(string text, string processName)
    {
        if (!IsTerminal(processName)) return text;
        var output = new StringBuilder();
        var pendingSpace = false;
        foreach (var rune in text.EnumerateRunes())
        {
            var v = rune.Value;
            if (v is 0x0A or 0x0D or 0x09 or 0x2028 or 0x2029) { pendingSpace = output.Length > 0; continue; }
            if (v < 0x20 || v is >= 0x7F and <= 0x9F) continue;
            if (pendingSpace && output.Length > 0 && output[^1] != ' ' && v != ' ') output.Append(' ');
            pendingSpace = false;
            output.Append(rune.ToString());
        }
        return output.ToString().Trim(' ');
    }
}
