import AppKit

// main.swift - entry point. LSUIElement app: menu bar only, no Dock icon, no main window.

// An in-app update starts the new copy this way to hand over the Keychain items (LLMSettings.swift).
if CommandLine.arguments.dropFirst().first == KeychainHandoff.receiveFlag { exit(KeychainHandoff.receive()) }
// Items an older version handed over in a file are taken over before anything (the history,
// which the app delegate loads as it is created) reads the Keychain.
KeychainHandoff.restoreIfPresent()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
