using System.Text;

namespace Hob.Cli;

/// <summary>
/// Renders the command templates in the install folder exactly as <c>hob.psm1</c>'s Write-HobBin does
/// (templates\README.md has the rules), so whichever last wrote a command, the other sees identical content.
/// </summary>
internal static class Shims
{
    public static void Write(HobPaths paths, string name, string prefix)
    {
        var values = new Dictionary<string, string>
        {
            ["{{PSM1}}"] = Path.Combine(paths.AppDir, "hob.psm1").Replace("'", "''"),
            ["{{CMD}}"] = Path.Combine(paths.AppDir, "cmd", "hob.cmd"),
            ["{{SH}}"] = GitBashPath(Path.Combine(paths.AppDir, "bash", "hob.sh")).Replace("'", "'\\''"),
            ["{{PREFIX}}"] = prefix,
        };

        Directory.CreateDirectory(paths.BinDir);
        WriteIfChanged(Path.Combine(paths.BinDir, name + ".ps1"), Render(paths, "shim.ps1", values, "\r\n"), new UTF8Encoding(true));
        WriteIfChanged(Path.Combine(paths.BinDir, name + ".cmd"), Render(paths, "shim.cmd", values, "\r\n"), new UTF8Encoding(false));
        WriteIfChanged(Path.Combine(paths.BinDir, name), Render(paths, "shim.sh", values, "\n"), new UTF8Encoding(false));
    }

    private static string Render(HobPaths paths, string template, Dictionary<string, string> values, string newLine)
    {
        string text = File.ReadAllText(Path.Combine(paths.AppDir, "templates", template)).Replace("\r\n", "\n");
        foreach (var (key, value) in values) text = text.Replace(key, value);
        return text.Replace("\n", newLine);
    }

    private static void WriteIfChanged(string path, string text, Encoding encoding)
    {
        if (File.Exists(path) && File.ReadAllText(path) == text) return;
        File.WriteAllText(path, text, encoding);
    }

    private static string GitBashPath(string windowsPath) =>
        windowsPath.Length > 1 && windowsPath[1] == ':'
            ? "/" + char.ToLowerInvariant(windowsPath[0]) + windowsPath[2..].Replace('\\', '/')
            : windowsPath.Replace('\\', '/');
}
