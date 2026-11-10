using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Hob.Cli;

/// <summary>
/// Opens another shell already in a folder, for Ctrl+Enter in the picker, and leaves the current one where it is.
/// Inside Windows Terminal it becomes a tab in the same window; anywhere else it gets its own console window. It
/// starts the program that ran hob, so PowerShell 7 opens PowerShell 7 rather than whatever is the default.
/// </summary>
internal static partial class NewTerminal
{
    private static readonly string[] Shells = ["pwsh.exe", "powershell.exe", "cmd.exe"];

    /// <returns>Null once the new shell has started, otherwise why it could not.</returns>
    public static string? Start(string folder, string shell)
    {
        string program = ShellProgram(shell);
        // These belong to this one call; inherited, they would point the new shell at a directives file that is
        // about to be deleted.
        foreach (string name in (string[])["HOB_DIRECTIVES", "HOB_SHELL", "HOB_PLUGIN_DIR"]) Environment.SetEnvironmentVariable(name, null);

        var attempts = new List<ProcessStartInfo>();
        if (HobPaths.Env("WT_SESSION") is not null) attempts.Add(WindowsTerminalTab(folder, program));
        // Shell-executing a console program is what gives it a console of its own instead of sharing this one.
        attempts.Add(new ProcessStartInfo(program) { UseShellExecute = true, WorkingDirectory = folder });

        string error = "";
        foreach (var info in attempts)
        {
            try
            {
                Process.Start(info)?.Dispose();
                return null;
            }
            catch (Win32Exception e) { error = e.Message; }
        }
        return $"could not open a new terminal in {folder}: {error}";
    }

    private static ProcessStartInfo WindowsTerminalTab(string folder, string program)
    {
        // wt splits its command line into subcommands at every unescaped ';'.
        static string Escape(string arg) => arg.Replace(";", "\\;");
        return new ProcessStartInfo("wt.exe") { UseShellExecute = false, ArgumentList = { "-w", "0", "new-tab", "-d", Escape(folder), Escape(program) } };
    }

    private static string ShellProgram(string shell)
    {
        string? parent = ParentImage();
        if (parent is not null && Shells.Contains(Path.GetFileName(parent), StringComparer.OrdinalIgnoreCase)) return parent;
        return shell == "cmd" ? "cmd.exe" : "powershell.exe";
    }

    private static string? ParentImage()
    {
        if (NtQueryInformationProcess(-1, 0, out var info, Marshal.SizeOf<BasicInfo>(), out _) != 0) return null;
        try
        {
            using var parent = Process.GetProcessById((int)info.InheritedFromUniqueProcessId);
            return parent.MainModule?.FileName;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception)
        {
            return null;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicInfo { public nint ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId; }

    [LibraryImport("ntdll.dll")]
    private static partial int NtQueryInformationProcess(nint process, int infoClass, out BasicInfo info, int length, out int returned);
}
