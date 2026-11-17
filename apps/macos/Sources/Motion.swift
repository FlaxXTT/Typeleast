import SwiftUI

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
            .opacity(down ? 0.90 : 1)
            .animation(reduceMotion ? nil : Theme.fast, value: down)
            .animation(reduceMotion ? nil : Theme.fast, value: active)
            .onHover { value in
                let next = value && enabled
                if hovering != next { hovering = next }
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

struct MotionIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlMotion(pressed: configuration.isPressed, cornerRadius: Theme.smallControlRadius))
    }
}
