using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32;
using TypeLeast.Core;

namespace TypeLeast;

internal sealed class WindowsCredentials : ICredentialStore
{
    public string? Read(string account) => CredentialStore.Read(account);
    public bool Write(string account, string value) => CredentialStore.Write(account, value);
}

/// <summary>The API key in the Windows Credential Manager, one generic credential per preset.</summary>
internal static class CredentialStore
{
    private const string Prefix = "TypeLeast.llm-api-key/";

    public static string? Read(string account)
    {
        if (!Native.CredReadW(Prefix + account, Native.CRED_TYPE_GENERIC, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<Native.CREDENTIAL>(ptr);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            var text = Encoding.UTF8.GetString(bytes);
            return text.Length > 0 ? text : null;
        }
        finally
        {
            Native.CredFree(ptr);
        }
    }

    /// <summary>Store the key; an empty value deletes it.</summary>
    public static bool Write(string account, string value)
    {
        value = value.Trim();
        if (value.Length == 0)
        {
            Native.CredDeleteW(Prefix + account, Native.CRED_TYPE_GENERIC, 0);
            return true;
        }
        var bytes = Encoding.UTF8.GetBytes(value);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var cred = new Native.CREDENTIAL
            {
                Type = Native.CRED_TYPE_GENERIC,
                TargetName = Prefix + account,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = Native.CRED_PERSIST_LOCAL_MACHINE,
                UserName = "TypeLeast",
            };
            return Native.CredWriteW(ref cred, 0);
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }
}

/// <summary>Start with Windows: the per-user Run key, no administrator rights.</summary>
internal static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    // Where Windows records that the user switched a startup app off (Task Manager, Settings → Startup).
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string Name = "TypeLeast";

    public static void Apply(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on && Environment.ProcessPath is { } exe)
            {
                key.SetValue(Name, AutostartEntry.Command(exe));
                // Turned on here after being switched off in Windows: without this Windows keeps skipping it.
                using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
                approved?.DeleteValue(Name, throwOnMissingValue: false);
            }
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch (Exception e)
        {
            Log.Write("autostart.fail", e.GetType().Name);
        }
    }

    /// <summary>Whether Windows will start TypeLeast at login: the Run value exists and the user has
    /// not switched it off in Windows. A value whose program is gone (a moved portable copy) is
    /// pointed at this copy. Null when the registry cannot be read.</summary>
    public static bool? Check()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            if (key?.GetValue(Name) is not string value) return false;
            using (var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey))
                if (AutostartEntry.SwitchedOff(approved?.GetValue(Name) as byte[])) return false;
            if (AutostartEntry.ExePath(value) is not { } exe || !File.Exists(exe)) Apply(true);
            return true;
        }
        catch (Exception e)
        {
            Log.Write("autostart.fail", e.GetType().Name);
            return null;
        }
    }
}

/// <summary>A small local log of events and error codes; never dictated text or keys.</summary>
internal static class Log
{
    private static readonly object Gate = new();

    public static void Write(string evt, string detail = "")
    {
        try
        {
            var path = AppPaths.LogFile();
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) File.Move(path, path + ".1", overwrite: true);
                File.AppendAllText(path, DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") + " " + evt
                    + (detail.Length > 0 ? " " + detail.Replace('\n', ' ') : "") + Environment.NewLine);
            }
        }
        catch (IOException)
        {
        }
    }
}

/// <summary>Opening links and folders with the shell.</summary>
internal static class Shell
{
    public static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("shell.open.fail", e.GetType().Name); }
    }

    /// <summary>The executable name of the window's process, e.g. "notepad.exe".</summary>
    public static string ProcessName(IntPtr hwnd)
    {
        try
        {
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == 0) return "";
            using var p = Process.GetProcessById((int)pid);
            return p.ProcessName + ".exe";
        }
        catch (Exception)
        {
            return "";
        }
    }

    public static Task Delay(int ms) => Task.Delay(ms);
}
