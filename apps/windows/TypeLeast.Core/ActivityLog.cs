using System.Globalization;
using System.Text.Json;

namespace TypeLeast.Core;

public sealed class ActivityDay
{
    public int Dictations { get; set; }
    public int Words { get; set; }
}

/// <summary>
/// Per-day usage for the home heatmap (活动): dates and counts only, never any text, in
/// app-activity.json. Kept apart from the history so a short history does not erase the
/// record of active days; clearing the history clears it too.
/// </summary>
public sealed class ActivityLog
{
    private readonly string path;
    public Dictionary<string, ActivityDay> Days { get; private set; } = new();
    public bool IsStarted => File.Exists(path);

    public ActivityLog(string path)
    {
        this.path = path;
        try
        {
            Days = JsonSerializer.Deserialize<Dictionary<string, ActivityDay>>(File.ReadAllText(path), Json.Options) ?? new();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            Days = new();
        }
    }

    public static string Key(DateTime date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public ActivityDay Day(DateTime date) => Days.TryGetValue(Key(date), out var d) ? d : new ActivityDay();

    public void Record(int words, DateTime date)
    {
        Add(date, words);
        Save();
    }

    /// <summary>First run after an update: rebuild the past from whatever history is still kept.</summary>
    public void SeedIfNeeded(IEnumerable<(DateTime Date, int Words)> items)
    {
        if (IsStarted) return;
        foreach (var (date, words) in items) Add(date, words);
        Save();
    }

    public void Clear()
    {
        Days.Clear();
        Save();
    }

    public int ActiveDays => Days.Values.Count(d => d.Dictations > 0);

    /// <summary>The current streak runs back from today, or from yesterday while today has nothing yet.</summary>
    public (int Current, int Longest) Streaks(DateTime today)
    {
        var active = new HashSet<string>(Days.Where(d => d.Value.Dictations > 0).Select(d => d.Key));
        var cursor = today.Date;
        if (!active.Contains(Key(cursor))) cursor = cursor.AddDays(-1);
        var current = 0;
        while (active.Contains(Key(cursor)))
        {
            current++;
            cursor = cursor.AddDays(-1);
        }
        int longest = 0, run = 0;
        DateTime? previous = null;
        foreach (var key in active.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (!DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)) continue;
            run = previous is { } p && (date - p).TotalDays == 1 ? run + 1 : 1;
            longest = Math.Max(longest, run);
            previous = date;
        }
        return (current, longest);
    }

    /// <summary>0 = no activity, 1 light ... 4 power use, by dictations that day.</summary>
    public static int Level(int dictations) => dictations switch
    {
        < 1 => 0,
        <= 3 => 1,
        <= 9 => 2,
        <= 24 => 3,
        _ => 4,
    };

    /// <summary>CJK characters plus latin words: the unit people mean by "字" (same as the Mac app).</summary>
    public static int CountWords(string text)
    {
        var cjk = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            var v = rune.Value;
            if (v is >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF
                or >= 0x3040 and <= 0x30FF or >= 0xAC00 and <= 0xD7AF) cjk++;
        }
        var latin = 0;
        var inWord = false;
        foreach (var c in text)
        {
            var part = c < 128 && char.IsLetterOrDigit(c);
            if (part && !inWord) latin++;
            inWord = part;
        }
        return cjk + latin;
    }

    private void Add(DateTime date, int words)
    {
        var key = Key(date);
        if (!Days.TryGetValue(key, out var day)) Days[key] = day = new ActivityDay();
        day.Dictations++;
        day.Words += Math.Max(0, words);
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Days, Json.Options));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}
