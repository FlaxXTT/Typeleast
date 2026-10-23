namespace TypeLeast.Core;

public static class EditCorrection
{
    public static (string From, string To)? Find(string before, string after)
    {
        if (before == after || before.Length > 2000 || after.Length > 2000) return null;
        int start = 0;
        while (start < before.Length && start < after.Length && before[start] == after[start]) start++;
        int end = 0;
        while (end < before.Length - start && end < after.Length - start && before[^(end + 1)] == after[^(end + 1)]) end++;
        while (start > 0 && InWord(before[start - 1]) && InWord(after[start - 1])) start--;
        while (end > 0 && InWord(before[before.Length - end]) && InWord(after[after.Length - end])) end--;
        var from = before[start..(before.Length - end)].Trim();
        var to = after[start..(after.Length - end)].Trim();
        if (from.Length is < 2 or > 60 || to.Length is < 2 or > 60 || !(from + to).All(char.IsLetter)) return null;
        return (from, to);
    }

    /// <summary>The word to add to the dictionary for this edit, or null. Only the corrected word is
    /// learned, as a spelling to prefer, never a "replace A with B" rule (a content edit such as
    /// 明天 → 后天 must not rewrite every later 明天). A latin fix must look like the same word
    /// (a typo), not a different one; Chinese cannot be compared by sound here, and is kept.</summary>
    public static string? LearnedWord(string before, string after)
    {
        if (Find(before, after) is not { } pair) return null;
        var latin = !(pair.From + pair.To).Any(IsCjk);
        if (latin && Similarity(pair.From.ToLowerInvariant(), pair.To.ToLowerInvariant()) < 0.6) return null;
        return pair.To;
    }

    /// <summary>How alike two latin spellings are: letters, or their consonant skeletons ("depsik" ~ "deepseek").</summary>
    public static double Similarity(string a, string b)
    {
        static string Skeleton(string s) => new(s.Where(c => !"aeiou".Contains(c)).ToArray());
        return Math.Max(Ratio(a, b), Ratio(Skeleton(a), Skeleton(b)) * 0.9);
    }

    private static double Ratio(string a, string b)
    {
        var longest = Math.Max(a.Length, b.Length);
        return longest == 0 ? 0 : 1 - (double)Levenshtein(a, b) / longest;
    }

    private static int Levenshtein(string a, string b)
    {
        var previous = Enumerable.Range(0, b.Length + 1).ToArray();
        var current = new int[b.Length + 1];
        for (var i = 1; i <= a.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= b.Length; j++)
                current[j] = Math.Min(Math.Min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            (previous, current) = (current, previous);
        }
        return previous[b.Length];
    }

    private static bool IsCjk(char c) => c is >= '\u3400' and <= '\u9FFF' or >= '\uF900' and <= '\uFAFF';

    /// <summary>Widen to whole words only in spaced scripts: Chinese has no spaces, so widening took the whole sentence.</summary>
    private static bool InWord(char c) => char.IsLetter(c) && c < '⺀';
}

/// <summary>When to judge an edit: the field is read every few seconds after a paste; once the pasted
/// text has been edited and the field then stayed the same for Settle, the user is done fixing it.
/// Nothing is judged after Window. Edited says whether a value differs from the pasted text.</summary>
public sealed class EditPoll(DateTime start, Func<string, bool> edited)
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(3), Settle = TimeSpan.FromSeconds(6), Window = TimeSpan.FromSeconds(120);

    public enum Step { Wait, Judge, Stop }

    private string? last;
    private DateTime lastChange = start;

    /// <summary>The field's value at <paramref name="at"/> (null: it cannot be read any more).</summary>
    public Step Feed(string? value, DateTime at)
    {
        if (value is null) return Step.Stop;
        if (value != last) { last = value; lastChange = at; }
        if (at - lastChange >= Settle && edited(value)) return Step.Judge;
        return at - start >= Window ? Step.Stop : Step.Wait;
    }

    /// <summary>Judge now (the next dictation started, or the user left the field): the value if it was edited.</summary>
    public string? Final(string? value) => value is not null && edited(value) ? value : null;
}
