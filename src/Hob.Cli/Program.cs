using Hob.Cli;
using Velopack;

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
        // What the shell wrappers call for everything they cannot answer from the index.
        "hob" => await new HobCommand(HobPaths.FromEnvironment(), Console.Out, Console.Error).Run(rest),
        "index" => Reindex(),
        "setup" => Setup(rest.Contains("--undo")),
        "update" => await Updater.Run(rest.Contains("--check")),
        "version" or "--version" => Print(AppInfo.Version),
        _ => Help(),
    };
}
catch (Exception ex)
{
    Console.Error.WriteLine($"hob: {ex.Message}");
    return 1;
}

// The wrappers call this when the index is missing or older than something it was built from.
static int Reindex()
{
    HobIndex.Refresh(Model.Load(HobPaths.FromEnvironment()), Console.Error);
    return 0;
}

static int Setup(bool undo)
{
    var paths = HobPaths.FromEnvironment();
    foreach (string step in undo ? Hooks.Remove(paths) : Hooks.Apply(paths)) Console.WriteLine(step);
    if (!undo) Console.WriteLine("Open a new terminal to pick up the PATH change.");
    return 0;
}

static int Print(string text)
{
    Console.WriteLine(text);
    return 0;
}

static int Help()
{
    Console.WriteLine($"""
        hob-cli {AppInfo.Version}: installs and updates hob. Use hob itself for everything else.

          hob-cli setup           put hob's commands on your user PATH (install does this for you)
          hob-cli setup --undo    take them off again (uninstall does this for you)
          hob-cli update          update to the latest release
          hob-cli update --check  only report whether an update is available
          hob-cli version         print the installed version
        """);
    return 0;
}
