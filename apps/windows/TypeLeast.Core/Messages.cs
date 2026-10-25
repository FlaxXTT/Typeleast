namespace TypeLeast.Core;

/// <summary>What the app tells the user, in one place (the same wording as on macOS).</summary>
public static class Messages
{
    public static string BetaNotice(string code) => code switch {
        "empty-transcript" => L10n.T("没听清，请再说一次。之前的回答保留。"),
        "beta-input-limit" => L10n.T("太长了。说短一些，或现在生成。"),
        "beta-validation" => L10n.T("结果没通过检查，未插入。可继续补充或重新生成。"),
        _ => L10n.T("这一轮没完成，之前的回答保留。请重说或生成。")
    };

    /// <summary>How long the microphone took from the request to its first audio. Speech before that is lost,
    /// so a slow device gets advice; 350 ms is roughly where a quick speaker loses the first syllable.</summary>
    public static string MicrophoneStartup(long ms) => ms <= 350
        ? L10n.T("麦克风启动用时 {0} 毫秒。", ms)
        : L10n.T("麦克风启动较慢（{0} 毫秒）。圆点变红后再说话，或换有线、内置麦克风。", ms);

    /// <summary>What to say about the recogniser, or "" when it is ready.</summary>
    public static string SpeechProblem(SpeechStatus? speech) => (speech?.Phase ?? "") switch
    {
        "ready" => "",
        "missing-model" => L10n.T("请选择并安装语音模型。"),
        "downloading" => L10n.T("正在下载语音模型") + (speech?.DownloadFraction is { } f ? "：" + (int)(f * 100) + "%" : "…"),
        "loading" => L10n.T("正在加载语音模型…"),
        "error" => L10n.T("语音模型出错：") + (speech?.Error ?? L10n.T("原因未知")),
        _ => L10n.T("语音识别未就绪"),
    };

    /// <summary>A failed connection test, explained.</summary>
    public static string ExplainLlmCode(string? code, string? message) => (code ?? "") switch
    {
        "HTTP_401" or "HTTP_403" => L10n.T("Key 无效或没有权限（") + code + "）",
        "HTTP_400" => L10n.T("模型 ID 可能有误（HTTP 400），请点「获取列表」选择"),
        "HTTP_404" => L10n.T("地址或模型 ID 错误（HTTP 404）"),
        "NETWORK" => L10n.T("连不上服务商：") + (message ?? "") + L10n.T("。请检查网络或代理"),
        "HTTP_500" or "HTTP_502" or "HTTP_503" or "HTTP_504" => L10n.T("服务商出错（") + code + L10n.T("），请稍后重试"),
        "HTTP_402" => L10n.T("余额不足（HTTP 402）"),
        "HTTP_429" => L10n.T("请求太多或额度用完（HTTP 429）"),
        "invalid-route" => L10n.T("请检查地址、Key 和模型"),
        "timeout" => L10n.T("超时无响应"),
        _ => L10n.T("失败：") + (message ?? code ?? L10n.T("未知错误")),
    };

    /// <summary>Why a dictation fell back to the raw text, or null when it did not.</summary>
    public static string? FallbackNote(string? reason) => reason switch
    {
        null or "" or "strength-off" => null,
        "no-api-key" => L10n.T("没有整理模型，已插入原话（去口头禅）"),
        "empty-transcript" => L10n.T("没有听到内容"),
        "model-timeout" => L10n.T("整理超时，已插入原话"),
        "model-max-tokens" => L10n.T("模型输出过长，已插入原话"),
        "output-format" => L10n.T("无法解析模型回复，已插入原话"),
        "model-error:HTTP_401" or "model-error:HTTP_403" => L10n.T("Key 被拒绝，已插入原话"),
        "model-error:NETWORK" => L10n.T("网络出错，已插入原话"),
        "cancelled" => L10n.T("已取消"),
        _ when reason.StartsWith("model-error") => L10n.T("整理模型出错，已插入原话"),
        _ => L10n.T("结果没通过检查，已插入原话"),
    };
}
