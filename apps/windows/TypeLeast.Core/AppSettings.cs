using System.Text.Json;
using System.Text.Json.Serialization;

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
    public DictationKey? AssistantHotkey { get; set; }
    /// <summary>Target language code the service knows (en, zh, ja, ko, fr, de, es, pt, it, ru).</summary>
    public string TranslateTarget { get; set; } = "en";
    /// <summary>中文字形: "hans" / "tw" / "hk".</summary>
    public string ZhVariant { get; set; } = "hans";
    /// <summary>A code from <see cref="CleanupModes.Codes"/>: "prompt" (自然整理), "concise" (AI 整理), or "promptbeta".</summary>
    public string Strength { get; set; } = "prompt";
    public bool UnifiedDictationApplied { get; set; }
    public void ApplyUnifiedDictation() { if (UnifiedDictationApplied) return; Strength = "prompt"; UnifiedDictationApplied = true; }
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
    /// <summary>更新提醒: a found version is offered with 立即更新 / 稍后. Nothing installs by itself.</summary>
    public bool AutoUpdate { get; set; } = true;
    /// <summary>auto, github or mirror (UpdateSources).</summary>
    public string UpdateSource { get; set; } = "auto";
    public bool OnboardingDone { get; set; }
    public bool PracticeGateRequired { get; set; } = true;
    [System.Text.Json.Serialization.JsonIgnore] public bool NeedsPractice => PracticeGateRequired && !OnboardingDone;
    /// <summary>The home page's 「设置在哪」 card was dismissed with 知道了.</summary>
    public bool GuideDismissed { get; set; }
    /// <summary>-1 = the system default microphone.</summary>
    public int MicrophoneDevice { get; set; } = -1;
    /// <summary>The dictionary of earlier versions, sealed; no longer used, kept so nothing is lost.</summary>
    public string? ProtectedVocabulary { get; set; }
    public string HistoryRetention { get; set; } = "forever";
    /// <summary>Keep each recording for five minutes (RetainedAudio.Lifetime) for History's retry; the stored name is older.</summary>
    public bool KeepAudio24h { get; set; }
    public string Appearance { get; set; } = "system";
    public bool ShowInTaskbar { get; set; } = true;
    public bool ShowIdleBar { get; set; }
    public bool UseFieldContext { get; set; }
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

    /// <summary>Sent with every request ("zh=tw"); null for simplified Chinese.</summary>
    [JsonIgnore]
    public string? VariantsHeader => ZhVariant == "hans" ? null : $"zh={ZhVariant}";

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
            var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Json.Options);
            if (loaded is not null)
            {
                using (var document = JsonDocument.Parse(File.ReadAllText(path))) {
                    if (!document.RootElement.EnumerateObject().Any(x => string.Equals(x.Name, "PracticeGateRequired", StringComparison.OrdinalIgnoreCase)))
                        loaded.PracticeGateRequired = false;
                }
                loaded.Strength = CleanupModes.Stored(loaded.Strength);
                loaded.ApplyUnifiedDictation();
                loaded.LlmBaseUrls ??= new();
                loaded.LlmModels ??= new();
                if (!Enum.IsDefined(loaded.Hotkey)) loaded.Hotkey = DictationKey.RightAlt;
                if (loaded.TranslateHotkey is { } key && !Enum.IsDefined(key)) loaded.TranslateHotkey = null;
                if (loaded.AssistantHotkey is { } assistant && !Enum.IsDefined(assistant)) loaded.AssistantHotkey = null;
                if (!new[] { "forever", "year", "month", "week", "day", "never" }.Contains(loaded.HistoryRetention)) loaded.HistoryRetention = "forever";
                if (!new[] { "system", "light", "dark" }.Contains(loaded.Appearance)) loaded.Appearance = "system";
                if (!UpdateSources.Modes.Contains(loaded.UpdateSource)) loaded.UpdateSource = "auto";
                loaded.InterfaceLanguage = L10n.Normalize(loaded.InterfaceLanguage);
                if (!new[] { "auto", "zh", "en", "yue", "ja", "ko" }.Contains(loaded.Language)) loaded.Language = "auto";
                if (!TranslateTargets.Contains(loaded.TranslateTarget)) loaded.TranslateTarget = "en";
                if (!ZhVariants.Contains(loaded.ZhVariant)) loaded.ZhVariant = "hans";
                // The two keys must differ; the dictation key wins.
                if (loaded.TranslateHotkey == loaded.Hotkey) loaded.TranslateHotkey = null;
                if (loaded.AssistantHotkey == loaded.Hotkey || loaded.AssistantHotkey == loaded.TranslateHotkey) loaded.AssistantHotkey = null;
                // The old default took Ctrl+Shift+V from every app: move it once.
                if (loaded.PasteShortcutDefaults < 1)
                {
                    if (loaded.PasteLastShortcut == "CtrlShiftV") loaded.PasteLastShortcut = "CtrlShiftAltV";
                    loaded.PasteShortcutDefaults = 1;
                }
                return loaded;
            }
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { var fresh = new AppSettings(); fresh.ApplyUnifiedDictation(); return fresh; }
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
        ApplyUnifiedDictation();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, Json.Options));
        File.Move(temp, path, overwrite: true);
    }
}
