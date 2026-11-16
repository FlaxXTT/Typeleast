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
// Removing an admin trust record can wait for a GUI session on hosted macOS.
// Replace its positive trust with an unspecified result instead. This clears
// the temporary grant without adding a denial or weakening normal validation.
let settings = [kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.unspecified.rawValue)]
let status = SecTrustSettingsSetTrustSettings(certificate, .admin, settings as CFDictionary)
guard status == errSecSuccess else {
    print("CI positive-trust cleanup failed without authentication UI: \(status)")
    exit(1)
}
print("PASS: temporary CI positive root trust cleared without authentication UI")
