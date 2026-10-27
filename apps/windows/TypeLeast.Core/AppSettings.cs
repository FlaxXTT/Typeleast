using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Nodes;

namespace TypeLeast.Core;

/// <summary>Which single key starts and stops dictation.</summary>
public enum DictationKey
{
    RightAlt,
    RightCtrl,
    CapsLock,
    F8,
}

/// <summary>
/// The app's own settings, in %APPDATA%\TypeLeast\app-settings.json. The API key is
/// NOT here: it lives in the Windows Credential Manager (see CredentialStore).
/// </summary>
public sealed class AppSettings
{
    public DictationKey Hotkey { get; set; } = DictationKey.RightAlt;
    /// <summary>翻译模式's own key (one tap starts, one tap finishes); null = off.</summary>
    public DictationKey? TranslateHotkey { get; set; }
    /// <summary>Target language code the service knows (en, zh, ja, ko, fr, de, es, pt, it, ru).</summary>
    public string TranslateTarget { get; set; } = "en";
    /// <summary>语言变体: Chinese "hans" / "tw" / "hk", English "us" / "gb".</summary>
    public string ZhVariant { get; set; } = "hans";
    public string EnVariant { get; set; } = "us";
    /// <summary>A code from <see cref="CleanupModes.Codes"/>: "prompt" (自然整理), "concise" (AI 整理), or "promptbeta".</summary>
    public string Strength { get; set; } = "concise";
    public bool AiCleanupDefaultApplied { get; set; }
    public void ApplyAICleanupDefault()
    {
        if (AiCleanupDefaultApplied) return;
        Strength = "concise";
        AiCleanupDefaultApplied = true;
    }
    public string InterfaceLanguage { get; set; } = "system";
    public string Language { get; set; } = "auto";
    public string LlmPresetId { get; set; } = "deepseek";
    /// <summary>Base URL and model are remembered per preset, so switching back keeps them.</summary>
    public Dictionary<string, string> LlmBaseUrls { get; set; } = new();
    public Dictionary<string, string> LlmModels { get; set; } = new();
    public string ModelMirror { get; set; } = "";
    public string NodePath { get; set; } = "";
    public bool LaunchAtLogin { get; set; }
    public bool RestoreClipboard { get; set; } = true;
    /// <summary>更新提醒: a found version is offered with 立即更新 / 稍后. Nothing installs by itself.</summary>
    public bool AutoUpdate { get; set; } = true;
    /// <summary>auto, github or mirror (UpdateSources).</summary>
    public string UpdateSource { get; set; } = "auto";
    public bool OnboardingDone { get; set; }
    public bool PracticeGateRequired { get; set; } = true;
    [System.Text.Json.Serialization.JsonIgnore] public bool NeedsPractice => PracticeGateRequired && !OnboardingDone;
    public string ExplanationMarkers { get; set; } = "";
    public bool ShortMarkersMigrated { get; set; }
    /// <summary>The home page's 「设置在哪」 card was dismissed with 知道了.</summary>
    public bool GuideDismissed { get; set; }
    /// <summary>-1 = the system default microphone.</summary>
    public int MicrophoneDevice { get; set; } = -1;
    public List<string> Words { get; set; } = new();
    public List<WordEntry> DictionaryEntries { get; set; } = new();
    public string HistoryRetention { get; set; } = "forever";
    /// <summary>Keep each recording for five minutes (RetainedAudio.Lifetime) for History's retry; the stored name is older.</summary>
    public bool KeepAudio24h { get; set; }
    public string InsertionMode { get; set; } = "autoPaste";
    public string Appearance { get; set; } = "system";
    public bool ShowInTaskbar { get; set; } = true;
    public bool ShowIdleBar { get; set; }
    public bool UseFieldContext { get; set; }
    /// <summary>On by default (as on the Mac): it compares the field on this computer only.</summary>
    public bool LearnCorrections { get; set; } = true;
    /// <summary>1 once LearnCorrections got its new default; before 1.17.6 it was off for everyone.</summary>
    public int LearningDefaults { get; set; }
    /// <summary>Terms the cleanup model corrected, waiting on the Dictionary page.</summary>
    public List<WordSuggestion> WordSuggestions { get; set; } = new();
    /// <summary>Suggestions the user ignored (lowercase), never offered again.</summary>
    public List<string> DismissedSuggestions { get; set; } = new();
    public bool FormattedLists { get; set; }
    public bool PlaySounds { get; set; } = true;
    public bool MuteOtherAudio { get; set; }
    /// <summary>Ctrl+Shift+V is paste in terminals and paste-as-plain-text in browsers and Office,
    /// so the default no longer takes it.</summary>
    public string PasteLastShortcut { get; set; } = "CtrlShiftAltV";
    /// <summary>1 once a Ctrl+Shift+V paste-last shortcut moved to Ctrl+Shift+Alt+V (1.21.1).</summary>
    public int PasteShortcutDefaults { get; set; }
    public double? WindowLeft { get; set; }
    public double? WindowTop { get; set; }
    public double WindowWidth { get; set; } = 956;
    public double WindowHeight { get; set; } = 679;
    [JsonIgnore] public bool PersistenceBlocked { get; private set; }

