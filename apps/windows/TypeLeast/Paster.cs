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
/// dictation never lands in the wrong place. Like the Mac app, the check is the
/// window, not the focused field: UI Automation field ids are missing or unstable
/// in browsers, Electron apps and terminals, and made most pastes fall back to copy.
/// </summary>
internal static class Paster
{
    public enum Outcome { Pasted, CopiedOnly, ClipboardChanged, Failed }

    /// <summary>Must run on the UI thread (the clipboard is an STA resource).</summary>
    public static async Task<Outcome> PasteAsync(string text, IntPtr expectedWindow, bool restoreClipboard, CancellationToken ct = default, bool formatted = false)
    {
        ct.ThrowIfCancellationRequested();
        if (expectedWindow == IntPtr.Zero || !SameWindow(expectedWindow, Native.GetForegroundWindow()))
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
        if (!SameWindow(expectedWindow, Native.GetForegroundWindow())) return Outcome.CopiedOnly;
        if (sequence != Native.GetClipboardSequenceNumber()) return Outcome.ClipboardChanged;
        Native.SendKeys((Native.VK_CONTROL, false), (Native.VK_V, false), (Native.VK_V, true), (Native.VK_CONTROL, true));
        if (restoreClipboard && previous is not null)
        {
            _ = RestoreLater(sequence, previous);
        }
        return Outcome.Pasted;
    }

    /// <summary>The same top-level window, also when one of them is an owned popup of the other.</summary>
    public static bool SameWindow(IntPtr expected, IntPtr current) =>
        PasteTarget.Matches(expected, current) || current != IntPtr.Zero && Native.RootOwner(expected) == Native.RootOwner(current);

    /// <summary>What the overlay says after a paste attempt.</summary>
    public static string Message(Outcome outcome) => outcome switch
    {
        Outcome.Pasted => L10n.T("已粘贴"),
        Outcome.ClipboardChanged => L10n.T("剪贴板被其他程序改动，已复制到剪贴板"),
        Outcome.Failed => L10n.T("无法写入剪贴板，请重试"),
        _ => L10n.T("窗口已切换，已复制到剪贴板"),
    };

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
