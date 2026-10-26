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
    Eq("a complete route uses the preset's URL", route?.BaseUrl, "https://api.deepseek.com");
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
    Eq("old plain words become dictionary entries", back.DictionaryEntries.FirstOrDefault()?.Word, "TypeLeast");
    Eq("…and are not written back", back.Words.Count, 0);
    Check("the key is never written to the settings file", !File.ReadAllText(file).Contains("sk-test"));
    File.WriteAllText(file, "{ broken");
    Eq("a broken file gives defaults", AppSettings.Load(file).Hotkey, DictationKey.RightAlt);
    File.WriteAllText(file, "{\"PasteLastShortcut\":\"CtrlShiftV\"}");
    Eq("the old Ctrl+Shift+V default moves once", AppSettings.Load(file).PasteLastShortcut, "CtrlShiftAltV");
    File.WriteAllText(file, "{\"PasteLastShortcut\":\"CtrlShiftV\",\"PasteShortcutDefaults\":1}");
    Eq("a Ctrl+Shift+V chosen after the move stays", AppSettings.Load(file).PasteLastShortcut, "CtrlShiftV");
    Eq("new settings do not take Ctrl+Shift+V", new AppSettings().PasteLastShortcut, "CtrlShiftAltV");
    File.WriteAllText(file, "{\"Strength\":\"maximal\"}");
    Eq("an old install switches to AI cleanup once", AppSettings.Load(file).Strength, "concise");
    foreach (var retired in new[] { "promptbrief", "promptify" })
    {
        File.WriteAllText(file, "{\"Strength\":\"" + retired + "\"}");
        Eq("the retired prompt-mode tier " + retired + " reads as concise", AppSettings.Load(file).Strength, "concise");
    }
    Eq("automatic updates are on for settings saved before they existed", AppSettings.Load(file).AutoUpdate, true);
    File.WriteAllText(file, "{\"Strength\":\"promptbeta\"}");
    var migratedAI = AppSettings.Load(file);
    Eq("existing Beta user switches to AI once", migratedAI.Strength, "concise");
    migratedAI.Strength = "prompt"; migratedAI.Save(file);
    Eq("next startup keeps chosen mode", AppSettings.Load(file).Strength, "prompt");
    var autoHint = WordEntry.Parse("ROG", "LG", "auto")!;
    Eq("automatic mapping is preserved", autoHint.ServiceValue, "LG=ROG");
    Eq("automatic mapping is not a replacement", autoHint.RequestValue, "ROG");
    Eq("manual mapping remains explicit", WordEntry.Parse("ROG", "LG")!.RequestValue, "LG=ROG");
    var heldName = JsonSerializer.Deserialize<DictateResponse>("{\"text\":\"draft\",\"raw\":\"LG\",\"clarification\":{\"question\":\"Which name?\",\"evidence\":\"LG\"}}", Json.Options)!;
    Eq("name confirmation never inserts a draft", heldName.InsertableText, "");


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
    Eq("missing models ask for an explicit choice", Messages.SpeechProblem(new SpeechStatus { Phase = "missing-model" }), L10n.T("请选择并安装语音模型。"));
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

    using (var requestContract = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "client-v2.json"))))
    {
        var sampleWav = Wav.FromPcm16(new byte[3200]);
        foreach (var sample in requestContract.RootElement.GetProperty("requestCases").EnumerateArray())
        {
            var id = sample.GetProperty("id").GetString();
            string? Optional(string name) => sample.GetProperty(name).ValueKind == JsonValueKind.Null ? null : sample.GetProperty(name).GetString();
            var dictionary = sample.GetProperty("dictionary").EnumerateArray().Select(v => v.GetString()!).ToArray();
            var localOnly = sample.GetProperty("localOnly").EnumerateArray().Select(v => v.GetString()!).ToArray();
            var language = sample.GetProperty("language").GetString()!;
            var strength = sample.GetProperty("strength").GetString()!;
            await client.DictateAsync(sampleWav, language, "example.editor", strength, null,
                translateTo: Optional("translateTo"), variants: Optional("variants"), dictionary: dictionary, localOnly: localOnly);
            Eq("shared request path: " + id, stub.LastPath, "/api/voice-polish/dictate");
            Eq("shared request language: " + id, stub.LastHeaders.GetValueOrDefault("x-voice-language"), language);
            Eq("shared request mode: " + id, stub.LastHeaders.GetValueOrDefault("x-voice-strength"), strength);
            Eq("shared request translation: " + id, stub.LastHeaders.GetValueOrDefault("x-voice-translate"), Optional("translateTo"));
            Eq("shared request variants: " + id, stub.LastHeaders.GetValueOrDefault("x-voice-variants"), Optional("variants"));
            var dictionaryBytes = int.Parse(stub.LastHeaders["x-voice-dictionary-bytes"]);
            Check("shared dictionary length: " + id, dictionaryBytes >= 0 && dictionaryBytes <= stub.LastBody.Length);
            if (dictionaryBytes > 0)
            {
                using var sentEntries = JsonDocument.Parse(stub.LastBody.AsMemory(0, dictionaryBytes));
                Eq("shared dictionary count: " + id, sentEntries.RootElement.GetArrayLength(), dictionary.Length + localOnly.Length);
                if (sentEntries.RootElement.GetArrayLength() == dictionary.Length + localOnly.Length)
                {
                    for (var i = 0; i < dictionary.Length; i++) Eq("shared dictionary word: " + id + "/" + i, sentEntries.RootElement[i].GetString(), dictionary[i]);
                    for (var i = 0; i < localOnly.Length; i++) Eq("shared local word: " + id + "/" + i, sentEntries.RootElement[dictionary.Length + i].GetProperty("local").GetString(), localOnly[i]);
                }
            }
            Check("shared WAV tail: " + id, stub.LastBody.AsSpan(dictionaryBytes).SequenceEqual(sampleWav));
        }
    }

    stub.Reply = (200, "{\"word\":\"公司\"}");
    Eq("the service names the learned word", await client.LearnedWordAsync("这家公式很好", "这家公司很好"), "公司");
    Eq("learned-word path", stub.LastPath, "/api/voice-polish/learned-word");
    var edit = JsonSerializer.Deserialize<JsonElement>(stub.LastBody);
    Check("the pasted and edited text are sent", edit.GetProperty("inserted").GetString() == "这家公式很好" && edit.GetProperty("edited").GetString() == "这家公司很好");
    stub.Reply = (200, "{\"word\":null}");
    Eq("no word when it was not a spelling fix", await client.LearnedWordAsync("明天开会", "后天开会"), null);

    // Plugins: the app only asks the service; its answers decode.
    stub.Reply = (200, "{\"plugins\":[{\"id\":\"example.dev-terms\",\"version\":\"1.0.0\",\"type\":\"dictionary\",\"name\":{\"zh-Hans\":\"开发术语\",\"en\":\"Dev terms\"},\"description\":{\"zh-Hans\":\"术语。\",\"en\":\"Terms.\"},\"author\":\"Example\",\"license\":\"CC0-1.0\",\"termCount\":3,\"source\":\"catalog\",\"enabled\":true}],\"style\":null,\"problems\":[]}");
    var plugins = await client.GetPluginsAsync();
    Eq("installed plugins decode", plugins.Plugins[0].Id, "example.dev-terms");
    Check("…with their switch and source", plugins.Plugins[0].Enabled == true && plugins.Plugins[0].Source == "catalog" && !plugins.Plugins[0].IsStyle);
    Eq("plugins path", stub.LastPath, "/api/voice-polish/plugins");
    await client.InstallPluginAsync(System.Text.Encoding.UTF8.GetBytes("{\"format\":\"typeleast-plugin\"}"), enable: true, digest: "abc");
    Eq("install carries the switch and the fingerprint of what was shown", stub.LastPath, "/api/voice-polish/plugins?enable=1&digest=abc");
    Eq("…and the file itself as the body", System.Text.Encoding.UTF8.GetString(stub.LastBody), "{\"format\":\"typeleast-plugin\"}");
    await client.SetPluginEnabledAsync("example.dev-terms", false);
    Eq("a switch is a PUT on the plugin", stub.LastMethod + " " + stub.LastPath, "PUT /api/voice-polish/plugins/example.dev-terms");
    await client.SelectStyleAsync(null);
    Eq("no style is sent as null", System.Text.Encoding.UTF8.GetString(stub.LastBody), "{\"id\":null}");
    await client.InstallCatalogPluginAsync("example.formal", false, "def");
    Eq("a catalog install sends the fingerprint it showed", JsonSerializer.Deserialize<JsonElement>(stub.LastBody).GetProperty("digest").GetString(), "def");
    Eq("a changed plugin is explained", PluginMessages.Describe("plugin-changed"), L10n.T("插件已变化。请重新查看后再安装"));
    await client.RemovePluginAsync("example.dev-terms");
    Eq("uninstall is a DELETE", stub.LastMethod, "DELETE");
    stub.Reply = (400, "{\"error\":\"not a valid plugin\",\"code\":\"plugin-invalid\",\"issues\":[]}");
    try { await client.InspectPluginAsync(new byte[] { 1 }); Check("an invalid file is refused", false); }
    catch (ServiceException e) { Eq("an invalid file is explained", PluginMessages.Describe(e), L10n.T("这不是插件文件")); }
    stub.Reply = (200, "{\"ok\":false,\"code\":\"market-offline\",\"source\":null,\"fetchedAt\":null,\"plugins\":[]}");
    var market = await client.GetPluginCatalogAsync();
    Check("an offline market is reported, not an error", !market.Ok && PluginMessages.Describe(market.Code) == L10n.T("无法获取插件目录，请检查网络"));
    Eq("the market follows the update source setting", stub.LastPath, "/api/voice-polish/plugins/catalog?sources=auto");
    stub.Reply = (200, "{\"ok\":true,\"source\":\"fastly.jsdelivr.net\",\"mirrored\":true,\"fetchedAt\":null,\"plugins\":[]}");
    var mirrored = await client.GetPluginCatalogAsync("mirror");
    Check("a catalog read through a mirror is marked", mirrored.Mirrored && stub.LastPath == "/api/voice-polish/plugins/catalog?sources=mirror");

    // Entries marked 「不发给模型」 go to the local service as {"local": entry}, after the ordinary ones.
    var (marked, markedBytes) = ServiceClient.DictateBody(new byte[] { 1, 2 }, new[] { "DeepSeek" }, new[] { "张为=章伟" });
    var markedJson = JsonSerializer.Deserialize<JsonElement>(marked.AsSpan(0, markedBytes));
    Check("ordinary entries first, marked ones as {local}", markedJson[0].GetString() == "DeepSeek" && markedJson[1].GetProperty("local").GetString() == "张为=章伟");
    Eq("no entries: the body is the WAV", ServiceClient.DictateBody(new byte[] { 1 }, null, new string[0]).DictionaryBytes, 0);

    // The service proves it is ours before anything is sent to it.
    Eq("HMAC proof matches the service's (RFC 4231 case 2 key)",
        ServiceClient.Proof("4a656665", "what do ya want for nothing?"), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    Eq("a non-hex key gives no proof", ServiceClient.Proof("zz", "x"), null);
    var impostor = new ServiceClient(dir) { ProofKey = string.Concat(Enumerable.Repeat("ab", 32)) };
    impostor.DiscoverBaseUri();
    stub.Reply = (200, "{\"ok\":true,\"service\":\"typeleast\",\"speech\":{\"phase\":\"ready\",\"ready\":true}}");
    try
    {
        await impostor.DictateAsync(Wav.FromPcm16(new byte[3200]), "auto", "notepad.exe", "prompt", route);
        Check("a listener without the proof is refused", false);
    }
    catch (ServiceException e)
    {
        Eq("a listener without the proof is refused", e.Kind, ServiceErrorKind.Untrusted);
        Eq("and the key never reached it", stub.LastHeaders.GetValueOrDefault("x-voice-llm"), null);
    }

    // The service exited: whatever answers on its old port (runtime.json still names it) proves itself again.
    var ownKey = string.Concat(Enumerable.Repeat("cd", 32));
    var owned = new ServiceClient(dir) { ProofKey = ownKey };
    owned.DiscoverBaseUri();
    stub.ProofKey = ownKey;
    stub.Reply = (200, "{\"ok\":true,\"service\":\"typeleast\",\"speech\":{\"phase\":\"ready\",\"ready\":true}}");
    Check("our own service proves itself", (await owned.HealthAsync()).Ok);
    owned.InvalidatePort();
    stub.ProofKey = null;
    owned.DiscoverBaseUri();
    try
    {
        await owned.DictateAsync(Wav.FromPcm16(new byte[3200]), "auto", "notepad.exe", "prompt", route);
        Check("after the service exits, its old port is checked again", false);
    }
    catch (ServiceException e)
    {
        Eq("after the service exits, its old port is checked again", e.Kind, ServiceErrorKind.Untrusted);
        Eq("and the key never reached the new listener", stub.LastHeaders.GetValueOrDefault("x-voice-llm"), null);
    }
    stub.ProofKey = null;

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
    var formatCatalog = JsonSerializer.Deserialize<SpeechModelCatalog>("""{"activeModelId":"","models":[{"id":"qwen3-asr-1.7b-fp16","name":"Qwen3-ASR-1.7B","precision":"fp16","category":"primary","downloadable":true}]}""", Json.Options)!;
    Eq("no model implicitly selected", formatCatalog.ActiveModelId, "");
    Eq("model precision preserved", formatCatalog.Models[0].Precision, "fp16");
    Eq("model category preserved", formatCatalog.Models[0].Category, "primary");
    await client.LocalModelActionAsync("register-known", new { modelId = "sensevoice-small" });
    Eq("known model configuration path", stub.LastPath, "/api/voice-polish/models/register-known");
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
    Eq("natural cleanup English label", L10n.Render("自然整理", "en"), "Natural");

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
    var chinese = new string('字', 800);
    var context = ServiceClient.ContextJson(chinese, new string('词', 400), new string('句', 300));
    Check("a full Chinese field context fits the header", ServiceClient.EncodeContextHeader(context) is not null);
    Check("context JSON keeps CJK as UTF-8, not \\u escapes", !System.Text.Encoding.UTF8.GetString(context).Contains("\\u"));
    Eq("no route means no header", ServiceClient.EncodeRouteHeader(null), null);
}

