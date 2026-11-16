import Foundation
import Security
import Darwin

// CI teardown only. Fail or terminate instead of opening an authorization sheet.
guard getuid() == 0, ProcessInfo.processInfo.environment["TYPELEAST_CI_TRUST_CLEANUP"] == "1",
      CommandLine.arguments.count == 2 else { exit(2) }
alarm(15)
guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let certificate = SecCertificateCreateWithData(nil, data as CFData) else { exit(2) }
let status = SecTrustSettingsRemoveTrustSettings(certificate, .admin)
guard status == errSecSuccess || status == errSecItemNotFound else {
    print("CI trust removal failed without authentication UI: \(status)")
    exit(1)
}
print("PASS: temporary CI root trust removed without authentication UI")
