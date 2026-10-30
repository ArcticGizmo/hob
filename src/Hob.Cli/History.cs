namespace Hob.Cli;

/// <summary>
/// <c>history.tsv</c>: one line per jump with when (.NET ticks, UTC), how, where, and for picker jumps which row
/// was chosen and what was typed. The last two are what E6 replays to check how often the intended place was
/// already on top. The PowerShell and bash wrappers append the same lines for the jumps they handle themselves.
/// </summary>
internal sealed class History
{
    private readonly Dictionary<string, List<long>> _visits = new(StringComparer.OrdinalIgnoreCase);

    public string File { get; }

    private History(string file) => File = file;

    public static History Load(string file)
    {
        var history = new History(file);
        if (!System.IO.File.Exists(file)) return history;
        foreach (string line in System.IO.File.ReadLines(file))
        {
            var fields = line.Split('\t');
            if (fields.Length < 3 || !long.TryParse(fields[0], out long ticks)) continue;
            if (!history._visits.TryGetValue(fields[2], out var list)) history._visits[fields[2]] = list = [];
            list.Add(ticks);
        }
        return history;
    }

    public IReadOnlyList<long> Visits(string path) => _visits.TryGetValue(path, out var list) ? list : [];

    public long Last(string path) => _visits.TryGetValue(path, out var list) && list.Count > 0 ? list[^1] : 0;

    /// <summary>zoxide-style buckets: a visit counts for less the older it gets, so habits and recent work both surface.</summary>
    public double Frecency(string path, long now)
    {
        var visits = Visits(path);
        double score = 0;
        for (int i = Math.Max(0, visits.Count - 200); i < visits.Count; i++)
        {
            long age = now - visits[i];
            score += age < TimeSpan.TicksPerHour ? 4 : age < TimeSpan.TicksPerDay ? 2 : age < 7 * TimeSpan.TicksPerDay ? 0.5 : 0.25;
        }
        return score;
    }

    public static void Append(string file, string path, string how, int pickIndex = -1, string query = "")
    {
        if (HobPaths.Env("HOB_NO_HISTORY") is not null) return;
        string clean = query.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            System.IO.File.AppendAllText(file, $"{DateTime.UtcNow.Ticks}\t{how}\t{path}\t{pickIndex}\t{clean}\n");
        }
        catch (IOException)
        {
            // Ranking is a nicety; a locked or read-only history file should never stop a jump.
        }
    }
}
