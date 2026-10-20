using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using TypeLeast.Core;

// Program.cs (Core.Tests) - unit proofs for the Windows app's logic and its client of
// the local service. A plain console runner: no test framework to download.

var passed = 0;
var failed = 0;
L10n.Configure("zh-Hans");

void Check(string name, bool ok, string detail = "")
{
    if (ok) { passed++; Console.WriteLine("PASS " + name); }
    else { failed++; Console.WriteLine("FAIL " + name + (detail.Length > 0 ? " :: " + detail : "")); }
}

void Eq<T>(string name, T got, T want) => Check(name, EqualityComparer<T>.Default.Equals(got, want), $"got={got} want={want}");

// ---- 1. WAV: the one shape the service accepts

{
    var pcm = new byte[16000 * 2];
    var wav = Wav.FromPcm16(pcm);
    Eq("wav header is 44 bytes", wav.Length, 44 + pcm.Length);
    Check("wav is canonical", Wav.IsCanonical(wav));
    Eq("one second of samples", Wav.Seconds(pcm.Length), 1.0);
    Check("an odd trailing byte is dropped", Wav.IsCanonical(Wav.FromPcm16(new byte[11])));
    Check("garbage is not canonical", !Wav.IsCanonical(Encoding.ASCII.GetBytes("not a wav file at all, no no no no no no no")));
    Eq("silence has no level", Wav.Level(pcm), 0.0);
    var loud = new byte[200];
    for (var i = 0; i < 100; i++) BitConverter.TryWriteBytes(loud.AsSpan(i * 2, 2), (short)20000);
    Check("a loud signal has a high level", Wav.Level(loud) > 0.9);
}

// ---- 2. the single-key tap (Right Alt by default)

{
    var t0 = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    var tap = new TapDetector(TapDetector.VirtualKey(DictationKey.RightAlt));
    Eq("right alt is VK_RMENU", tap.TargetVk, 0xA5);
    Check("down alone is not a tap", !tap.OnKey(0xA5, true, false, t0));
    Check("a quick down-up is a tap", tap.OnKey(0xA5, false, false, t0.AddMilliseconds(120)));
    tap.OnKey(0xA5, true, false, t0);
    Check("auto-repeat while held is ignored", !tap.OnKey(0xA5, true, false, t0.AddMilliseconds(40)));
    Check("still a tap after auto-repeat", tap.OnKey(0xA5, false, false, t0.AddMilliseconds(200)));
    tap.OnKey(0xA5, true, false, t0);
    tap.OnKey(0x45, true, false, t0.AddMilliseconds(50)); // AltGr+E
    Check("another key while held is a combination, not a tap", !tap.OnKey(0xA5, false, false, t0.AddMilliseconds(120)));
    tap.OnKey(0xA5, true, false, t0);
    Check("holding too long is not a tap", !tap.OnKey(0xA5, false, false, t0.AddMilliseconds(900)));
    tap.OnKey(0xA5, true, false, t0);
    tap.OnKey(0xE8, true, true, t0.AddMilliseconds(5)); // our own menu-mask key
    Check("keys the app injected itself do not spoil the tap", tap.OnKey(0xA5, false, false, t0.AddMilliseconds(100)));
    Check("an up without a down is not a tap", !tap.OnKey(0xA5, false, false, t0));
    Eq("labels are Chinese", TapDetector.Label(DictationKey.RightCtrl), "右 Ctrl");
}

// ---- 3. Node.js, the service folder, the ready line

