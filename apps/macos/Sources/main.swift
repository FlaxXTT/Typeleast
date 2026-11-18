import AppKit

// Registered as an application for the Apps list; runtime policy follows the Dock setting.

// Older updaters invoke this compatibility receiver; it does not pre-read credentials.
if CommandLine.arguments.dropFirst().first == KeychainHandoff.receiveFlag { exit(KeychainHandoff.receive()) }
if CommandLine.arguments.dropFirst().first == "--check-touch-id-migration" {
    do { try KeychainStore.reportTouchIDMigrationReadiness(); exit(0) }
    catch { print("Could not check credential migration."); exit(1) }
}
if CommandLine.arguments.dropFirst().first == "--migrate-keychain-to-touch-id" {
    let lock = InstanceLock()
    guard lock.acquire() else { exit(75) }
    let authorizationLimit: Int
    switch Array(CommandLine.arguments.dropFirst(2)) {
    case []: authorizationLimit = 0
    case ["--allow-legacy-authorization"]: authorizationLimit = 1
    case ["--allow-each-legacy-authorization"]: authorizationLimit = .max
    default: exit(2)
    }
    Task.detached {
        do {
            let migrated = try await KeychainStore.migrateToTouchID(authorizationLimit: authorizationLimit)
            print("Migrated \(migrated) credential items to the Touch ID Keychain.")
            exit(0)
        } catch {
            let problem = error as NSError
            print("Migration stopped, original items preserved: \(problem.domain) \(problem.code).")
            exit(1)
        }
    }
    withExtendedLifetime(lock) { RunLoop.main.run() }
    exit(1)
}
// A child that exits before reading its stdin (the service, an update's key hand-over) must
// fail that write, not end TypeLeast with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
