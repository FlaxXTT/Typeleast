using System;
using System.Threading.Tasks;
using System.Threading;
using System.Windows;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// Puts text at the caret of the app the dictation started in: clipboard, then
/// Ctrl+V, then the previous clipboard text back. If the user switched to another
/// window meanwhile, nothing is pasted (the text stays on the clipboard), so a
/// dictation never lands in the wrong place.
/// </summary>
internal static class Paster
{
    public enum Outcome { Pasted, CopiedOnly, Failed }

    /// <summary>Must run on the UI thread (the clipboard is an STA resource).</summary>
    public static async Task<Outcome> PasteAsync(string text, IntPtr expectedWindow, bool restoreClipboard, CancellationToken ct = default, FieldTarget? field = null, bool formatted = false)
    {
        ct.ThrowIfCancellationRequested();
        var foreground = Native.GetForegroundWindow();
        if (expectedWindow == IntPtr.Zero || foreground != expectedWindow || field is not null && !field.Matches())
        {
            return SetText(text) ? Outcome.CopiedOnly : Outcome.Failed;
        }
        IDataObject? previous = null;
        try { previous = Clipboard.GetDataObject(); } catch (Exception) { }
        if (!SetText(text)) return Outcome.Failed;
        if (formatted && FormattedText.HtmlClipboard(text) is { } html)
        {
            try
            {
                var data = new DataObject(); data.SetText(text); data.SetData(DataFormats.Html, html);
                Clipboard.SetDataObject(data, true);
            }
            catch (Exception) { return Outcome.CopiedOnly; }
        }
        var sequence = Native.GetClipboardSequenceNumber();
        await Task.Delay(30, ct);
        ct.ThrowIfCancellationRequested();
        if (!PasteTarget.Matches(expectedWindow, Native.GetForegroundWindow()) || field is not null && !field.Matches() || sequence != Native.GetClipboardSequenceNumber()) return Outcome.CopiedOnly;
        Native.SendKeys((Native.VK_CONTROL, false), (Native.VK_V, false), (Native.VK_V, true), (Native.VK_CONTROL, true));
        if (restoreClipboard && previous is not null)
        {
            _ = RestoreLater(sequence, previous);
        }
        return Outcome.Pasted;
    }

    private static async Task RestoreLater(uint sequence, IDataObject previous)
    {
        await Task.Delay(600);
        try { if (sequence == Native.GetClipboardSequenceNumber()) Clipboard.SetDataObject(previous, true); }
        catch (Exception) { }
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
