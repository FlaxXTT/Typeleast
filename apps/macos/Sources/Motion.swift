import SwiftUI

/// Pointer feedback is active only while the control is enabled and under the pointer.
struct ControlMotion: ViewModifier {
    var pressed = false
    var cornerRadius: CGFloat = 10
    var primary = false
    var scale: CGFloat = 1.05
    var travel: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    @State private var pointer = CGSize.zero
    @State private var size = CGSize(width: 100, height: 30)
    @State private var entrance = 0

    func body(content: Content) -> some View {
        let active = hovering && enabled
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(GeometryReader { proxy in
                Color.clear.onAppear { size = proxy.size }
                    .onChange(of: proxy.size) { _, value in size = value }
            })
            .overlay {
                shape.fill(RadialGradient(colors: [Color.white.opacity(primary ? 0.24 : 0.14), Theme.accent.opacity(0.12), .clear],
                                          center: UnitPoint(x: 0.5 + pointer.width * 0.45, y: 0.5 + pointer.height * 0.45),
                                          startRadius: 0, endRadius: max(size.width * 0.65, 28)))
                    .opacity(active ? 0.75 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(primary ? 0.45 : 0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(12, proxy.size.width * 0.28), height: proxy.size.height * 3)
                            .rotationEffect(.degrees(24))
                            .keyframeAnimator(initialValue: CGFloat(-0.5), trigger: entrance) { view, position in
                                view.offset(x: proxy.size.width * position, y: -proxy.size.height)
                            } keyframes: { _ in
                                MoveKeyframe(CGFloat(-0.5))
                                LinearKeyframe(CGFloat(1.5), duration: 0.6)
                            }
                    }
                    .clipShape(shape)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.9), Theme.accent.opacity(0.45), Theme.style.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .opacity(active ? 0.85 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .scaleEffect(reduceMotion || !enabled ? 1 : pressed ? 0.94 : active ? scale : 1)
            .rotation3DEffect(.degrees(active && !reduceMotion ? -pointer.height * 4 : 0), axis: (x: 1, y: 0, z: 0))
            .rotation3DEffect(.degrees(active && !reduceMotion ? pointer.width * 4 : 0), axis: (x: 0, y: 1, z: 0))
            .offset(x: active && !reduceMotion ? pointer.width * travel : 0, y: active && !reduceMotion ? pointer.height * travel - 1.5 : 0)
            .shadow(color: .black.opacity(active && !reduceMotion ? 0.16 : 0), radius: active ? 9 : 0, x: 0, y: active ? 5 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.58), value: hovering)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.72), value: pointer)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.48), value: pressed)
            .onContinuousHover { phase in
                guard enabled else { hovering = false; pointer = .zero; return }
                switch phase {
                case .active(let location):
                    if !hovering { entrance += 1 }
                    hovering = true
                    pointer = CGSize(width: max(-1, min(1, location.x / max(size.width, 1) * 2 - 1)),
                                     height: max(-1, min(1, location.y / max(size.height, 1) * 2 - 1)))
                case .ended: hovering = false; pointer = .zero
                }
            }
    }
}

/// Each navigation icon performs one short action on pointer entry.
struct SidebarMotionIcon: View {
    let page: HubPage
    let selected: Bool
    let hovering: Bool
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let motionReduced = reduceMotion
        Group {
            if page == .meetings {
                ZStack {
                    person(left: true)
                    person(left: false)
                }
            } else if page == .history {
                ZStack {
                    Circle().stroke(lineWidth: 1.3).frame(width: 13, height: 13)
                    Path { path in path.move(to: CGPoint(x: 9, y: 5)); path.addLine(to: CGPoint(x: 9, y: 9)); path.addLine(to: CGPoint(x: 12, y: 10)) }
                        .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, angle in
                            view.rotationEffect(.degrees(motionReduced ? 0 : angle))
                        } keyframes: { _ in
                            MoveKeyframe(CGFloat(0)); CubicKeyframe(CGFloat(-370), duration: 0.55); SpringKeyframe(CGFloat(-360), duration: 0.3)
                        }
                }
            } else {
                Image(systemName: page.symbol)
                    .symbolEffect(.bounce.byLayer, options: .speed(1.35), value: reduceMotion ? 0 : trigger)
                    .rotationEffect(.degrees(page == .settings && hovering && !reduceMotion ? 95 : 0))
                    .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.4), value: hovering)
            }
        }
        .font(.system(size: page == .meetings ? 10.5 : 14, weight: selected ? .semibold : .regular))
        .frame(width: 18, height: 18)
    }

    private func person(left: Bool) -> some View {
        let motionReduced = reduceMotion
        return Image(systemName: "person.fill")
            .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, progress in
                view.offset(x: (left ? -5 : 5) + (motionReduced ? 0 : progress * (left ? 3.5 : -3.5)), y: motionReduced ? 0 : -abs(progress) * 2)
                    .rotationEffect(.degrees(motionReduced ? 0 : progress * (left ? 17 : -17)))
            } keyframes: { _ in
                MoveKeyframe(CGFloat(0)); SpringKeyframe(CGFloat(1), duration: 0.22, spring: .bouncy); SpringKeyframe(CGFloat(-0.35), duration: 0.24); SpringKeyframe(CGFloat(0), duration: 0.3)
            }
    }
}

struct MotionIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlMotion(pressed: configuration.isPressed, cornerRadius: 7, scale: 1.06, travel: 1.5))
    }
}
