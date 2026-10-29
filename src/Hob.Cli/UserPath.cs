using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Hob.Cli;

/// <summary>
/// Adds or removes hob's own entry on the user PATH, never the system PATH. Works on the raw registry value:
/// <c>Environment.SetEnvironmentVariable</c> reads PATH expanded and writes it back as a plain string, silently
/// baking in every %VARIABLE% reference. The previous value is saved before each change.
/// </summary>
internal static partial class UserPath
{
    public static bool Edit(string keyPath, string entry, bool remove, string backupDir)
    {
        using var key = Registry.CurrentUser.CreateSubKey(keyPath, writable: true);
        string raw = key.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? "";
        var kind = raw.Length > 0 ? key.GetValueKind("Path") : RegistryValueKind.ExpandString;
        var entries = raw.Split(';', StringSplitOptions.RemoveEmptyEntries).ToList();

        bool Same(string e) => string.Equals(e.TrimEnd('\\'), entry.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
        bool present = entries.Exists(Same);
        if (remove != present) return false;

        Directory.CreateDirectory(backupDir);
        File.WriteAllText(Path.Combine(backupDir, $"path-{DateTime.Now:yyyyMMdd-HHmmss-fff}.txt"), raw);

        if (remove) entries.RemoveAll(Same);
        else entries.Add(entry);
        key.SetValue("Path", string.Join(';', entries), kind);

        if (keyPath == "Environment") BroadcastEnvironmentChange();
        return true;
    }

    // Tells Explorer, and so every terminal started from now on, to re-read the environment.
    private static void BroadcastEnvironmentChange()
    {
        const int HwndBroadcast = 0xffff;
        const uint WmSettingChange = 0x001A;
        const uint SmtoAbortIfHung = 0x0002;
        SendMessageTimeout(HwndBroadcast, WmSettingChange, 0, "Environment", SmtoAbortIfHung, 5000, out _);
    }

    [LibraryImport("user32.dll", EntryPoint = "SendMessageTimeoutW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint SendMessageTimeout(nint hWnd, uint msg, nuint wParam, string lParam, uint flags, uint timeout, out nuint result);
}
