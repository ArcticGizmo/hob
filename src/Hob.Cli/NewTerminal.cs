using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Hob.Cli;

/// <summary>
/// Opens another shell already in a folder, for Ctrl+Enter in the picker, and leaves the current one where it is.
/// Inside Windows Terminal it opens a Windows Terminal window or a tab in the current one; anywhere else, a
/// console window of its own. It starts the program that ran hob, so PowerShell 7 opens PowerShell 7 rather than
/// whatever is the default.
/// </summary>
internal static partial class NewTerminal
{
    private static readonly string[] Shells = ["pwsh.exe", "powershell.exe", "cmd.exe"];

    public static bool HasTabs => HobPaths.Env("WT_SESSION") is not null;

    /// <returns>Null once the new shell has started, otherwise why it could not.</returns>
    public static string? Start(string folder, string shell, bool tab)
    {
        string program = ShellProgram(shell);
        // These belong to this one call; inherited, they would point the new shell at a directives file that is
        // about to be deleted.
        foreach (string name in (string[])["HOB_DIRECTIVES", "HOB_SHELL", "HOB_PLUGIN_DIR"]) Environment.SetEnvironmentVariable(name, null);

        // You just pressed Ctrl+Enter, so whatever has focus is the terminal the picker is in.
        nint home = GetForegroundWindow();
        var attempts = new List<ProcessStartInfo>();
        if (HasTabs) attempts.Add(WindowsTerminal(folder, program, tab));
        // Shell-executing a console program is what gives it a console of its own instead of sharing this one.
        attempts.Add(new ProcessStartInfo(program) { UseShellExecute = true, WorkingDirectory = folder });

        string error = "";
        foreach (var info in attempts)
        {
            try
            {
                Process.Start(info)?.Dispose();
                // A tab lives in the same window, so taking focus back would not switch back to your tab anyway.
                if (!tab) TakeFocusBack(home);
                return null;
            }
            catch (Win32Exception e) { error = e.Message; }
        }
        return $"could not open a new terminal in {folder}: {error}";
    }

    private static ProcessStartInfo WindowsTerminal(string folder, string program, bool tab)
    {
        // wt splits its command line into subcommands at every unescaped ';'.
        static string Escape(string arg) => arg.Replace(";", "\\;");
        // Window 0 is the one you are typing in; "new" always makes another.
        return new ProcessStartInfo("wt.exe") { UseShellExecute = false, ArgumentList = { "-w", tab ? "0" : "new", "new-tab", "-d", Escape(folder), Escape(program) } };
    }

    /// <summary>
    /// Waits for the new window to take focus, then gives it back to <paramref name="home"/>, so you stay in the
    /// picker to open the next place. Windows only lets the program that has focus hand it on, so this borrows
    /// the new window's input queue for the moment it takes. A window still starting up can grab focus a second
    /// time, hence the second look.
    /// </summary>
    private static void TakeFocusBack(nint home)
    {
        if (home == 0) return;
        foreach (int waitMs in (int[])[3000, 750])
        {
            long until = Environment.TickCount64 + waitMs;
            nint now;
            while ((now = GetForegroundWindow()) == home || now == 0)
            {
                if (Environment.TickCount64 > until) return;
                Thread.Sleep(20);
            }
            uint self = GetCurrentThreadId(), owner = GetWindowThreadProcessId(now, out _);
            bool attached = owner != 0 && owner != self && AttachThreadInput(self, owner, true);
            try { SetForegroundWindow(home); }
            finally { if (attached) AttachThreadInput(self, owner, false); }
        }
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

    [LibraryImport("user32.dll")]
    private static partial nint GetForegroundWindow();

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint window);

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(nint window, out uint processId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AttachThreadInput(uint attach, uint attachTo, [MarshalAs(UnmanagedType.Bool)] bool doAttach);

    [LibraryImport("kernel32.dll")]
    private static partial uint GetCurrentThreadId();
}
