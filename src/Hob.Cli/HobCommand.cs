using System.Diagnostics;

namespace Hob.Cli;

/// <summary>
/// Everything typed after <c>hob</c> that the shell wrapper did not answer from the index. The wrapper passes
/// <c>HOB_SHELL</c> (powershell, cmd or bash) and <c>HOB_DIRECTIVES</c>, a file this appends <c>cd</c> and
/// <c>back</c> lines to, which the wrapper applies to your shell once this exits.
/// </summary>
internal sealed class HobCommand(HobPaths paths, TextWriter stdout, TextWriter stderr)
{
    public string Shell { get; init; } = (HobPaths.Env("HOB_SHELL") ?? "").ToLowerInvariant();
    public string? DirectivesFile { get; init; } = HobPaths.Env("HOB_DIRECTIVES");
    public string CurrentDirectory { get; init; } = Environment.CurrentDirectory;
    public Func<ITerminal?> OpenTerminal { get; init; } = ConsoleTerminal.TryOpen;
    public Func<bool, Task<int>> Update { get; init; } = Updater.Run;

    private Model _model = null!;
    private bool Bash => Shell == "bash";

    public async Task<int> Run(IReadOnlyList<string> args)
    {
        var words = args.Where(w => w.Length > 0).ToList();
        _model = Model.Load(paths);
        HobIndex.Refresh(_model, stderr);

        if (words.Count == 0 || words[0] is "--help" or "-h" or "-?" or "/?") return Overview();
        if (words[0] is "--version" or "-v" or "-V") return Print($"hob {AppInfo.Version}");
        if (words[0].StartsWith('-')) return Fail($"unknown option '{words[0]}'. Run 'hob' to see everything.");

        var found = Matcher.Find(_model.Top, words[0]);
        var rest = words.Skip(1).ToList();
        switch (found.Entry)
        {
            case Builtin builtin:
                switch (builtin.AliasOf ?? builtin.Name)
                {
                    case "to": return To(rest, printOnly: false);
                    case "path": return To(rest, printOnly: true);
                    case "back": return Back();
                    case "recent": return Recent();
                    case "update": return await Update(rest.Contains("--check"));
                    case "reindex":
                        HobIndex.Refresh(_model, stderr, force: true);
                        return Print($"rebuilt {paths.IndexFile}");
                }
                break;
            case Plugin plugin:
                return PluginWords(plugin, rest);
        }

        if (found.Candidates.Count > 1) return Fail($"'{words[0]}' is ambiguous: {string.Join(", ", found.Candidates.Select(c => c.Name))}");
        if (Matcher.FindPlace(_model, [words[0]]).Entry is not null) return Fail($"'{words[0]}' is a place. Did you mean '{JumpHint(words[0])}'?");
        return Fail($"'{words[0]}' is not something hob knows. Run 'hob' to see everything.");
    }

    private int To(List<string> rest, bool printOnly)
    {
        if (rest.Count > 0 && rest[0].StartsWith('-'))
        {
            return rest[0] switch
            {
                "--add" or "-a" => AddPlace(rest.Skip(1).ToList()),
                "--rm" or "--remove" => RemovePlace(rest.Skip(1).ToList()),
                "--list" or "-l" => ListPlaces(),
                _ => Fail($"unknown option '{rest[0]}'. Try --add, --rm or --list."),
            };
        }

        // Bash cannot be moved by a separate program, so `to` there explains the `cd "$(hob path)"` form.
        if (Bash && !printOnly)
        {
            if (rest.Count == 0) return ListPlaces();
            stderr.WriteLine($"hob: Git Bash runs hob as a separate program, so it cannot move your shell. Use:  cd \"$(hob path {string.Join(' ', rest)})\"");
            return 2;
        }

        var match = rest.Count is 1 or 2 ? Matcher.FindPlace(_model, rest) : new Match<Place>(null, []);
        if (match.Entry is not null) return Go(match.Entry, printOnly, "to");

        string query = string.Join(' ', rest);
        using var term = OpenTerminal();
        if (term is null)
        {
            if (rest.Count == 0) return printOnly ? Fail("usage: hob path <place>") : ListPlaces();
            if (match.Candidates.Count > 1)
                return Fail($"'{query}' could be: {string.Join(", ", match.Candidates.Select(c => c.Qualified))}. Be more specific, for example '{Verb(printOnly)} {match.Candidates[0].Qualified}'.");
            return Fail($"no place called '{query}'. 'hob to --list' shows them all.");
        }

        if (_model.Places.Count == 0) return Fail("there are no places yet. Add one with: hob to --add <name> [folder]");
        var history = History.Load(paths.HistoryFile);
        long now = DateTime.UtcNow.Ticks;
        var pick = Picker.Show(term, _model.Places, query, q => Ranking.Match(_model.Places, q, history, now));
        if (pick is null) return 1;
        return Go(pick.Place, printOnly, "picker", pick.Index, pick.Query);
    }

