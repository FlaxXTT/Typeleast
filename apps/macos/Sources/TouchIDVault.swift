import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A dedicated login-session Keychain whose random passphrase is wrapped by a Touch ID-only
/// Secure Enclave key. The wrapper contains no plaintext credentials and needs no team entitlement.
final class TouchIDVault {
    static let shared = TouchIDVault(directory: URL(fileURLWithPath: ServiceClient.stateDirectory).appendingPathComponent("credentials"))

    private struct Envelope: Codable {
        let vaultID: UUID
        let keyRepresentation: Data
        let encapsulatedKey: Data
        let sealedPassphrase: Data
    }

    private struct Session {
        let envelope: Envelope
        let passphrase: Data
        var values: [String: String]
    }

    private let directory: URL
    private let lock = NSLock()
    private var session: Session?
    private var configured: Bool
    private let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    private let query: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "TypeLeast.touch-id-vault",
        kSecAttrAccount as String: "credentials",
    ]

    init(directory: URL) {
        self.directory = directory
        configured = FileManager.default.fileExists(atPath: directory.appendingPathComponent("touch-id-v1.json").path)
    }

    private var manifest: URL { directory.appendingPathComponent("touch-id-v1.json") }
    var isConfigured: Bool { lock.withLock { configured } }
    var isUnlocked: Bool { lock.withLock { session != nil } }

    func read(_ account: String) -> String? { lock.withLock { session?.values[account] } }
    func accounts() -> [String]? { lock.withLock { session?.values.keys.sorted() } }

    func write(_ value: String?, account: String, onlyIfAbsent: Bool = false) -> OSStatus {
        lock.withLock {
            guard var next = session else { return errSecInteractionNotAllowed }
            if onlyIfAbsent && next.values[account] != nil { return errSecDuplicateItem }
            next.values[account] = value
            do {
                try withUnlockedKeychain(next.envelope, passphrase: next.passphrase) { keychain in
                    var match: [String: Any] = query
                    match[kSecMatchSearchList as String] = [keychain]
                    try check(SecItemUpdate(match as CFDictionary,
                                             [kSecValueData as String: try JSONEncoder().encode(next.values)] as CFDictionary))
                }
                session = next
                return errSecSuccess
            } catch {
                return Self.status(error)
            }
        }
    }

    func unlock(allowBiometryRecovery: Bool) async throws {
        if isUnlocked { return }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: manifest))
        let unlocked: Session
        do {
            unlocked = try await open(envelope)
        } catch let error as LAError where allowBiometryRecovery && error.code == .biometryLockout {
            try await restoreBiometryIfLockedOut()
            unlocked = try await open(envelope)
        }
        lock.withLock { if session == nil { session = unlocked } }
    }

    private func restoreBiometryIfLockedOut() async throws {
        let context = LAContext()
        defer { context.invalidate() }
        var problem: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &problem) { return }
        guard (problem as? LAError)?.code == .biometryLockout else {
            throw problem ?? Self.failure(errSecNotAvailable)
        }
        // This context restores Touch ID only. Unlocking the vault always uses a fresh context.
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                               localizedReason: L10n.text("恢复 TypeLeast 的 Touch ID")) else {
            throw Self.failure(errSecAuthFailed)
        }
    }

    /// Writes to a new Keychain and verifies that Touch ID can read it back before selecting it.
    /// The login Keychain and the history database are untouched throughout.
    func provision(values: [String: String]) async throws {
        try check(Self.noPasswordUI)
        guard !isConfigured else { throw Self.failure(errSecDuplicateItem) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let vaultID = UUID()
        let staging = vaultDirectory(vaultID)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var installed = false
        var created: SecKeychain?
        defer {
            if !installed {
                if let created { SecKeychainDelete(created) }
                try? fileManager.removeItem(at: staging)
            }
        }

        let context = LAContext()
        context.interactionNotAllowed = true
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                        [.biometryAny, .privateKeyUsage], nil) else {
            throw Self.failure(errSecNotAvailable)
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: acl, authenticationContext: context)
        var passphrase = Data(repeating: 0, count: 32)
        try check(passphrase.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        })
        var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: suite, info: info(vaultID))
        let envelope = Envelope(vaultID: vaultID, keyRepresentation: key.dataRepresentation,
                                encapsulatedKey: sender.encapsulatedKey, sealedPassphrase: try sender.seal(passphrase))
        try check(passphrase.withUnsafeBytes {
            SecKeychainCreate(keychainPath(vaultID), UInt32($0.count), $0.baseAddress, false, nil, &created)
        })
        guard let created else { throw Self.failure(errSecNotAvailable) }
        do {
            var add: [String: Any] = query
            add[kSecUseKeychain as String] = created
            add[kSecValueData as String] = try JSONEncoder().encode(values)
            try check(SecItemAdd(add as CFDictionary, nil))
            try check(SecKeychainLock(created))
        } catch {
            SecKeychainLock(created)
            throw error
        }
        let verified = try await open(envelope)
        guard verified.values == values else { throw Self.failure(errSecDecode) }
        try JSONEncoder().encode(envelope).write(to: manifest, options: .atomic)
        installed = true
        lock.withLock {
            configured = true
            session = verified
        }
    }

    private func open(_ envelope: Envelope) async throws -> Session {
        try check(Self.noPasswordUI)
        let context = LAContext()
        context.localizedFallbackTitle = ""
        defer { context.invalidate() }
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &problem),
              context.biometryType == .touchID else { throw problem ?? Self.failure(errSecNotAvailable) }
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                               localizedReason: L10n.text("解锁 TypeLeast 的钥匙串")) else {
            throw Self.failure(errSecAuthFailed)
        }
        context.interactionNotAllowed = true
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.keyRepresentation,
                                                                 authenticationContext: context)
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info(envelope.vaultID),
                                           encapsulatedKey: envelope.encapsulatedKey)
        let passphrase = try recipient.open(envelope.sealedPassphrase)
        let values = try withUnlockedKeychain(envelope, passphrase: passphrase) { keychain in
            var lookup: [String: Any] = query
            lookup[kSecMatchSearchList as String] = [keychain]
            lookup[kSecReturnData as String] = true
            var result: CFTypeRef?
            try check(SecItemCopyMatching(lookup as CFDictionary, &result))
            guard let bytes = result as? Data else { throw Self.failure(errSecDecode) }
            return try JSONDecoder().decode([String: String].self, from: bytes)
        }
        return Session(envelope: envelope, passphrase: passphrase, values: values)
    }

    private func withUnlockedKeychain<T>(_ envelope: Envelope, passphrase: Data,
                                         perform: (SecKeychain) throws -> T) throws -> T {
        var opened: SecKeychain?
        try check(SecKeychainOpen(keychainPath(envelope.vaultID), &opened))
        guard let opened else { throw Self.failure(errSecNotAvailable) }
        try check(passphrase.withUnsafeBytes { SecKeychainUnlock(opened, UInt32($0.count), $0.baseAddress, true) })
        defer { SecKeychainLock(opened) }
        return try perform(opened)
    }

    private func vaultDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func keychainPath(_ id: UUID) -> String { vaultDirectory(id).appendingPathComponent("TypeLeast.keychain-db").path }

    private func info(_ id: UUID) -> Data { Data(("TypeLeast Touch ID vault v1 " + id.uuidString).utf8) }

    static let noPasswordUI = SecKeychainSetUserInteractionAllowed(false)

    static func status(_ error: Error) -> OSStatus {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain ? OSStatus(error.code) : errSecAuthFailed
    }

    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Self.failure(status) }
    }
}
