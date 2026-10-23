namespace TypeLeast.Core;

// ClipboardPlan.cs - the decisions behind pasting through the clipboard on Windows,
// kept apart from the Win32 calls (Paster) so they can be tested anywhere:
// - ClipboardSnapshotPlan: which formats of the user's clipboard are saved, in what
//   order, within which size and time budget;
// - ClipboardHandover: who owns each saved memory block when it is put back;
// - PasteRestorePolicy: when the saved clipboard is put back after Ctrl+V.

/// <summary>Standard clipboard format ids and the registered names TypeLeast cares about.</summary>
public static class ClipboardFormats
{
    public const uint Text = 1, OemText = 7, Dib = 8, UnicodeText = 13, HDrop = 15, Locale = 16, DibV5 = 17;
    public const string Html = "HTML Format", Rtf = "Rich Text Format", Png = "PNG", DropEffect = "Preferred DropEffect";
}

public static class ClipboardSnapshotPlan
{
    /// <summary>One format larger than this is not saved; all saved formats together stay under TotalLimit.</summary>
    public const long FormatLimit = 32L << 20, TotalLimit = 64L << 20;
    /// <summary>Formats beyond the common ones are read only while the snapshot has taken less than this.</summary>
    public static readonly TimeSpan OptionalTime = TimeSpan.FromMilliseconds(300);

    private static readonly string[] CommonNames = [ClipboardFormats.Html, ClipboardFormats.Rtf, ClipboardFormats.Png, ClipboardFormats.DropEffect];
    private static readonly uint[] CommonIds = [ClipboardFormats.UnicodeText, ClipboardFormats.Locale, ClipboardFormats.HDrop, ClipboardFormats.DibV5, ClipboardFormats.Dib];

    /// <summary>Text, HTML, RTF, files and images: always saved (within the size budget).</summary>
    public static bool IsCommon(uint format, string? name) =>
        CommonIds.Contains(format) || name is not null && CommonNames.Contains(name);

    /// <summary>Formats whose data is plain memory. GDI and private handles cannot be copied,
    /// and OLE's own formats describe a live object, not data.</summary>
    public static bool Copyable(uint format, string? name) =>
        !(format is 2 or 3 or 9 or 14 or 0x80 or 0x82 or 0x83 or 0x8E || format is >= 0x200 and <= 0x3FF)
        && name is not ("DataObject" or "Ole Private Data");

    /// <summary>The formats to read, common ones first (in the order of <see cref="CommonIds"/>
    /// and <see cref="CommonNames"/>), then the rest as the clipboard lists them. Formats
    /// Windows makes by itself from a saved one are left out: ANSI and OEM text when
    /// Unicode text is there, the plain bitmap when the V5 bitmap is there.</summary>
    public static List<uint> Order(IReadOnlyList<uint> listed, Func<uint, string?> name)
    {
        var copyable = listed.Where(f => Copyable(f, name(f))).Distinct().ToList();
        if (copyable.Contains(ClipboardFormats.UnicodeText)) copyable.RemoveAll(f => f is ClipboardFormats.Text or ClipboardFormats.OemText);
        if (copyable.Contains(ClipboardFormats.DibV5)) copyable.Remove(ClipboardFormats.Dib);
        int Rank(uint f)
        {
            var id = Array.IndexOf(CommonIds, f);
            if (id >= 0) return id;
            var n = name(f);
            var named = n is null ? -1 : Array.IndexOf(CommonNames, n);
            return named >= 0 ? CommonIds.Length + named : int.MaxValue;
        }
        return copyable.Select((f, i) => (f, i)).OrderBy(x => Rank(x.f)).ThenBy(x => x.i).Select(x => x.f).ToList();
    }

    /// <summary>Whether to read <paramref name="format"/> after <paramref name="elapsed"/> of snapshot time.</summary>
    public static bool InTime(uint format, string? name, TimeSpan elapsed) => IsCommon(format, name) || elapsed < OptionalTime;
}

