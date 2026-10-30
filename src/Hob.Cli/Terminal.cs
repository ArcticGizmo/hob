using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Hob.Cli;

internal interface ITerminal : IDisposable
{
    int Width { get; }
    int Height { get; }
    void Write(string text);
    ConsoleKeyInfo ReadKey();
}

/// <summary>
/// Draws straight onto the console through <c>CONOUT$</c> with VT sequences, never on stdout, so the picker
/// still works inside <c>cd "$(hob places d)"</c> and <c>for /f</c>, where stdout is captured. Keys come from
/// stdin, which is the console in every shell that can show the picker.
/// </summary>
internal sealed partial class ConsoleTerminal : ITerminal
{
    private const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, ShareReadWrite = 3, OpenExisting = 3;
    private const uint VirtualTerminalProcessing = 0x0004;

    private readonly SafeFileHandle _out;
    private readonly uint _mode;
    private readonly bool _treatControlC;

    private ConsoleTerminal(SafeFileHandle handle, uint mode)
    {
        _out = handle;
        _mode = mode;
        SetConsoleMode(_out, mode | VirtualTerminalProcessing | 1);
        _treatControlC = Console.TreatControlCAsInput;
        Console.TreatControlCAsInput = true;
    }

    /// <summary>Null when there is no console to draw on or read from, such as under mintty or with input piped.</summary>
    public static ConsoleTerminal? TryOpen()
    {
        if (HobPaths.Env("HOB_NO_PICKER") is not null || Console.IsInputRedirected) return null;
        var handle = CreateFileW("CONOUT$", GenericRead | GenericWrite, ShareReadWrite, 0, OpenExisting, 0, 0);
        if (handle.IsInvalid || !GetConsoleMode(handle, out uint mode))
        {
            handle.Dispose();
            return null;
        }
        return new ConsoleTerminal(handle, mode);
    }

    public int Width => Info().Right - Info().Left + 1;
    public int Height => Info().Bottom - Info().Top + 1;

    public void Write(string text) => WriteConsoleW(_out, text, (uint)text.Length, out _, 0);

    public ConsoleKeyInfo ReadKey() => Console.ReadKey(intercept: true);

    public void Dispose()
    {
        Console.TreatControlCAsInput = _treatControlC;
        SetConsoleMode(_out, _mode);
        _out.Dispose();
    }

    private SmallRect Info() => GetConsoleScreenBufferInfo(_out, out var info) ? info.Window : new SmallRect { Right = 79, Bottom = 24 };

    [StructLayout(LayoutKind.Sequential)]
    private struct Coord { public short X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SmallRect { public short Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BufferInfo { public Coord Size, Cursor; public ushort Attributes; public SmallRect Window; public Coord MaxWindow; }

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial SafeFileHandle CreateFileW(string name, uint access, uint share, nint security, uint disposition, uint flags, nint template);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetConsoleMode(SafeFileHandle handle, out uint mode);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetConsoleMode(SafeFileHandle handle, uint mode);

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool WriteConsoleW(SafeFileHandle handle, string text, uint length, out uint written, nint reserved);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetConsoleScreenBufferInfo(SafeFileHandle handle, out BufferInfo info);
}
