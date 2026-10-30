namespace Hob.Cli.Tests;

public sealed class ModelTests : IDisposable
{
    private readonly TempHob _hob = new();

    public void Dispose() => _hob.Dispose();

    [Fact]
    public void Places_are_seeded_once()
    {
        var model = Model.Load(_hob.Paths);
        Assert.Equal(["home", "docs", "downloads", "git", "temp"], model.Places.Select(p => p.Name));

        PlaceStore.Save(_hob.Paths.PlacesFile, []);
        Assert.Empty(Model.Load(_hob.Paths).Places);
    }

    [Fact]
    public void Your_own_place_wins_an_exact_tie_with_a_plugin_place()
    {
        string docs = _hob.Folder("pdocs");
        _hob.Plugin("work", $$"""{ "name": "work", "locations": { "docs": "{{docs.Replace("\\", "/")}}" } }""");
        var model = Model.Load(_hob.Paths);

        var match = Matcher.FindPlace(model, ["docs"]);
        Assert.Null(match.Entry!.Plugin);
        Assert.Equal(docs, Matcher.FindPlace(model, ["work", "docs"]).Entry!.Path);
        Assert.Equal("work docs", model.Places.Single(p => p.Plugin is not null).Completion);
    }

    [Fact]
    public void A_unique_prefix_matches_and_a_shared_one_does_not()
    {
        var model = Model.Load(_hob.Paths);
        Assert.Equal("downloads", Matcher.FindPlace(model, ["dow"]).Entry!.Name);
        var shared = Matcher.FindPlace(model, ["d"]);
        Assert.Null(shared.Entry);
        Assert.Equal(2, shared.Candidates.Count);
    }

    [Fact]
    public void Broken_settings_fall_back_to_defaults_with_a_warning()
    {
        Directory.CreateDirectory(_hob.Paths.DataDir);
        File.WriteAllText(_hob.Paths.SettingsFile, "{ nope");
        var model = Model.Load(_hob.Paths);
        Assert.Equal("hb", model.Settings.Alias);
        Assert.Contains(model.Warnings, w => w.Contains("not valid JSON"));
    }

    [Fact]
    public void Plugin_folder_is_a_root()
    {
        _hob.Plugin("self", """{ "name": "self", "root": "{plugin}" }""");
        var plugin = Model.Load(_hob.Paths).Plugins.Single();
        Assert.Equal(plugin.Dir, plugin.Root);
    }

    [Fact]
    public void Index_holds_every_spelling_the_wrappers_may_answer()
    {
        string root = _hob.Folder("proj");
        _hob.Plugin("work", $$"""
            { "name": "work", "root": "{{root.Replace("\\", "/")}}", "locations": { "api": "." },
              "commands": { "build": { "run": ["{plugin}\\build.cmd"] }, "multi": { "run": ["node", "x.js"] } } }
            """);
        var model = Model.Load(_hob.Paths);
        var lines = HobIndex.Render(model).Split('\n');

        Assert.StartsWith(HobIndex.FormatHeader + " ", lines[0]);
        Assert.Contains("to|dow|" + model.Roots["home"] + "\\Downloads", lines);
        Assert.DoesNotContain(lines, l => l.StartsWith("to|d|"));
        Assert.Contains($"to|w a|{root}", lines);
        Assert.Contains($"go|work|{root}", lines);
        Assert.Contains(lines, l => l.StartsWith("run|work build|") && l.EndsWith("|" + model.Plugins[0].Dir));
        // A command with arguments in `run` cannot be split by cmd, so the exe runs it.
        Assert.DoesNotContain(lines, l => l.StartsWith("run|work multi|"));
    }

    [Fact]
    public void Index_is_stale_once_places_change()
    {
        var model = Model.Load(_hob.Paths);
        HobIndex.Refresh(model, TextWriter.Null);
        Assert.True(HobIndex.IsCurrent(model));

        File.SetLastWriteTimeUtc(_hob.Paths.PlacesFile, DateTime.UtcNow.AddMinutes(1));
        Assert.False(HobIndex.IsCurrent(Model.Load(_hob.Paths)));
    }

    [Fact]
    public void Bin_writes_a_shortcut_per_plugin_and_removes_old_ones()
    {
        _hob.Plugin("zzhobtest", """{ "name": "zzhobtest" }""");
        HobIndex.Refresh(Model.Load(_hob.Paths), TextWriter.Null, force: true);
        Assert.True(File.Exists(Path.Combine(_hob.Paths.BinDir, "zzhobtest.ps1")));

        Directory.Delete(Path.Combine(_hob.Paths.UserPluginsDir, "zzhobtest"), recursive: true);
        HobIndex.Refresh(Model.Load(_hob.Paths), TextWriter.Null, force: true);
        Assert.False(File.Exists(Path.Combine(_hob.Paths.BinDir, "zzhobtest.ps1")));
        Assert.True(File.Exists(Path.Combine(_hob.Paths.BinDir, "hob.ps1")));
    }

    [Theory]
    [InlineData("h")]
    [InlineData("cd")]
    [InlineData("if")]
    public void Names_PowerShell_or_cmd_resolve_first_are_taken(string name) => Assert.True(Bin.IsTaken(name, _hob.Paths.BinDir));
}
