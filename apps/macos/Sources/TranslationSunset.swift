import SwiftUI

struct TranslationSunset: View {
    var working = false
    var hoverChanged: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pointer = CGSize.zero

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !(hovering || working))) { context in
            TranslationSunsetArtwork(engaged: hovering || working, working: working, pointer: pointer,
                                     time: context.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
        }
        .frame(width: 104, height: 56)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.72), value: hovering)
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: pointer)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                if !hovering { hovering = true; hoverChanged(true) }
                pointer = CGSize(width: max(-1, min(1, (location.x - 52) / 52)),
                                 height: max(-1, min(1, (location.y - 28) / 28)))
            case .ended:
                hovering = false
                pointer = .zero
                hoverChanged(false)
            }
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

    private var moving: Bool { engaged && !reduceMotion }
    private var phase: Double { moving ? time * (working ? 1.85 : 0.8) : 0 }
    private var drift: CGFloat { moving ? CGFloat(sin(phase * 0.7)) : 0 }
    private var pointerX: CGFloat { moving ? pointer.width : 0 }
    private var pointerY: CGFloat { moving ? pointer.height : 0 }

    var body: some View {
        let shore = SunsetShoreShape(flow: drift)
        ZStack {
            shore
                .fill(Color(red: 0.48, green: 0.25, blue: 0.68).opacity(engaged ? 0.22 : 0.08))
                .blur(radius: engaged ? 6 : 3)
                .offset(y: 3)
            Canvas { context, size in
                drawScene(in: &context, size: size)
            }
            .clipShape(shore)
            .overlay {
                shore.stroke(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.25), Color(red: 0.14, green: 0.2, blue: 0.43).opacity(0.32)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
            }
            .shadow(color: Color(red: 0.18, green: 0.14, blue: 0.35).opacity(engaged ? 0.24 : 0.16), radius: engaged ? 5 : 3, y: 2)
        }
        .frame(width: 86, height: 44)
        .rotationEffect(.degrees(pointerX * 3))
        .offset(x: pointerX * 2, y: pointerY * 1.4 - (engaged ? 1 : 0))
        .frame(width: 104, height: 56)
    }

    private func drawScene(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        let horizon: CGFloat = height * 0.53 + pointerY * 0.6
        let sun = CGPoint(x: width * 0.56 + pointerX * 2,
                          y: height * 0.36 + pointerY * 0.8 - (engaged ? 1 : 0))
        let radius: CGFloat = 9.7
        let sunset = Gradient(colors: [Color(red: 1, green: 0.94, blue: 0.63),
                                      Color(red: 1, green: 0.66, blue: 0.43),
                                      Color(red: 1, green: 0.32, blue: 0.56)])
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: [.init(color: Color(red: 0.23, green: 0.25, blue: 0.58), location: 0),
                             .init(color: Color(red: 0.65, green: 0.36, blue: 0.70), location: 0.45),
                             .init(color: Color(red: 0.97, green: 0.56, blue: 0.61), location: 0.64),
                             .init(color: Color(red: 0.21, green: 0.64, blue: 0.81), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: width * 0.25, y: height)))

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: engaged ? 5 : 3.5))
            glow.fill(Path(ellipseIn: CGRect(x: sun.x - 13, y: sun.y - 11, width: 26, height: 24)),
                      with: .color(Color(red: 1, green: 0.60, blue: 0.54).opacity(0.5)))
        }
        context.drawLayer { disc in
            disc.clip(to: Path(ellipseIn: CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: radius * 2)))
            var bars = Path()
            bars.addRect(CGRect(x: sun.x - radius, y: sun.y - radius, width: radius * 2, height: 8))
            for index in 0..<4 {
                bars.addRect(CGRect(x: sun.x - radius, y: sun.y - 0.2 + CGFloat(index) * 3, width: radius * 2, height: 1.9))
            }
            disc.fill(bars, with: .linearGradient(sunset,
                startPoint: CGPoint(x: sun.x, y: sun.y - radius), endPoint: CGPoint(x: sun.x, y: sun.y + radius)))
        }

        // The sea crosses the electronic sun and carries its reflection.
        context.fill(Path(CGRect(x: 0, y: horizon, width: width, height: height - horizon)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.18, green: 0.31, blue: 0.62), Color(red: 0.15, green: 0.54, blue: 0.72), Color(red: 0.37, green: 0.79, blue: 0.82)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: width * 0.3, y: height)))
        var horizonLine = Path()
        horizonLine.move(to: CGPoint(x: 8, y: horizon))
        horizonLine.addLine(to: CGPoint(x: width - 7, y: horizon))
        context.stroke(horizonLine, with: .linearGradient(Gradient(colors: [.clear, Color(red: 1, green: 0.78, blue: 0.72), .clear]),
            startPoint: CGPoint(x: 10, y: horizon), endPoint: CGPoint(x: width - 8, y: horizon)), lineWidth: 0.8)

        for row in 0..<5 {
            let wobble = moving ? CGFloat(sin(phase * 1.3 + Double(row) * 1.4)) : 0
            let y = horizon + 2.8 + CGFloat(row) * 3.1
            let half: CGFloat = 6.5 - CGFloat(row) * 0.62
            var reflection = Path()
            reflection.move(to: CGPoint(x: sun.x - half + wobble * 1.5, y: y))
            reflection.addQuadCurve(to: CGPoint(x: sun.x + half + wobble, y: y - 0.4),
                                    control: CGPoint(x: sun.x, y: y + wobble * 0.9))
            context.stroke(reflection, with: .color(Color(red: 1, green: 0.72 + Double(row) * 0.025, blue: 0.69).opacity(0.88 - Double(row) * 0.09)),
                           style: StrokeStyle(lineWidth: row == 0 ? 1.3 : 1.1, lineCap: .round))
        }
        for row in 0..<3 {
            let wave = moving ? CGFloat(sin(phase + Double(row) * 1.9)) : 0
            let y = horizon + 5.5 + CGFloat(row) * 5.3
            var path = Path()
            path.move(to: CGPoint(x: -2, y: y + wave))
            path.addCurve(to: CGPoint(x: width + 2, y: y - wave * 0.6),
                          control1: CGPoint(x: width * 0.27, y: y - 2.7 - wave),
                          control2: CGPoint(x: width * 0.66, y: y + 2.5 + wave))
            context.stroke(path, with: .color(Color(red: 0.58, green: 0.93, blue: 0.98).opacity(row == 1 ? 0.68 : 0.37)),
                           style: StrokeStyle(lineWidth: 0.75, lineCap: .round))
        }

        var beach = Path()
        beach.move(to: CGPoint(x: width + 2, y: height * 0.67))
        beach.addCurve(to: CGPoint(x: width * 0.63, y: height + 2),
                       control1: CGPoint(x: width * 0.84, y: height * 0.72 + drift * 0.4),
                       control2: CGPoint(x: width * 0.87, y: height * 0.96))
        beach.addLine(to: CGPoint(x: width + 2, y: height + 2))
        beach.closeSubpath()
        context.fill(beach, with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.88, blue: 0.79), Color(red: 0.96, green: 0.74, blue: 0.70)]),
            startPoint: CGPoint(x: width, y: height * 0.7), endPoint: CGPoint(x: width * 0.72, y: height)))
        var foam = Path()
        foam.move(to: CGPoint(x: width + 1, y: height * 0.65))
        foam.addCurve(to: CGPoint(x: width * 0.61, y: height + 1),
                      control1: CGPoint(x: width * 0.82, y: height * 0.71 + drift * 0.6),
                      control2: CGPoint(x: width * 0.86, y: height * 0.96))
        context.stroke(foam, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.05, lineCap: .round))

        var glint = Path()
        glint.move(to: CGPoint(x: 16, y: 12))
        glint.addQuadCurve(to: CGPoint(x: 37, y: 7.5), control: CGPoint(x: 25, y: 6.5))
        context.stroke(glint, with: .color(.white.opacity(0.34)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }
}

private struct SunsetShoreShape: Shape {
    var flow: CGFloat
    var animatableData: CGFloat {
        get { flow }
        set { flow = newValue }
    }
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: point(0.11, 0.22))
        path.addCurve(to: point(0.56, 0.065), control1: point(0.24, 0.005), control2: point(0.41, 0.14 + flow * 0.012))
        path.addCurve(to: point(0.965, 0.31), control1: point(0.77, -0.01), control2: point(0.98, 0.12))
        path.addCurve(to: point(0.88, 0.84), control1: point(1.01, 0.46), control2: point(0.97, 0.72 + flow * 0.012))
        path.addCurve(to: point(0.43, 0.945), control1: point(0.76, 1.005), control2: point(0.62, 0.88))
        path.addCurve(to: point(0.04, 0.66), control1: point(0.23, 1.005), control2: point(0.035, 0.92))
        path.addCurve(to: point(0.11, 0.22), control1: point(0.005, 0.49), control2: point(0.015, 0.35))
        path.closeSubpath()
        return path
    }
}
