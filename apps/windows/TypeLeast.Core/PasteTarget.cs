namespace TypeLeast.Core;

public static class PasteTarget
{
    public static bool Matches(System.IntPtr expected, System.IntPtr current) =>
        expected == System.IntPtr.Zero || expected == current;
}
