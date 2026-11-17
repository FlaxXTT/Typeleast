import SwiftUI

private struct TranslationSunPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var translationSunPressed: Bool {
        get { self[TranslationSunPressedKey.self] }
        set { self[TranslationSunPressedKey.self] = newValue }
    }
}

/// A compact ink mark with no plate, material, shadow or repeating animation.
struct TranslationSunset: View {
    static let displaySize = CGSize(width: 24, height: 24)
    var hoverChanged: (Bool) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.translationSunPressed) private var pressed
    @State private var hovering = false

    var body: some View {
        Canvas { context, _ in
            let ink = colorScheme == .dark
                ? Color(red: 242.0 / 255, green: 241.0 / 255, blue: 240.0 / 255)
                : Color(red: 29.0 / 255, green: 26.0 / 255, blue: 26.0 / 255)
            var circle = Path()
            circle.move(to: CGPoint(x: 12.2, y: 2.5))
            circle.addCurve(to: CGPoint(x: 17.6, y: 7.9),
                            control1: CGPoint(x: 15.3, y: 2.3), control2: CGPoint(x: 17.8, y: 4.9))
            circle.addCurve(to: CGPoint(x: 11.8, y: 13.6),
                            control1: CGPoint(x: 17.9, y: 11.1), control2: CGPoint(x: 14.7, y: 13.9))
            circle.addCurve(to: CGPoint(x: 6.5, y: 8.2),
                            control1: CGPoint(x: 8.7, y: 13.4), control2: CGPoint(x: 6.3, y: 11.1))
            circle.addCurve(to: CGPoint(x: 12.2, y: 2.5),
                            control1: CGPoint(x: 6.1, y: 5.0), control2: CGPoint(x: 9.2, y: 2.6))
            circle.closeSubpath()
            context.fill(circle, with: .color(ink))

            var first = Path()
            first.move(to: CGPoint(x: 4.5, y: 17.3))
            first.addCurve(to: CGPoint(x: 19.5, y: 17.2),
                           control1: CGPoint(x: 8.4, y: 16.9), control2: CGPoint(x: 15.4, y: 17.7))
            context.stroke(first, with: .color(ink),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round))

            var second = Path()
            second.move(to: CGPoint(x: 6.8, y: 20.9))
            second.addCurve(to: CGPoint(x: 17.3, y: 21.0),
                            control1: CGPoint(x: 9.6, y: 21.2), control2: CGPoint(x: 14.3, y: 20.6))
            context.stroke(second, with: .color(ink.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
        .frame(width: Self.displaySize.width, height: Self.displaySize.height)
        .scaleEffect(pressed && !reduceMotion ? 0.90 : 1)
        .opacity(hovering || pressed ? 1 : 0.88)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .onHover { inside in
            guard hovering != inside else { return }
            hovering = inside
            hoverChanged(inside)
        }
        .onDisappear { if hovering { hoverChanged(false) } }
    }
}