    [JsonIgnore] public LlmPreset Preset => LlmPreset.Find(LlmPresetId);

    public static readonly string[] TranslateTargets = { "en", "zh", "ja", "ko", "fr", "de", "es", "pt", "it", "ru" };
    public static readonly string[] ZhVariants = { "hans", "tw", "hk" };
    public static readonly string[] EnVariants = { "us", "gb" };

    /// <summary>Sent with every request ("zh=tw,en=gb"); null while both are the defaults.</summary>
    [JsonIgnore]
    public string? VariantsHeader => ZhVariant == "hans" && EnVariant == "us" ? null : $"zh={ZhVariant},en={EnVariant}";

    [JsonIgnore]
    public string LlmBaseUrl
    {
        get => LlmBaseUrls.TryGetValue(LlmPresetId, out var v) && v.Length > 0 ? v : Preset.BaseUrl;
        set => LlmBaseUrls[LlmPresetId] = value.Trim();
    }

    [JsonIgnore]
    public string LlmModel
    {
        get => LlmModels.TryGetValue(LlmPresetId, out var v) ? v : "";
        set => LlmModels[LlmPresetId] = value.Trim();
    }

    /// <summary>The route to send with a dictation, or null when it is not complete yet
    /// (then the service inserts the tidied transcript, reason no-api-key).</summary>
    public LlmRoute? ActiveRoute(Func<string, string?> readKey)
    {
        var key = readKey(LlmPresetId) ?? "";
        if (LlmModel.Length == 0 || !LlmPreset.IsAllowedBaseUrl(LlmBaseUrl) || (Preset.NeedsKey && key.Length == 0)) return null;
        return new LlmRoute(LlmBaseUrl, LlmModel, key);
    }

