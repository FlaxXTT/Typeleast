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
    /// <summary>"prompt" (Article cleanup), "promptify" (提示词模式) or "off" (raw transcription).</summary>
    public string Strength { get; set; } = "prompt";
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
    public bool OnboardingDone { get; set; }
    /// <summary>-1 = the system default microphone.</summary>
    public int MicrophoneDevice { get; set; } = -1;
    public List<string> Words { get; set; } = new();

    [JsonIgnore] public LlmPreset Preset => LlmPreset.Find(LlmPresetId);

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

    public static AppSettings Load(string path)
    {
        try
        {
            var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Json.Options);
            if (loaded is not null)
            {
                if (loaded.Strength is not ("prompt" or "promptify" or "off")) loaded.Strength = "prompt";
                loaded.LlmBaseUrls ??= new();
                loaded.LlmModels ??= new();
                loaded.Words ??= new();
                loaded.InterfaceLanguage = L10n.Normalize(loaded.InterfaceLanguage);
                if (!new[] { "auto", "zh", "en", "yue", "ja", "ko" }.Contains(loaded.Language)) loaded.Language = "auto";
                return loaded;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
        }
        return new AppSettings();
    }

    /// <summary>Atomic write: a crash never leaves a half-written file.</summary>
    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, Json.Options));
        File.Move(temp, path, overwrite: true);
    }
}
