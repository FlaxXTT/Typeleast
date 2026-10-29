using System.Net;
using System.Security.Cryptography;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace TypeLeast.Core;

// ServiceClient.cs - HTTP client for the TypeLeast local service (service/ in this
// repository): local speech recognition plus cleanup with the user's own model.
// The same contract as apps/macos/Sources/ServiceClient.swift.

public enum ServiceErrorKind { NoToken, Transport, Http, Decoding, Untrusted }

public sealed class ServiceException : Exception
{
    public ServiceErrorKind Kind { get; }
    public int? Status { get; }
    public string? Code { get; }

    public ServiceException(ServiceErrorKind kind, string message, int? status = null, string? code = null)
        : base(message)
    {
        Kind = kind;
        Status = status;
        Code = code;
    }

    /// <summary>/health not answering, or answering 401/403/404/5xx, means "service not running".</summary>
    public bool ServiceUnavailable => Kind is ServiceErrorKind.NoToken or ServiceErrorKind.Transport or ServiceErrorKind.Untrusted
        || (Kind == ServiceErrorKind.Http && Status is 401 or 403 or 404 or >= 500);
}

public sealed class ServiceClient
{
    public const string RoutePrefix = "/api/voice-polish";
    /// <summary>The service refuses larger context headers.</summary>
    public const int MaxContextHeaderBytes = 8 * 1024;

    // Loopback calls never go through a proxy; calls to a model provider use the system's.
    private static readonly HttpClient Loopback = new(new SocketsHttpHandler
    {
        UseProxy = false,
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(3),
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    private static readonly HttpClient Internet = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        ConnectTimeout = TimeSpan.FromSeconds(10),
    })
    { Timeout = TimeSpan.FromSeconds(15) };

    public Uri BaseUri { get; private set; } = new("http://127.0.0.1:1");
    public int? LastPort { get; private set; }
    public string RuntimePath { get; set; }
    public string TokenPath { get; set; }
    /// <summary>Test seam: when set, the token file is not read.</summary>
    public string? TokenOverride { get; set; }
    public TimeSpan ShortTimeout { get; set; } = TimeSpan.FromSeconds(3);
    public TimeSpan DictateTimeout { get; set; } = TimeSpan.FromSeconds(600);
    public TimeSpan BetaTimeout { get; set; } = TimeSpan.FromSeconds(300);

    public ServiceClient(string? stateDirectory = null)
    {
        var dir = stateDirectory ?? AppPaths.StateDirectory();
        RuntimePath = Path.Combine(dir, "runtime.json");
        TokenPath = Path.Combine(dir, "api-token");
    }

    // ---- port and token

    public void UsePort(int port)
    {
        if (port <= 0 || port >= 65536) return;
        LastPort = port;
        BaseUri = new Uri("http://127.0.0.1:" + port);
    }

    /// <summary>
    /// The service this app started has stopped: point nowhere and forget that its port proved
    /// itself. Another program may take that port (and runtime.json may still name it) before
    /// the service is back, so whatever answers there next must answer the challenge again.
    /// </summary>
    public void InvalidatePort()
    {
        lock (proofGate) { verifiedBase = null; }
        LastPort = null;
        BaseUri = new Uri("http://127.0.0.1:1");
    }

