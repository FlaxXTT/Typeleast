using System;
using System.Linq;
using TypeLeast.Core;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace TypeLeast;

internal static class FieldContextReader
{
    /// <summary>Longest selection read, in characters.</summary>
    public const int SelectionLimit = 20000;

    /// <summary>Password managers: their fields are never read.</summary>
    public static bool Blocked(IntPtr window)
    {
        var app = Shell.ProcessName(window).ToLowerInvariant();
        return app.Contains("keepass") || app.Contains("1password") || app.Contains("bitwarden") || app.Contains("credential");
    }

    /// <summary>The text selected in the foreground app (a field or a web page), read on this computer
    /// only; null when nothing is selected, for password fields, or when it cannot be read.</summary>
    public static string? Selection(IntPtr window)
    {
        if (window == IntPtr.Zero || Native.GetForegroundWindow() != window || Blocked(window)) return null;
        try
        {
            var field = AutomationElement.FocusedElement;
            if (field is null || field.Current.IsPassword) return null;
            if (!field.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) return null;
            var text = string.Concat(((TextPattern)pattern).GetSelection().Select(r => r.GetText(SelectionLimit)));
            return string.IsNullOrWhiteSpace(text) ? null : (text.Length > SelectionLimit ? text[..SelectionLimit] : text);
        }
        catch (Exception) { return null; }
    }

    public static byte[]? Read(FieldTarget target)
    {
        if (!target.Matches()) return null;
        if (Blocked(target.Window)) return null;
        try
        {
            var field = AutomationElement.FocusedElement;
            if (field is null || field.Current.IsPassword || !field.Current.IsEnabled) return null;
            if (!field.TryGetCurrentPattern(TextPattern.Pattern, out var pattern)) return null;
            var text = (TextPattern)pattern;
            var selections = text.GetSelection();
            if (selections.Length != 1) return null;
            var selected = selections[0];
            var before = selected.Clone(); before.MoveEndpointByRange(TextPatternRangeEndpoint.End, selected, TextPatternRangeEndpoint.Start); before.MoveEndpointByUnit(TextPatternRangeEndpoint.Start, TextUnit.Character, -800);
            var after = selected.Clone(); after.MoveEndpointByRange(TextPatternRangeEndpoint.Start, selected, TextPatternRangeEndpoint.End); after.MoveEndpointByUnit(TextPatternRangeEndpoint.End, TextUnit.Character, 300);
            // Shared service performs its existing bounded context normalization and redaction.
            return ServiceClient.ContextJson(before.GetText(800), selected.GetText(400), after.GetText(300));
        }
        catch (Exception) { return null; }
    }
    /// <summary>The text before the cursor, read on this computer only; null when it cannot be read.</summary>
    public static string? Before(FieldTarget target)
    {
        if (Read(target) is not { } json) return null;
        try { using var doc = System.Text.Json.JsonDocument.Parse(json); return doc.RootElement.GetProperty("before").GetString(); }
        catch (Exception) { return null; }
    }
}
