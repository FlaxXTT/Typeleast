import AppKit
import ApplicationServices
import SwiftUI

// SelectionWatcher.swift - after the user drag-selects a long passage in any app (often a
// prompt another AI wrote), a small button near the mouse offers 「用 TypeLeast 拆解提示词」.
// The selection is read through Accessibility on this Mac only; nothing is sent until the
// button is clicked. Password fields and TypeLeast's own windows are ignored.

final class SelectionWatcher {
    /// A selection this long or longer is worth breaking down.
    static let minimumCharacters = 80
    static let visibleSeconds: TimeInterval = 8

    var onBreakdown: ((_ text: String, _ appBundleId: String) -> Void)?
    var enabled: () -> Bool = { true }

    private var monitors: [Any] = []
    private var dragged = false
    private var panel: NSPanel?
    private var hideTimer: Timer?

    func start() {
        guard monitors.isEmpty else { return }
        let events: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] _ in self?.dragged = false; self?.hide() }),
            (.leftMouseDragged, { [weak self] _ in self?.dragged = true }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
        ]
        for (mask, handler) in events {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(monitor) }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide()
    }

    private func mouseUp(_ event: NSEvent) {
        // A drag or a triple click selects a passage; a plain click does not.
        guard enabled(), dragged || event.clickCount >= 3, AXIsProcessTrusted() else { return }
        dragged = false
        let point = NSEvent.mouseLocation
        // Give the app a moment to update its selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  let text = SelectionWatcher.selectedText(),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).count >= SelectionWatcher.minimumCharacters else { return }
            self.show(at: point, text: text, appBundleId: app.bundleIdentifier ?? "")
        }
    }

    /// The focused element's selected text, unless it is a password field.
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        return selected as? String
    }

    private func show(at point: NSPoint, text: String, appBundleId: String) {
        let view = BreakdownButtonView { [weak self] in
            self?.hide()
            self?.onBreakdown?(text, appBundleId)
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            panel = p
            return p
        }()
        p.contentView = host
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: point.x + 8, y: point.y - size.height - 10))
        p.orderFrontRegardless()
        hideTimer?.invalidate()
        let t = Timer(timeInterval: SelectionWatcher.visibleSeconds, repeats: false) { [weak self] _ in self?.hide() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
    }
}

/// The dark capsule offered next to a selection.
struct BreakdownButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "text.magnifyingglass").font(.system(size: 12, weight: .semibold))
                Text(L10n.text("用 TypeLeast 拆解提示词")).font(.system(size: 12.5, weight: .semibold)).fixedSize()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.09)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .padding(4)
    }
}
