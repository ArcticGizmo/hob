using System.Text.Json;

namespace Hob.Cli;

/// <summary>
/// Where hob's files live. The install folder (<see cref="AppDir"/>, Velopack's <c>current</c>) is replaced on
/// every update, so everything that must survive one lives in the data folder instead. The environment
/// overrides match the ones <c>hob.psm1</c> reads, so tests can point both at scratch folders.
/// </summary>
internal sealed record HobPaths(string AppDir, string DataDir, string BinDir, string IndexFile, string SettingsFile, string PathKey)
{
    public static HobPaths FromEnvironment()
    {
        // Not LOCALAPPDATA\hob: that is Velopack's install folder, which uninstall deletes outright.
        string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".hob");
        string settings = Env("HOB_SPIKE_SETTINGS") ?? Path.Combine(data, "settings.json");
        return new HobPaths(
            Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory),
            Path.GetDirectoryName(settings)!,
            Env("HOB_SPIKE_BIN") ?? Path.Combine(data, "bin"),
            Env("HOB_SPIKE_INDEX") ?? Path.Combine(data, "index.txt"),
            settings,
            // Lets tests aim PATH edits at a throwaway registry key instead of the real user environment.
            Env("HOB_SPIKE_PATH_KEY") ?? "Environment");
    }

    /// <summary>The short name from settings.json, defaulting to hb like the module does.</summary>
    public string Alias()
    {
        if (!File.Exists(SettingsFile)) return "hb";
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(SettingsFile));
            return doc.RootElement.TryGetProperty("alias", out var alias) && alias.ValueKind == JsonValueKind.String
                ? alias.GetString() ?? ""
                : "hb";
        }
        catch (JsonException)
        {
            return "hb";
        }
    }

    private static string? Env(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;
}
