namespace Hob.Cli;

/// <summary>
/// What install, update and uninstall do. Velopack runs these in <c>hob-cli.exe</c> with no console and a
/// 15-30 s budget, so they do the minimum directly and never start another process: an installer launching
/// PowerShell is the kind of chain endpoint security watches for. <c>hob-cli setup</c> runs the same steps by hand.
/// </summary>
internal static class Hooks
{
    /// <summary>
    /// Writes every command (hob, the short name, plugin shortcuts) and the index, and puts the command folder on
    /// the user PATH. The install folder is stable across updates, so the commands keep pointing at the right files.
    /// </summary>
    public static IEnumerable<string> Apply(HobPaths paths)
    {
        var model = Model.Load(paths);
        var warnings = new StringWriter();
        HobIndex.Refresh(model, warnings, force: true);
        var commands = Directory.GetFiles(paths.BinDir, "*.ps1").Select(Path.GetFileNameWithoutExtension).Order();
        yield return $"wrote {string.Join(", ", commands)} in {paths.BinDir}";
        foreach (string line in warnings.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)) yield return line;

        yield return UserPath.Edit(paths.PathKey, paths.BinDir, remove: false, BackupDir(paths))
            ? $"added {paths.BinDir} to your user PATH"
            : $"{paths.BinDir} is already on your user PATH";
    }

    /// <summary>
    /// Takes the command folder off the user PATH and deletes the generated files. Settings, places, your plugins
    /// and your jump history stay, so a reinstall picks up where you left off.
    /// </summary>
    public static IEnumerable<string> Remove(HobPaths paths)
    {
        yield return UserPath.Edit(paths.PathKey, paths.BinDir, remove: true, BackupDir(paths))
            ? $"removed {paths.BinDir} from your user PATH"
            : $"{paths.BinDir} was not on your user PATH";

        if (Directory.Exists(paths.BinDir))
        {
            Directory.Delete(paths.BinDir, recursive: true);
            yield return $"deleted {paths.BinDir}";
        }
        if (File.Exists(paths.IndexFile))
        {
            File.Delete(paths.IndexFile);
            yield return $"deleted {paths.IndexFile}";
        }
    }

    /// <summary>Runs a hook where nobody can see its output, recording the result for later diagnosis.</summary>
    public static void RunUnattended(string hook, Func<HobPaths, IEnumerable<string>> steps)
    {
        var paths = HobPaths.FromEnvironment();
        var log = new List<string> { $"{DateTime.Now:O} {hook}" };
        try
        {
            log.AddRange(steps(paths));
        }
        catch (Exception ex)
        {
            log.Add($"failed: {ex.Message}. Run hob-cli setup to retry.");
        }
        try
        {
            Directory.CreateDirectory(paths.DataDir);
            File.AppendAllLines(Path.Combine(paths.DataDir, "hob-cli.log"), log);
        }
        catch (IOException)
        {
            // Nowhere left to report to; setup can be rerun by hand.
        }
    }

    private static string BackupDir(HobPaths paths) => Path.Combine(paths.DataDir, "path-backups");
}