    public static AppSettings Load(string path, IHistoryProtection? protection = null)
    {
        try
        {
            // Ignore retired payloads before typed decoding, so even malformed old words
            // cannot reset unrelated settings or require a vocabulary decryption key.
            var documentNode = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
            foreach (var key in documentNode.Select(x => x.Key).Where(x => new[] {"dictionaryEntries","wordSuggestions","dismissedSuggestions","words","protectedVocabulary"}.Contains(x, StringComparer.OrdinalIgnoreCase)).ToArray()) documentNode.Remove(key);
            var loaded = JsonSerializer.Deserialize<AppSettings>(documentNode.ToJsonString(), Json.Options);
            if (loaded is not null)
            {
                using (var document = JsonDocument.Parse(File.ReadAllText(path))) {
                    if (!document.RootElement.EnumerateObject().Any(x => string.Equals(x.Name, "PracticeGateRequired", StringComparison.OrdinalIgnoreCase)))
                        loaded.PracticeGateRequired = false;
                }
                if(!loaded.ShortMarkersMigrated) {
                    if(new[]{"background","explanation","aside"}.Contains(loaded.ExplanationMarkers))loaded.ExplanationMarkers="note";
                    loaded.ShortMarkersMigrated=true;
                }
                using(var document=JsonDocument.Parse(File.ReadAllText(path)))VocabularyStorage.Decode(document.RootElement,loaded,protection);
                loaded.Strength = CleanupModes.Stored(loaded.Strength);
                loaded.ApplyAICleanupDefault();
                loaded.LlmBaseUrls ??= new();
                loaded.LlmModels ??= new();
                loaded.Words ??= new();
                loaded.DictionaryEntries ??= new();
                loaded.WordSuggestions ??= new();
                loaded.DismissedSuggestions ??= new();
                if (loaded.DictionaryEntries.Any(e => e is null || e.Word is null || e.HeardAs is null || WordEntry.Parse(e.Word, e.HeardAs, e.Source) is null)) throw new JsonException("Invalid dictionary entries");
                if (!Enum.IsDefined(loaded.Hotkey)) loaded.Hotkey = DictationKey.RightAlt;
                if (loaded.TranslateHotkey is { } key && !Enum.IsDefined(key)) loaded.TranslateHotkey = null;
                // Settings from before structured entries kept plain strings here; read once, no longer written.
                if (loaded.DictionaryEntries.Count == 0)
                    loaded.DictionaryEntries = loaded.Words.Select(WordEntry.FromLegacy).OfType<WordEntry>().ToList();
                loaded.Words = new();
                if (!new[] { "forever", "year", "month", "week", "day", "never" }.Contains(loaded.HistoryRetention)) loaded.HistoryRetention = "forever";
                if (!new[] { "autoPaste", "clipboardOnly", "preview" }.Contains(loaded.InsertionMode)) loaded.InsertionMode = "autoPaste";
                if (!new[] { "system", "light", "dark" }.Contains(loaded.Appearance)) loaded.Appearance = "system";
                if (!UpdateSources.Modes.Contains(loaded.UpdateSource)) loaded.UpdateSource = "auto";
                loaded.InterfaceLanguage = L10n.Normalize(loaded.InterfaceLanguage);
                if (!new[] { "note", "background", "explanation", "aside" }.Contains(loaded.ExplanationMarkers)) loaded.ExplanationMarkers = "";
                if (!new[] { "auto", "zh", "en", "yue", "ja", "ko" }.Contains(loaded.Language)) loaded.Language = "auto";
                if (!TranslateTargets.Contains(loaded.TranslateTarget)) loaded.TranslateTarget = "en";
                if (!ZhVariants.Contains(loaded.ZhVariant)) loaded.ZhVariant = "hans";
                if (!EnVariants.Contains(loaded.EnVariant)) loaded.EnVariant = "us";
                // The two keys must differ; the dictation key wins.
                if (loaded.TranslateHotkey == loaded.Hotkey) loaded.TranslateHotkey = null;
                // Learning used to be off by default and was easy to miss: switch it on once.
                if (loaded.LearningDefaults < 1) { loaded.LearnCorrections = true; loaded.LearningDefaults = 1; }
                // The old default took Ctrl+Shift+V from every app: move it once.
                if (loaded.PasteShortcutDefaults < 1)
                {
                    if (loaded.PasteLastShortcut == "CtrlShiftV") loaded.PasteLastShortcut = "CtrlShiftAltV";
                    loaded.PasteShortcutDefaults = 1;
                }
                return loaded;
            }
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { var fresh = new AppSettings(); fresh.ApplyAICleanupDefault(); return fresh; }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or PlatformNotSupportedException)
        {
            return new AppSettings { PersistenceBlocked = true };
        }
        return new AppSettings { PersistenceBlocked = true };
    }

    /// <summary>Atomic write: a crash never leaves a half-written file.</summary>
    public void Save(string path, IHistoryProtection? protection = null)
    {
        if (PersistenceBlocked) throw new IOException("Existing settings could not be read; retained without replacement");
        // Settings written by this version already contain the user's current choice.
        // Only a file from an older version should trigger the one-time default move.
        AiCleanupDefaultApplied = true;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, VocabularyStorage.Encode(this, protection));
        File.Move(temp, path, overwrite: true);
    }
}
