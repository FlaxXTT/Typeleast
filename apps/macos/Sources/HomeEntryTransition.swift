import SwiftUI

enum HomeEntryReveal {
    private static let lead = 25
    private static let stagger = 48
    private static let growth = 140.0
    private static let settle = 60.0
    private static let restingScale = 1.065
    private static let initialScale = 0.18
    private static let growCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.18, y: 0.72),
                                                    endControlPoint: UnitPoint(x: 0.25, y: 1))
    private static let settleCurve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.18, y: 0.65),
                                                      endControlPoint: UnitPoint(x: 0.28, y: 1))
    static let fadeStart = lead + (AppIconArtwork.barRatios.count - 1) * stagger + Int(growth + settle) + 66
    static let fadeDuration = 0.14

    static func bar(at index: Int, elapsed: Double) -> (scale: Double, opacity: Double) {
        let time = elapsed - Double(lead + index * stagger)
        if time <= 0 { return (initialScale, 0) }
        if time < growth {
            let progress = growCurve.value(at: time / growth)
            return (initialScale + (restingScale - initialScale) * progress, progress)
        }
        if time < growth + settle {
            let progress = settleCurve.value(at: (time - growth) / settle)
            return (restingScale - (restingScale - 1) * progress, 1)
        }
        return (1, 1)
    }
}

struct HomeEntryMask: View {
    var startedAt: ContinuousClock.Instant? = nil
    var resting = false
    private static let size: CGFloat = 82
    private static let bars = AppIconArtwork.waveformBars(
        in: CGRect(x: 0, y: 0, width: size, height: size)
    )

    var body: some View {
        Color.white
            .overlay {
                if let startedAt {
                    TimelineView(.animation(paused: resting)) { _ in
                        let elapsed = resting ? Double(HomeEntryReveal.fadeStart)
                            : startedAt.duration(to: .now) / .milliseconds(1)
                        waveform(elapsed: elapsed)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func waveform(elapsed: Double) -> some View {
        ZStack {
            ForEach(Self.bars.indices, id: \.self) { index in
                let shape = Self.bars[index]
                let pose = HomeEntryReveal.bar(at: index, elapsed: elapsed)
                Capsule()
                    .fill(Color(cgColor: AppIconArtwork.waveformColor(at: index)))
                    .frame(width: shape.width, height: shape.height)
                    .scaleEffect(x: 1, y: pose.scale)
                    .opacity(pose.opacity)
                    .position(x: shape.midX, y: shape.midY)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }
}

struct HomeEntryTransition<Content: View>: View {
    let request: Int?
    var startupCovered = false
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entry: Entry?

    private struct Entry {
        enum Phase { case holding, fading, revealed }
        let id = UUID()
        let request: Int
        let startedAt = ContinuousClock.now
        var phase = Phase.holding
    }

    private var activeRequest: Int? { reduceMotion || startupCovered ? nil : request }

    var body: some View {
        let current = entry?.request == activeRequest ? entry : nil
        let fading = current?.phase == .fading
        let covering = startupCovered || (activeRequest != nil && current?.phase != .revealed)
        content(covering)
            .overlay {
                if covering {
                    HomeEntryMask(startedAt: current?.startedAt, resting: fading)
                        .opacity(fading ? 0 : 1)
                }
            }
            .onChange(of: activeRequest) { _, next in
                if next == nil { entry = nil }
            }
            .task(id: activeRequest) {
                if let request = activeRequest { await reveal(request) }
            }
    }

    @MainActor
    private func reveal(_ request: Int) async {
        let current = Entry(request: request)
        entry = current
        do { try await Task.sleep(for: .milliseconds(HomeEntryReveal.fadeStart)) }
        catch { return }
        guard entry?.id == current.id, activeRequest == request, !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: HomeEntryReveal.fadeDuration), completionCriteria: .logicallyComplete) {
            entry?.phase = .fading
        } completion: {
            guard entry?.id == current.id, activeRequest == request else { return }
            entry?.phase = .revealed
        }
    }
}