Console.WriteLine();
{
    Eq("invalid UI preference follows system", L10n.Normalize("bad"), "system");
    Eq("Chinese system uses Simplified Chinese", L10n.Resolve("system", "zh-TW"), "zh-Hans");
    Eq("other systems use English", L10n.Resolve(null, "ja-JP"), "en");
    Eq("manual English overrides system", L10n.Resolve("en", "zh-CN"), "en");
    Eq("manual Chinese overrides system", L10n.Resolve("zh-Hans", "en-US"), "zh-Hans");
    Eq("translated label", L10n.Render("设置", "en"), "Settings");
    Eq("content slots remain verbatim", L10n.Render("听写 {0} 次 · {1} 字 · {2} 分钟", "en", "用户 {1}", 2, 3), "用户 {1} dictations · 2 characters · 3 minutes");
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
{
    var dir = Path.Combine(Path.GetTempPath(), "typeleast-data-" + Guid.NewGuid()); Directory.CreateDirectory(dir);
    try
    {
        var history = new LocalHistory(Path.Combine(dir, "history.json"), TestHistoryProtection.Shared);
        history.Add(new HistoryEntry { Text = "old fixture", Time = DateTimeOffset.UtcNow.AddDays(-40) });
        history.Add(new HistoryEntry { Text = "new fixture", Request = new("zh", "prompt", "en", "zh=tw,en=gb") });
        history.ApplyRetention("month"); Eq("retention removes old entries", history.Entries.Count, 1);
        var reloaded = new LocalHistory(Path.Combine(dir, "history.json"), TestHistoryProtection.Shared);
        Eq("retry preserves translation target", reloaded.Last?.Request?.TranslateTo, "en");
        Eq("retry preserves variants", reloaded.Last?.Request?.Variants, "zh=tw,en=gb");
        history.ApplyRetention("never"); history.Add(new HistoryEntry { Text = "memory-only result" });
        Eq("never keeps paste-last in memory", history.Last?.Text, "memory-only result");
        Eq("never writes no result", new LocalHistory(Path.Combine(dir, "history.json"), TestHistoryProtection.Shared).Entries.Count, 0);
        history.Clear(); Check("clear forgets memory result", history.Last is null);
        var settingsPath = Path.Combine(dir, "settings.json");
        File.WriteAllText(settingsPath, "{\"words\":[\"heard=TypeLeast\",\"SenseVoice\"]}");
        var settings = AppSettings.Load(settingsPath);
        Eq("legacy dictionary entries migrate", settings.DictionaryEntries.Count, 2);
        Eq("legacy heardAs preserved", settings.DictionaryEntries[0].HeardAs, "heard");
        Eq("legacy source is manual", settings.DictionaryEntries[0].Source, "manual");
        Check("entries saved before 「不发给模型」 existed are sent as before", settings.DictionaryEntries.All(e => !e.LocalOnly));
        var kept = JsonSerializer.Deserialize<WordEntry>("{\"Word\":\"章伟\",\"HeardAs\":\"张为\",\"LocalOnly\":true}", Json.Options)!;
        Check("the mark survives saving", kept.LocalOnly && JsonSerializer.Deserialize<WordEntry>(JsonSerializer.Serialize(kept, Json.Options), Json.Options)!.LocalOnly);
        var preview = WordImport.Preview("word,heardAs\nTypeLeast,heard\n\"Product, Name\",wrong\nnew,old\n\"unterminated", settings.DictionaryEntries);
        Eq("CSV duplicates reported", preview.Duplicates, 1); Eq("CSV valid preview", preview.Valid.Count, 2);
        Eq("CSV invalid line reported", preview.InvalidLines.Single(), 5);
        Eq("CSV quoted commas preserved", preview.Valid[0].Word, "Product, Name");
        Check("dictionary rejects controls", WordEntry.Parse("bad\nword") is null);
        Check("dictionary enforces service limit", WordEntry.Parse(new string('a', 121)) is null);
        File.WriteAllText(settingsPath, "{broken"); var broken = AppSettings.Load(settingsPath);
        Check("corrupt settings block writes", broken.PersistenceBlocked);
        try { broken.Save(settingsPath); Check("cannot replace corrupt settings", false); } catch (IOException) { Check("cannot replace corrupt settings", File.ReadAllText(settingsPath) == "{broken"); }
        var audio = new RetainedAudio(Path.Combine(dir, "recordings"), TestHistoryProtection.Shared);
        var id = Guid.NewGuid().ToString("N"); var wav = Wav.FromPcm16(new byte[16000]);
        audio.Save(id, wav); Check("retained audio round-trip", audio.Load(id).SequenceEqual(wav));
        Check("retained audio is sealed", !File.ReadAllBytes(Path.Combine(dir,"recordings",id+".audio")).AsSpan().SequenceEqual(wav));
        Eq("retry audio lives five minutes", RetainedAudio.Lifetime, TimeSpan.FromMinutes(5));
        File.SetLastWriteTimeUtc(Path.Combine(dir,"recordings",id+".audio"), DateTime.UtcNow.AddMinutes(-4));
        Check("four-minute-old audio can still be retried", audio.Available(id));
        audio.Prune(new[] { id });
        Check("…and is not pruned", File.Exists(Path.Combine(dir,"recordings",id+".audio")));
        File.SetLastWriteTimeUtc(Path.Combine(dir,"recordings",id+".audio"), DateTime.UtcNow.AddMinutes(-6));
        Check("retained audio expires after five minutes", !audio.Available(id)); audio.Prune(new[] { id });
        Check("expired audio removed", !File.Exists(Path.Combine(dir,"recordings",id+".audio")));
        try { audio.Save("../escape", wav); Check("audio rejects path traversal", false); } catch (InvalidDataException) { Check("audio rejects path traversal", true); }
        Check("format lists produces HTML", FormattedText.HtmlClipboard("1. 第一项\n2. <safe>")?.Contains("&lt;safe&gt;") == true);
        Check("ordinary text stays plain", FormattedText.HtmlClipboard("ordinary paragraph") is null);
    }
    finally { Directory.Delete(dir, true); }
}
// ---- microphone start-up advice

{
    Check("fast microphone gets no advice", !Messages.MicrophoneStartup(120).Contains("蓝牙"));
    Check("slow microphone gets advice", Messages.MicrophoneStartup(900).Contains("变红"));
}

// ---- cue sounds, waveform level and cleanup modes

{
    var start = Chimes.Start(); var stop = Chimes.Stop();
    Check("start chime is a WAV", start.Length > 44 && System.Text.Encoding.ASCII.GetString(start, 0, 4) == "RIFF");
    Check("stop chime is a WAV", stop.Length > 44 && System.Text.Encoding.ASCII.GetString(stop, 8, 4) == "WAVE");
    var level = new AudioLevel();
    Eq("silence draws nothing", level.Next(0), 0.0);
    Check("room noise stays flat", level.Next(6 * Math.Pow(10, -52 / 20.0)) == 0);
    var quiet = 6 * Math.Pow(10, -38 / 20.0);
    double shown = 0; for (var i = 0; i < 30; i++) shown = level.Next(quiet);
    Check("quiet speech fills most of the bar", shown > 0.8, $"shown={shown}");
    Check("loud speech is clamped", new AudioLevel().Next(6) <= 1);
    Eq("AI cleanup is first in the three modes", string.Join(",", CleanupModes.Codes), "concise,prompt,promptbeta");
    Eq("retired verbatim setting becomes natural cleanup", CleanupModes.Stored("off"), "prompt");
    Eq("natural cleanup appears in the mode label", CleanupModes.Title("prompt"), L10n.T("自然整理"));
    Check("natural cleanup keeps its stored id", CleanupModes.IsKnown("prompt") && !CleanupModes.IsKnown("maximal") && !CleanupModes.IsKnown("promptify"));
    Eq("an unknown stored mode is standard cleanup", CleanupModes.Stored("maximal"), "prompt");
}

// ---- Windows release lookup: Mac keeps GitHub's "latest"; Windows reads its own assets

{
    var json = """
    [
      {"tag_name":"v1.17.0","html_url":"https://example.invalid/mac","draft":false,"prerelease":false,"assets":[{"name":"TypeLeast-1.17.0-macOS-AppleSilicon.zip"}]},
      {"tag_name":"windows-v1.16.1","html_url":"https://example.invalid/win","draft":false,"prerelease":false,"assets":[{"name":"TypeLeast-1.16.1-Windows-x64-Setup.exe"},{"name":"TypeLeast-1.16.1-Windows-x64-Portable.zip"}]},
      {"tag_name":"windows-v1.18.0","html_url":"https://example.invalid/draft","draft":true,"prerelease":false,"assets":[{"name":"TypeLeast-1.18.0-Windows-x64-Setup.exe"}]},
      {"tag_name":"windows-v1.17.5","html_url":"https://example.invalid/pre","draft":false,"prerelease":true,"assets":[{"name":"TypeLeast-1.17.5-Windows-x64-Setup.exe"}]},
      {"tag_name":"v1.5.0","html_url":"https://example.invalid/old","draft":false,"prerelease":false,"assets":[{"name":"TypeLeast-1.5.0-Windows-x64-Setup.exe"}]}
    ]
    """;
    var newest = WindowsRelease.Newest(json);
    Eq("windows release ignores mac-only releases", newest?.Version, "1.16.1");
    Eq("windows release keeps its own tag", newest?.Tag, "windows-v1.16.1");
    Check("windows release is newer than 1.16.0", WindowsRelease.IsNewer("1.16.1", "1.16.0"));
    Check("same windows version is not newer", !WindowsRelease.IsNewer("1.16.1", "1.16.1"));
    Check("1.10.0 is newer than 1.9.3", WindowsRelease.IsNewer("1.10.0", "1.9.3"));
    Check("no windows asset gives no release", WindowsRelease.Newest("[{\"tag_name\":\"v1\",\"assets\":[{\"name\":\"x.dmg\"}]}]") is null);
    Check("a non-list answer gives no release", WindowsRelease.Newest("{\"message\":\"Not Found\"}") is null);
    var withFiles = WindowsRelease.Newest("""
    [{"tag_name":"v1.18.0","html_url":"https://github.com/FlaxXTT/Typeleast/releases/tag/v1.18.0","assets":[
      {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/FlaxXTT/Typeleast/releases/download/v1.18.0/SHA256SUMS.txt"},
      {"name":"TypeLeast-1.18.0-Windows-x64-Setup.exe","browser_download_url":"https://github.com/FlaxXTT/Typeleast/releases/download/v1.18.0/TypeLeast-1.18.0-Windows-x64-Setup.exe"}]},
     {"tag_name":"v1.18.1","assets":[{"name":"TypeLeast-1.18.1-Windows-x64-Setup.exe","browser_download_url":"https://evil.example/setup.exe"}]}]
    """);
    Eq("the newest Windows release is found", withFiles?.Version, "1.18.1");
    Eq("a download from anywhere but this repository is dropped", withFiles?.SetupUrl, null);
    var good = WindowsRelease.Newest("""
    [{"tag_name":"v1.18.0","assets":[
      {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/FlaxXTT/Typeleast/releases/download/v1.18.0/SHA256SUMS.txt"},
      {"name":"TypeLeast-1.18.0-Windows-x64-Setup.exe","browser_download_url":"https://github.com/FlaxXTT/Typeleast/releases/download/v1.18.0/TypeLeast-1.18.0-Windows-x64-Setup.exe"}]}]
    """);
    Eq("the installer URL is kept", good?.SetupUrl, "https://github.com/FlaxXTT/Typeleast/releases/download/v1.18.0/TypeLeast-1.18.0-Windows-x64-Setup.exe");
    Eq("the checksum list URL is kept", good?.SumsUrl, "https://github.com/FlaxXTT/Typeleast/releases/download/v1.18.0/SHA256SUMS.txt");
    var hash = new string('a', 64);
    Eq("checksum lines are read", WindowsRelease.Checksum("x.exe", hash + "  x.exe\n" + new string('b', 64) + " *y.exe\n"), hash);
    Eq("binary-mode lines work too", WindowsRelease.Checksum("y.exe", hash + "  x.exe\n" + new string('b', 64) + " *y.exe\n"), new string('b', 64));
    Eq("a missing file has no checksum", WindowsRelease.Checksum("z.exe", hash + "  x.exe"), null);
    Check("the installed copy can update in place",
        WindowsRelease.IsInstalledCopy(Path.Combine("L", "Programs", "TypeLeast"), "L", p => p == Path.Combine("L", "Programs", "TypeLeast", "unins000.exe")));
    Check("a portable copy cannot", !WindowsRelease.IsInstalledCopy(Path.Combine("D", "Tools", "TypeLeast"), "L", _ => true));
}

{
    var exe = @"C:\Users\u\AppData\Local\Programs\TypeLeast\TypeLeast.exe";
    Eq("the Run value starts this copy quietly", AutostartEntry.Command(exe), "\"" + exe + "\" --autostart");
    Eq("the program is read back from the Run value", AutostartEntry.ExePath(AutostartEntry.Command(exe)), exe);
    Eq("an unquoted value is not trusted", AutostartEntry.ExePath(exe + " --autostart"), null);
    Eq("an empty or broken value has no program", AutostartEntry.ExePath("\"\""), null);
    Eq("a missing value has no program", AutostartEntry.ExePath(null), null);
    Check("switched off in Task Manager", AutostartEntry.SwitchedOff([3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]));
    Check("switched off (other form)", AutostartEntry.SwitchedOff([7, 0, 0, 0]));
    Check("switched on again", !AutostartEntry.SwitchedOff([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    Check("no mark means on", !AutostartEntry.SwitchedOff(null) && !AutostartEntry.SwitchedOff([]));
}

{
    var folders = UserData.Folders(Path.Combine("U", "Roaming"), Path.Combine("U", "Local"));
    Eq("remove-data deletes two folders", folders.Length, 2);
    Eq("settings, history and service state", folders[0], Path.Combine("U", "Roaming", "TypeLeast"));
    Eq("speech models", folders[1], Path.Combine("U", "Local", "TypeLeast"));
    Check("never the installed program", folders.All(f => !f.Contains("Programs")));
}

{
    // Clipboard snapshot: order, synthesized formats, budget, time.
    const uint excel = 0xC100, html = 0xC101, png = 0xC102, ole = 0xC103;
    string? Name(uint f) => f switch { excel => "Biff12", html => "HTML Format", png => "PNG", ole => "Ole Private Data", _ => null };
    var order = ClipboardSnapshotPlan.Order([excel, ClipboardFormats.Text, html, ClipboardFormats.UnicodeText, ClipboardFormats.Locale, ole, 2, ClipboardFormats.Dib, ClipboardFormats.DibV5, png], Name);
    Eq("common formats first, then the rest in clipboard order", string.Join(",", order),
        string.Join(",", new uint[] { ClipboardFormats.UnicodeText, ClipboardFormats.Locale, ClipboardFormats.DibV5, html, png, excel }));
    Check("ANSI text is left to Windows when Unicode text is saved", !order.Contains(ClipboardFormats.Text));
    Check("the plain bitmap is left to Windows when the V5 bitmap is saved", !order.Contains(ClipboardFormats.Dib));
    Check("ANSI text is kept when it is the only text", ClipboardSnapshotPlan.Order([ClipboardFormats.Text], Name).Contains(ClipboardFormats.Text));
    Check("handles and OLE objects are not copied", !order.Contains(2u) && !order.Contains(ole));

    var budget = new ClipboardBudget();
    Check("a huge image is skipped", !budget.TryTake(ClipboardSnapshotPlan.FormatLimit + 1));
    Check("…without using the budget, so the text after it is still saved", budget.TryTake(100) && budget.Used == 100);
    var full = new ClipboardBudget();
    Check("formats fill the budget up to the limit", full.TryTake(ClipboardSnapshotPlan.FormatLimit) && full.TryTake(ClipboardSnapshotPlan.TotalLimit - ClipboardSnapshotPlan.FormatLimit));
    Check("one byte more does not fit", !full.TryTake(1));
    Check("an empty format is not saved", !new ClipboardBudget().TryTake(0));

    var late = TimeSpan.FromSeconds(1);
    Check("common formats are read however long it takes", ClipboardSnapshotPlan.InTime(ClipboardFormats.UnicodeText, null, late) && ClipboardSnapshotPlan.InTime(html, "HTML Format", late));
    Check("other formats only while the snapshot is quick", ClipboardSnapshotPlan.InTime(excel, "Biff12", TimeSpan.FromMilliseconds(100)) && !ClipboardSnapshotPlan.InTime(excel, "Biff12", late));
}

{
    // Handover: every block is taken by the clipboard or freed, once.
    var blocks = new List<(uint, IntPtr)> { (13, 1), (16, 2), (17, 3) };
    var ok = new FakeSink();
    Check("all blocks handed over", ClipboardHandover.Commit(blocks, ok) && ok.Taken.Count == 3 && ok.Freed.Count == 0 && ok.Emptied);
    var failing = new FakeSink { RefuseAt = 16 };
    Check("a refused block fails the handover", !ClipboardHandover.Commit(blocks, failing));
    Eq("blocks before it belong to the clipboard", string.Join(",", failing.Taken), "1");
    Eq("it and the ones after it are freed", string.Join(",", failing.Freed), "2,3");
    var locked = new FakeSink { CannotEmpty = true };
    Check("a clipboard that cannot be emptied is left as it is", !ClipboardHandover.Commit(blocks, locked) && locked.Taken.Count == 0);
    Eq("…and every block is freed", string.Join(",", locked.Freed), "1,2,3");
    var unused = new FakeSink();
    ClipboardHandover.Discard(blocks, unused);
    Eq("a snapshot that is not restored is freed", string.Join(",", unused.Freed), "1,2,3");
}

{
    // When to restore after Ctrl+V.
    var t0 = new DateTime(2026, 10, 23, 12, 0, 0, DateTimeKind.Utc);
    DateTime At(int ms) => t0.AddMilliseconds(ms);
    const uint target = 100, history = 200, other = 300;

    var p = new PasteRestorePolicy(target);
    p.Read(At(5), history);
    Eq("nothing before Ctrl+V", p.Decide(At(10)), RestoreDecision.Wait);
    p.KeysSent(At(30));
    p.Read(At(40), history);
    Eq("clipboard history reading again is not the paste", p.Decide(At(2000)), RestoreDecision.Wait);
    p.Read(At(3000), target);
    Eq("a slow target: wait while it may read more", p.Decide(At(3100)), RestoreDecision.Wait);
    p.Read(At(3150), target);
    Eq("still reading (HTML, then text)", p.Decide(At(3300)), RestoreDecision.Wait);
    Eq("restored once reads are quiet", p.Decide(At(3350)), RestoreDecision.Restore);

    var never = new PasteRestorePolicy(target);
    never.KeysSent(At(0));
    Eq("still waiting before the limit", never.Decide(At(4999)), RestoreDecision.Wait);
    Eq("nobody read it: keep the dictation on the clipboard", never.Decide(At(5000)), RestoreDecision.Keep);

    var unknown = new PasteRestorePolicy(target);
    unknown.KeysSent(At(0));
    unknown.Read(At(50), 0);
    Eq("a reader without a window counts", unknown.Decide(At(300)), RestoreDecision.Restore);

    var hosted = new PasteRestorePolicy(target);
    hosted.KeysSent(At(0));
    hosted.Read(At(80), other);
    Eq("a new reader after Ctrl+V counts (apps hosted in another process)", hosted.Decide(At(300)), RestoreDecision.Restore);

    var replaced = new PasteRestorePolicy(target);
    replaced.KeysSent(At(0));
    replaced.Read(At(50), target);
    replaced.Replaced();
    Eq("another program replaced the clipboard: leave it", replaced.Decide(At(1000)), RestoreDecision.Keep);
}

{
    // Which word an edit teaches is decided by the service (service/test/edit-correction.test.js);
    // the client test below checks the request.
    var t0 = new DateTime(2026, 10, 23, 12, 0, 0, DateTimeKind.Utc);
    var poll = new EditPoll(t0, v => v != "hello deepseak");
    Eq("the pasted text alone is not an edit", poll.Feed("hello deepseak", t0.AddSeconds(30)), EditPoll.Step.Wait);
    Eq("mid-edit: wait", poll.Feed("hello deeps", t0.AddSeconds(33)), EditPoll.Step.Wait);
    Eq("settling: wait", poll.Feed("hello deepseek", t0.AddSeconds(36)), EditPoll.Step.Wait);
    Eq("settled for 6 s: judge", poll.Feed("hello deepseek", t0.AddSeconds(42)), EditPoll.Step.Judge);
    var late = new EditPoll(t0, v => v != "x");
    Eq("nothing is watched after 2 minutes", late.Feed("x", t0.AddSeconds(120)), EditPoll.Step.Stop);
    Eq("an unreadable field ends the watch", new EditPoll(t0, _ => true).Feed(null, t0), EditPoll.Step.Stop);
    Eq("the next dictation judges an edit at once", new EditPoll(t0, v => v != "x").Final("y"), "y");
    Eq("…but not an untouched paste", new EditPoll(t0, v => v != "x").Final("x"), null);

    // Detection lives in the service; local merge/ignore is still tested here.
    using (var fixtures = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "suggestion-responses.json"))))
    {
        foreach (var sample in fixtures.RootElement.EnumerateArray())
        {
            var response = System.Text.Json.JsonSerializer.Deserialize<DictateResponse>(sample.GetProperty("response").GetRawText(), Json.Options)!;
            var expected = sample.GetProperty("expectedWords").EnumerateArray().Select(e => e.GetString());
            Eq("suggestion response: " + sample.GetProperty("id").GetString(), string.Join("|", response.Suggestions.Select(s => s.Word)), string.Join("|", expected));
            Eq("optional suggestions cannot break text", response.InsertableText, "Result stays usable.");
        }
    }
    using (var contract = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "client-v2.json"))))
    {
        Eq("shared client contract version", contract.RootElement.GetProperty("version").GetInt32(), 2);
        foreach (var sample in contract.RootElement.GetProperty("modeCases").EnumerateArray())
        {
            var storedElement = sample.GetProperty("stored");
            var stored = storedElement.ValueKind == JsonValueKind.Null ? null : storedElement.GetString();
            var label = stored ?? "null";
            var mode = CleanupModes.Stored(stored);
            Eq("shared stored mode: " + label, mode, sample.GetProperty("expected").GetString());
            Eq("shared mode title: " + label, CleanupModes.Title(mode), sample.GetProperty("labelZh").GetString());
        }
        foreach (var sample in contract.RootElement.GetProperty("responseCases").EnumerateArray())
        {
            var id = sample.GetProperty("id").GetString();
            var response = JsonSerializer.Deserialize<DictateResponse>(sample.GetProperty("response").GetRawText(), Json.Options)!;
            Eq("shared insertable response: " + id, response.InsertableText, sample.GetProperty("insertable").GetString());
            Eq("shared beta waiting: " + id, response.BetaWaiting, sample.GetProperty("betaWaiting").GetBoolean());
            var translation = sample.GetProperty("translated");
            Eq("shared translation result: " + id, response.Translated, translation.ValueKind == JsonValueKind.Null ? null : translation.GetString());
        }
    }
    var seenAt = new DateTime(2026, 10, 23, 0, 0, 0, DateTimeKind.Utc);
    var none = new HashSet<string>();
    var merged = WordSuggestions.Merge([], "DeepSeek", "德普西克", seenAt, none, none);
    var originalSuggestion = merged[0];
    merged = WordSuggestions.Merge(merged, "deepseek", "deep seek", seenAt, none, none);
    Eq("merging a repeat does not mutate stored settings before saving", originalSuggestion.Count, 1);
    Eq("a repeated suggestion is counted once", string.Join(",", merged.Select(m => m.Count)), "2");
    Eq("a word already in the dictionary is not suggested", WordSuggestions.Merge([], "GitHub", "get hub", seenAt, new HashSet<string> { "github" }, none).Count, 0);
    Eq("an ignored word is not suggested again", WordSuggestions.Merge([], "GitHub", "get hub", seenAt, none, new HashSet<string> { "github" }).Count, 0);
    Eq("download progress is a fraction", UpdateProgressText.Fraction(UpdateStage.Downloading, 25 << 20, 50 << 20), 0.5);
    Eq("an unknown size shows a moving bar", UpdateProgressText.Fraction(UpdateStage.Downloading, 1, null), null);
    string WriteTemp(string json) { var f = Path.Combine(Path.GetTempPath(), "tl-src-" + Guid.NewGuid().ToString("N") + ".json"); File.WriteAllText(f, json); return f; }
    Check("the download line shows megabytes", UpdateProgressText.Describe(UpdateStage.Downloading, 25 << 20, 50 << 20).Contains("25.0 / 50.0"));
    var setupUrl = WindowsRelease.DownloadPrefix + "v1.17.8/TypeLeast-1.17.8-Windows-x64-Setup.exe";
    var auto = UpdateSources.For(setupUrl, "auto");
    Eq("auto tries GitHub first", auto[0].Source, "GitHub");
    Eq("…then the mirrors, each with the full GitHub address", auto[1].Url, "https://ghfast.top/" + setupUrl);
    Eq("…named by host", auto[1].Source, "ghfast.top");
    Eq("mirrors-first ends with GitHub", UpdateSources.For(setupUrl, "mirror")[^1].Source, "GitHub");
    Eq("GitHub only means one source", UpdateSources.For(setupUrl, "github").Count, 1);
    Eq("other addresses are never sent to a mirror", UpdateSources.For("https://example.com/x.exe", "mirror").Count, 1);
    Check("the line names the source", UpdateProgressText.Describe(UpdateStage.Downloading, 1 << 20, 2 << 20, "ghfast.top").Contains("ghfast.top"));
    Eq("an unknown source setting falls back to auto", AppSettings.Load(WriteTemp("""{"UpdateSource":"weird"}""")).UpdateSource, "auto");

    Eq("the service starting: ask often", HealthPolling.Interval(false, null, null), HealthPolling.Busy);
    Eq("a speech model loading: ask often", HealthPolling.Interval(true, "loading", null), HealthPolling.Busy);
    Eq("a model downloading: ask often", HealthPolling.Interval(true, "ready", "downloading"), HealthPolling.Busy);
    Eq("all ready and idle: ask rarely", HealthPolling.Interval(true, "ready", null), HealthPolling.Idle);
    Eq("no model yet, nothing happening: rarely", HealthPolling.Interval(true, "missing-model", null), HealthPolling.Idle);
    var (body, length) = ServiceClient.DictateBody([1, 2, 3], ["DeepSeek", "得普=DeepSeek"]);
    Eq("the dictionary rides first, as JSON", System.Text.Json.JsonSerializer.Deserialize<string[]>(body.AsSpan(0, length))?.Length, 2);
    Eq("then the WAV", string.Join(",", body[length..]), "1,2,3");
    Eq("no dictionary: just the WAV", ServiceClient.DictateBody([1, 2, 3], []).DictionaryBytes, 0);
    var quarter = RingGeometry.ArcEnd(0.25, 10, 50, 50);
    Check("a quarter ends at 3 o'clock", Math.Abs(quarter.X - 60) < 1e-9 && Math.Abs(quarter.Y - 50) < 1e-9);
    var half = RingGeometry.ArcEnd(0.5, 10, 50, 50);
    Check("a half ends at 6 o'clock", Math.Abs(half.X - 50) < 1e-9 && Math.Abs(half.Y - 60) < 1e-9);
    Check("a full ring stops just short of closing", RingGeometry.ArcEnd(1, 10, 50, 50).X < 50);
    Check("the large arc only past half", !RingGeometry.IsLargeArc(0.5) && RingGeometry.IsLargeArc(0.51));
    Eq("steps: download, check, install", string.Join(",", UpdatePolicy.Steps), "下载,校验,安装");
    Eq("verifying is the second step", UpdatePolicy.Step(UpdateStage.Verifying), 1);
    var newer = new WindowsReleaseInfo("1.18.0", "v1.18.0", "");
    Check("a found update is offered when all is clear", UpdatePolicy.ShouldOffer(newer, true, null, false));
    Check("not while dictating or Prompt Beta is open", !UpdatePolicy.ShouldOffer(newer, true, null, true));
    Check("稍后: not offered again in this run", !UpdatePolicy.ShouldOffer(newer, true, "1.18.0", false));
    Check("a newer version is offered even after 稍后", UpdatePolicy.ShouldOffer(new WindowsReleaseInfo("1.19.0", "v1.19.0", ""), true, "1.18.0", false));
    Check("not with 更新提醒 off", !UpdatePolicy.ShouldOffer(newer, false, null, false));
    Check("learning is on for new installs", new AppSettings().LearnCorrections);
    var old = Path.Combine(Path.GetTempPath(), "tl-learn-" + Guid.NewGuid().ToString("N") + ".json");
    File.WriteAllText(old, """{"LearnCorrections":false}""");
    Check("switched on once for settings from before", AppSettings.Load(old) is { LearnCorrections: true, LearningDefaults: 1 });
    File.WriteAllText(old, """{"LearnCorrections":false,"LearningDefaults":1}""");
    Check("a later choice to turn it off is kept", !AppSettings.Load(old).LearnCorrections);
    File.Delete(old);
}


