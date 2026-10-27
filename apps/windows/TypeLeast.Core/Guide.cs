namespace TypeLeast.Core;

/// <summary>The settings people most often cannot find, for the home-page card and the setup guide.
/// Tab is the Settings tab (0 听写, 1 整理, 2 通用, 3 隐私与权限, 4 服务与更新); Page "" is the sidebar itself.</summary>
public static class SettingsGuide
{
    public sealed record Entry(string Title, string Place, string Page, int Tab = 0);

    public static IReadOnlyList<Entry> Entries => new Entry[]
    {
        new(L10n.T("需求助手"), L10n.T("侧栏"), ""),
        new(L10n.T("API Key"), L10n.T("设置 › 整理"), "settings", 1),
        new(L10n.T("快捷键"), L10n.T("设置 › 听写"), "settings", 0),
        new(L10n.T("语音模型和下载镜像"), L10n.T("设置 › 服务与更新"), "settings", 4),
        new(L10n.T("个人偏好"), L10n.T("侧栏 › 个人偏好"), "dictionary"),
        new(L10n.T("麦克风"), L10n.T("设置 › 隐私与权限"), "settings", 3),
    };
}

/// <summary>Speech models come from huggingface.co, which some networks block or slow down.</summary>
public static class ModelMirror
{
    public const string Suggested = "https://hf-mirror.com";

    /// <summary>A download that failed on the network (not a checksum or disk problem).</summary>
    public static bool NetworkFailure(SpeechStatus? speech) =>
        speech?.Operation is { Phase: "error", Error: "download-failed" }
        || speech is { Phase: "error", Error: { } error } && new[] { "could not reach", "was interrupted", " answered HTTP " }.Any(error.Contains);
}
