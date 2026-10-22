using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Threading;
using System.Windows.Interop;
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

    /// <summary>Must run on the UI thread (the clipboard owner window lives there).</summary>
    public static async Task<Outcome> PasteAsync(string text, IntPtr expectedWindow, bool restoreClipboard, CancellationToken ct = default, bool formatted = false)
    {
        ct.ThrowIfCancellationRequested();
        if (expectedWindow == IntPtr.Zero || !SameWindow(expectedWindow, Native.GetForegroundWindow()))
        {
            return SetText(text) ? Outcome.CopiedOnly : Outcome.Failed;
        }
        var previous = restoreClipboard ? Snapshot() : null;
        if (!Set(text, formatted ? FormattedText.HtmlClipboard(text) : null)) return Outcome.Failed;
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

    // The clipboard is written with the plain Win32 calls. WPF's Clipboard goes through OLE, which on some
    // Windows 11 systems fails every call (RPC_E_UNEXPECTED / CLIPBRD_E_CANT_OPEN) while Win32 works; and
    // putting back Clipboard.GetDataObject(), a live view rather than a copy, made the clipboard refer to itself.

    private const uint CF_UNICODETEXT = 13, GMEM_MOVEABLE = 2;
    private const long SnapshotLimit = 64L << 20;
    private static readonly uint HtmlFormat = Native.RegisterClipboardFormatW("HTML Format");
    /// <summary>A hidden message-only window: EmptyClipboard with no owner window makes SetClipboardData fail.</summary>
    private static HwndSource? owner;

    /// <summary>Formats whose data is a GDI or private handle, not memory that can be copied.</summary>
    private static bool Copyable(uint format)
    {
        if (format is 2 or 3 or 9 or 14 or 0x80 or 0x82 or 0x83 or 0x8E || format is >= 0x200 and <= 0x3FF) return false;
        var name = new StringBuilder(64);
        return Native.GetClipboardFormatNameW(format, name, name.Capacity) == 0 || name.ToString() is not ("DataObject" or "Ole Private Data");
    }

    /// <summary>The clipboard is sometimes held by another app for a moment: retry briefly (at most half a second).</summary>
    private static bool Open()
    {
        owner ??= new HwndSource(new HwndSourceParameters("TypeLeast clipboard") { ParentWindow = new IntPtr(-3) });
        for (var attempt = 0; attempt < 25; attempt++)
        {
            if (Native.OpenClipboard(owner.Handle)) return true;
            Thread.Sleep(20);
        }
        return false;
    }

    /// <summary>A copy of everything on the clipboard that is plain memory (text, HTML, RTF, files, images as DIB).</summary>
    private static List<(uint Format, byte[] Data)>? Snapshot()
    {
        if (!Open()) return null;
        try
        {
            var copy = new List<(uint, byte[])>();
            long total = 0;
            for (var format = Native.EnumClipboardFormats(0); format != 0; format = Native.EnumClipboardFormats(format))
            {
                if (!Copyable(format)) continue;
                var handle = Native.GetClipboardData(format);
                if (handle == IntPtr.Zero) continue;
                var size = (long)Native.GlobalSize(handle).ToUInt64();
                if (size == 0 || (total += size) > SnapshotLimit) continue;
                var source = Native.GlobalLock(handle);
                if (source == IntPtr.Zero) continue;
                var bytes = new byte[size];
                Marshal.Copy(source, bytes, 0, bytes.Length);
                Native.GlobalUnlock(handle);
                copy.Add((format, bytes));
            }
            return copy.Count > 0 ? copy : null;
        }
        finally { Native.CloseClipboard(); }
    }

    private static async Task RestoreLater(uint sequence, List<(uint Format, byte[] Data)> previous)
    {
        await Task.Delay(600);
        if (sequence == Native.GetClipboardSequenceNumber()) Write(previous);
    }

    public static bool SetText(string text) => Set(text, null);

    private static bool Set(string text, string? html)
    {
        var data = new List<(uint, byte[])> { (CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0")) };
        if (html is not null) data.Add((HtmlFormat, Encoding.UTF8.GetBytes(html + "\0")));
        if (Write(data)) return true;
        Log.Write("clipboard.fail");
        return false;
    }

    private static bool Write(List<(uint Format, byte[] Data)> data)
    {
        if (!Open()) return false;
        try
        {
            if (!Native.EmptyClipboard()) return false;
            foreach (var (format, bytes) in data)
            {
                var memory = Native.GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
                if (memory == IntPtr.Zero) return false;
                var target = Native.GlobalLock(memory);
                if (target == IntPtr.Zero) { Native.GlobalFree(memory); return false; }
                Marshal.Copy(bytes, 0, target, bytes.Length);
                Native.GlobalUnlock(memory);
                // On success the clipboard owns the memory; otherwise it is still ours to free.
                if (Native.SetClipboardData(format, memory) == IntPtr.Zero) { Native.GlobalFree(memory); return false; }
            }
            return true;
        }
        finally { Native.CloseClipboard(); }
    }
}
