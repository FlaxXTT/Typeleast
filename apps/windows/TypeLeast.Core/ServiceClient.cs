using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace TypeLeast.Core;

// ServiceClient.cs - HTTP client for the TypeLeast local service (service/ in this
// repository): local speech recognition plus cleanup with the user's own model.
// The same contract as apps/macos/Sources/ServiceClient.swift.

public enum ServiceErrorKind { NoToken, Transport, Http, Decoding }

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
    public bool ServiceUnavailable => Kind is ServiceErrorKind.NoToken or ServiceErrorKind.Transport
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
    public TimeSpan DictateTimeout { get; set; } = TimeSpan.FromSeconds(120);

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

    // ---- plumbing

    private async Task<(HttpStatusCode Status, string Body)> SendAsync(HttpMethod method, string path, HttpContent? content,
        IDictionary<string, string>? headers, TimeSpan timeout, CancellationToken ct)
    {
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
    public static string? EncodeContextHeader(byte[]? json)
    {
        if (json is null || json.Length == 0) return null;
        var encoded = Convert.ToBase64String(json);
        return Encoding.ASCII.GetByteCount(encoded) <= MaxContextHeaderBytes ? encoded : null;
    }

    public Task<DictateResponse> DictateAsync(byte[] wav, string language, string appHint, string strength,
        LlmRoute? llm, byte[]? fieldContext = null, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var headers = new Dictionary<string, string>
            {
                ["x-voice-language"] = language,
                ["x-voice-app"] = appHint,
                ["x-voice-strength"] = strength,
            };
            if (EncodeContextHeader(fieldContext) is { } context) headers["x-voice-context"] = context;
            if (EncodeRouteHeader(llm) is { } route) headers["x-voice-llm"] = route;
            var content = new ByteArrayContent(wav);
            content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            var (status, body) = await SendAsync(HttpMethod.Post, "/dictate", content, headers, DictateTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            return Decode<DictateResponse>(body);
        });

    public Task<List<string>> PutDictionaryAsync(IEnumerable<string> entries, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var json = JsonSerializer.Serialize(new { entries = entries.ToArray() });
            var (status, body) = await SendAsync(HttpMethod.Put, "/dictionary", new StringContent(json, Encoding.UTF8, "application/json"),
                null, ShortTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.TryGetProperty("dictionary", out var d) && d.ValueKind == JsonValueKind.Array
                ? d.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToList()
                : new List<string>();
        });

    /// <summary>Start the one-time model download (about 241 MB); progress shows in /health.</summary>
    public Task<bool> DownloadModelsAsync(string? endpoint, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var json = string.IsNullOrWhiteSpace(endpoint) ? "{}" : JsonSerializer.Serialize(new { endpoint });
            var (status, body) = await SendAsync(HttpMethod.Post, "/models/download", new StringContent(json, Encoding.UTF8, "application/json"),
                null, ShortTimeout, ct).ConfigureAwait(false);
            if (status is not (HttpStatusCode.Accepted or HttpStatusCode.OK)) throw HttpError(status, body);
            return true;
        });

    public Task<PromptifySettings> GetPromptifyAsync(CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var (status, body) = await SendAsync(HttpMethod.Get, "/prompts/promptify", null, null, ShortTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, body);
            return Decode<PromptifySettings>(body);
        });

    /// <summary>Change the prompt-mode settings: a new appendix, a replacement default, or (restoreDefault) the default back.</summary>
    public Task<PromptifySettings> SetPromptifyAsync(string? appendix = null, string? overrideText = null, bool restoreDefault = false, CancellationToken ct = default) =>
        WithPortRetry(async () =>
        {
            var body = new Dictionary<string, object?>();
            if (appendix is not null) body["appendix"] = appendix;
            if (restoreDefault) body["override"] = null;
            else if (overrideText is not null) body["override"] = overrideText;
            var json = JsonSerializer.Serialize(body);
            var (status, text) = await SendAsync(HttpMethod.Put, "/prompts/promptify", new StringContent(json, Encoding.UTF8, "application/json"),
                null, ShortTimeout, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK) throw HttpError(status, text);
            return Decode<PromptifySettings>(text);
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