    private int Go(Place place, bool printOnly, string how, int pickIndex = -1, string query = "")
    {
        if (!Directory.Exists(place.Path)) return Fail($"'{place.Qualified}' points at {place.Path}, which does not exist");
        if (printOnly)
        {
            stdout.WriteLine(Bash ? Shims.GitBashPath(place.Path) : place.Path);
            History.Append(paths.HistoryFile, place.Path, "path", pickIndex, query);
            return 0;
        }
        if (Bash)
        {
            stderr.WriteLine($"hob: Git Bash runs hob as a separate program, so it cannot move your shell. Use:  cd \"$(hob path {place.Qualified})\"");
            return 2;
        }
        if (!Directive($"cd {place.Path}")) return 1;
        History.Append(paths.HistoryFile, place.Path, how, pickIndex, query);
        return 0;
    }

    private int Back()
    {
        if (Bash) return Fail("Git Bash runs hob as a separate program, so there is no jump to go back from. Use  cd -  instead.", 2);
        return Directive("back") ? 0 : 1;
    }

    private bool Directive(string line)
    {
        if (DirectivesFile is null)
        {
            stderr.WriteLine("hob: only the hob command can move your shell; hob-cli.exe on its own cannot");
            return false;
        }
        File.AppendAllText(DirectivesFile, line + "\n");
        return true;
    }

