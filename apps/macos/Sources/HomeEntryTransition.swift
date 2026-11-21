import SwiftUI

struct HomeEntryMask: View {
    var body: some View {
        Color.white
            .overlay { AppMarkView(size: 82, surface: .waveformOnly) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct HomeEntryTransition<Content: View>: View {
    let request: Int?
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entry: Entry?

    private struct Entry {
        enum Phase { case holding, fading, revealed }
        let id = UUID()
        let request: Int
        var phase = Phase.holding
    }

    private var activeRequest: Int? { reduceMotion ? nil : request }

    var body: some View {
        let phase = entry?.request == activeRequest ? entry?.phase : nil
        let covering = activeRequest != nil && phase != .revealed
        content(covering)
            .overlay {
                if covering {
                    HomeEntryMask().opacity(phase == .fading ? 0 : 1)
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
        do { try await Task.sleep(for: .milliseconds(320)) }
        catch { return }
        guard entry?.id == current.id, activeRequest == request, !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.14), completionCriteria: .logicallyComplete) {
            entry?.phase = .fading
        } completion: {
            guard entry?.id == current.id, activeRequest == request else { return }
            entry?.phase = .revealed
        }
    }
}