/// <summary>The size budget of one snapshot: a format is charged only when it is saved.</summary>
public sealed class ClipboardBudget
{
    public long Used { get; private set; }

    public bool TryTake(long size)
    {
        if (size <= 0 || size > ClipboardSnapshotPlan.FormatLimit || Used + size > ClipboardSnapshotPlan.TotalLimit) return false;
        Used += size;
        return true;
    }
}

/// <summary>The clipboard side of a handover; the Win32 version lives in Paster.</summary>
public interface IClipboardSink
{
    bool Empty();
    /// <summary>True when the clipboard took the block (it then owns it).</summary>
    bool Put(uint format, IntPtr block);
    void Free(IntPtr block);
}

/// <summary>Puts saved memory blocks on the clipboard without copying them again. Each block is
/// used once: the clipboard owns the ones it took, every other one is freed here.</summary>
public static class ClipboardHandover
{
    /// <summary>Empty the clipboard and hand over every block (the clipboard must be open).
    /// False when something failed: the blocks not taken are freed.</summary>
    public static bool Commit(IReadOnlyList<(uint Format, IntPtr Block)> saved, IClipboardSink sink)
    {
        if (!sink.Empty())
        {
            Discard(saved, sink);
            return false;
        }
        for (var i = 0; i < saved.Count; i++)
        {
            if (sink.Put(saved[i].Format, saved[i].Block)) continue;
            for (var j = i; j < saved.Count; j++) sink.Free(saved[j].Block);
            return false;
        }
        return true;
    }

    public static void Discard(IReadOnlyList<(uint Format, IntPtr Block)> saved, IClipboardSink sink)
    {
        foreach (var (_, block) in saved) sink.Free(block);
    }
}

public enum RestoreDecision { Wait, Restore, Keep }

/// <summary>
/// When to put the user's clipboard back after Ctrl+V. The dictation is offered with delayed
/// rendering, so every read of it is reported (time and process). Clipboard watchers (Windows
/// clipboard history, some browsers) read it as soon as it is written, before Ctrl+V; those reads
/// do not count. A read after Ctrl+V by the target's process, by a process that did not read
/// before, or by an unknown process is the paste: once reads have been quiet for <see cref="Quiet"/>
/// (an app often reads HTML and then text), the clipboard is restored. With no such read within
/// <see cref="GiveUp"/> the paste did not happen and the dictation stays on the clipboard.
/// If another program replaced the clipboard meanwhile, it is left alone.
/// </summary>
public sealed class PasteRestorePolicy(uint targetProcess)
{
    public static readonly TimeSpan Quiet = TimeSpan.FromMilliseconds(200), GiveUp = TimeSpan.FromSeconds(5);

    private readonly HashSet<uint> earlyReaders = [];
    private DateTime? keysSent, lastPasteRead;
    private bool replaced;

    public bool PasteSeen => lastPasteRead is not null;
    public bool WasReplaced => replaced;

    public void KeysSent(DateTime at) => keysSent ??= at;

    /// <summary>The dictation was read by <paramref name="process"/> (0 when unknown).</summary>
    public void Read(DateTime at, uint process)
    {
        if (keysSent is null || at < keysSent)
        {
            if (process != 0 && process != targetProcess) earlyReaders.Add(process);
            return;
        }
        if (process == 0 || process == targetProcess || !earlyReaders.Contains(process)) lastPasteRead = at;
    }

    public void Replaced() => replaced = true;

    public RestoreDecision Decide(DateTime now)
    {
        if (replaced) return RestoreDecision.Keep;
        if (keysSent is not { } sent) return RestoreDecision.Wait;
        if (lastPasteRead is { } read) return now - read >= Quiet ? RestoreDecision.Restore : RestoreDecision.Wait;
        return now - sent >= GiveUp ? RestoreDecision.Keep : RestoreDecision.Wait;
    }
}
