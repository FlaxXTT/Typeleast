using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace TypeLeast.Core;

public interface IHistoryProtection
{
    byte[] Protect(byte[] data);
    byte[] Unprotect(byte[] data);
}

/// <summary>Windows DPAPI, current user only. No new package or application key file.</summary>
public sealed class DpapiHistoryProtection : IHistoryProtection
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);

    public byte[] Protect(byte[] data) => Transform(data, true);
    public byte[] Unprotect(byte[] data) => Transform(data, false);
    private static byte[] Transform(byte[] data, bool encrypt)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("History protection requires Windows.");
        var input = new Blob { Length = data.Length, Data = Marshal.AllocHGlobal(Math.Max(1, data.Length)) };
        var output = new Blob();
        try {
            Marshal.Copy(data, 0, input.Data, data.Length);
            // UI_FORBIDDEN only. Never use LOCAL_MACHINE, which lets other users decrypt.
            var ok = encrypt
                ? CryptProtectData(ref input, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new CryptographicException("History protection failed.");
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        } finally {
            Clear(input.Data, input.Length); Marshal.FreeHGlobal(input.Data);
            if (output.Data != IntPtr.Zero) { Clear(output.Data, output.Length); LocalFree(output.Data); }
        }
    }
    private static void Clear(IntPtr pointer, int length)
    {
        var zeros = new byte[Math.Min(length, 4096)];
        for (var offset = 0; offset < length; offset += zeros.Length)
            Marshal.Copy(zeros, 0, IntPtr.Add(pointer, offset), Math.Min(zeros.Length, length - offset));
    }
}
