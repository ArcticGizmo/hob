namespace Hob.Cli;

/// <summary>
/// What install, update and uninstall do. Velopack runs these in <c>hob-cli.exe</c> with no console and a
/// 15-30 s budget, so they do the minimum directly and never start another process: an installer launching
/// PowerShell is the kind of chain endpoint security watches for. <c>hob-cli setup</c> runs the same steps by hand.
/// </summary>
internal static class Hooks
{
    /// <summary>
    /// Writes <c>hob</c> and the short name, and puts the command folder on the user PATH. Plugin shortcuts depend
    /// on the plugins, which only the module reads, so the index is removed instead: the next hob in any shell
    /// rebuilds it and writes them. The install folder is stable across updates, so the commands keep pointing
    /// at the right files without being rewritten.
    /// </summary>
    public static IEnumerable<string> Apply(HobPaths paths)
    {
        Shims.Write(paths, "hob", "");
        yield return $"wrote hob in {paths.BinDir}";

        string alias = paths.Alias();
        if (alias.Length > 0 && !alias.Equals("hob", StringComparison.OrdinalIgnoreCase))
        {
            Shims.Write(paths, alias, "");
            yield return $"wrote {alias}";
        }

        if (File.Exists(paths.IndexFile))
        {
            File.Delete(paths.IndexFile);
            yield return "plugin shortcuts will be rebuilt the next time hob runs";
        }

        yield return UserPath.Edit(paths.PathKey, paths.BinDir, remove: false, BackupDir(paths))
            ? $"added {paths.BinDir} to your user PATH"
            : $"{paths.BinDir} is already on your user PATH";
    }

    /// <summary>
    /// Takes the command folder off the user PATH and deletes the generated files. Settings, your plugins and
    /// your jump history stay, so a reinstall picks up where you left off.
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
