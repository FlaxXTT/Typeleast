import SwiftUI

/// Local drawing clocks do not publish animation frames through the app model.
private struct LoadingTimeline<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @ViewBuilder var content: (Double, Bool) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            content(max(0, context.date.timeIntervalSince(start)), reduceMotion)
        }
    }
}

struct SkeletonWave: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var radius: CGFloat = 3

    var body: some View {
        LoadingTimeline { elapsed, reduced in
            GeometryReader { geometry in
                let cycle = max(0, elapsed - 0.5).truncatingRemainder(dividingBy: 2)
                let travel = elapsed < 0.5 ? -1 : min(1, cycle) * 2 - 1
                RoundedRectangle(cornerRadius: radius).fill(Theme.loadingTrack)
                    .overlay {
                        if !reduced {
                            LinearGradient(colors: [.clear, Theme.skeletonHighlight, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .offset(x: geometry.size.width * travel)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// An eight-point capsule: dual travelling bars, or a real measured fraction.
struct LoadingLinearProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var value: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.loadingTrack)
                if let value {
                    Capsule().fill(Theme.accent)
                        .scaleEffect(x: min(1, max(0, value)), y: 1, anchor: .leading)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
                } else {
                    LoadingTimeline { elapsed, reduced in
                        if reduced {
                            Capsule().fill(Theme.accent).scaleEffect(x: 0.35, y: 1)
                        } else {
                            ZStack(alignment: .leading) {
                                bar(elapsed: elapsed, delayed: false, width: geometry.size.width)
                                bar(elapsed: elapsed, delayed: true, width: geometry.size.width)
                            }
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("进度"))
        .accessibilityValue(value.map { "\(Int(min(1, max(0, $0)) * 100))%" } ?? L10n.text("正在加载…"))
    }

    private func bar(elapsed: Double, delayed: Bool, width: CGFloat) -> some View {
        let time = elapsed - (delayed ? 1.15 : 0)
        let phase = max(0, time).truncatingRemainder(dividingBy: 2.1) / 2.1
        let t = min(1, phase / 0.6)
        let eased = delayed ? MotionBezier.value(t, x1: 0.165, y1: 0.84, x2: 0.44, y2: 1)
                            : MotionBezier.value(t, x1: 0.65, y1: 0.815, x2: 0.735, y2: 0.395)
        let left = delayed ? -2 + 3.07 * eased : -0.35 + 1.35 * eased
        let right = delayed ? 1 - 1.08 * eased : 1 - 1.9 * eased
        return Rectangle().fill(Theme.accent)
            .scaleEffect(x: max(0, 1 - left - right), y: 1, anchor: .leading)
            .offset(x: width * left)
            .opacity(time < 0 ? 0 : 1)
    }
}

struct LoadingCircularProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 20
    var thickness: CGFloat = 3.6
    var color: Color = Theme.accent
    var value: Double? = nil

    private var lineWidth: CGFloat { size * thickness / 44 }

    var body: some View {
        Group {
            if let value {
                ZStack {
                    Circle().stroke(Theme.loadingTrack, lineWidth: lineWidth)
                    Circle().trim(from: 0, to: min(1, max(0, value)))
                        .stroke(color, lineWidth: lineWidth)
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
                }
            } else {
                LoadingTimeline { elapsed, reduced in
                    let phase = reduced ? 0.25 : elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let half = phase < 0.5 ? phase * 2 : (phase - 0.5) * 2
                    let eased = MotionBezier.value(half, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
                    let length = phase < 0.5 ? 1 + 99 * eased : 100 - 99 * eased
                    let offset = phase < 0.5 ? -15 * eased : -15 - 111 * eased
                    Circle().trim(from: 0, to: length / 126)
                        .stroke(color, lineWidth: lineWidth)
                        .rotationEffect(.degrees(phase * 360 - offset / 126 * 360 - 90))
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("正在加载…"))
        .accessibilityValue(value.map { "\(Int(min(1, max(0, $0)) * 100))%" } ?? "")
    }
}

private enum MotionBezier {
    static func value(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func coordinate(_ t: Double, _ first: Double, _ second: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * first + 3 * (1 - t) * t * t * second + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let t = (low + high) / 2
            if coordinate(t, x1, x2) < x { low = t } else { high = t }
        }
        return coordinate((low + high) / 2, y1, y2)
    }
}
