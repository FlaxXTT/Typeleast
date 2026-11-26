import AppKit
import Combine
import SwiftUI

enum HoverFeedbackReset {
    static let events = Publishers.MergeMany([
        NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification,
        NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification
    ].map { NotificationCenter.default.publisher(for: $0) }).share()
}

private struct TransientHover: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .onHover {
                let next = enabled && $0
                if hovering != next { hovering = next }
            }
            .onChange(of: enabled) { _, _ in reset() }
            .onReceive(HoverFeedbackReset.events) { _ in reset() }
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

    func hoverFeedback(_ feedback: ControlHoverFeedback = .standard) -> some View {
        modifier(ControlMotion(feedback: feedback, dimWhenDisabled: false))
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

enum ControlHoverFeedback: Equatable {
    case standard, compact, magnetic, fixed

    var lift: CGFloat {
        switch self {
        case .standard: return 1
        case .compact: return 0.5
        case .magnetic: return 1.5
        case .fixed: return 0
        }
    }

    func follow(_ location: CGPoint, in size: CGSize) -> CGSize {
        guard self == .magnetic, size.width > 0, size.height > 0 else { return .zero }
        let x = 2 * location.x / size.width - 1
        let y = 2 * location.y / size.height - 1
        let scale = 2 / max(1, hypot(x, y))
        return CGSize(width: x * scale, height: y * scale)
    }
}

/// Lift the artwork within the original button bounds.
struct ControlMotion: ViewModifier {
    var pressed = false
    var cornerRadius: CGFloat = Theme.radius
    var primary = false
    var feedback = ControlHoverFeedback.standard
    var dimWhenDisabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.windowHoverPointer) private var windowPointer
    @State private var hovering = false
    @State private var bounds = CGSize.zero
    @State private var pointerOffset = CGSize.zero
    @State private var id = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if feedback == .magnetic && enabled && !reduceMotion {
            surface(content)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { bounds = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): pointerOffset = feedback.follow(location, in: bounds)
                    case .ended: pointerOffset = .zero
                    }
                }
        } else {
            surface(content)
        }
    }

    private func surface(_ content: Content) -> some View {
        let active = hovering && enabled
        let down = pressed && enabled
        let lifted = active && !down && !reduceMotion
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return content
            .overlay {
                if active || down {
                    shape.fill(primary ? Color.black.opacity(down ? 0.18 : 0.09)
                                       : Theme.controlHover)
                        .overlay {
                            shape.strokeBorder(primary ? Color.white.opacity(0.16)
                                                       : Theme.border, lineWidth: 1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(down && feedback != .fixed && !reduceMotion ? 0.98 : 1)
            .offset(x: lifted ? pointerOffset.width : 0,
                    y: lifted ? min(0, pointerOffset.height - feedback.lift) : 0)
            .opacity(enabled ? (down ? 0.90 : 1) : (dimWhenDisabled ? 0.48 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pointerOffset)
            .animation(reduceMotion ? nil : .easeOut(duration: active ? 0.12 : 0.17), value: active)
            .animation(reduceMotion ? nil : Theme.fast, value: down)
            .contentShape(shape)
            .transientHover($hovering)
            .onChange(of: hovering) { _, active in
                windowPointer?.control(id, hovering: active)
                if !active { pointerOffset = .zero }
            }
            .onDisappear { windowPointer?.control(id, hovering: false) }
    }
}

struct FlatActionButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.radius
    var feedback = ControlHoverFeedback.standard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ControlMotion(pressed: configuration.isPressed, cornerRadius: cornerRadius,
                                    feedback: configuration.role == .destructive ? .fixed : feedback))
    }
}

extension NSView {
    /// Animate the backing layer so AppKit's frame and click target stay in place.
    func setControlLift(_ points: CGFloat) {
        guard let layer else { return }
        let lift = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : points
        let translation = isFlipped ? -lift : lift
        guard abs(layer.transform.m42 - translation) > 0.001 else { return }
        let from = layer.presentation()?.transform.m42 ?? layer.transform.m42
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(translation, forKeyPath: "transform.translation.y")
        CATransaction.commit()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = from
            move.duration = points > 0 ? 0.12 : 0.17
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(move, forKey: "controlHoverLift")
        }
    }
}
