using System;
using System.Threading.Tasks;
using System.Windows;

namespace TypeLeast;

/// <summary>
/// Puts text at the caret of the app the dictation started in: clipboard, then
/// Ctrl+V, then the previous clipboard text back. If the user switched to another
/// window meanwhile, nothing is pasted (the text stays on the clipboard), so a
/// dictation never lands in the wrong place.
/// </summary>
internal static class Paster
{
    public enum Outcome { Pasted, CopiedOnly }

    /// <summary>Must run on the UI thread (the clipboard is an STA resource).</summary>
    public static async Task<Outcome> PasteAsync(string text, IntPtr expectedWindow, bool restoreClipboard)
    {
        var foreground = Native.GetForegroundWindow();
        if (expectedWindow != IntPtr.Zero && foreground != expectedWindow)
        {
            SetText(text);
            return Outcome.CopiedOnly;
        }
        string? previous = null;
        try { if (Clipboard.ContainsText()) previous = Clipboard.GetText(); } catch (Exception) { }
        if (!SetText(text)) return Outcome.CopiedOnly;
        await Task.Delay(30);
        Native.SendKeys((Native.VK_CONTROL, false), (Native.VK_V, false), (Native.VK_V, true), (Native.VK_CONTROL, true));
        if (restoreClipboard && previous is not null)
        {
            await Task.Delay(600);
            try
            {
                // Only if nobody else changed the clipboard in the meantime.
                if (Clipboard.ContainsText() && Clipboard.GetText() == text) SetText(previous);
            }
            catch (Exception) { }
        }
        return Outcome.Pasted;
    }

    /// <summary>The clipboard is sometimes held by another app for a moment: retry briefly.</summary>
    public static bool SetText(string text)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(text, true);
                return true;
            }
            catch (Exception)
            {
                System.Threading.Thread.Sleep(30);
            }
        }
        Log.Write("clipboard.fail");
        return false;
    }
}
