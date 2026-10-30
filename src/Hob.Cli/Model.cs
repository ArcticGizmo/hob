using System.Text.Json;
using System.Text.RegularExpressions;

namespace Hob.Cli;

internal interface INamed
{
    string Name { get; }
}

internal sealed record Builtin(string Name, string Usage, string Description, string? AliasOf = null) : INamed;

internal sealed class Plugin(string name, string description, string dir, string? root) : INamed
{
    public string Name { get; } = name;
    public string Description { get; } = description;
    public string Dir { get; } = dir;
    public string? Root { get; } = root;
    public List<Place> Locations { get; } = [];
    public List<PluginCommand> Commands { get; } = [];

    public IEnumerable<INamed> Children => Locations.Cast<INamed>().Concat(Commands);
}

/// <summary>A folder you can jump to. <see cref="Plugin"/> is null for your own places from places.json.</summary>
internal sealed record Place(string Name, string Path, Plugin? Plugin) : INamed
{
    public string Qualified => Plugin is null || Plugin.Name == Name ? Name : $"{Plugin.Name} {Name}";

    /// <summary>What Tab completes to: the short name unless another place shares it.</summary>
    public string Completion { get; set; } = Name;
}

internal sealed record PluginCommand(string Name, string Description, IReadOnlyList<string> Run, Plugin Plugin) : INamed;

/// <summary>Everything hob knows, built from settings, places.json and the plugin manifests.</summary>
internal sealed partial class Model
{
    public static readonly IReadOnlyList<Builtin> Builtins =
    [
        new("to", "to [place]", "Jump to a place; on its own, pick one"),
        new("cd", "cd [place]", "Same as to", AliasOf: "to"),
        new("places", "places [place|add|rm]", "List places, or print one's folder: code (hob places docs). add <name> [folder], rm <name>"),
        new("back", "back", "Go back to where the last jump came from"),
        new("recent", "recent", "Places ranked by how often and how recently you go there"),
        new("update", "update", "Update hob to the latest release"),
        new("reindex", "reindex", "Rebuild the lookup table, after editing plugins by hand"),
    ];

    public static readonly string[] PlaceBuiltins = ["to", "cd", "places"];

    /// <summary>
    /// Words after <c>places</c> that manage places rather than name one, so no place may be called them. The
    /// wrappers repeat this list, so a place that merely starts with one (address) is not answered from the index.
    /// </summary>
    public static readonly string[] PlaceVerbs = ["add", "rm", "remove"];

    public required HobPaths Paths { get; init; }
    public required Settings Settings { get; init; }
    public required IReadOnlyDictionary<string, string> Roots { get; init; }
    public required List<KeyValuePair<string, string>> UserPlaces { get; init; }
    public required List<Plugin> Plugins { get; init; }
    public required List<Place> Places { get; init; }
    public required List<string> Warnings { get; init; }
    /// <summary>Files and folders whose change means the model, and so the index, is out of date.</summary>
    public required List<string> Watch { get; init; }

    public IEnumerable<INamed> Top => Builtins.Cast<INamed>().Concat(Plugins);

    public static Model Load(HobPaths paths)
    {
        var warnings = new List<string>();
        var settings = Settings.Load(paths.SettingsFile, warnings);
        var roots = BuildRoots(settings);
        var userPlaces = PlaceStore.Load(paths.PlacesFile, warnings);
        Directory.CreateDirectory(paths.UserPluginsDir);

        var watch = new List<string> { paths.SettingsFile, paths.PlacesFile };
        var places = new List<Place>();
        foreach (var (name, template) in userPlaces)
        {
            try { places.Add(new Place(name, ExpandPath(template, roots, null), null)); }
            catch (FormatException ex) { warnings.Add($"ignored place '{name}': {ex.Message}"); }
        }

        var plugins = new List<Plugin>();
        foreach (string source in PluginSources(paths, settings))
        {
            // A folder that does not exist yet is watched through its nearest existing parent, whose timestamp
            // changes when it is created.
            string? existing = source;
            while (existing is not null && !Directory.Exists(existing)) existing = Path.GetDirectoryName(existing);
            if (existing is not null && !watch.Contains(existing, StringComparer.OrdinalIgnoreCase)) watch.Add(existing);
            if (!Directory.Exists(source)) continue;

            foreach (string dir in Directory.GetDirectories(source).Order(StringComparer.OrdinalIgnoreCase))
            {
                string manifest = Path.Combine(dir, "plugin.json");
                if (!File.Exists(manifest)) continue;
                watch.Add(manifest);
                try
                {
                    var plugin = ReadPlugin(manifest, dir, roots);
                    if (Builtins.Any(b => b.Name.Equals(plugin.Name, StringComparison.OrdinalIgnoreCase)))
                        warnings.Add($"ignored {manifest} because '{plugin.Name}' is a built-in command");
                    else if (plugins.FirstOrDefault(p => p.Name.Equals(plugin.Name, StringComparison.OrdinalIgnoreCase)) is { } earlier)
                        warnings.Add($"ignored {manifest} because '{plugin.Name}' is already provided by {earlier.Dir}");
                    else plugins.Add(plugin);
                }
                catch (Exception ex) when (ex is JsonException or FormatException or InvalidOperationException or IOException)
                {
                    warnings.Add($"skipped {manifest} ({ex.Message})");
                }
            }
        }

        foreach (var plugin in plugins)
        {
            if (plugin.Root is not null) places.Add(new Place(plugin.Name, plugin.Root, plugin));
            places.AddRange(plugin.Locations);
        }
        foreach (var place in places)
        {
            bool shared = places.Count(p => p.Name.Equals(place.Name, StringComparison.OrdinalIgnoreCase)) > 1;
            // Your own place keeps the short name; the plugin's one completes to its qualified form.
            place.Completion = shared && place.Plugin is not null ? place.Qualified : place.Name;
        }

        return new Model
        {
            Paths = paths, Settings = settings, Roots = roots, UserPlaces = userPlaces, Plugins = plugins,
            Places = places, Warnings = warnings, Watch = watch,
        };
    }

