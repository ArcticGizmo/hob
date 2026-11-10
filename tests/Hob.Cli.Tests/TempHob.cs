namespace Hob.Cli.Tests;

/// <summary>A scratch install folder (with the real templates) and data folder, deleted afterwards.</summary>
internal sealed class TempHob : IDisposable
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "hob-test-" + Guid.NewGuid().ToString("N")[..8]);
    public HobPaths Paths { get; }
    public string Directives { get; }
    public StringWriter Out { get; } = new();
    public StringWriter Err { get; } = new();

    public TempHob()
    {
        string app = Path.Combine(Root, "app");
        Directory.CreateDirectory(Path.Combine(app, "templates"));
        foreach (string file in Directory.GetFiles(Path.Combine(RepoRoot(), "shell", "templates"), "shim.*"))
            File.Copy(file, Path.Combine(app, "templates", Path.GetFileName(file)));
        Paths = new HobPaths(app, Path.Combine(Root, "data"), "Software\\hob-unit-test");
        Directives = Path.Combine(Root, "directives.txt");
        File.WriteAllText(Directives, "");
    }

    public string Folder(string relative)
    {
        string path = Path.Combine(Root, relative);
        Directory.CreateDirectory(path);
        return path;
    }

    public void Plugin(string name, string json)
    {
        string dir = Path.Combine(Paths.UserPluginsDir, name);
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "plugin.json"), json);
    }

    /// <summary>Every (folder, shell) a command asked to open a new terminal in; none is really opened.</summary>
    public List<(string Folder, string Shell)> Started { get; } = [];

    public HobCommand Command(string shell = "powershell", ITerminal? terminal = null, string? startError = null) =>
        new(Paths, Out, Err)
        {
            Shell = shell, DirectivesFile = Directives, CurrentDirectory = Root, OpenTerminal = () => terminal, Update = _ => Task.FromResult(0),
            StartTerminal = (folder, s) => { Started.Add((folder, s)); return startError; },
        };

    public async Task<int> Run(params string[] words)
    {
        Out.GetStringBuilder().Clear();
        Err.GetStringBuilder().Clear();
        File.WriteAllText(Directives, "");
        return await Command().Run(words);
    }

    public string DirectiveText => File.ReadAllText(Directives);

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !Directory.Exists(Path.Combine(dir.FullName, "shell", "templates"))) dir = dir.Parent;
        return dir?.FullName ?? throw new InvalidOperationException("repository root not found");
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); }
        catch (IOException) { }
    }
}
