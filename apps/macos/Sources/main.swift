import AppKit

// Registered as an application for the Apps list; runtime policy follows the Dock setting.

// An in-app update starts the new copy this way to hand over the Keychain items (LLMSettings.swift).
if CommandLine.arguments.dropFirst().first == KeychainHandoff.receiveFlag { exit(KeychainHandoff.receive()) }
// Items an older version handed over in a file are taken over before anything (the history,
// which the app delegate loads as it is created) reads the Keychain.
KeychainHandoff.restoreIfPresent()

// A child that exits before reading its stdin (the service, an update's key hand-over) must
// fail that write, not end TypeLeast with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