    /// <summary>Port the service published, or null when the file is absent or malformed.</summary>
    public int? PublishedPort()
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(RuntimePath));
            if (doc.RootElement.TryGetProperty("port", out var p) && p.TryGetInt32(out var port) && port > 0 && port < 65536) return port;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
        }
        return null;
    }

    public bool DiscoverBaseUri()
    {
        var port = PublishedPort();
        if (port is null) return false;
        UsePort(port.Value);
        return true;
    }

    public string? LoadToken()
    {
        if (TokenOverride is not null) return TokenOverride.Trim().Length > 0 ? TokenOverride.Trim() : null;
        try
        {
            var text = File.ReadAllText(TokenPath).Trim();
            return text.Length > 0 ? text : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    // ---- service identity

    private readonly object proofGate = new();
    private string? proofKey;
    private Uri? verifiedBase;

    /// <summary>
    /// The secret this app gave the service it started (hex), or null when it started none
    /// (tests, a service run by hand): then nothing is checked.
    /// </summary>
    public string? ProofKey
    {
        get { lock (proofGate) return proofKey; }
        set { lock (proofGate) { proofKey = value; verifiedBase = null; } }
    }

    /// <summary>HMAC-SHA256(key, challenge) in lower-case hex, as the service computes it; null for a bad key.</summary>
    public static string? Proof(string key, string challenge)
    {
        try { return Convert.ToHexString(HMACSHA256.HashData(Convert.FromHexString(key), Encoding.UTF8.GetBytes(challenge))).ToLowerInvariant(); }
        catch (FormatException) { return null; }
    }

    /// <summary>
    /// Before anything (an API key above all) goes to a port read from runtime.json, the
    /// listener there must answer a fresh challenge with the secret only our own child has.
    /// </summary>
    private async Task EnsureVerifiedAsync(CancellationToken ct)
    {
        string? key; Uri base_;
        lock (proofGate) { key = proofKey; base_ = BaseUri; if (key is null || verifiedBase == base_) return; }
        var challenge = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        var (status, body) = await SendAsync(HttpMethod.Get, "/health", null,
            new Dictionary<string, string> { ["x-typeleast-challenge"] = challenge }, ShortTimeout, ct, verify: false).ConfigureAwait(false);
        if (status != HttpStatusCode.OK) throw HttpError(status, body);
        string? answer = null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("proof", out var p) && p.ValueKind == JsonValueKind.String) answer = p.GetString();
        }
        catch (JsonException) { }
        var expected = Proof(key, challenge);
        if (answer is null || expected is null || !CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(answer.ToLowerInvariant()), Encoding.ASCII.GetBytes(expected)))
            throw new ServiceException(ServiceErrorKind.Untrusted, "the local service could not prove its identity");
        lock (proofGate) { if (BaseUri == base_) verifiedBase = base_; }
    }

    // ---- plumbing

    private async Task<(HttpStatusCode Status, string Body)> SendAsync(HttpMethod method, string path, HttpContent? content,
        IDictionary<string, string>? headers, TimeSpan timeout, CancellationToken ct, bool verify = true)
    {
        if (verify) await EnsureVerifiedAsync(ct).ConfigureAwait(false);
        var token = LoadToken() ?? throw new ServiceException(ServiceErrorKind.NoToken, "token unavailable: " + TokenPath);
        using var request = new HttpRequestMessage(method, new Uri(BaseUri, RoutePrefix + path)) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (headers is not null)
            foreach (var (k, v) in headers) request.Headers.TryAddWithoutValidation(k, v);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        try
        {
            using var response = await Loopback.SendAsync(request, cts.Token).ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
            return (response.StatusCode, body);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ServiceException(ServiceErrorKind.Transport, "timeout after " + (int)timeout.TotalSeconds + "s");
        }
        catch (HttpRequestException e)
        {
            throw new ServiceException(ServiceErrorKind.Transport, "service unreachable: " + e.Message);
        }
    }

    private static ServiceException HttpError(HttpStatusCode status, string body)
    {
        ApiErrorBody? parsed = null;
        try { parsed = JsonSerializer.Deserialize<ApiErrorBody>(body, Json.Options); } catch (JsonException) { }
        return new ServiceException(ServiceErrorKind.Http, "HTTP " + (int)status + " " + (parsed?.Code ?? "") + " " + (parsed?.Error ?? ""),
            (int)status, parsed?.Code);
    }

    private static T Decode<T>(string body)
    {
        try
        {
            return JsonSerializer.Deserialize<T>(body, Json.Options) ?? throw new ServiceException(ServiceErrorKind.Decoding, "empty body");
        }
        catch (JsonException e)
        {
            throw new ServiceException(ServiceErrorKind.Decoding, "bad response: " + e.Message);
        }
    }

    /// <summary>
    /// One request; on a transport failure re-read the published port and retry once
    /// (the service restarted and got a new port).
    /// </summary>
    private async Task<T> WithPortRetry<T>(Func<Task<T>> body)
    {
        try
        {
            return await body().ConfigureAwait(false);
        }
        catch (ServiceException e) when (e.Kind == ServiceErrorKind.Transport)
        {
            var before = BaseUri;
            if (!DiscoverBaseUri() || BaseUri == before) throw;
            return await body().ConfigureAwait(false);
        }
    }

    private static Task<T> Once<T>(Func<Task<T>> body) => body();

    // ---- endpoints

    public Task<HealthResponse> HealthAsync(CancellationToken ct = default) => WithPortRetry(() => HealthOnceAsync(ct));

    public async Task<HealthResponse> HealthOnceAsync(CancellationToken ct = default)
    {
        var (status, body) = await SendAsync(HttpMethod.Get, "/health", null, null, ShortTimeout, ct).ConfigureAwait(false);
        if (status != HttpStatusCode.OK) throw HttpError(status, body);
        return Decode<HealthResponse>(body);
    }

    /// <summary>The user's own route travels as base64(JSON) in x-voice-llm, to 127.0.0.1 only.</summary>
    public static string? EncodeRouteHeader(LlmRoute? route) =>
        route is null ? null : Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(route));

    /// <summary>Field context travels as base64(JSON) in x-voice-context; too large means none.</summary>
    // Default escaping writes each CJK character as \uXXXX (6 bytes instead of 3); a full Chinese
    // field then went over MaxContextHeaderBytes and was dropped. The service parses UTF-8 JSON.
    private static readonly JsonSerializerOptions ContextOptions = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>The text around the cursor as UTF-8 JSON for x-voice-context.</summary>
    public static byte[] ContextJson(string before, string selected, string after) =>
        JsonSerializer.SerializeToUtf8Bytes(new { before, selected, after }, ContextOptions);

    public static string? EncodeContextHeader(byte[]? json)
    {
        if (json is null || json.Length == 0) return null;
        var encoded = Convert.ToBase64String(json);
        return Encoding.ASCII.GetByteCount(encoded) <= MaxContextHeaderBytes ? encoded : null;
    }

    /// <summary>The body of /dictate: the dictionary as JSON (its length in x-voice-dictionary-bytes), then the WAV.
    /// Entries marked 「不发给模型」 go as {"local": entry}; the service never passes those to a model.</summary>
    public static (byte[] Body, int DictionaryBytes) DictateBody(byte[] wav, IReadOnlyCollection<string>? dictionary, IReadOnlyCollection<string>? localOnly = null, string? clarificationSource = null, string? clarificationEvidence = null, object? personalization = null)
    {
        var entries = new List<object>();
        if (dictionary is not null) entries.AddRange(dictionary);
        if (localOnly is not null) entries.AddRange(localOnly.Select(entry => new Dictionary<string, string> { ["local"] = entry }));
        if (clarificationSource is not null) entries.Add(new { clarificationSource, clarificationEvidence });
        if(personalization is not null)entries.Add(new {personalization=JsonSerializer.SerializeToUtf8Bytes(personalization).Length<=131072?personalization:new {version=1,disabled=true}});
        if (entries.Count == 0) return (wav, 0);
        var json = JsonSerializer.SerializeToUtf8Bytes(entries);
        if(json.Length>256*1024) {
            var minimal=new List<object> {new {personalization=new {version=1,disabled=true}}};
            if(clarificationSource is not null)minimal.Add(new {clarificationSource,clarificationEvidence});
            json=JsonSerializer.SerializeToUtf8Bytes(minimal);
        }
        return ([.. json, .. wav], json.Length);
    }

    /// <param name="dictionary">The Dictionary page's entries ("word" or "heard=word"), sent with every
    /// dictation; the service keeps no copy, so there is nothing to keep in sync.</param>
    public Task<DictateResponse> DictateAsync(byte[] wav, string language, string appHint, string strength,
        LlmRoute? llm, byte[]? fieldContext = null, CancellationToken ct = default, string? betaSession = null,
        string? translateTo = null, string? variants = null, IReadOnlyCollection<string>? dictionary = null, IReadOnlyCollection<string>? localOnly = null, string? clarificationSource = null, string? clarificationEvidence = null, object? personalization = null, Action<TaskProgress>? onProgress = null) =>
        Once(async () =>
        {
            var requestId = Guid.NewGuid().ToString();
            var headers = new Dictionary<string, string>
            {
                ["x-request-id"] = requestId,
                ["x-voice-language"] = language,
                ["x-voice-app"] = appHint,
                ["x-voice-strength"] = strength,
                ["x-voice-task"] = translateTo is not null ? "translation" : strength == "promptbeta" ? "assistant" : "dictation",
                ["x-voice-clarification"] = "1",
            };
            if (EncodeContextHeader(fieldContext) is { } context) headers["x-voice-context"] = context;
            if (EncodeRouteHeader(llm) is { } route) headers["x-voice-llm"] = route;
            if (!string.IsNullOrEmpty(betaSession)) headers["x-voice-beta-session"] = betaSession;
            if (!string.IsNullOrEmpty(translateTo)) headers["x-voice-translate"] = translateTo;
            if (!string.IsNullOrEmpty(variants)) headers["x-voice-variants"] = variants;
            var (payload, dictionaryBytes) = DictateBody(wav, dictionary, localOnly, clarificationSource, clarificationEvidence, personalization);
            headers["x-voice-dictionary-bytes"] = dictionaryBytes.ToString(System.Globalization.CultureInfo.InvariantCulture);
            var content = new ByteArrayContent(payload);
            content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            // Prompt Beta makes up to four model calls in one request.
            var timeout = strength == "promptbeta" && DictateTimeout < BetaTimeout ? BetaTimeout : DictateTimeout;
            using var polling = CancellationTokenSource.CreateLinkedTokenSource(ct);
            var progressTask = onProgress is null ? Task.CompletedTask : PollProgress(requestId, onProgress, polling.Token);
            (HttpStatusCode status, string body) response;
            try { response = await SendAsync(HttpMethod.Post, "/dictate", content, headers, timeout, ct).ConfigureAwait(false); }
            finally { polling.Cancel(); await progressTask.ConfigureAwait(false); }
            var (status, body) = response;
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            return Decode<DictateResponse>(body);
        });

    private async Task PollProgress(string id, Action<TaskProgress> report, CancellationToken ct)
    {
        try {
            while (true) {
                await Task.Delay(1000, ct).ConfigureAwait(false);
                var (status, body) = await SendAsync(HttpMethod.Get, "/tasks/progress?id="+id, null, null, TimeSpan.FromSeconds(3), ct).ConfigureAwait(false);
                if (status != HttpStatusCode.OK) return;
                var value = Decode<TaskProgress>(body);
                ct.ThrowIfCancellationRequested(); report(value);
            }
        } catch (Exception e) when (e is OperationCanceledException or ServiceException or JsonException) { }
    }

    public Task<DictateResponse> PolishAsync(string text, string language, string strength, LlmRoute? llm, string? translateTo,
        string? variants, IReadOnlyCollection<string> dictionary, IReadOnlyCollection<string> localOnly, CancellationToken ct, byte[]? fieldContext = null, object? personalization = null, string? betaSession = null, string? source = null) =>
        Once(async () =>
        {
            var entries = new List<object>(dictionary);
            entries.AddRange(localOnly.Select(entry => new { local = entry }));
            using var context = fieldContext is null ? null : JsonDocument.Parse(fieldContext);
            var json = JsonSerializer.Serialize(new { text, language, strength, task = translateTo is not null ? "translation" : strength == "promptbeta" ? "assistant" : "dictation", llm, translateTo, variants,
                fieldContext = context?.RootElement, dictionary = entries, supportsClarification = true, personalization, betaSession, source }, Json.Options);
            if(Encoding.UTF8.GetByteCount(json)>256*1024)json=JsonSerializer.Serialize(new {text,language,strength,task=translateTo is not null?"translation":strength=="promptbeta"?"assistant":"dictation",llm,translateTo,variants,fieldContext=context?.RootElement,dictionary=Array.Empty<object>(),supportsClarification=true,personalization=new {version=1,disabled=true}},Json.Options);
            var (status, body) = await SendAsync(HttpMethod.Post, "/polish", new StringContent(json, Encoding.UTF8, "application/json"),
                new Dictionary<string, string>(), DictateTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            return Decode<DictateResponse>(body);
        });

    /// <summary>Prompt Beta: write the prompt without answers (skip), or forget the questions (cancel).</summary>
    public Task<DictateResponse> BetaAsync(string sessionId, bool skip, string appHint, LlmRoute? llm, CancellationToken ct = default,
        string? variants = null) =>
        Once(async () =>
        {
            var headers = new Dictionary<string, string> { ["x-voice-app"] = appHint };
            if (!string.IsNullOrEmpty(variants)) headers["x-voice-variants"] = variants;
            if (EncodeRouteHeader(llm) is { } route) headers["x-voice-llm"] = route;
            var json = JsonSerializer.Serialize(new { sessionId });
            var (status, body) = await SendAsync(HttpMethod.Post, skip ? "/assistant/finish" : "/assistant/cancel",
                new StringContent(json, Encoding.UTF8, "application/json"), headers, BetaTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            return skip ? Decode<DictateResponse>(body) : new DictateResponse();
        });

    /// <summary>Start the one-time model download (about 241 MB); progress shows in /health.</summary>
    public Task<bool> DownloadModelsAsync(string? endpoint, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            // Always sent: an empty mirror means huggingface.co, so clearing it needs no service restart.
            var json = JsonSerializer.Serialize(new { endpoint = endpoint?.Trim() ?? "" });
            var (status, body) = await SendAsync(HttpMethod.Post, "/models/download", new StringContent(json, Encoding.UTF8, "application/json"),
                null, ShortTimeout, ct).ConfigureAwait(false);
            if (status is not (HttpStatusCode.Accepted or HttpStatusCode.OK)) throw HttpError(status, body);
            return true;
        });

    public Task<SpeechModelCatalog> GetSpeechModelsAsync(CancellationToken ct = default) => WithPortRetry(async () => {
        var (status, body) = await SendAsync(HttpMethod.Get, "/models", null, null, ShortTimeout, ct).ConfigureAwait(false);
        if (status != HttpStatusCode.OK) throw HttpError(status, body);
        return Decode<SpeechModelCatalog>(body);
    });
    public Task<string> LocalModelActionAsync(string path, object value, CancellationToken ct = default) => WithPortRetry(async () => {
        var json = JsonSerializer.Serialize(value, Json.Options);
        var (status, body) = await SendAsync(HttpMethod.Post, "/models/" + path,
            new StringContent(json, Encoding.UTF8, "application/json"), null, TimeSpan.FromSeconds(60), ct).ConfigureAwait(false);
        if (status is not (HttpStatusCode.OK or HttpStatusCode.Accepted)) throw HttpError(status, body);
        return body;
    });
    public Task<bool> SpeechModelActionAsync(string id, bool download = false, bool cancel = false, string endpoint = "", CancellationToken ct = default) => WithPortRetry(async () => {
        var path = cancel ? "/models/download/cancel" : download ? "/models/download" : "/models/active";
        var json = JsonSerializer.Serialize(new { modelId = id, activate = true, endpoint });
        var (status, body) = await SendAsync(download || cancel ? HttpMethod.Post : HttpMethod.Put, path,
            new StringContent(json, Encoding.UTF8, "application/json"), null, ShortTimeout, ct).ConfigureAwait(false);
        if (status != HttpStatusCode.Accepted) throw HttpError(status, body);
        return true;
    });

    /// <summary>Ask the service to make one tiny call with this route (nothing is recorded).</summary>
    public Task<LlmTestResult> TestLlmAsync(LlmRoute route, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var json = JsonSerializer.Serialize(new { llm = route });
            var (status, body) = await SendAsync(HttpMethod.Post, "/test-llm", new StringContent(json, Encoding.UTF8, "application/json"),
                null, TimeSpan.FromSeconds(25), ct).ConfigureAwait(false);
            if (status is not (HttpStatusCode.OK or HttpStatusCode.BadRequest)) throw HttpError(status, body);
            return Decode<LlmTestResult>(body);
        });

    /// <summary>The word a fix right after a paste teaches, judged by the service (the same rule as on
    /// macOS); null when it was not a spelling fix. The text is only compared there.</summary>
    public Task<string?> LearnedWordAsync(string inserted, string edited, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var json = JsonSerializer.Serialize(new { inserted, edited });
            var (status, body) = await SendAsync(HttpMethod.Post, "/learned-word", new StringContent(json, Encoding.UTF8, "application/json"),
                null, ShortTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            return Decode<LearnedWordResult>(body).Word;
        });

    // ---- plugins (data files the service checks, stores and applies)

    private Task<T> PluginRequest<T>(HttpMethod method, string path, byte[]? body = null, TimeSpan? timeout = null, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            HttpContent? content = body is null ? null : new ByteArrayContent(body) { Headers = { ContentType = new MediaTypeHeaderValue("application/json") } };
            var (status, text) = await SendAsync(method, "/plugins" + path, content, null, timeout ?? TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, text);
            return Decode<T>(text);
        });

    private static byte[] JsonBody(object value) => JsonSerializer.SerializeToUtf8Bytes(value);

    public Task<PluginState> GetPluginsAsync(CancellationToken ct = default) => PluginRequest<PluginState>(HttpMethod.Get, "", ct: ct);
    public Task<PluginState> SetPluginEnabledAsync(string id, bool enabled, CancellationToken ct = default) =>
        PluginRequest<PluginState>(HttpMethod.Put, "/" + Uri.EscapeDataString(id), JsonBody(new { enabled }), ct: ct);

    /// <summary>The provider's model ids, from its OpenAI-compatible GET /models (called directly).</summary>
    public static async Task<List<string>> ListModelsAsync(LlmRoute route, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, route.BaseUrl.TrimEnd('/') + "/models");
        if (route.ApiKey.Length > 0) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", route.ApiKey);
        try
        {
            using var response = await Internet.SendAsync(request, ct).ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK)
                throw new ServiceException(ServiceErrorKind.Http, "HTTP " + (int)response.StatusCode, (int)response.StatusCode);
            return LlmRoute.ModelIds(body);
        }
        catch (HttpRequestException e)
        {
            throw new ServiceException(ServiceErrorKind.Transport, e.Message);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ServiceException(ServiceErrorKind.Transport, "timeout");
        }
    }
}
