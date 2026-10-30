namespace Hob.Cli;

internal sealed record Match<T>(T? Entry, IReadOnlyList<T> Candidates) where T : class;

internal static class Matcher
{
    /// <summary>Exact match wins; otherwise a unique prefix is accepted, so <c>hb to dow</c> works without completion.</summary>
    public static Match<T> Find<T>(IEnumerable<T> entries, string token) where T : class, INamed
    {
        var list = entries as IReadOnlyCollection<T> ?? entries.ToList();
        var exact = list.Where(e => e.Name.Equals(token, StringComparison.OrdinalIgnoreCase)).ToList();
        if (exact.Count == 1) return new(exact[0], exact);
        if (exact.Count > 1) return new(Prefer(exact), exact);
        var candidates = list.Where(e => e.Name.StartsWith(token, StringComparison.OrdinalIgnoreCase)).ToList();
        return new(candidates.Count == 1 ? candidates[0] : null, candidates);
    }

    // Your own place beats a plugin's place of the same name; the plugin's is still reachable qualified.
    private static T? Prefer<T>(List<T> exact) where T : class
    {
        var own = exact.Where(e => e is Place { Plugin: null }).ToList();
        return own.Count == 1 ? own[0] : null;
    }

    /// <summary>A place from one word (any plugin, or your own) or two (plugin, then one of its places).</summary>
    public static Match<Place> FindPlace(Model model, IReadOnlyList<string> words)
    {
        if (words.Count == 1) return Find(model.Places, words[0]);
        if (words.Count != 2) return new(null, []);
        var plugin = Find(model.Plugins, words[0]).Entry;
        return plugin is null ? new(null, []) : Find(plugin.Locations, words[1]);
    }

    public static IEnumerable<string> Prefixes(string name)
    {
        string lower = name.ToLowerInvariant();
        for (int i = 1; i <= lower.Length; i++) yield return lower[..i];
    }
}