{
    Check("v24.21.0 parses", ServiceLocator.ParseNodeVersion("v24.21.0\r\n") == (24, 21, 0));
    Check("garbage is no version", ServiceLocator.ParseNodeVersion("'node' is not recognized") is null);
    Check("Node 22 is supported", ServiceLocator.IsSupported("v22.0.0"));
    Check("Node 20 is too old", !ServiceLocator.IsSupported("v20.18.1"));
    Eq("the ready line gives the port", ServiceLocator.ParseReadyLine("{\"event\":\"ready\",\"port\":51234,\"pid\":4321}"), (int?)51234);
    Eq("a log line is not a ready line", ServiceLocator.ParseReadyLine("[typeleast] listening"), (int?)null);
    Eq("restarts back off", ServiceLocator.RestartDelay(4), (double?)30);
    Eq("then give up", ServiceLocator.RestartDelay(5), (double?)null);

    var appDir = Path.Combine("fixtures", "Apps", "TypeLeast");
    var nvmDir = Path.Combine("fixtures", "Users", "someone", "nvm");
    var env = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
    {
        ["ProgramFiles"] = Path.Combine("fixtures", "ProgramFiles"),
        ["LOCALAPPDATA"] = Path.Combine("fixtures", "Local"),
        ["NVM_HOME"] = nvmDir,
        ["PATH"] = "\"" + Path.Combine("fixtures", "Tools", "node") + "\"" + ";",
    };
    var nvm = new Dictionary<string, string[]> { [nvmDir] = new[] { "v20.1.0", "v24.2.0", "v22.9.0", "settings.txt" } };
    var list = ServiceLocator.NodeCandidates(appDir, env, dir => nvm.TryGetValue(dir, out var v) ? v : Array.Empty<string>());
    Eq("the Node.js shipped with the app comes first", list[0], Path.Combine(appDir, "node", "node.exe"));
    Check("the official installer location is tried", list.Contains(Path.Combine(env["ProgramFiles"]!, "nodejs", "node.exe")));
    var nvmFirst = list.FindIndex(p => p.StartsWith(nvmDir + Path.DirectorySeparatorChar));
    Eq("nvm versions are tried newest first", list[nvmFirst], Path.Combine(nvmDir, "v24.2.0", "node.exe"));
    Check("quoted PATH entries are unquoted", list.Contains(Path.Combine("fixtures", "Tools", "node", "node.exe")));
    Eq("no duplicates", list.Count, list.Distinct(StringComparer.OrdinalIgnoreCase).Count());

    bool Exists(string p) => p == Path.Combine(appDir, "service", "bin", "typeleast-service.mjs") || p == Path.Combine(@"D:\dev\service", "bin", "typeleast-service.mjs");
    Eq("the service beside the app is used", ServiceLocator.ServiceDirectory(appDir, new Dictionary<string, string?>(), Exists), Path.Combine(appDir, "service"));
    Eq("an environment variable cannot replace the bundled service",
        ServiceLocator.ServiceDirectory(appDir, new Dictionary<string, string?> { ["TYPELEAST_SERVICE_DIR"] = @"D:\dev\service" }, Exists), Path.Combine(appDir, "service"));
    Eq("TYPELEAST_SERVICE_DIR is used when nothing is bundled (development)",
        ServiceLocator.ServiceDirectory(@"C:\Elsewhere", new Dictionary<string, string?> { ["TYPELEAST_SERVICE_DIR"] = @"D:\dev\service" }, Exists), @"D:\dev\service");
    Eq("the service environment drops code-loading variables",
        string.Join(",", ServiceLocator.UnsafeServiceVariables(new[] { "PATH", "NODE_OPTIONS", "node_path", "NODE_TLS_REJECT_UNAUTHORIZED", "NODE_EXTRA_CA_CERTS", "HTTPS_PROXY" })),
        "NODE_OPTIONS,node_path,NODE_TLS_REJECT_UNAUTHORIZED");
    Eq("no service folder is null", ServiceLocator.ServiceDirectory(@"C:\Elsewhere", new Dictionary<string, string?>(), Exists), null);
}

// ---- 4. settings, presets, the route

{
    Check("https may carry a key", LlmPreset.IsAllowedBaseUrl("https://api.deepseek.com/v1"));
    Check("http to another host may not", !LlmPreset.IsAllowedBaseUrl("http://api.example.com/v1"));
    Check("http to this computer may (Ollama)", LlmPreset.IsAllowedBaseUrl("http://127.0.0.1:11434/v1"));
    Check("every preset except custom has a usable URL", LlmPreset.All.Where(p => p.Id != "custom").All(p => LlmPreset.IsAllowedBaseUrl(p.BaseUrl)));
    Eq("an unknown preset falls back to the first", LlmPreset.Find("gone").Id, "deepseek");

    var s = new AppSettings();
    Eq("default key is right alt", s.Hotkey, DictationKey.RightAlt);
    Eq("no model means no route", s.ActiveRoute(_ => "sk-test"), null);
    s.LlmModel = "deepseek-chat";
    Eq("no key means no route", s.ActiveRoute(_ => null), null);
    var route = s.ActiveRoute(_ => "sk-test");
    Eq("a complete route uses the preset's URL", route?.BaseUrl, "https://api.deepseek.com/v1");
    s.LlmPresetId = "ollama";
    s.LlmModel = "qwen2.5:7b";
    Eq("a local server needs no key", s.ActiveRoute(_ => null)?.Model, "qwen2.5:7b");
    s.LlmBaseUrl = "http://example.com/v1";
    Eq("an unsafe URL disables the route", s.ActiveRoute(_ => null), null);
    s.LlmPresetId = "deepseek";
    Eq("each preset keeps its own model", s.LlmModel, "deepseek-chat");

    var dir = Path.Combine(Path.GetTempPath(), "typeleast-tests-" + Guid.NewGuid().ToString("N"));
    var file = Path.Combine(dir, "app-settings.json");
    s.Hotkey = DictationKey.F8;
    s.Words.Add("TypeLeast");
    s.Save(file);
    var back = AppSettings.Load(file);
    Eq("settings round-trip", back.Hotkey, DictationKey.F8);
    Eq("words round-trip", back.Words.FirstOrDefault(), "TypeLeast");
    Check("the key is never written to the settings file", !File.ReadAllText(file).Contains("sk-test"));
    File.WriteAllText(file, "{ broken");
    Eq("a broken file gives defaults", AppSettings.Load(file).Hotkey, DictationKey.RightAlt);
    File.WriteAllText(file, "{\"Strength\":\"maximal\"}");
    Eq("an old strength reads as Article", AppSettings.Load(file).Strength, "prompt");
    File.WriteAllText(file, "{\"Strength\":\"promptify\"}");
    Eq("prompt mode is remembered", AppSettings.Load(file).Strength, "promptify");

    var history = new LocalHistory(Path.Combine(dir, "app-history.json"), TestHistoryProtection.Shared);
    history.Add(new HistoryEntry { Text = "第一条", Seconds = 2 });
    history.Add(new HistoryEntry { Text = "第二条", Seconds = 3 });
    Eq("history is newest first", new LocalHistory(Path.Combine(dir, "app-history.json"), TestHistoryProtection.Shared).Last?.Text, "第二条");
    Eq("stats count characters", history.Stats().Characters, 6);
    Directory.Delete(dir, true);
}

