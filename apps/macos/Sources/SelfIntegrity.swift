import Foundation
import Security

// SelfIntegrity.swift - before the local service starts, check that this app's own
// signature still holds, resources included: the service scripts, node_modules and
// Node.js all live in Contents/Resources, and macOS does not re-check them on every
// launch. A changed file means someone else's code would run with this app's
// microphone and Accessibility permissions, so the service is not started.

enum SelfIntegrity {
    /// nil when the bundle's signature (and every sealed file) is intact; otherwise why not.
    static func problem(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        // A valid replacement signature is insufficient. The on-disk code must still
        // match the code identity held by the OS for this running process.
        if bundleURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return "running identity unavailable" }
            // Dynamic validation accepts different flags from the static resource check below.
            guard SecCodeCheckValidity(running, [], nil) == errSecSuccess else { return "running identity changed" }
        }
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code)
        guard created == errSecSuccess, let code else { return "unreadable signature (\(created))" }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status != errSecSuccess else { return nil }
        let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
        return "signature check failed (\(status))" + (detail.isEmpty ? "" : ": " + detail)
    }
}
