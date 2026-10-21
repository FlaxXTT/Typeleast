using System;
using System.Linq;
using System.Windows.Automation;

namespace TypeLeast;

/// <summary>Field identity only. Capturing a target does not read its text.</summary>
internal sealed class FieldTarget
{
    public IntPtr Window { get; }
    private readonly int[]? identity;
    private FieldTarget(IntPtr window, int[]? identity) { Window = window; this.identity = identity; }
    public static FieldTarget Capture() => CaptureFor(Native.GetForegroundWindow());

    /// <summary>The focused field of <paramref name="window"/>, if it is still in front. UI Automation can
    /// take a second in browsers and Electron apps, so dictation calls this off the UI thread, after the microphone is open.</summary>
    public static FieldTarget CaptureFor(IntPtr window)
    {
        if (window == IntPtr.Zero || Native.GetForegroundWindow() != window) return new(window, null);
        try { return new(window, AutomationElement.FocusedElement?.GetRuntimeId()); }
        catch (Exception) { return new(window, null); }
    }
    public bool Matches()
    {
        if (Window == IntPtr.Zero || Native.GetForegroundWindow() != Window || identity is null) return false;
        try { return AutomationElement.FocusedElement?.GetRuntimeId().SequenceEqual(identity) == true; }
        catch (Exception) { return false; }
    }
}
