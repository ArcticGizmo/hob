namespace Hob.Cli.Tests;

public sealed class HobCommandTests : IDisposable
{
    private readonly TempHob _hob = new();

    public void Dispose() => _hob.Dispose();

    [Fact]
    public async Task Empty_words_show_the_overview_rather_than_an_ambiguity()
    {
        Assert.Equal(0, await _hob.Command().Run([""]));
        Assert.Contains("Commands", _hob.Out.ToString());
        Assert.Equal("", _hob.Err.ToString());
    }

    [Fact]
    public async Task Overview_lists_to_and_cd_on_one_line()
    {
        await _hob.Run();
        var lines = _hob.Out.ToString().Split('\n');
        Assert.Single(lines, l => l.TrimStart().StartsWith("to, cd <place>"));
        Assert.DoesNotContain(lines, l => l.TrimStart().StartsWith("cd "));
    }

    [Theory]
    [InlineData("--version")]
    [InlineData("-v")]
    public async Task Version_flags_print_the_version(string flag)
    {
        Assert.Equal(0, await _hob.Run(flag));
        Assert.Equal($"hob {AppInfo.Version}", _hob.Out.ToString().Trim());
    }

    [Theory]
    [InlineData("list")]
    [InlineData("naive")]
    [InlineData("nav")]
    public async Task Removed_commands_are_unknown(string word)
    {
        Assert.Equal(1, await _hob.Run(word));
        Assert.Contains("is not something hob knows", _hob.Err.ToString());
    }

    [Fact]
    public async Task Seeded_places_can_be_removed_and_stay_removed()
    {
        await _hob.Run("to", "--rm", "downloads");
        Assert.Equal(1, await _hob.Run("to", "downloads"));
        Assert.DoesNotContain("downloads", File.ReadAllText(_hob.Paths.PlacesFile));
    }

    [Fact]
    public async Task Add_defaults_to_the_current_folder_and_updates_an_existing_name()
    {
        Assert.Equal(0, await _hob.Run("to", "--add", "work"));
        Assert.Contains($"added work: {_hob.Root}", _hob.Out.ToString());

        string other = _hob.Folder("other");
        Assert.Equal(0, await _hob.Run("to", "--add", "work", other));
        Assert.Contains($"updated work: {_hob.Root} -> {other}", _hob.Out.ToString());

        Assert.Equal(0, await _hob.Run("to", "work"));
        Assert.Equal($"cd {other}\n", _hob.DirectiveText);
    }

    [Theory]
    [InlineData("bad/name")]
    [InlineData("-dash")]
    [InlineData("two words")]
    public async Task Add_rejects_names_that_cannot_be_typed_back(string name)
    {
        Assert.Equal(1, await _hob.Run("to", "--add", name, _hob.Root));
    }

    [Fact]
    public async Task Add_rejects_a_missing_folder()
    {
        Assert.Equal(1, await _hob.Run("to", "--add", "x", Path.Combine(_hob.Root, "nope")));
        Assert.Contains("is not a folder", _hob.Err.ToString());
    }

    [Fact]
    public async Task Remove_explains_where_a_plugin_place_comes_from()
    {
        _hob.Plugin("work", $$"""{ "name": "work", "locations": { "api": "{{_hob.Folder("api").Replace("\\", "/")}}" } }""");
        Assert.Equal(1, await _hob.Run("to", "--rm", "api"));
        Assert.Contains("comes from the work plugin", _hob.Err.ToString());
    }

    [Fact]
    public async Task Bash_gets_posix_paths_and_cd_hints()
    {
        string folder = _hob.Folder("b");
        await _hob.Run("to", "--add", "b", folder);

        var command = _hob.Command("bash");
        Assert.Equal(0, await command.Run(["path", "b"]));
        Assert.StartsWith("/", _hob.Out.ToString().Split('\n')[^2]);

        Assert.Equal(2, await _hob.Command("bash").Run(["to", "b"]));
        Assert.Contains("cd \"$(hob path b)\"", _hob.Err.ToString());
    }

    [Fact]
    public async Task Ambiguous_place_without_a_console_lists_the_candidates()
    {
        Assert.Equal(1, await _hob.Run("to", "d"));
        Assert.Contains("'d' could be: docs, downloads", _hob.Err.ToString());
    }

    [Fact]
    public async Task Picker_chooses_a_place_and_records_the_row()
    {
        string a = _hob.Folder("alpha"), b = _hob.Folder("beta");
        await _hob.Run("to", "--add", "alpha", a);
        await _hob.Run("to", "--add", "beta", b);
        File.WriteAllText(_hob.Directives, "");

        var term = new FakeTerminal(Key('b'), Key('e'), new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        Assert.Equal(0, await _hob.Command(terminal: term).Run(["to"]));
        Assert.Equal($"cd {b}\n", _hob.DirectiveText);
        Assert.Contains($"\tpicker\t{b}\t0\tbe", File.ReadAllText(_hob.Paths.HistoryFile));
    }

    [Fact]
    public async Task Picker_escape_moves_nothing()
    {
        var term = new FakeTerminal(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
        Assert.Equal(1, await _hob.Command(terminal: term).Run(["to"]));
        Assert.Equal("", _hob.DirectiveText);
    }

    [Fact]
    public async Task Plugin_root_and_location_jump()
    {
        string root = _hob.Folder("proj");
        Directory.CreateDirectory(Path.Combine(root, "api"));
        _hob.Plugin("work", $$"""{ "name": "work", "root": "{{root.Replace("\\", "/")}}", "locations": { "api": "api" } }""");

        Assert.Equal(0, await _hob.Run("work"));
        Assert.Equal($"cd {root}\n", _hob.DirectiveText);
        Assert.Equal(0, await _hob.Run("wo", "a"));
        Assert.Equal($"cd {Path.Combine(root, "api")}\n", _hob.DirectiveText);
    }

    [Fact]
    public async Task A_plugin_named_like_a_builtin_is_ignored()
    {
        _hob.Plugin("to", """{ "name": "to" }""");
        await _hob.Run();
        Assert.Contains("is a built-in command", _hob.Err.ToString());
    }

    [Fact]
    public async Task A_place_typed_as_a_command_suggests_to()
    {
        Assert.Equal(1, await _hob.Run("docs"));
        Assert.Contains("Did you mean 'hob to docs'?", _hob.Err.ToString());
    }

    private static ConsoleKeyInfo Key(char c) => new(c, ConsoleKey.A + (char.ToUpperInvariant(c) - 'A'), false, false, false);

    private sealed class FakeTerminal(params ConsoleKeyInfo[] keys) : ITerminal
    {
        private readonly Queue<ConsoleKeyInfo> _keys = new(keys);
        public int Width => 100;
        public int Height => 30;
        public void Write(string text) { }
        public ConsoleKeyInfo ReadKey() => _keys.Dequeue();
        public void Dispose() { }
    }
}
