using System;
using System.Linq;
using System.Threading.Tasks;
using TypeLeast.Core;
using TypeLeast.Ui;

namespace TypeLeast;

/// <summary>Legacy port for confirmed whole-output revisions. Vocabulary callbacks are inert.</summary>
internal sealed class DictionaryController(AppSettings settings)
{
    private readonly EditLearner learner = new((_,_)=>Task.FromResult<string?>(null));

    /// <summary>Sent with every dictation: "word" or "heard=word"; the service passes on only those a dictation mentions.</summary>
    public string[] ServiceEntries => Array.Empty<string>();

    /// <summary>Entries marked 「不发给模型」: the service only fixes their heard-as spellings locally.</summary>
    public string[] LocalEntries => Array.Empty<string>();

    public void AddWord(string entry)
    {
        if (WordEntry.FromLegacy(entry) is { } word) SaveWord(word);
    }

    public bool SaveWord(WordEntry entry) => false;
    public void RemoveWord(string entry) { }
    /// <summary>A paste landed in <paramref name="field"/>: watch it for a fix of <paramref name="text"/>.</summary>
    public void Pasted(FieldTarget field, string text, Action<string>? onRevision = null)
    {
        if (settings.LearnCorrections && onRevision is not null) learner.Start(field, text, Learned, onRevision);
    }

    /// <summary>The next dictation starts: judge the last fix now.</summary>
    public void DictationStarting() => learner.Finish();

    /// <summary>Stop watching (microphone test, cancel, learning switched off).</summary>
    public void StopWatching() => learner.Stop();

    /// <summary>Retired callback: model guesses cannot become vocabulary.</summary>
    public void Received(System.Collections.Generic.IEnumerable<SuggestionCandidate> candidates)
    {
        // Model guesses never become persistent vocabulary.
    }

    /// <summary>A word the user selected in History: added to the dictionary by hand.</summary>
    public void AddFromHistory(string word) { }

    /// <summary>A word the user corrected after a dictation: added as a spelling to prefer (never a
    /// replacement rule), unless it is already there; the toast can take it back.</summary>
    private void Learned(string word) { /* Only confirmed whole revisions become preferences. */ }
}
