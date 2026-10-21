namespace TypeLeast.Core;

/// <summary>What the app tells the user, in one place (the same wording as on macOS).</summary>
public static class Messages
{
    public static string BetaNotice(string code) => code switch {
        "empty-transcript" => L10n.T("没有听到有效补充，请再说一次；已有信息保留。"),
        "beta-input-limit" => L10n.T("本次补充超出会话容量，未被接收。请缩短后重说，或先生成已有内容。"),
        "beta-validation" => L10n.T("结果未通过原意或事实检查，未插入。已有信息保留，可继续补充或重试生成。"),
        _ => L10n.T("本轮处理未完成，已有信息保留。请重说本次补充或重试生成。")
    };

    /// <summary>How long the microphone took from the request to its first audio. Speech before that is lost,
    /// so a slow device gets advice; 350 ms is roughly where a quick speaker loses the first syllable.</summary>
    public static string MicrophoneStartup(long ms) => ms <= 350
        ? L10n.T("麦克风启动用时 {0} 毫秒。", ms)
        : L10n.T("麦克风启动用时 {0} 毫秒，较慢：录音条的圆点变红后再开始说话。蓝牙耳机通常更慢，可在设置中换用电脑自带或有线麦克风。", ms);

    /// <summary>What to say about the recogniser, or "" when it is ready.</summary>
    public static string SpeechProblem(SpeechStatus? speech) => (speech?.Phase ?? "") switch
    {
        "ready" => "",
        "missing-model" => L10n.T("语音模型还没下载（约 241 MB，只需一次）"),
        "downloading" => L10n.T("正在下载语音模型") + (speech?.DownloadFraction is { } f ? "：" + (int)(f * 100) + "%" : "…"),
        "loading" => L10n.T("语音模型加载中…"),
        "error" => L10n.T("语音模型出错：") + (speech?.Error ?? L10n.T("未知原因")),
        _ => L10n.T("语音识别还在准备"),
    };

    /// <summary>A failed connection test, explained.</summary>
    public static string ExplainLlmCode(string? code, string? message) => (code ?? "") switch
    {
        "HTTP_401" or "HTTP_403" => L10n.T("Key 无效或没有权限（") + code + "）",
        "HTTP_400" => L10n.T("服务商拒绝了请求：多半是模型 ID 不对（HTTP 400）。点「获取列表」选一个"),
        "HTTP_404" => L10n.T("地址或模型 ID 不对（HTTP 404）"),
        "NETWORK" => L10n.T("连不上服务商：") + (message ?? "") + L10n.T("。请检查网络或代理"),
        "HTTP_500" or "HTTP_502" or "HTTP_503" or "HTTP_504" => L10n.T("服务商那边暂时出错（") + code + L10n.T("），稍后再试"),
        "HTTP_402" => L10n.T("账户余额不足（HTTP 402）"),
        "HTTP_429" => L10n.T("请求太频繁或额度用完（HTTP 429）"),
        "invalid-route" => L10n.T("地址、Key 或模型没填对"),
        "timeout" => L10n.T("超时没有回应"),
        _ => L10n.T("失败：") + (message ?? code ?? L10n.T("未知错误")),
    };

    /// <summary>Why a dictation fell back to the raw text, or null when it did not.</summary>
    public static string? FallbackNote(string? reason) => reason switch
    {
        null or "" or "strength-off" => null,
        "no-api-key" => L10n.T("整理模型未设置，已插入原话（去掉了口水词）"),
        "empty-transcript" => L10n.T("没有听到内容"),
        "model-timeout" => L10n.T("整理超时，已插入原话"),
        "model-max-tokens" => L10n.T("模型输出达到长度上限，已插入原话"),
        "output-format" => L10n.T("模型返回格式无法解析，已插入原话"),
        "model-error:HTTP_401" or "model-error:HTTP_403" => L10n.T("整理请求鉴权失败，已插入原话"),
        "model-error:NETWORK" => L10n.T("整理请求网络失败，已插入原话"),
        "cancelled" => L10n.T("已取消"),
        _ when reason.StartsWith("model-error") => L10n.T("整理模型出错，已插入原话"),
        _ => L10n.T("整理结果没通过检查，已插入原话"),
    };
}
