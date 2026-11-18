import AppKit
import Combine
import SwiftUI

private struct TransientHover: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.isEnabled) private var enabled
    private static let resets = Publishers.MergeMany([
        NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification,
        NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification
    ].map { NotificationCenter.default.publisher(for: $0) }).share()

    func body(content: Content) -> some View {
        content
            .onHover {
                let next = enabled && $0
                if hovering != next { hovering = next }
            }
            .onChange(of: enabled) { _, _ in reset() }
            .onReceive(Self.resets) { _ in reset() }
            .onDisappear(perform: reset)
    }

    private func reset() {
        if hovering { hovering = false }
    }
}

extension View {
    func transientHover(_ hovering: Binding<Bool>) -> some View {
        modifier(TransientHover(hovering: hovering))
    }

    func resetCopyFeedback(_ feedback: Binding<UUID?>) -> some View {
        let current = feedback.wrappedValue
        return task(id: current) {
            guard let current else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled && feedback.wrappedValue == current {
                feedback.wrappedValue = nil
            }
        }
    }
}

/// Hover changes only a flat highlight; press feedback is short and does not move layout.
struct ControlMotion: ViewModifier {
    var pressed = false
    var cornerRadius: CGFloat = Theme.radius
    var primary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        let active = hovering && enabled
        let down = pressed && enabled
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        content
            .overlay {
                if active || down {
                    shape.fill(primary ? Color.white.opacity(down ? 0.12 : 0.07)
                                       : Theme.cardHover)
                        .overlay {
                            shape.strokeBorder(primary ? Color.white.opacity(0.20)
                                                       : Theme.border, lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(down && !reduceMotion ? 0.98 : 1)
            .opacity(enabled ? (down ? 0.90 : 1) : 0.48)
            .animation(reduceMotion ? nil : Theme.fast, value: down)
            .animation(reduceMotion ? nil : Theme.fast, value: active)
            .transientHover($hovering)
            .onChange(of: down) { _, down in
                if down { hovering = false }
            }
    }
}

/// Navigation uses one static symbol instead of layered keyframe animations.
struct SidebarMotionIcon: View {
    let page: HubPage
    let selected: Bool
    let hovering: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: page.symbol)
            .font(.system(size: 16, weight: .regular))
            .opacity(enabled ? (selected || hovering ? 1 : 0.86) : 0.5)
            .frame(width: 16, height: 16)
    }
}

struct FlatActionButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.radius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ControlMotion(pressed: configuration.isPressed, cornerRadius: cornerRadius))
    }
}
