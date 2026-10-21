using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using TypeLeast.Core;

namespace TypeLeast;

/// <summary>
/// A low-level keyboard hook that sees one key tapped on its own (Right Alt by
/// default) and Esc while recording. It only reads key codes; it never records
/// what is typed. The hook runs on the UI thread, which has the message loop it
/// needs, and returns quickly: the actual work is posted, not done here.
/// </summary>
internal sealed class KeyboardHook : IDisposable
{
    private readonly Native.LowLevelKeyboardProc proc;
    private IntPtr handle;
    private readonly TapDetector tap;
    /// <summary>翻译模式's key; null when it is off.</summary>
    private TapDetector? translateTap;

    /// <summary>A clean tap of the dictation key.</summary>
    public event Action? Tapped;
    /// <summary>A clean tap of the translate key.</summary>
    public event Action? TranslateTapped;
    public event Action? PasteLast;
    public string CopyShortcut { get; set; } = "CtrlShiftV";
    private bool copyPressed;
    /// <summary>Esc while <see cref="SwallowEscape"/> is set (recording).</summary>
    public event Action? Escape;
    /// <summary>When true, Esc is consumed instead of reaching the focused app.</summary>
    public bool SwallowEscape { get; set; }

    public KeyboardHook(DictationKey key, DictationKey? translateKey = null)
    {
        tap = new TapDetector(TapDetector.VirtualKey(key));
        SetTranslateKey(translateKey);
        proc = Callback; // keep the delegate alive for as long as the hook is installed
    }

    public void SetKey(DictationKey key)
    {
        tap.TargetVk = TapDetector.VirtualKey(key);
        tap.Reset();
    }

    public void SetTranslateKey(DictationKey? key)
    {
        translateTap = key is { } k ? new TapDetector(TapDetector.VirtualKey(k)) : null;
    }

    public bool Install()
    {
        if (handle != IntPtr.Zero) return true;
        using var module = Process.GetCurrentProcess().MainModule;
        handle = Native.SetWindowsHookExW(Native.WH_KEYBOARD_LL, proc, Native.GetModuleHandleW(module?.ModuleName), 0);
        if (handle == IntPtr.Zero) Log.Write("hook.fail", "error " + Marshal.GetLastWin32Error());
        return handle != IntPtr.Zero;
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
            var message = wParam.ToInt32();
            var isDown = message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
            var injected = (info.flags & Native.LLKHF_INJECTED) != 0;
            var vk = (int)info.vkCode;
            if (!injected && vk == Native.VK_V)
            {
                if (copyPressed)
                {
                    if (!isDown) { copyPressed = false; PasteLast?.Invoke(); }
                    return new IntPtr(1);
                }
                var ctrl = (Native.GetAsyncKeyState(0x11) & 0x8000) != 0;
                var shift = (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
                var alt = (Native.GetAsyncKeyState(0x12) & 0x8000) != 0;
                if (isDown && ctrl && (CopyShortcut == "CtrlShiftV" && shift && !alt || CopyShortcut == "CtrlAltV" && alt && !shift))
                { copyPressed = true; return new IntPtr(1); }
            }

            if (!injected && vk == Native.VK_ESCAPE && SwallowEscape)
            {
                if (isDown) Escape?.Invoke();
                return new IntPtr(1);
            }

            // A lone Alt tap would open the focused window's menu bar and steal the
            // caret; an unassigned key in between makes Windows ignore it.
            if (!injected && isDown && (vk == tap.TargetVk || vk == translateTap?.TargetVk) && vk is 0xA4 or 0xA5)
                Native.SendKeys((Native.VK_MENU_MASK, false), (Native.VK_MENU_MASK, true));

            var now = DateTime.UtcNow;
            if (tap.OnKey(vk, isDown, injected, now)) Tapped?.Invoke();
            if (translateTap?.OnKey(vk, isDown, injected, now) == true) TranslateTapped?.Invoke();
        }
        return Native.CallNextHookEx(handle, nCode, wParam, lParam);
    }

    public void Dispose()
    {
        if (handle != IntPtr.Zero) Native.UnhookWindowsHookEx(handle);
        handle = IntPtr.Zero;
    }
}