// ---- 5. messages

{
    Eq("ready speech has no problem", Messages.SpeechProblem(new SpeechStatus { Phase = "ready", Ready = true }), "");
    Check("missing models are explained", Messages.SpeechProblem(new SpeechStatus { Phase = "missing-model" }).Contains("241 MB"));
    var downloading = JsonSerializer.Deserialize<HealthResponse>(
        "{\"ok\":false,\"service\":\"typeleast\",\"speech\":{\"phase\":\"downloading\",\"download\":{\"received\":60000000,\"total\":240000000}}}", Json.Options)!;
    Eq("health names the service", downloading.Service, "typeleast");
    Check("download progress decodes", Math.Abs((downloading.Speech!.DownloadFraction ?? 0) - 0.25) < 1e-9);
    Check("progress shows in the message", Messages.SpeechProblem(downloading.Speech).Contains("25%"));
    Check("401 is explained as a bad key", Messages.ExplainLlmCode("HTTP_401", null).Contains("Key"));
    Eq("no fallback note on success", Messages.FallbackNote(null), null);
    Check("missing key is explained", Messages.FallbackNote("no-api-key")!.Contains("原话"));
    Eq("model ids come sorted", string.Join(",", LlmRoute.ModelIds("{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"},{\"x\":1}]}")), "a,b");
    Eq("bad /models body gives none", LlmRoute.ModelIds("nope").Count, 0);
}

// ---- 6. the client against a stub service

