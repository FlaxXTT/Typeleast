namespace TypeLeast.Core;

// UserData.cs - what "remove my data" deletes when TypeLeast is uninstalled: the
// settings, history, recordings and service state in %APPDATA%\TypeLeast and the
// speech models in %LOCALAPPDATA%\TypeLeast. The program itself lives in
// %LOCALAPPDATA%\Programs\TypeLeast and is removed by the uninstaller.
public static class UserData
{
    public const string RemoveArgument = "--remove-user-data";

    /// <summary>The folders to delete. A TYPELEAST_HOME override is not followed:
    /// only TypeLeast's own folders are removed.</summary>
    public static string[] Folders(string appData, string localAppData) =>
        [Path.Combine(appData, "TypeLeast"), Path.Combine(localAppData, "TypeLeast")];
}