{
    var waiting = JsonSerializer.Deserialize<DictateResponse>("""{"text":"","raw":"latest answer","beta":{"sessionId":"s","questions":[],"confirmed":["confirmed"],"round":3,"ready":true,"notice":"beta-validation"}}""")!;
    Check("ready clarification waits for explicit generate", waiting.BetaWaiting);
    Eq("ready clarification inserts nothing", waiting.InsertableText, "");
    Eq("round metadata decodes", waiting.Beta?.Round, 3);
    Eq("confirmed metadata decodes", waiting.Beta?.Confirmed?[0], "confirmed");
    Eq("notice metadata decodes", waiting.Beta?.Notice, "beta-validation");
}

using (var notes = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "release-notes.json"))))
{
    foreach (var sample in notes.RootElement.EnumerateArray())
        Eq("release summary: " + sample.GetProperty("id").GetString(), ReleaseSummary.Text(sample.GetProperty("markdown").GetString()!, sample.GetProperty("language").GetString()), sample.GetProperty("expected").GetString());
    Eq("release summary line is bounded", ReleaseSummary.Text("- " + new string('x', 1000)).Length, 142);
    var path = Path.Combine(Path.GetTempPath(), "tl-tiers-" + Guid.NewGuid().ToString("N") + ".json");
    try
    {
        var settings = new AppSettings { Strength = "concise" };
        settings.Save(path);
        Eq("the concise tier persists", AppSettings.Load(path).Strength, "concise");
    }
    finally { File.Delete(path); }
}

