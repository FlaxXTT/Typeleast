import AppKit
import Carbon.HIToolbox

// HotKey.swift - global hotkeys via Carbon RegisterEventHotKey.
// AppKit/Carbon only: no event tap, therefore NO Input Monitoring permission.

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let userData = userData, let event = event else { return OSStatus(eventNotHandledErr) }
    let centre = Unmanaged<HotKeyCentre>.fromOpaque(userData).takeUnretainedValue()
    var hkID = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                               EventParamType(typeEventHotKeyID), nil,
                               MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    if err == noErr {
        centre.fire(id: hkID.id)
        return noErr
    }
    return OSStatus(eventNotHandledErr)
}

final class HotKeyCentre {
    static let shared = HotKeyCentre()
    /// 'DSHV'
    private static let signature: OSType = 0x44534856

    private var eventHandler: EventHandlerRef?
    private var refs: [String: EventHotKeyRef] = [:]
    private var actions: [String: () -> Void] = [:]
    private var idToKey: [UInt32: String] = [:]
    private var nextID: UInt32 = 1

    /// slot -> human readable registration result, surfaced in Settings.
    private(set) var status: [String: String] = [:]

    func installIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let err = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec,
                                      Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if err != noErr { status["handler"] = "InstallEventHandler -> " + String(err) }
    }

    fileprivate func fire(id: UInt32) {
        guard let key = idToKey[id], let action = actions[key] else { return }
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    @discardableResult
    func register(slot: String, binding: HotKeyBinding, action: @escaping () -> Void) -> Bool {
        installIfNeeded()
        unregister(slot: slot)
        guard binding.enabled else {
            status[slot] = L10n.text("已停用")
            return false
        }
        var ref: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let hkID = EventHotKeyID(signature: HotKeyCentre.signature, id: id)
        let err = RegisterEventHotKey(binding.keyCode, binding.modifiers, hkID,
                                      GetApplicationEventTarget(), 0, &ref)
        guard err == noErr, let r = ref else {
            status[slot] = L10n.text("注册失败 (OSStatus ") + String(err) + ")"
            return false
        }
        refs[slot] = r
        actions[slot] = action
        idToKey[id] = slot
        status[slot] = L10n.text("已注册 ") + HotKeyCentre.describe(keyCode: binding.keyCode, modifiers: binding.modifiers)
        return true
    }

    func unregister(slot: String) {
        if let r = refs[slot] {
            UnregisterEventHotKey(r)
            refs[slot] = nil
        }
        if let id = idToKey.first(where: { $0.value == slot })?.key { idToKey[id] = nil }
        actions[slot] = nil
    }

    func unregisterAll() {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        idToKey.removeAll()
    }

    // MARK: names

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        return s + keyName(keyCode)
    }

    /// NSEvent.ModifierFlags -> Carbon modifier mask used by RegisterEventHotKey.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        if let n = keyNames[code] { return n }
        return "Key" + String(code)
    }

    static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8",
        0x19: "9", 0x1D: "0",
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x35: "Esc", 0x33: "Delete", 0x75: "FwdDelete",
        0x73: "Home", 0x77: "End", 0x74: "PageUp", 0x79: "PageDown",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x3F: "Fn", 0x18: "=", 0x1B: "-", 0x21: "[", 0x2A: "\\", 0x27: "'", 0x29: ";", 0x2B: ",",
        0x2F: ".", 0x2C: "/", 0x32: "`",
    ]
}
