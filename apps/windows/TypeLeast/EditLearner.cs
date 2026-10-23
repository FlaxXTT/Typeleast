using System;
using System.Windows.Threading;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// Watches one field for up to two minutes after an insertion and learns the word the user
/// corrected; no keyboard input is collected. The field is observed only when it held exactly
/// the inserted text (never surrounding private text). It is judged once the edit has settled,
/// when the user leaves the field, or when the next dictation starts.
/// </summary>
internal sealed class EditLearner
{
    /// <summary>The paste may land a moment after the insertion is reported.</summary>
    private static readonly TimeSpan BaselineWait = TimeSpan.FromSeconds(5);

    private readonly DispatcherTimer timer = new() { Interval = EditPoll.Interval };
    private FieldTarget? target;
    private string inserted = "";
    private Action<string>? learned;
    private EditPoll? poll;
    private DateTime started;
    private bool baselineSeen;
    private string? lastRead;

    public EditLearner() => timer.Tick += (_, _) => Tick();

    public void Start(FieldTarget field, string text, Action<string> onLearn)
    {
        Finish(); if (text.Length > 2000) return;
        target = field; inserted = text; learned = onLearn; started = DateTime.UtcNow;
        baselineSeen = false; lastRead = null;
        poll = new EditPoll(started, value => value != text);
        timer.Interval = TimeSpan.FromSeconds(1);
        timer.Start();
    }

    public void Stop() { timer.Stop(); target = null; inserted = ""; learned = null; poll = null; lastRead = null; }

    /// <summary>Judge what the field held when last read (the next dictation started).</summary>
    public void Finish()
    {
        if (baselineSeen && poll?.Final(lastRead) is { } value) Judge(value); else Stop();
    }

    private void Tick()
    {
        if (target is null || poll is null) { Stop(); return; }
        // The user left the field: they are done with it.
        if (!target.Matches()) { Finish(); return; }
        var current = FieldContextReader.ReadLearningField(target);
        if (current is null || current.Length > inserted.Length * 2 + 40) { Finish(); return; }
        if (!baselineSeen)
        {
            if (current == inserted) { baselineSeen = true; timer.Interval = EditPoll.Interval; }
            else if (DateTime.UtcNow - started > BaselineWait) Stop();
            return;
        }
        lastRead = current;
        switch (poll.Feed(current, DateTime.UtcNow))
        {
            case EditPoll.Step.Judge: Judge(current); break;
            case EditPoll.Step.Stop: Stop(); break;
        }
    }

    private void Judge(string value)
    {
        var word = EditCorrection.LearnedWord(inserted, value);
        var callback = learned;
        Stop();
        if (word is not null) callback?.Invoke(word);
    }
}