// ---- new-user guide: every entry names a place; a failed model download offers a mirror
{
    var entries = SettingsGuide.Entries;
    Eq("the guide lists six places", entries.Count, 6);
    Check("every guide entry says where it is", entries.All(e => e.Place.Length > 0));
    Eq("the API key lives under Settings › Cleanup", entries.First(e => e.Title == L10n.T("API Key")).Tab, 1);
    Eq("the mirror lives under Settings › Service and updates", entries.First(e => e.Title == L10n.T("语音模型和下载镜像")).Tab, 4);
    SpeechStatus Speech(string json) => JsonSerializer.Deserialize<SpeechStatus>(json, Json.Options)!;
    Check("an unreachable host is a network failure", ModelMirror.NetworkFailure(Speech("""{"phase":"error","error":"could not reach huggingface.co: fetch failed"}""")));
    Check("a failed catalog download is a network failure", ModelMirror.NetworkFailure(Speech("""{"phase":"ready","operation":{"modelId":"x","phase":"error","error":"download-failed"}}""")));
    Check("a checksum failure is not", !ModelMirror.NetworkFailure(Speech("""{"phase":"ready","operation":{"modelId":"x","phase":"error","error":"checksum-mismatch"}}""")));
    Check("a load failure is not", !ModelMirror.NetworkFailure(Speech("""{"phase":"error","error":"model load failed"}""")));
    Check("no status is not", !ModelMirror.NetworkFailure(null));
    Eq("the suggested mirror", ModelMirror.Suggested, "https://hf-mirror.com");
}

