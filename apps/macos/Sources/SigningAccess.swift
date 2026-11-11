import Foundation
import Security

/// Restrict only the named signing identity; never export key material.
enum SigningAccess {
    enum Failure: Error { case security(OSStatus), ambiguousIdentity }
    static func tighten(name: String = "TypeLeast Local Signing") throws {
        var found: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &found)
        if status == errSecItemNotFound { return }
        try check(status)
        let identities = (found as? [SecIdentity] ?? []).filter { identity in
            var cert: SecCertificate?; var common: CFString?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
                  SecCertificateCopyCommonName(cert, &common) == errSecSuccess else { return false }
            return common as String? == name
        }
        guard identities.count <= 1 else { throw Failure.ambiguousIdentity }
        guard let identity = identities.first else { return }
        var key: SecKey?
        try check(SecIdentityCopyPrivateKey(identity, &key))
        guard let key else { throw Failure.security(errSecItemNotFound) }
        let item = unsafeBitCast(key, to: SecKeychainItem.self)
        var access: SecAccess?
        try check(SecKeychainItemCopyAccess(item, &access))
        guard let access else { throw Failure.security(errSecItemNotFound) }
        if try restrict(access: access, name: name) { try check(SecKeychainItemSetAccess(item, access)) }
    }
    static func restrict(access: SecAccess, name: String) throws -> Bool {
        var list: CFArray?
        try check(SecAccessCopyACLList(access, &list))
        var changed = false
        for acl in list as? [SecACL] ?? [] {
            var apps: CFArray?; var description: CFString?
            var selector = SecKeychainPromptSelector()
            try check(SecACLCopyContents(acl, &apps, &description, &selector))
            guard let allowed = apps as? [SecTrustedApplication] else { continue }
            let remaining = try allowed.filter { app in
                var data: CFData?
                try check(SecTrustedApplicationCopyData(app, &data))
                guard let data, let path = String(data: data as Data, encoding: .utf8) else { return true }
                return path.trimmingCharacters(in: .controlCharacters) != "/usr/bin/codesign"
            }
            if remaining.count != allowed.count {
                try check(SecACLSetContents(acl, remaining as CFArray, description ?? name as CFString, selector))
                changed = true
            }
        }
        return changed
    }
    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Failure.security(status) }
    }
}
