using System;
using System.Text.Json;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace TypeLeast;

internal static class FieldContextReader
{
    public static byte[]? Read(FieldTarget target)
    {
        if (!target.Matches()) return null;
        var app = Shell.ProcessName(target.Window).ToLowerInvariant();
        if (app.Contains("keepass") || app.Contains("1password") || app.Contains("bitwarden") || app.Contains("credential")) return null;
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
            return JsonSerializer.SerializeToUtf8Bytes(new { before = before.GetText(800), selected = selected.GetText(400), after = after.GetText(300) });
        }
        catch (Exception) { return null; }
    }
    public static string? ReadLearningField(FieldTarget target)
    {
        if (Read(target) is null) return null;
        try
        {
            var field = AutomationElement.FocusedElement;
            if (field?.TryGetCurrentPattern(TextPattern.Pattern, out var pattern) != true) return null;
            var value = ((TextPattern)pattern).DocumentRange.GetText(2001);
            return value.Length <= 2000 ? value : null;
        }
        catch (Exception) { return null; }
    }
}