using (var contract = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "automatic-dictionary-v1.json"))))
{
    foreach (var item in contract.RootElement.GetProperty("cases").EnumerateArray())
    {
        var id = item.GetProperty("id").GetString()!;
        var settings = new AppSettings { LearnCorrections = item.GetProperty("enabled").GetBoolean() };
        if (item.TryGetProperty("initial", out var initial))
            settings.DictionaryEntries = initial.EnumerateArray().Select(v => WordEntry.Parse(v.GetString()!)!).ToList();
        if (item.TryGetProperty("ignored", out var ignored)) settings.DismissedSuggestions = ignored.EnumerateArray().Select(v => v.GetString()!).ToList();
        settings.WordSuggestions = item.GetProperty("pending").EnumerateArray().Select(v => new WordSuggestion { Word = v.GetProperty("word").GetString()!, HeardAs = v.GetProperty("heardAs").GetString()! }).ToList();
        var incoming = item.GetProperty("incoming").EnumerateArray().Select(v => new SuggestionCandidate(v.GetProperty("word").GetString()!, v.GetProperty("heardAs").GetString()!)).ToArray();
        WordSuggestions.ApplyAutomatic(settings, incoming);
        Eq("automatic dictionary: " + id, string.Join(",", settings.DictionaryEntries.Select(e => e.Word).Order()), string.Join(",", item.GetProperty("expected").EnumerateArray().Select(e => e.GetString()!).Order()));
        Eq("pending dictionary: " + id, settings.WordSuggestions.Count, item.GetProperty("pendingCount").GetInt32());
        if (settings.DictionaryEntries.FirstOrDefault(e => e.Source == "auto") is { } entry)
        {
            WordSuggestions.RememberDeletion(settings, [entry]);
            settings.DictionaryEntries.Remove(entry);
            var path = Path.Combine(Path.GetTempPath(), "typeleast-auto-dictionary-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                settings.LearningDefaults = 1;
                settings.Save(path);
                settings = AppSettings.Load(path);
            }
            finally { File.Delete(path); }
            WordSuggestions.ApplyAutomatic(settings, [new(entry.Word, entry.HeardAs)]);
            Check("deleted dictionary term stays removed: " + id, !settings.DictionaryEntries.Any(e => e.Word == entry.Word));
        }
    }
}

ContextPreferencesTests.Run(Check);
Console.WriteLine($"TESTS: {passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

/// <summary>A tiny HTTP/1.1 server on 127.0.0.1 that records one request at a time.</summary>
sealed class StubServer
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    public int Port { get; }
    public (int Status, string Body) Reply { get; set; } = (200, "{}");
    /// <summary>When set, a challenge is answered like the real service (the reply must be a JSON object).</summary>
    public string? ProofKey { get; set; }
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
        var reply = Reply.Body;
        if (ProofKey is not null && headers.TryGetValue("x-typeleast-challenge", out var challenge))
            reply = reply[..reply.LastIndexOf('}')] + ",\"proof\":\"" + ServiceClient.Proof(ProofKey, challenge) + "\"}";
        var payload = Encoding.UTF8.GetBytes(reply);
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

sealed class FakeSink : IClipboardSink
{
    public uint? RefuseAt;
    public bool CannotEmpty, Emptied;
    public List<IntPtr> Taken = [], Freed = [];
    public bool Empty() => Emptied = !CannotEmpty;
    public bool Put(uint format, IntPtr block)
    {
        if (format == RefuseAt) return false;
        Taken.Add(block);
        return true;
    }
    public void Free(IntPtr block) => Freed.Add(block);
}
