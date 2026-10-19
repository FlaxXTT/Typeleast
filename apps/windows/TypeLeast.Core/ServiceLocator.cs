using System.Text.Json;

namespace TypeLeast.Core;

/// <summary>
/// Pure decisions for starting the local service on Windows, kept apart from
/// Process so they can be tested: where Node.js is, where the service is, what
/// its ready line says, and how long to wait before a restart.
/// </summary>
public static class ServiceLocator
{
    public const int MinimumNodeMajor = 22;

    public static (int Major, int Minor, int Patch)? ParseNodeVersion(string? text)
    {
        var t = (text ?? "").Trim();
        if (t.StartsWith('v')) t = t[1..];
        var parts = t.Split('.');
        if (parts.Length != 3 || !int.TryParse(parts[0], out var a) || !int.TryParse(parts[1], out var b) || !int.TryParse(parts[2], out var c)) return null;
        return (a, b, c);
    }

    public static bool IsSupported(string? version) => ParseNodeVersion(version) is { } v && v.Major >= MinimumNodeMajor;

    /// <summary>The port in the service's ready line: {"event":"ready","port":51234,...}.</summary>
    public static int? ParseReadyLine(string? line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.Object
                && root.TryGetProperty("event", out var e) && e.ValueKind == JsonValueKind.String && e.GetString() == "ready"
                && root.TryGetProperty("port", out var p) && p.TryGetInt32(out var port) && port > 0 && port < 65536)
                return port;
        }
        catch (JsonException)
        {
        }
        return null;
    }

    /// <summary>Seconds before restart number <paramref name="attempt"/> (1-based); null = give up.</summary>
    public static double? RestartDelay(int attempt)
    {
        double[] delays = { 1, 3, 10, 30 };
        return attempt >= 1 && attempt <= delays.Length ? delays[attempt - 1] : null;
    }

    /// <summary>
    /// The service shipped beside the app. TYPELEAST_SERVICE_DIR (development) is used
    /// only when there is none, so an environment variable can never swap the code an
    /// installed app runs.
    /// </summary>
    public static string? ServiceDirectory(string appDir, IDictionary<string, string?> env, Func<string, bool> exists)
    {
        var candidates = new List<string> { Path.Combine(appDir, "service") };
        if (env.TryGetValue("TYPELEAST_SERVICE_DIR", out var dev) && !string.IsNullOrWhiteSpace(dev)) candidates.Add(dev);
        return candidates.FirstOrDefault(dir => exists(Path.Combine(dir, "bin", "typeleast-service.mjs")));
    }

    /// <summary>
    /// Variables removed before the service starts: they would load other code into
    /// Node.js or weaken its TLS checks (NODE_OPTIONS, NODE_PATH,
    /// NODE_TLS_REJECT_UNAUTHORIZED, ...). NODE_EXTRA_CA_CERTS stays for networks that
    /// need their own certificate authority.
    /// </summary>
    public static List<string> UnsafeServiceVariables(IEnumerable<string> keys)
    {
        var prefixes = new[] { "NODE_", "NPM_", "ELECTRON_" };
        return keys.Where(k => !string.Equals(k, "NODE_EXTRA_CA_CERTS", StringComparison.OrdinalIgnoreCase)
                               && prefixes.Any(p => k.StartsWith(p, StringComparison.OrdinalIgnoreCase))).ToList();
    }

    /// <summary>
    /// Where node.exe usually is, most specific first: the copy shipped with the
    /// app, then the official installer, nvm-windows, Volta, Scoop, fnm, and
    /// finally every folder on PATH. <paramref name="list"/> returns a folder's
    /// sub-folder names.
    /// </summary>
    public static List<string> NodeCandidates(string appDir, IDictionary<string, string?> env, Func<string, IEnumerable<string>> list)
    {
        string? Env(string key) => env.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v) ? v : null;
        var out_ = new List<string> { Path.Combine(appDir, "node", "node.exe") };
        if (Env("ProgramFiles") is { } pf) out_.Add(Path.Combine(pf, "nodejs", "node.exe"));
        if (Env("ProgramW6432") is { } pf64) out_.Add(Path.Combine(pf64, "nodejs", "node.exe"));
        if (Env("LOCALAPPDATA") is { } local)
        {
            out_.Add(Path.Combine(local, "Programs", "nodejs", "node.exe"));
            out_.Add(Path.Combine(local, "Volta", "bin", "node.exe"));
        }
        if (Env("NVM_SYMLINK") is { } nvmLink) out_.Add(Path.Combine(nvmLink, "node.exe"));
        if (Env("NVM_HOME") is { } nvmHome) out_.AddRange(Newest(nvmHome, list).Select(v => Path.Combine(nvmHome, v, "node.exe")));
        if (Env("USERPROFILE") is { } profile)
        {
            out_.Add(Path.Combine(profile, "scoop", "apps", "nodejs-lts", "current", "node.exe"));
            out_.Add(Path.Combine(profile, "scoop", "apps", "nodejs", "current", "node.exe"));
        }
        if (Env("FNM_DIR") is { } fnm)
        {
            var versions = Path.Combine(fnm, "node-versions");
            out_.AddRange(Newest(versions, list).Select(v => Path.Combine(versions, v, "installation", "node.exe")));
        }
        if (Env("PATH") is { } path)
            foreach (var dir in path.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                out_.Add(Path.Combine(dir.Trim('"'), "node.exe"));
        return out_.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static IEnumerable<string> Newest(string dir, Func<string, IEnumerable<string>> list) =>
        list(dir).Where(name => ParseNodeVersion(name) is not null)
            .OrderByDescending(name => ParseNodeVersion(name)!.Value.Major)
            .ThenByDescending(name => ParseNodeVersion(name)!.Value.Minor)
            .ThenByDescending(name => ParseNodeVersion(name)!.Value.Patch);
}
