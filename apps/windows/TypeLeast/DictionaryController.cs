using System;
using System.Linq;
using System.Threading.Tasks;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>
/// Everything that adds words to the dictionary as one piece: editing it by hand, learning a word
/// the user corrects after a paste (EditLearner), suggestions from what the cleanup model corrected
/// (WordSuggestions), a word picked in History, and the "已加入词典 · 撤销" toast. The words live in
/// the settings and go with every dictation.
/// </summary>
internal sealed class DictionaryController(AppSettings settings, Func<bool> save, Action<string> setHint, Func<bool> quitting,
    Func<string, string, Task<string?>> learnedWord)
{
    private readonly EditLearner learner = new(learnedWord);
    private LearnedToast? toast;

    /// <summary>Sent with every dictation: "word" or "heard=word"; the service passes on only those a dictation mentions.</summary>
    public string[] ServiceEntries => settings.DictionaryEntries.Where(e => !e.LocalOnly).Select(e => e.RequestValue).ToArray();

    /// <summary>Entries marked 「不发给模型」: the service only fixes their heard-as spellings locally.</summary>
    public string[] LocalEntries => settings.DictionaryEntries.Where(e => e.LocalOnly).Select(e => e.RequestValue).ToArray();

    public void AddWord(string entry)
    {
        if (WordEntry.FromLegacy(entry) is { } word) SaveWord(word);
    }

    public bool SaveWord(WordEntry entry)
    {
        if (WordEntry.Parse(entry.Word, entry.HeardAs, entry.Source) is null) return false;
        if (entry.Source == "auto" && settings.DismissedSuggestions.Contains(entry.Word, StringComparer.OrdinalIgnoreCase)) return false;
        if (settings.DictionaryEntries.Any(e => e.Id != entry.Id && string.Equals(e.ServiceValue, entry.ServiceValue, StringComparison.OrdinalIgnoreCase)))
        { setHint(L10n.T("词条已存在或输入无效")); return false; }
        var previous = settings.DictionaryEntries.ToList();
        var index = settings.DictionaryEntries.FindIndex(e => e.Id == entry.Id);
        if (index < 0) settings.DictionaryEntries.Add(entry); else settings.DictionaryEntries[index] = entry;
        if (!save()) { settings.DictionaryEntries = previous; return false; }
        return true;
    }

    public void RemoveWord(string entry)
    {
        var previous = settings.DictionaryEntries.ToList();
        var dismissed = settings.DismissedSuggestions.ToList();
        var removed = settings.DictionaryEntries.Where(e => e.Id == entry || e.ServiceValue == entry).ToList();
        settings.DictionaryEntries.RemoveAll(e => e.Id == entry || e.ServiceValue == entry);
        WordSuggestions.RememberDeletion(settings, removed);
        if (!save()) { settings.DictionaryEntries = previous; settings.DismissedSuggestions = dismissed; }
    }

    /// <summary>A paste landed in <paramref name="field"/>: watch it for a fix of <paramref name="text"/>.</summary>
    public void Pasted(FieldTarget field, string text)
    {
        if (settings.LearnCorrections) learner.Start(field, text, Learned);
    }

    /// <summary>The next dictation starts: judge the last fix now.</summary>
    public void DictationStarting() => learner.Finish();

    /// <summary>Stop watching (microphone test, cancel, learning switched off).</summary>
    public void StopWatching() => learner.Stop();

    /// <summary>Service-filtered terms are learned automatically; the dictionary remains editable.</summary>
    public void Received(System.Collections.Generic.IEnumerable<SuggestionCandidate> candidates)
    {
        var previousEntries = settings.DictionaryEntries.ToList();
        var previousPending = settings.WordSuggestions.ToList();
        if (!WordSuggestions.ApplyAutomatic(settings, candidates)) return;
        if (!save()) { settings.DictionaryEntries = previousEntries; settings.WordSuggestions = previousPending; }
    }

    /// <summary>A word the user selected in History: added to the dictionary by hand.</summary>
    public void AddFromHistory(string word)
    {
        word = word.Trim();
        if (word.Length is 0 or > 40 || word.Contains('\n')) return;
        if (settings.DictionaryEntries.Any(e => e.Word.Equals(word, StringComparison.OrdinalIgnoreCase))) { setHint(L10n.T("「{0}」已在词典里", word)); return; }
        if (WordEntry.Parse(word) is { } entry && SaveWord(entry)) setHint(L10n.T("已把「{0}」加入词典", word));
    }

    /// <summary>A word the user corrected after a dictation: added as a spelling to prefer (never a
    /// replacement rule), unless it is already there; the toast can take it back.</summary>
    private void Learned(string word)
    {
        if (!settings.LearnCorrections || quitting()) return;
        if (settings.DictionaryEntries.Any(e => string.Equals(e.Word, word, StringComparison.OrdinalIgnoreCase))) return;
        if (WordEntry.Parse(word, "", "auto") is not { } entry || !SaveWord(entry)) return;
        setHint(L10n.T("已把「{0}」加入词典", word));
        toast ??= new LearnedToast();
        toast.Show(L10n.T("已把「{0}」加入词典", word), () =>
        {
            RemoveWord(entry.Id);
            setHint(L10n.T("已从词典删除「{0}」", word));
        });
    }
}