    // Your own plugin folders come first so a plugin of yours can replace a built-in one with the same name.
    // Built-ins live in the install folder, which an update replaces, so nothing of yours belongs there.
    private static IEnumerable<string> PluginSources(HobPaths paths, Settings settings)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string raw in settings.PluginPaths.Append(paths.UserPluginsDir).Append(paths.BuiltinPluginsDir))
        {
            string path = Path.GetFullPath(Environment.ExpandEnvironmentVariables(raw));
            if (seen.Add(path)) yield return path;
        }
    }

    private static Dictionary<string, string> BuildRoots(Settings settings)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        // LOCALAPPDATA\Temp rather than %TEMP%, which can be an 8.3 short path.
        string temp = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Temp");
        if (!Directory.Exists(temp)) temp = Path.GetTempPath();
        var roots = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["home"] = home,
            ["temp"] = Path.TrimEndingDirectorySeparator(temp),
            ["git"] = Path.Combine(home, "Documents", "git"),
        };
        foreach (var (name, value) in settings.Roots) roots[name] = Environment.ExpandEnvironmentVariables(value);
        return roots;
    }

    private static Plugin ReadPlugin(string manifest, string dir, IReadOnlyDictionary<string, string> roots)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(manifest), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        var json = doc.RootElement;
        string name = json.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString()! : throw new FormatException("no \"name\"");
        if (!PlaceStore.ValidName().IsMatch(name)) throw new FormatException($"'{name}' is not a valid plugin name");
        string description = json.TryGetProperty("description", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString()! : "";

        var pluginRoots = new Dictionary<string, string>(roots, StringComparer.OrdinalIgnoreCase) { ["plugin"] = dir };
        string? root = json.TryGetProperty("root", out var r) && r.ValueKind == JsonValueKind.String ? ExpandPath(r.GetString()!, pluginRoots, null) : null;
        var plugin = new Plugin(name, description, dir, root);

        if (json.TryGetProperty("locations", out var locations) && locations.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in locations.EnumerateObject())
            {
                if (prop.Value.ValueKind != JsonValueKind.String) continue;
                plugin.Locations.Add(new Place(prop.Name, ExpandPath(prop.Value.GetString()!, pluginRoots, root), plugin));
            }
        }
        if (json.TryGetProperty("commands", out var commands) && commands.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in commands.EnumerateObject())
            {
                if (prop.Value.ValueKind != JsonValueKind.Object || !prop.Value.TryGetProperty("run", out var run)) continue;
                var parts = run.ValueKind == JsonValueKind.Array
                    ? run.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToList()
                    : run.ValueKind == JsonValueKind.String ? [run.GetString()!] : [];
                if (parts.Count == 0) continue;
                parts = parts.Select(part => part.Replace("{plugin}", dir)).ToList();
                string text = prop.Value.TryGetProperty("description", out var cd) && cd.ValueKind == JsonValueKind.String ? cd.GetString()! : "";
                plugin.Commands.Add(new PluginCommand(prop.Name, text, parts, plugin));
            }
        }
        return plugin;
    }

    [GeneratedRegex(@"\{(\w+)\}")]
    private static partial Regex RootPattern();

    public static string ExpandPath(string template, IReadOnlyDictionary<string, string> roots, string? baseDir)
    {
        string expanded = RootPattern().Replace(Environment.ExpandEnvironmentVariables(template), m =>
            roots.TryGetValue(m.Groups[1].Value, out var value) ? value : throw new FormatException($"unknown root {{{m.Groups[1].Value}}} in '{template}'"));
        if (baseDir is not null) expanded = Path.Combine(baseDir, expanded);
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(expanded));
    }
}