{
    var stub = new StubServer();
    var dir = Path.Combine(Path.GetTempPath(), "typeleast-client-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(dir);
    File.WriteAllText(Path.Combine(dir, "api-token"), "tok123\n");
    File.WriteAllText(Path.Combine(dir, "runtime.json"), "{\"port\":" + stub.Port + "}");
    var client = new ServiceClient(dir);
    Eq("the published port is read", client.PublishedPort(), (int?)stub.Port);
    Check("discovery points the client at it", client.DiscoverBaseUri() && client.BaseUri.Port == stub.Port);

    stub.Reply = (200, "{\"ok\":true,\"service\":\"typeleast\",\"version\":\"0.2.0\",\"speech\":{\"phase\":\"ready\",\"ready\":true}}");
    var health = await client.HealthAsync();
    Check("health decodes", health.Ok && health.Speech?.Ready == true);
    Eq("health path", stub.LastPath, "/api/voice-polish/health");
    Eq("bearer token sent", stub.LastHeaders.GetValueOrDefault("authorization"), "Bearer tok123");
    Eq("host header is loopback", stub.LastHeaders.GetValueOrDefault("host"), "127.0.0.1:" + stub.Port);

    stub.Reply = (200, "{\"requestId\":\"r\",\"text\":\"好的。\",\"raw\":\"好的\",\"fallback\":false,\"ms\":{\"total\":12}}");
    var route = new LlmRoute("https://api.example.com/v1", "m", "sk-secret");
    var result = await client.DictateAsync(Wav.FromPcm16(new byte[3200]), "auto", "notepad.exe", "prompt", route);
    Eq("dictate decodes", result.InsertableText, "好的。");
    Eq("dictate path", stub.LastPath, "/api/voice-polish/dictate");
    Eq("content type is wav", stub.LastHeaders.GetValueOrDefault("content-type"), "audio/wav");
    Eq("app hint header", stub.LastHeaders.GetValueOrDefault("x-voice-app"), "notepad.exe");
    var sent = stub.LastHeaders.GetValueOrDefault("x-voice-llm") ?? "";
    var decoded = JsonSerializer.Deserialize<JsonElement>(Convert.FromBase64String(sent));
    Eq("the route travels as base64 JSON", decoded.GetProperty("baseURL").GetString(), "https://api.example.com/v1");
    Check("the body is the WAV itself", Wav.IsCanonical(stub.LastBody));
    await client.DictateAsync(Wav.FromPcm16(new byte[3200]), "auto", "notepad.exe", "prompt", route,
        translateTo: "en", variants: "zh=tw,en=gb");
    Eq("the target language is sent", stub.LastHeaders.GetValueOrDefault("x-voice-translate"), "en");
    Eq("the variants are sent", stub.LastHeaders.GetValueOrDefault("x-voice-variants"), "zh=tw,en=gb");
    await client.DictateAsync(Wav.FromPcm16(new byte[3200]), "auto", "notepad.exe", "prompt", route);
    Eq("ordinary dictation sends no target", stub.LastHeaders.GetValueOrDefault("x-voice-translate"), null);

    stub.Reply = (503, "{\"error\":\"speech model is not ready\",\"code\":\"speech-not-ready\"}");
    try
    {
        await client.DictateAsync(Wav.FromPcm16(new byte[3200]), "auto", "x", "prompt", null);
        Check("503 throws", false);
    }
    catch (ServiceException e)
    {
        Eq("503 carries its code", e.Code, "speech-not-ready");
        Check("503 means unavailable", e.ServiceUnavailable);
    }

    stub.Reply = (202, "{\"ok\":true,\"phase\":\"downloading\"}");
    Check("model download starts", await client.DownloadModelsAsync("https://mirror.example.com"));
    Check("the mirror is sent", Encoding.UTF8.GetString(stub.LastBody).Contains("mirror.example.com"));

    stub.Reply = (200, """{"activeModelId":"sensevoice-small","models":[{"id":"fun-asr-nano","name":"Fun-ASR-Nano","modelBytes":1009605061,"sourceUrl":"https://huggingface.co/example/model","licenseUrl":"https://huggingface.co/example/source","canSetLanguage":true,"installed":true}],"operation":{"modelId":"fun-asr-nano","phase":"waiting","received":100,"total":100,"error":null}}""");
    var catalog = await client.GetSpeechModelsAsync();
    Eq("catalog request path", stub.LastPath, "/api/voice-polish/models");
    Eq("catalog selected default", catalog.ActiveModelId, "sensevoice-small");
    Check("catalog installed state", catalog.Models[0].Installed);
    Check("catalog waiting blocks repeated actions", catalog.Operation?.Running == true);
    stub.Reply = (202, "{\"ok\":true,\"phase\":\"accepted\"}");
    await client.SpeechModelActionAsync("fun-asr-nano", download: true, endpoint: "https://mirror.example.com");
    Eq("candidate download method", stub.LastMethod, "POST");
    var modelBody = JsonSerializer.Deserialize<JsonElement>(stub.LastBody);
    Eq("candidate download identifies model", modelBody.GetProperty("modelId").GetString(), "fun-asr-nano");
    Check("candidate download requests activation", modelBody.GetProperty("activate").GetBoolean());
    Eq("candidate download retains mirror", modelBody.GetProperty("endpoint").GetString(), "https://mirror.example.com");
    await client.SpeechModelActionAsync("qwen3-asr-0.6b");
    Eq("installed model activation method", stub.LastMethod, "PUT");
    Eq("installed model activation path", stub.LastPath, "/api/voice-polish/models/active");
    await client.SpeechModelActionAsync("fun-asr-nano", cancel: true);
    Eq("candidate cancel method", stub.LastMethod, "POST");
    Eq("candidate cancel path", stub.LastPath, "/api/voice-polish/models/download/cancel");
    var modelStatus = JsonSerializer.Deserialize<SpeechStatus>("""{"modelId":"fun-asr-nano","modelName":"Fun-ASR-Nano","ready":true,"canSetLanguage":true,"languages":["auto","zh","en","ja"]}""", Json.Options)!;
    Eq("health identifies actual recognizer", modelStatus.ModelName, "Fun-ASR-Nano");
    Eq("health language capabilities", string.Join(",", modelStatus.Languages!), "auto,zh,en,ja");
    Eq("natural cleanup English label", L10n.Render("自然整理", "en"), "Natural cleanup");

    stub.Stop();
    var dead = new ServiceClient(dir);
    dead.UsePort(1);
    File.WriteAllText(Path.Combine(dir, "runtime.json"), "{\"port\":1}");
    try
    {
        await dead.HealthAsync();
        Check("a closed port throws", false);
    }
    catch (ServiceException e)
    {
        Check("a closed port is a transport error", e.Kind == ServiceErrorKind.Transport && e.ServiceUnavailable);
    }

    File.Delete(Path.Combine(dir, "api-token"));
    try
    {
        await new ServiceClient(dir).HealthAsync();
        Check("no token throws", false);
    }
    catch (ServiceException e)
    {
        Eq("no token is reported as such", e.Kind, ServiceErrorKind.NoToken);
    }
    Directory.Delete(dir, true);

    Eq("an oversized context header is dropped", ServiceClient.EncodeContextHeader(new byte[ServiceClient.MaxContextHeaderBytes]), null);
    Eq("no route means no header", ServiceClient.EncodeRouteHeader(null), null);
}

// ---- 7. prompt mode settings

{
    var code = PromptifyGuard.MakeCode();
    Check("the unlock code has six digits", code.Length == 6 && code.All(char.IsDigit));
    Check("the right code unlocks", PromptifyGuard.Matches(" " + code + "\r\n", code));
    Check("a wrong code does not", !PromptifyGuard.Matches(code == "000000" ? "111111" : "000000", code));
    var s = JsonSerializer.Deserialize<PromptifySettings>("{\"default\":\"默认\",\"appendix\":\"追加\",\"override\":null,\"modified\":false,\"effective\":\"x\"}", Json.Options)!;
    Eq("prompt settings decode", s.Appendix, "追加");
    Eq("no override means the default is in use", s.Override, null);
}

Console.WriteLine();
{
    Eq("invalid UI preference follows system", L10n.Normalize("bad"), "system");
    Eq("Chinese system uses Simplified Chinese", L10n.Resolve("system", "zh-TW"), "zh-Hans");
    Eq("other systems use English", L10n.Resolve(null, "ja-JP"), "en");
    Eq("manual English overrides system", L10n.Resolve("en", "zh-CN"), "en");
    Eq("manual Chinese overrides system", L10n.Resolve("zh-Hans", "en-US"), "zh-Hans");
    Eq("translated label", L10n.Render("设置", "en"), "Settings");
    Eq("content slots remain verbatim", L10n.Render("已听写 {0} 次 · 共 {1} 字 · 说了 {2} 分钟", "en", "用户 {1}", 2, 3), "用户 {1} dictations · 2 characters · 3 minutes of speech");
    Check("URL credentials rejected", !LlmPreset.IsAllowedBaseUrl("https://someone:fake@api.example.com/v1"));
    Check("URL query credentials rejected", !LlmPreset.IsAllowedBaseUrl("https://api.example.com/v1?key=fake"));
    Check("no paste after focus change", !PasteTarget.Matches(new IntPtr(1), new IntPtr(2)));
    Check("same window may receive paste", PasteTarget.Matches(new IntPtr(1), new IntPtr(1)));
    var path = Path.Combine(Path.GetTempPath(), "typeleast-ui-" + Guid.NewGuid() + ".json");
    try {
        new AppSettings { InterfaceLanguage = "en", Language = "ja" }.Save(path);
        var saved = AppSettings.Load(path);
        Eq("UI language persists", saved.InterfaceLanguage, "en");
        Eq("dictation language is independent", saved.Language, "ja");
        Eq("saving does not switch running UI", L10n.Language, "zh-Hans");
    } finally { if (File.Exists(path)) File.Delete(path); }
}

// Prompt Beta: questions come back with a session; settings keep the new strength.
{
    var asked = System.Text.Json.JsonSerializer.Deserialize<DictateResponse>(
        "{\"text\":\"\",\"raw\":\"r\",\"fallback\":false,\"beta\":{\"sessionId\":\"s-1\",\"questions\":[\"给谁看？\"]}}")!;
    Eq("beta questions are read", string.Join("|", asked.BetaQuestions), "给谁看？");
    Eq("beta session is read", asked.Beta?.SessionId, "s-1");
    var done = System.Text.Json.JsonSerializer.Deserialize<DictateResponse>(
        "{\"text\":\"## 目标\",\"raw\":\"r\",\"fallback\":false,\"beta\":{\"issues\":1,\"patched\":true}}")!;
    Eq("a finished prompt has no questions", done.BetaQuestions.Count, 0);
    var plain = System.Text.Json.JsonSerializer.Deserialize<DictateResponse>("{\"text\":\"x\",\"raw\":\"x\",\"fallback\":false}")!;
    Eq("older services without beta still decode", plain.BetaQuestions.Count, 0);
    var path = Path.Combine(Path.GetTempPath(), "typeleast-beta-" + Guid.NewGuid() + ".json");
    try {
        new AppSettings { Strength = "promptbeta" }.Save(path);
        Eq("Prompt Beta strength survives a reload", AppSettings.Load(path).Strength, "promptbeta");
    } finally { if (File.Exists(path)) File.Delete(path); }
}

// 翻译 and 语言变体: decoding and settings.
{
    var translated = System.Text.Json.JsonSerializer.Deserialize<DictateResponse>(
        "{\"text\":\"Hello\",\"raw\":\"你好\",\"fallback\":false,\"translated\":\"en\"}")!;
    Eq("the translated language is read", translated.Translated, "en");
    Eq("default variants send nothing", new AppSettings().VariantsHeader, null);
    Eq("chosen variants make the header", new AppSettings { ZhVariant = "tw", EnVariant = "gb" }.VariantsHeader, "zh=tw,en=gb");
    var path = Path.Combine(Path.GetTempPath(), "typeleast-translate-" + Guid.NewGuid() + ".json");
    try
    {
        new AppSettings { TranslateHotkey = DictationKey.F8, TranslateTarget = "ja", ZhVariant = "hk", EnVariant = "gb" }.Save(path);
        var loaded = AppSettings.Load(path);
        Eq("the translate key survives a reload", loaded.TranslateHotkey, (DictationKey?)DictationKey.F8);
        Eq("the target survives a reload", loaded.TranslateTarget, "ja");
        Eq("the Chinese variant survives a reload", loaded.ZhVariant, "hk");
        new AppSettings { Hotkey = DictationKey.F8, TranslateHotkey = DictationKey.F8, TranslateTarget = "xx", ZhVariant = "nope" }.Save(path);
        loaded = AppSettings.Load(path);
        Eq("the translate key cannot be the dictation key", loaded.TranslateHotkey, (DictationKey?)null);
        Eq("an unknown target reads as English", loaded.TranslateTarget, "en");
        Eq("an unknown variant reads as Simplified", loaded.ZhVariant, "hans");
        Eq("the translate key is off by default", new AppSettings().TranslateHotkey, (DictationKey?)null);
    }
    finally { if (File.Exists(path)) File.Delete(path); }
}

// Activity heatmap: counts per day, streaks, levels; never any text.
{
    var path = Path.Combine(Path.GetTempPath(), "typeleast-activity-" + Guid.NewGuid() + ".json");
    try
    {
        var log = new ActivityLog(path);
        Eq("a new log is empty", log.ActiveDays, 0);
        log.SeedIfNeeded(new[] { (new DateTime(2026, 10, 10, 9, 0, 0), 30), (new DateTime(2026, 10, 10, 18, 0, 0), 5), (new DateTime(2026, 10, 11), 8) });
        Eq("seeding counts per day", log.Day(new DateTime(2026, 10, 10)).Dictations, 2);
        Eq("seeding adds the words", log.Day(new DateTime(2026, 10, 10)).Words, 35);
        log.SeedIfNeeded(new[] { (new DateTime(2026, 10, 1), 1) });
        Eq("seeding happens only once", log.Day(new DateTime(2026, 10, 1)).Dictations, 0);
        log.Record(12, new DateTime(2026, 10, 12));
        log.Record(3, new DateTime(2026, 10, 14));
        log.Record(4, new DateTime(2026, 10, 15));
        Eq("active days", log.ActiveDays, 5);
        Eq("current streak ends today", log.Streaks(new DateTime(2026, 10, 15)).Current, 2);
        Eq("longest streak", log.Streaks(new DateTime(2026, 10, 15)).Longest, 3);
        Eq("a streak survives until the day is over", log.Streaks(new DateTime(2026, 10, 16)).Current, 2);
        Eq("and breaks after a missed day", log.Streaks(new DateTime(2026, 10, 17)).Current, 0);
        Eq("levels", string.Join(",", new[] { 0, 1, 4, 10, 25 }.Select(ActivityLog.Level)), "0,1,2,3,4");
        Eq("counts persist", new ActivityLog(path).Day(new DateTime(2026, 10, 12)).Words, 12);
        var stored = File.ReadAllText(path);
        Check("only dates and counts are stored", stored.Contains("2026-10-12") && !stored.Contains("text"));
        Eq("words: CJK characters plus latin words", ActivityLog.CountWords("你好 DeepSeek v3"), 4);
        log.Clear();
        Eq("clearing empties it", new ActivityLog(path).ActiveDays, 0);
    }
    finally { if (File.Exists(path)) File.Delete(path); }
}

// Protected history: disk migration and failures must preserve existing data.
{
    var dir = Path.Combine(Path.GetTempPath(), "typeleast-protected-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(dir);
    var path = Path.Combine(dir, "history.json");
    try {
        File.WriteAllText(path, "[{\"text\":\"fictional private words\",\"raw\":\"fictional raw\"}]");
        var protection = new TestHistoryProtection();
        var history = new LocalHistory(path, protection);
        Eq("legacy history migrates", history.Last?.Text, "fictional private words");
        Check("stored history contains no plaintext", !System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains("fictional"));
        Eq("protected history reloads", new LocalHistory(path, protection).Last?.Raw, "fictional raw");
        var saved = File.ReadAllBytes(path);
        protection.Fail = true;
        history.Add(new HistoryEntry { Text = "unsaved fixture" });
        Check("encryption failure preserves disk history", saved.SequenceEqual(File.ReadAllBytes(path)));
        Check("encryption failure is reported", history.LastError is not null);
        Check("no plaintext temp file on encryption failure", !File.Exists(path + ".tmp"));
        var locked = new LocalHistory(path, protection);
        locked.Add(new HistoryEntry { Text = "cannot overwrite unreadable history" });
        Check("unreadable ciphertext is preserved", saved.SequenceEqual(File.ReadAllBytes(path)));
        locked.Clear();
        Check("explicit Clear removes locked history", !File.Exists(path));
        File.WriteAllText(path, "[{\"text\":\"migration fixture\"}]");
        var legacy = File.ReadAllBytes(path);
        var failedMigration = new LocalHistory(path, protection);
        Check("failed migration preserves original", legacy.SequenceEqual(File.ReadAllBytes(path)));
        Check("failed migration is reported", failedMigration.LastError is not null);
        if (OperatingSystem.IsWindows()) {
            File.Delete(path);
            var native = new LocalHistory(path);
            native.Add(new HistoryEntry { Text = "DPAPI fixture" });
            Eq("real current-user DPAPI reloads", new LocalHistory(path).Last?.Text, "DPAPI fixture");
            Check("real DPAPI hides text", !System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(path)).Contains("DPAPI fixture"));
            var encrypted = File.ReadAllBytes(path); encrypted[^1] ^= 1; File.WriteAllBytes(path, encrypted);
            var damaged = new LocalHistory(path);
            Check("damaged DPAPI is rejected", damaged.LastError is not null);
            damaged.Add(new HistoryEntry { Text = "preserve damaged file" });
            Check("damaged DPAPI is retained", encrypted.SequenceEqual(File.ReadAllBytes(path)));
        } else Console.WriteLine("SKIP native DPAPI: requires Windows");
    } finally { Directory.Delete(dir, true); }
}
Eq("terminal paste strips newlines", TerminalGuard.SafeText("echo hi\r\nwhoami\n", "WindowsTerminal.exe"), "echo hi whoami");
Eq("normal editors keep newlines", TerminalGuard.SafeText("a\nb", "notepad"), "a\nb");
Eq("terminal paste strips controls", TerminalGuard.SafeText("a\u001bb\u0003c\u2028d", "pwsh"), "abc d");

{
    var malicious = "sk-fake-private\r\nhttps://secret.example/private";
    var line = new DiagnosticEvent(malicious, malicious, malicious, double.NaN, 999, -1).Format();
    Check("diagnostic rejects arbitrary strings", !line.Contains("private") && !line.Contains('\n'));
    Check("diagnostic rejects invalid numeric values", line.Contains("elapsedMs=unknown") && line.Contains("characters=unknown"));
    Check("diagnostic preserves bounded reason", new DiagnosticEvent("dictation", "complete", "model-timeout", 12000).Format().Contains("reason=model-timeout"));
    Check("diagnostic preserves auth category", DiagnosticEvent.SafeReason("model-error:HTTP_401") == "model-error:HTTP_401");
    Eq("diagnostic rejects provider text", DiagnosticEvent.SafeReason("model-error:secret"), "other");
}
{
    var tracker = new OperationTracker();
    for (var i = 0; i < 100; i++)
    {
        var old = tracker.TryBegin()!;
        Check("parallel entry rejected " + i, tracker.TryBegin() is null);
        tracker.Cancel();
        var next = tracker.TryBegin()!;
        Check("cancel invalidates late result " + i, old.Token.IsCancellationRequested && !tracker.IsCurrent(old));
        tracker.Complete(old);
        Check("old completion preserves new operation " + i, tracker.IsCurrent(next));
        tracker.Complete(next);
    }
    var recovery = new RestartPolicy();
    foreach (var expected in new double?[] { 1, 3, 10, 30, null })
        Eq("short-lived ready does not reset backoff", recovery.Next(TimeSpan.FromSeconds(2)), expected);
    Eq("stable uptime resets backoff", recovery.Next(TimeSpan.FromSeconds(60)), 1.0);
    if (OperatingSystem.IsWindows())
    {
        var dir = Path.Combine(Path.GetTempPath(), "typeleast-acl-" + Guid.NewGuid());
        try
        {
            PrivateStorage.EnsureDirectory(dir);
            var rules = System.IO.FileSystemAclExtensions.GetAccessControl(new DirectoryInfo(dir));
            Check("state ACL inheritance is disabled", rules.AreAccessRulesProtected);
            var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User;
            var grants = rules.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier));
            Check("state ACL grants only current user", grants.Cast<System.Security.AccessControl.FileSystemAccessRule>().All(rule => rule.IdentityReference.Equals(sid)));
        }
        finally { Directory.Delete(dir, true); }
    }
}
Console.WriteLine($"TESTS: {passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

/// <summary>A tiny HTTP/1.1 server on 127.0.0.1 that records one request at a time.</summary>
sealed class StubServer
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    public int Port { get; }
    public (int Status, string Body) Reply { get; set; } = (200, "{}");
    public string LastPath { get; private set; } = "";
    public string LastMethod { get; private set; } = "";
    public Dictionary<string, string> LastHeaders { get; private set; } = new();
    public byte[] LastBody { get; private set; } = Array.Empty<byte>();

    public StubServer()
    {
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        _ = Task.Run(Loop);
    }

    public void Stop() => listener.Stop();

    private async Task Loop()
    {
        while (true)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(); }
            catch { return; }
            _ = Task.Run(() => Serve(client));
        }
    }

    private async Task Serve(TcpClient client)
    {
        using var _ = client;
        var stream = client.GetStream();
        var buffer = new List<byte>();
        var chunk = new byte[8192];
        int headerEnd;
        while ((headerEnd = IndexOf(buffer, "\r\n\r\n"u8.ToArray())) < 0)
        {
            var n = await stream.ReadAsync(chunk);
            if (n == 0) return;
            buffer.AddRange(chunk.AsSpan(0, n).ToArray());
        }
        var head = Encoding.ASCII.GetString(buffer.GetRange(0, headerEnd).ToArray()).Split("\r\n");
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in head.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        var length = headers.TryGetValue("content-length", out var cl) ? int.Parse(cl) : 0;
        var body = buffer.Skip(headerEnd + 4).ToList();
        while (body.Count < length)
        {
            var n = await stream.ReadAsync(chunk);
            if (n == 0) break;
            body.AddRange(chunk.AsSpan(0, n).ToArray());
        }
        LastPath = head[0].Split(' ')[1];
        LastMethod = head[0].Split(' ')[0];
        LastHeaders = headers;
        LastBody = body.ToArray();
        var payload = Encoding.UTF8.GetBytes(Reply.Body);
        var response = $"HTTP/1.1 {Reply.Status} X\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(response));
        await stream.WriteAsync(payload);
    }

    private static int IndexOf(List<byte> haystack, byte[] needle)
    {
        for (var i = 0; i + needle.Length <= haystack.Count; i++)
        {
            var match = true;
            for (var j = 0; j < needle.Length && match; j++) match = haystack[i + j] == needle[j];
            if (match) return i;
        }
        return -1;
    }
}

// Isolated test cipher; production always uses current-user DPAPI.
sealed class TestHistoryProtection : IHistoryProtection
{
    public static readonly TestHistoryProtection Shared = new();
    private readonly byte[] key = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);
    public bool Fail { get; set; }
    public byte[] Protect(byte[] data) {
        if (Fail) throw new System.Security.Cryptography.CryptographicException();
        var result = new byte[data.Length + 28];
        System.Security.Cryptography.RandomNumberGenerator.Fill(result.AsSpan(0,12));
        using var aes = new System.Security.Cryptography.AesGcm(key,16);
        aes.Encrypt(result.AsSpan(0,12),data,result.AsSpan(28),result.AsSpan(12,16));
        return result;
    }
    public byte[] Unprotect(byte[] data) {
        if (Fail) throw new System.Security.Cryptography.CryptographicException();
        var result = new byte[data.Length-28];
        using var aes = new System.Security.Cryptography.AesGcm(key,16);
        aes.Decrypt(data.AsSpan(0,12),data.AsSpan(28),data.AsSpan(12,16),result);
        return result;
    }
}
