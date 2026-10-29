namespace TypeLeast.Core;

/// <summary>The practice passes when one real recording was recognised and cleaned up; what was said is up to the user.</summary>
public sealed class PracticeProgress
{
    public enum Outcome { Passed, TooShort, NothingHeard, NotCleaned }
    public bool Complete { get; private set; }
    public Outcome Accept(DictateResponse response, double seconds)
    {
        if (seconds < 0.6) return Outcome.TooShort;
        if (string.IsNullOrWhiteSpace(response.Raw)) return Outcome.NothingHeard;
        if (response.Fallback || string.IsNullOrWhiteSpace(response.InsertableText)) return Outcome.NotCleaned;
        Complete = true;
        return Outcome.Passed;
    }
}
