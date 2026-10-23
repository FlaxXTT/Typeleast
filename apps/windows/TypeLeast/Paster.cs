using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Threading.Tasks;
using System.Threading;
using System.Windows.Interop;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// Puts text at the caret of the app the dictation started in: clipboard, then
/// Ctrl+V, then the user's previous clipboard back. If the user switched to another
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
        var payload = Payload(text, formatted ? FormattedText.HtmlClipboard(text) : null);
        // Saving the user's clipboard can make the app it came from render large data: off the UI thread.
        var previous = restoreClipboard ? await Task.Run(Snapshot) : null;
        Session? session = null;
        if (previous is not null && DelayedRendering)
        {
            Native.GetWindowThreadProcessId(expectedWindow, out var process);
            session = Offer(payload, previous, process);
            if (session is null) return Outcome.Failed;
        }
        else if (!Write(payload))
        {
            if (previous is not null) Discard(previous);
            Log.Write("clipboard.fail");
            return Outcome.Failed;
        }
        var sequence = Native.GetClipboardSequenceNumber();
        try
        {
            await Task.Delay(30, ct);
        }
        catch (OperationCanceledException)
        {
            // Cancelled before Ctrl+V: the user's clipboard goes back right away.
            if (session is not null) Finish(session, RestoreDecision.Restore);
            else if (previous is not null) Restore(previous);
            throw;
        }
        if (!SameWindow(expectedWindow, Native.GetForegroundWindow()))
        {
            if (session is not null) Finish(session, RestoreDecision.Keep);
            else if (previous is not null) Discard(previous);
            return Outcome.CopiedOnly;
        }
        if (session is not null ? session.Policy.Decide(DateTime.UtcNow) == RestoreDecision.Keep : sequence != Native.GetClipboardSequenceNumber())
        {
            if (session is not null) Finish(session, RestoreDecision.Keep);
            else if (previous is not null) Discard(previous);
            return Outcome.ClipboardChanged;
        }
        Native.SendKeys((Native.VK_CONTROL, false), (Native.VK_V, false), (Native.VK_V, true), (Native.VK_CONTROL, true));
        if (session is not null)
        {
            session.Policy.KeysSent(DateTime.UtcNow);
            _ = Watch(session);
        }
        else if (previous is not null)
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

    /// <summary>Copy only (no paste, no restore).</summary>
    public static bool SetText(string text)
    {
        if (Write(Payload(text, null))) return true;
        Log.Write("clipboard.fail");
        return false;
    }

    // The clipboard is used through the plain Win32 calls. WPF's Clipboard goes through OLE, which on some
    // Windows 11 systems fails every call (RPC_E_UNEXPECTED / CLIPBRD_E_CANT_OPEN) while Win32 works; and
    // putting back Clipboard.GetDataObject(), a live view rather than a copy, made the clipboard refer to itself.
    //
    // The user's clipboard is saved once, straight into memory blocks of our own, and those same blocks are
    // handed back to the clipboard when it is restored (ClipboardHandover): no second copy, nothing on the
    // managed heap. The dictation is offered with delayed rendering, so Windows tells us each time a program
    // reads it; PasteRestorePolicy turns those reads into "the paste happened, restore now".

    /// <summary>Off: write the dictation at once and restore after a fixed wait (the behaviour before delayed rendering).</summary>
    private static readonly bool DelayedRendering = true;
    private const uint GMEM_MOVEABLE = 2, WM_RENDERFORMAT = 0x0305, WM_RENDERALLFORMATS = 0x0306, WM_DESTROYCLIPBOARD = 0x0307;
    private static readonly uint HtmlFormat = Native.RegisterClipboardFormatW(ClipboardFormats.Html);

    /// <summary>A hidden message-only window: it owns what TypeLeast puts on the clipboard (EmptyClipboard with
    /// no owner window makes SetClipboardData fail) and receives the delayed-rendering requests.</summary>
    private static HwndSource? owner;
    private static HwndSource Owner
    {
        get
        {
            if (owner is null)
            {
                owner = new HwndSource(new HwndSourceParameters("TypeLeast clipboard") { ParentWindow = new IntPtr(-3) });
                owner.AddHook(OwnerMessage);
            }
            return owner;
        }
    }

    /// <summary>The dictation offered on the clipboard, and the user's clipboard waiting to go back.</summary>
    private sealed class Session(List<(uint Format, byte[] Data)> payload, List<(uint Format, IntPtr Block)> previous, uint target)
    {
        public readonly List<(uint Format, byte[] Data)> Payload = payload;
        public readonly List<(uint Format, IntPtr Block)> Previous = previous;
        public readonly PasteRestorePolicy Policy = new(target);
        public bool Restoring, Done;
    }

    private static Session? active;

    private static List<(uint Format, byte[] Data)> Payload(string text, string? html)
    {
        var data = new List<(uint, byte[])> { (ClipboardFormats.UnicodeText, Encoding.Unicode.GetBytes(text + "\0")) };
        if (html is not null) data.Add((HtmlFormat, Encoding.UTF8.GetBytes(html + "\0")));
        return data;
    }

    /// <summary>The clipboard is sometimes held by another app for a moment: retry briefly (at most half a second).</summary>
    private static bool Open(IntPtr window)
    {
        for (var attempt = 0; attempt < 25; attempt++)
        {
            if (Native.OpenClipboard(window)) return true;
            Thread.Sleep(20);
        }
        return false;
    }

    private static IntPtr Block(byte[] bytes)
    {
        var memory = Native.GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
        if (memory == IntPtr.Zero) return IntPtr.Zero;
        var target = Native.GlobalLock(memory);
        if (target == IntPtr.Zero) { Native.GlobalFree(memory); return IntPtr.Zero; }
        System.Runtime.InteropServices.Marshal.Copy(bytes, 0, target, bytes.Length);
        Native.GlobalUnlock(memory);
        return memory;
    }

    /// <summary>Copy of the user's clipboard into memory blocks of our own (see ClipboardSnapshotPlan for what is
    /// kept). Runs on a worker thread; the clipboard is opened without a window, only to read.</summary>
    private static List<(uint Format, IntPtr Block)>? Snapshot()
    {
        if (!Open(IntPtr.Zero)) return null;
        var saved = new List<(uint, IntPtr)>();
        try
        {
            var listed = new List<uint>();
            for (var format = Native.EnumClipboardFormats(0); format != 0; format = Native.EnumClipboardFormats(format)) listed.Add(format);
            var names = new Dictionary<uint, string?>();
            string? Name(uint format)
            {
                if (names.TryGetValue(format, out var known)) return known;
                var name = new StringBuilder(128);
                return names[format] = Native.GetClipboardFormatNameW(format, name, name.Capacity) > 0 ? name.ToString() : null;
            }
            var budget = new ClipboardBudget();
            var clock = Stopwatch.StartNew();
            foreach (var format in ClipboardSnapshotPlan.Order(listed, Name))
            {
                if (!ClipboardSnapshotPlan.InTime(format, Name(format), clock.Elapsed)) continue;
                var source = Native.GetClipboardData(format);
                if (source == IntPtr.Zero) continue;
                var size = Native.GlobalSize(source);
                if (!budget.TryTake((long)size.ToUInt64())) continue;
                var from = Native.GlobalLock(source);
                if (from == IntPtr.Zero) continue;
                var copy = Native.GlobalAlloc(GMEM_MOVEABLE, size);
                var to = copy == IntPtr.Zero ? IntPtr.Zero : Native.GlobalLock(copy);
                if (to != IntPtr.Zero)
                {
                    Native.CopyMemory(to, from, size);
                    Native.GlobalUnlock(copy);
                    saved.Add((format, copy));
                }
                else if (copy != IntPtr.Zero) Native.GlobalFree(copy);
                Native.GlobalUnlock(source);
            }
        }
        catch (Exception)
        {
            Discard(saved);
            return null;
        }
        finally { Native.CloseClipboard(); }
        return saved.Count > 0 ? saved : null;
    }

    private sealed class Win32Sink : IClipboardSink
    {
        public static readonly Win32Sink Instance = new();
        public bool Empty() => Native.EmptyClipboard();
        public bool Put(uint format, IntPtr block) => Native.SetClipboardData(format, block) != IntPtr.Zero;
        public void Free(IntPtr block) => Native.GlobalFree(block);
    }

    private static void Discard(List<(uint Format, IntPtr Block)> saved) => ClipboardHandover.Discard(saved, Win32Sink.Instance);

    /// <summary>Write data now. Every block is made before the clipboard is touched: if one cannot be made,
    /// the clipboard stays as it was.</summary>
    private static bool Write(List<(uint Format, byte[] Data)> data)
    {
        var blocks = new List<(uint, IntPtr)>();
        foreach (var (format, bytes) in data)
        {
            var block = Block(bytes);
            if (block == IntPtr.Zero) { Discard(blocks); return false; }
            blocks.Add((format, block));
        }
        if (!Open(Owner.Handle)) { Discard(blocks); return false; }
        try { return ClipboardHandover.Commit(blocks, Win32Sink.Instance); }
        finally { Native.CloseClipboard(); }
    }

    /// <summary>Put the saved clipboard back (its blocks are handed over, not copied).</summary>
    private static void Restore(List<(uint Format, IntPtr Block)> saved)
    {
        if (!Open(Owner.Handle)) { Discard(saved); Log.Write("clipboard.restore.fail"); return; }
        try { if (!ClipboardHandover.Commit(saved, Win32Sink.Instance)) Log.Write("clipboard.restore.fail"); }
        finally { Native.CloseClipboard(); }
    }

    /// <summary>Announce the dictation's formats without their data; Windows asks for the data when a
    /// program reads it (WM_RENDERFORMAT).</summary>
    private static Session? Offer(List<(uint Format, byte[] Data)> payload, List<(uint Format, IntPtr Block)> previous, uint target)
    {
        if (!Open(Owner.Handle)) { Discard(previous); Log.Write("clipboard.fail"); return null; }
        try
        {
            // Emptying ends an earlier offer of ours (WM_DESTROYCLIPBOARD marks it replaced).
            if (!Native.EmptyClipboard()) { Discard(previous); Log.Write("clipboard.fail"); return null; }
            var session = new Session(payload, previous, target);
            active = session;
            foreach (var (format, _) in payload) Native.SetClipboardData(format, IntPtr.Zero);
            return session;
        }
        finally { Native.CloseClipboard(); }
    }

    private static async Task Watch(Session session)
    {
        while (!session.Done)
        {
            await Task.Delay(50);
            var decision = session.Policy.Decide(DateTime.UtcNow);
            if (decision != RestoreDecision.Wait) Finish(session, decision);
        }
    }

    /// <summary>End an offer: put the user's clipboard back, or keep the dictation and free the saved copy.</summary>
    private static void Finish(Session session, RestoreDecision decision)
    {
        if (session.Done) return;
        session.Done = true;
        if (decision == RestoreDecision.Restore && !session.Policy.WasReplaced)
        {
            session.Restoring = true;
            Restore(session.Previous);
        }
        else
        {
            // Keeping the dictation: hand Windows its data now, so it survives TypeLeast quitting.
            if (decision == RestoreDecision.Keep && active == session) RenderAll(session);
            Discard(session.Previous);
        }
        if (active == session) active = null;
    }

    /// <summary>Fallback without delayed rendering: restore after a fixed wait unless the clipboard changed.</summary>
    private static async Task RestoreLater(uint sequence, List<(uint Format, IntPtr Block)> previous)
    {
        await Task.Delay(600);
        if (sequence == Native.GetClipboardSequenceNumber()) Restore(previous);
        else Discard(previous);
    }

    private static void Render(Session session, uint format)
    {
        foreach (var (f, bytes) in session.Payload)
        {
            if (f != format) continue;
            var block = Block(bytes);
            if (block != IntPtr.Zero && Native.SetClipboardData(format, block) == IntPtr.Zero) Native.GlobalFree(block);
        }
    }

    private static void RenderAll(Session session)
    {
        if (!Open(Owner.Handle)) return;
        try
        {
            if (Native.GetClipboardOwner() != Owner.Handle) return;
            foreach (var (format, _) in session.Payload) Render(session, format);
        }
        finally { Native.CloseClipboard(); }
    }

    private static IntPtr OwnerMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        var session = active;
        switch ((uint)message)
        {
            case WM_RENDERFORMAT when session is not null:
                // The reader has the clipboard open: put the data in place and note who asked.
                Render(session, (uint)wParam.ToInt64());
                var reader = Native.GetOpenClipboardWindow();
                uint process = 0;
                if (reader != IntPtr.Zero) Native.GetWindowThreadProcessId(reader, out process);
                session.Policy.Read(DateTime.UtcNow, process);
                handled = true;
                break;
            case WM_RENDERALLFORMATS when session is not null:
                // TypeLeast is quitting while its offer is on the clipboard.
                RenderAll(session);
                handled = true;
                break;
            case WM_DESTROYCLIPBOARD when session is not null && !session.Restoring:
                session.Policy.Replaced();
                handled = true;
                break;
        }
        return IntPtr.Zero;
    }
}
