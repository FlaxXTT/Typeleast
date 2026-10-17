namespace TypeLeast.Core;

/// <summary>
/// Where TypeLeast keeps its files on Windows, the same folders the service uses
/// (service/lib/paths.js): state in %APPDATA%\TypeLeast, models in
/// %LOCALAPPDATA%\TypeLeast\models. TYPELEAST_HOME overrides the state folder.
/// </summary>
public static class AppPaths
{
    public static string StateDirectory(IDictionary<string, string?>? env = null)
    {
        var e = env ?? Environment();
        var over = Get(e, "TYPELEAST_HOME");
        if (over is not null) return over;
        var appData = Get(e, "APPDATA") ?? System.Environment.GetFolderPath(System.Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, "TypeLeast");
    }

    /// <summary>Settings and history of the app itself (the service has its own files beside them).</summary>
    public static string AppSettingsFile(string? stateDir = null) => Path.Combine(stateDir ?? StateDirectory(), "app-settings.json");
    public static string AppHistoryFile(string? stateDir = null) => Path.Combine(stateDir ?? StateDirectory(), "app-history.json");
    public static string LogFile(string? stateDir = null) => Path.Combine(stateDir ?? StateDirectory(), "typeleast-app.log");

    private static string? Get(IDictionary<string, string?> env, string key) =>
        env.TryGetValue(key, out var v) && !string.IsNullOrWhiteSpace(v) ? v.Trim() : null;

    public static IDictionary<string, string?> Environment()
    {
        var map = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry entry in System.Environment.GetEnvironmentVariables())
            map[(string)entry.Key] = entry.Value as string;
        return map;
    }
}
