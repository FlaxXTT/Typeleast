import SwiftUI

/// The dictionary: the user's own words, plus the bundled technical terms switch.
struct DictionaryPage: View {
    @EnvironmentObject var model: AppModel
    // Kept for existing developer render callers.
    init(initialTab: Int = 0) {}
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManualDictionaryPage()
            TechTermsRow(plugins: model.plugins)
                .padding(.horizontal, 36).padding(.bottom, 20)
        }
    }
}

/// One switch for the bundled technical-terms pack.
private struct TechTermsRow: View {
    @ObservedObject var plugins: PluginController
    var body: some View {
        if let pack = plugins.techTerms {
            Toggle(L10n.text("技术术语"), isOn: Binding(get: { pack.enabled == true }, set: { plugins.setEnabled(pack.id, $0) }))
                .toggleStyle(.switch).font(.system(size: 13))
                .onAppear { plugins.refresh() }
        } else {
            Color.clear.frame(height: 0).onAppear { plugins.refresh() }
        }
    }
}
