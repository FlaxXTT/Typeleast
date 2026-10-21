using System.Security.AccessControl;
using System.Security.Principal;

namespace TypeLeast.Core;

/// <summary>Protect only the dedicated application state directory, never an arbitrary parent.</summary>
public static class PrivateStorage
{
    public static void EnsureDirectory(string path)
    {
        var full = Path.GetFullPath(path);
        if (full.TrimEnd(Path.DirectorySeparatorChar) == Path.GetPathRoot(full)?.TrimEnd(Path.DirectorySeparatorChar))
            throw new UnauthorizedAccessException("A dedicated state directory is required");
        for (var parent = new DirectoryInfo(full); parent is not null; parent = parent.Parent)
            if (parent.Exists && parent.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UnauthorizedAccessException("State link rejected");
        // Other files in the folder (the prompt file, a user's own notes) are not an error:
        // failing here would stop the app from starting at all.
        Directory.CreateDirectory(path);
        if (!OperatingSystem.IsWindows()) return;
        var sid = WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException("No current user SID");
        var security = new DirectorySecurity();
        security.SetOwner(sid);
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
        // Remove explicit legacy grants from existing immediate state files as well.
        foreach (var file in new DirectoryInfo(path).EnumerateFiles())
        {
            if (file.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new UnauthorizedAccessException("State link rejected");
            var acl = new FileSecurity();
            acl.SetOwner(sid);
            acl.SetAccessRuleProtection(false, false);
            file.SetAccessControl(acl);
        }
    }
}
