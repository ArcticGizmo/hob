namespace Hob.Cli;

/// <summary>
/// Where hob's files live. The install folder (<see cref="AppDir"/>, Velopack's <c>current</c>) is replaced on
/// every update, so everything that must survive one lives in the data folder instead. <c>HOB_HOME</c> moves the
/// whole data folder, which is how tests stay off the real one; the shell wrappers read the same variable.
/// </summary>
internal sealed record HobPaths(string AppDir, string DataDir, string PathKey)
{
    public string BinDir => Path.Combine(DataDir, "bin");
    public string IndexFile => Path.Combine(DataDir, "index.txt");
    public string SettingsFile => Path.Combine(DataDir, "settings.json");
    public string PlacesFile => Path.Combine(DataDir, "places.json");
    public string HistoryFile => Path.Combine(DataDir, "history.tsv");
    public string UserPluginsDir => Path.Combine(DataDir, "plugins");
    public string BuiltinPluginsDir => Path.Combine(AppDir, "plugins");
    public string ExePath => Path.Combine(AppDir, "hob-cli.exe");

    public static HobPaths FromEnvironment()
    {
        // Not LOCALAPPDATA\hob: that is Velopack's install folder, which uninstall deletes outright.
        string data = Env("HOB_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".hob");
        return new HobPaths(
            Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory),
            Path.GetFullPath(data),
            // Lets tests aim PATH edits at a throwaway registry key instead of the real user environment.
            Env("HOB_PATH_KEY") ?? "Environment");
    }

    public static string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;
}
