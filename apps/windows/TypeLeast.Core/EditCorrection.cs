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

    /// <summary>Widen to whole words only in spaced scripts: Chinese has no spaces, so widening took the whole sentence.</summary>
    private static bool InWord(char c) => char.IsLetter(c) && c < '⺀';
}
