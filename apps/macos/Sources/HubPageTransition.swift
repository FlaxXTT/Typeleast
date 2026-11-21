import SwiftUI

struct HubPageTransition<Page: Hashable, Content: View>: View {
    let selection: Page
    var animate = true
    @ViewBuilder let content: (Page) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content(selection)
                .id(selection)
                .transition(reduceMotion ? .identity : .push(from: .trailing))
        }
        .clipped()
        .animation(reduceMotion || !animate ? nil : .easeInOut(duration: 0.20), value: selection)
    }
}
