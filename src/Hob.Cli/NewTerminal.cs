using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

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

    private const uint CreateNewConsole = 0x10, CreateNoWindow = 0x08000000, UseShowWindow = 0x1;
    private const short ShowMinNoActive = 7;

    public static bool HasTabs => HobPaths.Env("WT_SESSION") is not null;

    /// <returns>Null once the new shell has started, otherwise why it could not.</returns>
    public static string? Start(string folder, string shell, bool tab)
    {
        string program = ShellProgram(shell);
        // These belong to this one call; inherited, they would point the new shell at a directives file that is
        // about to be deleted.
        foreach (string name in (string[])["HOB_DIRECTIVES", "HOB_SHELL", "HOB_PLUGIN_DIR"]) Environment.SetEnvironmentVariable(name, null);

        // A window opens minimized and without focus, so you stay in the picker to open the next one. A tab
        // cannot: asking wt for that would minimize the window you are typing in.
        if (HasTabs && Launch(WindowsTerminal(folder, program, tab), null, CreateNoWindow, background: !tab) is null) return null;
        // Windows Terminal is missing, or this is not inside it.
        string? error = Launch(Quote(program), folder, CreateNewConsole, background: true);
        return error is null ? null : $"could not open a new terminal in {folder}: {error}";
    }

    private static string WindowsTerminal(string folder, string program, bool tab)
    {
        // wt splits its command line into subcommands at every unescaped ';'.
        static string Escape(string arg) => Quote(arg.Replace(";", "\\;"));
        // Window 0 is the one you are typing in; "new" always makes another.
        return $"wt.exe -w {(tab ? "0" : "new")} new-tab -d {Escape(folder)} {Escape(program)}";
    }

    /// <summary>
    /// CreateProcess rather than Process.Start, which has no way to ask for a window that does not take focus.
    /// </summary>
    private static unsafe string? Launch(string commandLine, string? directory, uint flags, bool background)
    {
        var startup = new StartupInfo { Size = sizeof(StartupInfo) };
        if (background)
        {
            startup.Flags = UseShowWindow;
            startup.ShowWindow = ShowMinNoActive;
        }
        // CreateProcessW may write into the command line, so it needs its own buffer.
        char[] buffer = (commandLine + '\0').ToCharArray();
        fixed (char* line = buffer)
        fixed (char* dir = directory)
        {
            if (!CreateProcessW(null, line, 0, 0, false, flags, 0, dir, &startup, out var info))
                return new Win32Exception(Marshal.GetLastPInvokeError()).Message;
            CloseHandle(info.Process);
            CloseHandle(info.Thread);
        }
        return null;
    }

    /// <summary>The quoting CommandLineToArgvW undoes: backslashes only escape when they come before a quote.</summary>
    private static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny([' ', '\t', '"']) < 0) return arg;
        var text = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { slashes++; continue; }
            text.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c);
            slashes = 0;
        }
        return text.Append('\\', slashes * 2).Append('"').ToString();
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

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public nint Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute;
        public uint Flags;
        public short ShowWindow, Reserved2;
        public nint Reserved3, StdInput, StdOutput, StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public nint Process, Thread; public int ProcessId, ThreadId; }

    [LibraryImport("ntdll.dll")]
    private static partial int NtQueryInformationProcess(nint process, int infoClass, out BasicInfo info, int length, out int returned);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool CreateProcessW(char* application, char* commandLine, nint processAttributes, nint threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags, nint environment, char* directory, StartupInfo* startup, out ProcessInfo info);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);
}
