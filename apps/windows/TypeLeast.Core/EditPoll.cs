namespace TypeLeast.Core;

/// <summary>When to judge an edit: the field is read every few seconds after a paste; once the pasted
/// text has been edited and the field then stayed the same for Settle, the user is done fixing it.
/// Nothing is judged after Window. Edited says whether a value differs from the pasted text.</summary>
public sealed class EditPoll(DateTime start, Func<string, bool> edited)
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(3), Settle = TimeSpan.FromSeconds(6), Window = TimeSpan.FromSeconds(120);

    public enum Step { Wait, Judge, Stop }

    private readonly DateTime started = start;
    private string? last;
    private DateTime lastChange = start;

    /// <summary>The field's value at <paramref name="at"/> (null: it cannot be read any more).</summary>
    public Step Feed(string? value, DateTime at)
    {
        if (value is null) return Step.Stop;
        if (value != last) { last = value; lastChange = at; }
        if (at - lastChange >= Settle && edited(value)) return Step.Judge;
        return at - started >= Window ? Step.Stop : Step.Wait;
    }

    /// <summary>Judge now (the next dictation started, or the user left the field): the value if it was edited.</summary>
    public string? Final(string? value) => value is not null && edited(value) ? value : null;
}
