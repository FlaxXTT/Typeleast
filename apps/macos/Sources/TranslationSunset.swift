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

/// The TypeLeast waveform in sunset colours, without a backing plate.
struct TranslationSunset: View {
    static let displaySize = CGSize(width: 18, height: 18)
    static let artworkSize = CGSize(width: 14, height: 14)
    private static let parchment = Color(.sRGB, red: 231.0 / 255, green: 219.0 / 255, blue: 184.0 / 255)
    private static let ink = Color(.sRGB, red: 18.0 / 255, green: 18.0 / 255, blue: 18.0 / 255)
    private static let matcha = Color(.sRGB, red: 164.0 / 255, green: 206.0 / 255, blue: 70.0 / 255)
    var hoverChanged: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.translationSunPressed) private var pressed
    @State private var hovering = false

    var body: some View {
        Canvas { context, size in
            let bars = AppIconArtwork.barRatios
            let width: CGFloat = 1.7
            let stride: CGFloat = 2.55
            let left = (size.width - CGFloat(bars.count - 1) * stride - width) / 2
            for (index, ratio) in bars.enumerated() {
                let height = 9.7 * ratio
                let bar = CGRect(x: left + stride * CGFloat(index), y: 6 - height / 2, width: width, height: height)
                let path = Path(roundedRect: bar, cornerRadius: width / 2)
                context.stroke(path, with: .color(Self.parchment), lineWidth: 1.1)
                if index == bars.count - 1 {
                    context.fill(path, with: .color(Self.matcha))
                } else {
                    context.fill(path, with: .linearGradient(
                        Gradient(stops: [.init(color: Self.matcha, location: 0), .init(color: Self.matcha, location: 0.5),
                                         .init(color: Self.ink, location: 0.5), .init(color: Self.ink, location: 1)]),
                        startPoint: CGPoint(x: bar.midX, y: bar.minY), endPoint: CGPoint(x: bar.midX, y: bar.maxY)))
                }
            }
            let horizon = Path(roundedRect: CGRect(x: 2.35, y: 12.2, width: 9.3, height: 1.25), cornerRadius: 0.625)
            context.stroke(horizon, with: .color(Self.parchment), lineWidth: 1.1)
            context.fill(horizon, with: .color(Self.ink))
        }
        .frame(width: Self.artworkSize.width, height: Self.artworkSize.height)
        .scaleEffect(pressed && !reduceMotion ? 0.90 : 1)
        .opacity(hovering || pressed ? 1 : 0.94)
        .frame(width: Self.displaySize.width, height: Self.displaySize.height)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .transientHover($hovering)
        .onChange(of: hovering) { _, inside in hoverChanged(inside) }
        .onDisappear { if hovering { hoverChanged(false) } }
    }
}