    private int AddPlace(List<string> args)
    {
        if (args.Count is 0 or > 2) return Fail("usage: hob to --add <name> [folder]   (the folder defaults to where you are)");
        string name = args[0];
        if (!PlaceStore.ValidName().IsMatch(name)) return Fail($"'{name}' can't be a place name: use letters, digits, '.', '_' and '-', starting with a letter or digit");
        string folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args.Count == 2 ? Environment.ExpandEnvironmentVariables(args[1]) : CurrentDirectory, CurrentDirectory));
        if (!Directory.Exists(folder)) return Fail($"{folder} is not a folder");

        var places = _model.UserPlaces;
        int existing = places.FindIndex(p => p.Key.Equals(name, StringComparison.OrdinalIgnoreCase));
        if (existing >= 0)
        {
            string before = places[existing].Value;
            places[existing] = new(places[existing].Key, folder);
            stdout.WriteLine($"updated {places[existing].Key}: {before} -> {folder}");
        }
        else
        {
            places.Add(new(name, folder));
            stdout.WriteLine($"added {name}: {folder}");
        }
        return SavePlaces(places);
    }

    private int RemovePlace(List<string> args)
    {
        if (args.Count != 1) return Fail("usage: hob to --rm <name>");
        var places = _model.UserPlaces;
        int index = places.FindIndex(p => p.Key.Equals(args[0], StringComparison.OrdinalIgnoreCase));
        if (index < 0)
        {
            var fromPlugin = _model.Places.FirstOrDefault(p => p.Plugin is not null && p.Name.Equals(args[0], StringComparison.OrdinalIgnoreCase));
            if (fromPlugin is not null) return Fail($"'{fromPlugin.Qualified}' comes from the {fromPlugin.Plugin!.Name} plugin; change it in {Path.Combine(fromPlugin.Plugin.Dir, "plugin.json")}");
            return Fail($"you have no place called '{args[0]}'. Yours are: {string.Join(", ", places.Select(p => p.Key))}");
        }
        stdout.WriteLine($"removed {places[index].Key} ({places[index].Value})");
        places.RemoveAt(index);
        return SavePlaces(places);
    }

    private int SavePlaces(List<KeyValuePair<string, string>> places)
    {
        PlaceStore.Save(paths.PlacesFile, places);
        _model = Model.Load(paths);
        HobIndex.Refresh(_model, stderr, force: true);
        return 0;
    }

    private int PluginWords(Plugin plugin, List<string> rest)
    {
        if (rest.Count == 0)
        {
            if (plugin.Root is not null) return Go(new Place(plugin.Name, plugin.Root, plugin), printOnly: false, "direct");
            ShowPlugin(plugin);
            return 0;
        }
        var found = Matcher.Find(plugin.Children, rest[0]);
        switch (found.Entry)
        {
            case Place place: return Go(place, printOnly: false, "direct");
            case PluginCommand command: return RunCommand(command, rest.Skip(1).ToList());
        }
        if (found.Candidates.Count > 1) return Fail($"'{rest[0]}' is ambiguous in {plugin.Name}: {string.Join(", ", found.Candidates.Select(c => c.Name))}");
        return Fail($"'{rest[0]}' is not something {plugin.Name} knows. Run '{plugin.Name}' to see what it has.");
    }

    /// <summary>
    /// Normally the wrapper runs plugin commands itself, from the index. This is the path for ones it cannot
    /// (several words in <c>run</c>) or has not indexed yet. The directives file is inherited, so a command
    /// started here can still move your shell.
    /// </summary>
    private int RunCommand(PluginCommand command, List<string> extra)
    {
        var info = command.Run[0].EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)
            ? new ProcessStartInfo("powershell.exe") { ArgumentList = { "-NoProfile", "-File" } }
            : new ProcessStartInfo();
        if (info.FileName.Length == 0) info.FileName = command.Run[0];
        else info.ArgumentList.Add(command.Run[0]);
        foreach (string arg in command.Run.Skip(1).Concat(extra)) info.ArgumentList.Add(arg);
        info.UseShellExecute = false;
        info.Environment["HOB_PLUGIN_DIR"] = command.Plugin.Dir;
        using var process = Process.Start(info)!;
        process.WaitForExit();
        return process.ExitCode;
    }

    private int Recent()
    {
        var history = History.Load(paths.HistoryFile);
        long now = DateTime.UtcNow.Ticks;
        var ranked = _model.Places
            .Where(p => history.Visits(p.Path).Count > 0)
            .Select(p => (place: p, score: history.Frecency(p.Path, now), visits: history.Visits(p.Path).Count, last: history.Last(p.Path)))
            .OrderByDescending(r => r.score).ThenByDescending(r => r.last)
            .Take(15)
            .ToList();
        if (ranked.Count == 0) return Print($"No history yet. Jumps are recorded in {paths.HistoryFile}");
        stdout.WriteLine("  score  visits  last      place");
        foreach (var r in ranked)
        {
            var ago = TimeSpan.FromTicks(now - r.last);
            string last = ago.TotalHours < 1 ? $"{(int)ago.TotalMinutes}m ago" : ago.TotalDays < 1 ? $"{(int)ago.TotalHours}h ago" : $"{(int)ago.TotalDays}d ago";
            stdout.WriteLine($"{r.score,7:0.##}  {r.visits,6}  {last,-8}  {r.place.Qualified,-16}{r.place.Path}");
        }
        stdout.WriteLine();
        stdout.WriteLine($"History: {paths.HistoryFile}");
        return 0;
    }

    private int Overview()
    {
        stdout.WriteLine($"hob {AppInfo.Version}");
        stdout.WriteLine();
        ListPlaces();
        // Plugin places are already listed above, so only commands here.
        foreach (var plugin in _model.Plugins.Where(p => p.Commands.Count > 0))
        {
            stdout.WriteLine();
            ShowPlugin(plugin, commandsOnly: true);
        }
        stdout.WriteLine();
        stdout.WriteLine("Commands");
        var rows = Model.Builtins.Where(b => b.AliasOf is null).Select(b =>
        {
            var aliases = Model.Builtins.Where(a => a.AliasOf == b.Name).Select(a => a.Name);
            string name = string.Join(", ", aliases.Prepend(b.Name));
            return (name: b.Usage.Replace(b.Name, name), description: b.Description);
        }).Append((name: "--version, -v", description: "Print hob's version")).Append((name: "--help, -h", description: "This list")).ToList();
        int width = rows.Max(r => r.name.Length) + 2;
        foreach (var (name, description) in rows) stdout.WriteLine($"  {name.PadRight(width)}{description}");
        return 0;
    }

    private int ListPlaces()
    {
        stdout.WriteLine(Bash
            ? "Places: cd \"$(hob path <name>)\".  Yours: hob to --add <name> [folder], hob to --rm <name>"
            : "Places: hob to <name>.  Yours: hob to --add <name> [folder], hob to --rm <name>");
        if (_model.Places.Count == 0) stdout.WriteLine("  (none yet)");
        int width = _model.Places.Count == 0 ? 0 : Math.Min(24, _model.Places.Max(p => p.Qualified.Length) + 2);
        foreach (var place in _model.Places) stdout.WriteLine($"  {place.Qualified.PadRight(width)}{place.Path}");
        return 0;
    }

    private void ShowPlugin(Plugin plugin, bool commandsOnly = false)
    {
        stdout.WriteLine($"{plugin.Name}: {plugin.Description}".TrimEnd(' ', ':'));
        var rows = plugin.Commands.Select(c => (c.Name, Detail: c.Description)).ToList();
        if (!commandsOnly)
        {
            rows.InsertRange(0, plugin.Locations.Select(l => (l.Name, Detail: l.Path)));
            if (plugin.Root is not null) rows.Insert(0, ("(itself)", plugin.Root));
        }
        int width = rows.Count == 0 ? 0 : rows.Max(r => r.Name.Length) + 2;
        foreach (var (name, detail) in rows) stdout.WriteLine($"  {name.PadRight(width)}{detail}");
    }

    private string JumpHint(string place) => Bash ? $"cd \"$(hob path {place})\"" : $"hob to {place}";
    private static string Verb(bool printOnly) => printOnly ? "hob path" : "hob to";

    private int Print(string text)
    {
        stdout.WriteLine(text);
        return 0;
    }

    private int Fail(string message, int code = 1)
    {
        stderr.WriteLine($"hob: {message}");
        return code;
    }
}
