namespace TypeLeast.Core;

/// <summary>
/// Recognises a clean single tap of one key (Right Alt by default), the Windows
/// counterpart of the Mac's single Fn press: down and up within MaxHold, with no
/// other key pressed in between. A held key (AltGr+e, Ctrl+C) is not a tap, and
/// keys the app injected itself are ignored.
/// </summary>
public sealed class TapDetector
{
    public int TargetVk { get; set; }
    public TimeSpan MaxHold { get; set; } = TimeSpan.FromMilliseconds(600);

    private bool down;
    private bool spoiled;
    private DateTime downAt;

    public TapDetector(int targetVk) => TargetVk = targetVk;

    /// <returns>true when this event completes a clean tap.</returns>
    public bool OnKey(int vk, bool isDown, bool injected, DateTime now)
    {
        if (injected) return false;
        if (vk == TargetVk)
        {
            if (isDown)
            {
                if (down) return false; // auto-repeat while held
                down = true;
                spoiled = false;
                downAt = now;
                return false;
            }
            var wasDown = down;
            down = false;
            return wasDown && !spoiled && now - downAt <= MaxHold;
        }
        if (isDown && down) spoiled = true;
        return false;
    }

    public void Reset()
    {
        down = false;
        spoiled = false;
    }

    /// <summary>Virtual-key code of each choice.</summary>
    public static int VirtualKey(DictationKey key) => key switch
    {
        DictationKey.RightAlt => 0xA5,   // VK_RMENU
        DictationKey.RightCtrl => 0xA3,  // VK_RCONTROL
        DictationKey.CapsLock => 0x14,   // VK_CAPITAL
        DictationKey.F8 => 0x77,         // VK_F8
        _ => 0xA5,
    };

    public static string Label(DictationKey key) => key switch
    {
        DictationKey.RightAlt => "右 Alt",
        DictationKey.RightCtrl => "右 Ctrl",
        DictationKey.CapsLock => "Caps Lock",
        DictationKey.F8 => "F8",
        _ => key.ToString(),
    };
}
