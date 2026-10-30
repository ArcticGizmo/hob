using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Hob.Cli;

/// <summary>
/// Your own places, in <c>places.json</c> as <c>{"name": "folder"}</c>. hob writes the file once with a few
/// everyday places and never again on its own, so deleting one of them sticks.
/// </summary>
internal static partial class PlaceStore
{
    public static readonly IReadOnlyList<KeyValuePair<string, string>> Seeds =
    [
        new("home", "{home}"),
        new("docs", "{home}/Documents"),
        new("downloads", "{home}/Downloads"),
        new("git", "{git}"),
        new("temp", "{temp}"),
    ];

    /// <summary>Names become index keys, completion words and the second word of <c>hob to</c>.</summary>
    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._-]*$")]
    public static partial Regex ValidName();

    public static List<KeyValuePair<string, string>> Load(string file, ICollection<string> warnings)
    {
        if (!File.Exists(file))
        {
            Save(file, Seeds);
            return [.. Seeds];
        }
        var places = new List<KeyValuePair<string, string>>();
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(file), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            if (doc.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException("expected an object of name: folder");
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (prop.Value.ValueKind != JsonValueKind.String) warnings.Add($"ignored place '{prop.Name}' in {file}: the folder must be a string");
                else if (!ValidName().IsMatch(prop.Name)) warnings.Add($"ignored place '{prop.Name}' in {file}: names are letters, digits, '.', '_' and '-'");
                else places.Add(new(prop.Name, prop.Value.GetString()!));
            }
        }
        catch (JsonException ex)
        {
            warnings.Add($"ignored {file}, which is not valid JSON ({ex.Message})");
        }
        return places;
    }

    public static void Save(string file, IEnumerable<KeyValuePair<string, string>> places)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            foreach (var (name, folder) in places) writer.WriteString(name, folder);
            writer.WriteEndObject();
        }
        File.WriteAllText(file, Encoding.UTF8.GetString(stream.ToArray()) + Environment.NewLine);
    }
}
