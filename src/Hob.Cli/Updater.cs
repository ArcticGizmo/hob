using System.Reflection;
using Velopack;
using Velopack.Sources;

namespace Hob.Cli;

internal static class AppInfo
{
    public static readonly string Version =
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "unknown";
}

internal static class Updater
{
    public static async Task<int> Run(bool checkOnly)
    {
        string repo = Assembly.GetExecutingAssembly().GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "RepositoryUrl")?.Value ?? "https://github.com/ArcticGizmo/hob";
        var manager = new UpdateManager(new GithubSource(repo, accessToken: null, prerelease: false));
        if (!manager.IsInstalled)
        {
            Console.Error.WriteLine("hob: this copy isn't an installed release, so it can't update itself. Update a checkout with git pull and build\\dev.ps1.");
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
}
