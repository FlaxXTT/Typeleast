import Foundation
import Darwin

/// A process-owned lock. Closing the descriptor (including a crash) releases it.
final class InstanceLock {
    private let directory: String
    private var descriptor: Int32 = -1
    init(directory: String = ServiceClient.stateDirectory) { self.directory = directory }
    func acquire() -> Bool {
        if descriptor >= 0 { return true }
        do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        let fd = Darwin.open(directory + "/app-instance.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return false }
        descriptor = fd
        return true
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
