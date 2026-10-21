using System;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>Thirty-second, one-field observation after an insertion; no keyboard input collection.</summary>
internal sealed class EditLearner
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private FieldTarget? target;
    private string inserted = "";
    private DateTime until;
    private Action<WordEntry>? learned;
    private bool baselineSeen;
    public EditLearner() => timer.Tick += (_, _) => Tick();
    public void Start(FieldTarget field, string text, Action<WordEntry> onLearn)
    {
        Stop(); if (text.Length > 2000) return;
        target = field; inserted = text; learned = onLearn; until = DateTime.UtcNow.AddSeconds(30); baselineSeen = false; timer.Start();
    }
    public void Stop() { timer.Stop(); target = null; inserted = ""; learned = null; }
    private void Tick()
    {
        if (DateTime.UtcNow >= until || target is null || !target.Matches()) { Stop(); return; }
        var current = FieldContextReader.ReadLearningField(target);
        if (current is null) { Stop(); return; }
        // Observe only a field containing exactly our insertion, never surrounding private text.
        if (!baselineSeen) { if (current == inserted) baselineSeen = true; else Stop(); return; }
        if (current == inserted) return;
        var pair = EditCorrection.Find(inserted, current); var callback = learned;
        Stop();
        if (pair is { } p && WordEntry.Parse(p.To, p.From, "auto") is { } entry) callback?.Invoke(entry);
    }
}
