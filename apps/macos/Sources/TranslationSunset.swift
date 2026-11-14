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

struct TranslationSunset: View {
    var working = false
    var hoverChanged: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.translationSunPressed) private var pressed
    @State private var hovering = false
    @State private var pointer = CGSize.zero
    @State private var enteredAt = Date().timeIntervalSinceReferenceDate

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !(hovering || working))) { context in
            TranslationSunsetArtwork(engaged: hovering || working, working: working, pointer: pointer,
                                     time: max(0, context.date.timeIntervalSinceReferenceDate - enteredAt),
                                     reduceMotion: reduceMotion, pressed: pressed)
        }
        .frame(width: 128, height: 80)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.7), value: hovering)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if !hovering {
                    enteredAt = Date().timeIntervalSinceReferenceDate
                    hovering = true
                    hoverChanged(true)
                }
                pointer = CGSize(width: max(-1, min(1, (location.x - 64) / 64)),
                                 height: max(-1, min(1, (location.y - 40) / 40)))
            case .ended:
                hovering = false
                pointer = .zero
                hoverChanged(false)
            }
        }
        .onChange(of: working) { _, active in
            if active { enteredAt = Date().timeIntervalSinceReferenceDate }
        }
        .onDisappear { if hovering { hoverChanged(false) } }
    }
}

struct TranslationSunsetArtwork: View {
    let engaged: Bool
    let working: Bool
    let pointer: CGSize
    let time: TimeInterval
    let reduceMotion: Bool
    var pressed = false

    private var moving: Bool { engaged && !reduceMotion }
    private var phase: Double { moving ? time * (working ? 3.7 : 2.05) : 0 }
    private var reveal: CGFloat { moving ? CGFloat(min(1, max(0, time / 0.48))) : 1 }
    private var pointerX: CGFloat { moving ? pointer.width : 0 }
    private var pointerY: CGFloat { moving ? pointer.height : 0 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(engaged ? 1 : 0.94),
                                               Color(white: engaged ? 0.94 : 0.985)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white, Color.black.opacity(engaged ? 0.18 : 0.07)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
            Canvas { context, _ in
                drawInk(in: &context)
            }
            .frame(width: 128, height: 80)
            .scaleEffect(pressed && !reduceMotion ? 0.83 : 1)
            .rotationEffect(.degrees(pressed && !reduceMotion ? -7 : 0))
            .offset(y: pressed && !reduceMotion ? 2 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.45), value: pressed)
            .allowsHitTesting(false)
        }
        .frame(width: 128, height: 80)
    }

    private func drawInk(in context: inout GraphicsContext) {
        let lift: CGFloat = moving ? CGFloat(sin(min(time / 0.7, 1) * .pi)) * 9 : 0
        let sway = moving ? sin(phase) : 0
        let sunCenter = CGPoint(x: 64 + pointerX * 6,
                                y: 34 - (engaged ? 3 : 0) - lift + CGFloat(sway) * (working ? 2.7 : 1.5) + pointerY * 2)
        let tilt = pointerX * 15 + CGFloat(sway) * (working ? 15 : 5) + (engaged ? -8 : 0)
        let ink = Color(white: 0.13)
        context.drawLayer { sun in
            sun.translateBy(x: sunCenter.x, y: sunCenter.y)
            sun.rotate(by: .degrees(Double(tilt)))
            var circle = Path()
            circle.move(to: CGPoint(x: 0.5, y: -15))
            circle.addCurve(to: CGPoint(x: 15.2, y: -0.6),
                            control1: CGPoint(x: 8.9, y: -15.5), control2: CGPoint(x: 15.5, y: -8.2))
            circle.addCurve(to: CGPoint(x: -0.7, y: 14.9),
                            control1: CGPoint(x: 15.8, y: 8.7), control2: CGPoint(x: 7.2, y: 15.3))
            circle.addCurve(to: CGPoint(x: -14.7, y: 0.7),
                            control1: CGPoint(x: -8.8, y: 14.1), control2: CGPoint(x: -15.3, y: 8.8))
            circle.addCurve(to: CGPoint(x: 0.5, y: -15),
                            control1: CGPoint(x: -15.5, y: -8.5), control2: CGPoint(x: -7.3, y: -14.8))
            let end = moving ? 0.12 + reveal * 0.88 : 1
            sun.stroke(circle.trimmedPath(from: 0, to: min(end, 0.73)), with: .color(ink),
                       style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
            if end > 0.73 {
                sun.stroke(circle.trimmedPath(from: 0.73, to: end), with: .color(ink.opacity(0.86)),
                           style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            sun.drawLayer { hatch in
                hatch.clip(to: circle)
                for index in -2...2 {
                    let slide = moving ? CGFloat(sin(phase * 0.85 + Double(index) * 0.65)) * (working ? 2.2 : 1.2) : 0
                    let shift = CGFloat(index) * 7.7 + slide
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: -21, y: 21 + shift))
                    stroke.addQuadCurve(to: CGPoint(x: 21, y: -21 + shift),
                                        control: CGPoint(x: 0.4, y: shift - 0.55))
                    let opacity = engaged ? Double(0.6 + reveal * 0.25) : 0.7
                    hatch.stroke(stroke, with: .color(ink.opacity(opacity)),
                                 style: StrokeStyle(lineWidth: index.isMultiple(of: 2) ? 0.85 : 1.05, lineCap: .round))
                }
            }
        }

        // Three pen strokes make the shore; they do not fill a landscape.
        let expansion: CGFloat = engaged ? (reduceMotion ? 1 : reveal) : 0
        for row in 0..<3 {
            let rhythm = moving ? CGFloat(sin(phase * 0.72 + Double(row) * 1.1)) : 0
            let width: CGFloat = [43, 32, 20][row] + expansion * [33, 26, 18][row]
            let center: CGFloat = 63 + pointerX * (row == 0 ? -2.5 : 1.8) + CGFloat(row - 1) * 1.5
            let y: CGFloat = 55.5 + CGFloat(row) * 6
            var line = Path()
            line.move(to: CGPoint(x: center - width / 2, y: y + rhythm * 0.8))
            line.addCurve(to: CGPoint(x: center + width / 2, y: y - rhythm * 0.6),
                          control1: CGPoint(x: center - width * 0.19, y: y - 0.6 - rhythm * (working ? 1.2 : 0.55)),
                          control2: CGPoint(x: center + width * 0.22, y: y + 0.85 + rhythm * 0.5))
            context.stroke(line, with: .color(ink.opacity([0.85, 0.65, 0.43][row])),
                           style: StrokeStyle(lineWidth: [1.3, 1.1, 0.9][row], lineCap: .round, lineJoin: .round))
        }
    }
}
