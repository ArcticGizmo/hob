namespace Hob.Cli;

internal static class Ranking
{
    /// <summary>
    /// Every space-separated term must appear somewhere in the place's qualified name or path. Places whose name
    /// starts with the first term rank first; within that, frecency decides, then recency, then list order.
    /// </summary>
    public static List<Place> Match(IReadOnlyList<Place> places, string query, History history, long now)
    {
        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        const StringComparison ignoreCase = StringComparison.OrdinalIgnoreCase;
        return places
            .Select((place, order) => (place, order))
            .Where(p => terms.All(t => $"{p.place.Qualified} {p.place.Path}".Contains(t, ignoreCase)))
            .Select(p => new
            {
                p.place,
                p.order,
                rank = terms.Length == 0 || p.place.Name.StartsWith(terms[0], ignoreCase) ? 0
                    : p.place.Name.Contains(terms[0], ignoreCase) ? 1
                    : p.place.Qualified.Contains(terms[0], ignoreCase) ? 2
                    : 3,
                score = history.Frecency(p.place.Path, now),
                last = history.Last(p.place.Path),
            })
            .OrderBy(p => p.rank).ThenByDescending(p => p.score).ThenByDescending(p => p.last).ThenBy(p => p.order)
            .Select(p => p.place)
            .ToList();
    }
}
