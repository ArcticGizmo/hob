using System.Text.Json;

namespace Hob.Cli;

/// <summary><c>settings.json</c>. Every key is optional, and a broken file falls back to the defaults with a warning.</summary>
internal sealed record Settings(string Alias, bool Shortcuts, IReadOnlyList<string> PluginPaths, IReadOnlyDictionary<string, string> Roots)
{
    public static readonly Settings Default = new("hb", true, [], new Dictionary<string, string>());

    public static Settings Load(string file, ICollection<string> warnings)
    {
        if (!File.Exists(file)) return Default;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(file), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new JsonException("expected an object");

            string alias = Default.Alias;
            if (root.TryGetProperty("alias", out var a)) alias = a.ValueKind == JsonValueKind.String ? a.GetString() ?? "" : "";
            bool shortcuts = !root.TryGetProperty("shortcuts", out var s) || s.ValueKind != JsonValueKind.False;
            var pluginPaths = new List<string>();
            if (root.TryGetProperty("pluginPaths", out var p) && p.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in p.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String) pluginPaths.Add(item.GetString()!);
                }
            }
            var roots = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (root.TryGetProperty("roots", out var r) && r.ValueKind == JsonValueKind.Object)
            {
                foreach (var prop in r.EnumerateObject())
                {
                    if (prop.Value.ValueKind == JsonValueKind.String) roots[prop.Name] = prop.Value.GetString()!;
                }
            }
            return new Settings(alias, shortcuts, pluginPaths, roots);
        }
        catch (JsonException ex)
        {
            warnings.Add($"ignored {file}, which is not valid JSON ({ex.Message})");
            return Default;
        }
    }
}
