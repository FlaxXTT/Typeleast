namespace TypeLeast.Core;

/// <summary>
/// Prompt mode's system prompt as a plain text file the user edits in a text editor,
/// like a configuration file. The service keeps its own promptify.json; the app
/// sends the file's text to it as the replacement of the default prompt.
/// </summary>
public static class PromptFile
{
    public const string FileName = "promptify-system.md";

    public static string PathIn(string stateDir) => Path.Combine(stateDir, FileName);

    /// <summary>The replacement to send for the file's text, or null for the default prompt
    /// (no file, an empty file, or the default text itself, whatever the line endings).</summary>
    public static string? OverrideFrom(string? fileText, string defaultText)
    {
        if (fileText is null) return null;
        var text = Normalize(fileText);
        return text.Length == 0 || text == Normalize(defaultText) ? null : text;
    }

    /// <summary>What the file starts with: the prompt in effect now, with Windows line endings for Notepad.</summary>
    public static string Initial(string? currentOverride, string defaultText) =>
        Normalize(currentOverride ?? defaultText).Replace("\n", "\r\n") + "\r\n";

    private static string Normalize(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n').Trim();
}
