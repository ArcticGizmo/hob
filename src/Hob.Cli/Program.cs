using System.Reflection;
using Hob.Cli;
using Velopack;
using Velopack.Sources;

// Velopack starts this exe with hook arguments during install, update and uninstall, runs the matching
// callback and exits, so this has to come before anything else.
VelopackApp.Build()
    .OnAfterInstallFastCallback(_ => Hooks.RunUnattended("install", Hooks.Apply))
    .OnAfterUpdateFastCallback(_ => Hooks.RunUnattended("update", Hooks.Apply))
    .OnBeforeUninstallFastCallback(_ => Hooks.RunUnattended("uninstall", Hooks.Remove))
    .Run();

string command = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
string[] rest = args.Skip(1).ToArray();

try
{
    return command switch
    {
        "setup" => Setup(rest.Contains("--undo")),
        "update" => await Update(rest.Contains("--check")),
        "version" or "--version" => Print(Version()),
        _ => Help(),
    };
}
catch (Exception ex)
{
    Console.Error.WriteLine($"hob-cli: {ex.Message}");
    return 1;
}

static int Setup(bool undo)
{
    var paths = HobPaths.FromEnvironment();
    foreach (string step in undo ? Hooks.Remove(paths) : Hooks.Apply(paths)) Console.WriteLine(step);
    if (!undo) Console.WriteLine("Open a new terminal to pick up the PATH change.");
    return 0;
}

static async Task<int> Update(bool checkOnly)
{
    string repo = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == "RepositoryUrl")?.Value ?? "https://github.com/ArcticGizmo/hob";
    var manager = new UpdateManager(new GithubSource(repo, accessToken: null, prerelease: false));
    if (!manager.IsInstalled)
    {
        Console.Error.WriteLine("hob-cli: this copy isn't a Velopack install, so it can't update itself.");
        return 1;
    }

    string current = manager.CurrentVersion?.ToString() ?? "unknown";
    var update = await manager.CheckForUpdatesAsync();
    if (update is null)
    {
        Console.WriteLine($"hob {current} is up to date.");
        return 0;
    }

    string next = update.TargetFullRelease.Version.ToString();
    if (checkOnly)
    {
        Console.WriteLine($"Update available: {current} -> {next}. Run hob update to install it.");
        return 0;
    }

    Console.Write($"Downloading {next}... ");
    await manager.DownloadUpdatesAsync(update);
    Console.WriteLine("done.");
    // Velopack's updater waits for this process to exit, swaps the install in place and runs the update hook.
    manager.WaitExitThenApplyUpdates(update.TargetFullRelease, silent: true, restart: false);
    Console.WriteLine($"Updating hob {current} -> {next}. It finishes as this command exits; new terminals get the new version.");
    return 0;
}

static string Version() =>
    Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";

static int Print(string text)
{
    Console.WriteLine(text);
    return 0;
}

static int Help()
{
    Console.WriteLine($"""
        hob-cli {Version()}: installs and updates hob. Use hob itself for everything else.

          hob-cli setup           put hob's commands on your user PATH (install does this for you)
          hob-cli setup --undo    take them off again (uninstall does this for you)
          hob-cli update          update to the latest release
          hob-cli update --check  only report whether an update is available
          hob-cli version         print the installed version
        """);
    return 0;
}
