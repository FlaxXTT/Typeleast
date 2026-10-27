import SwiftUI

struct PersonalizationPendingBadge: View {
    @ObservedObject private var preferences = PreferenceExamples.shared
    var body: some View { if !preferences.pending.isEmpty { Text("\(preferences.pending.count)").font(.caption).foregroundColor(Theme.secondary) } }
}
struct PersonalizationDetails: View {
    @ObservedObject private var preferences = PreferenceExamples.shared
    @EnvironmentObject var model: AppModel
    let entry: LocalHistoryEntry
    private func referenceTitle(_ reference: PersonalizationReference) -> String {
        let subject: String
        if reference.kind == "example" { subject = L10n.text("表达示例") }
        else { subject = reference.word ?? reference.label ?? reference.sourceId }
        var source = L10n.text("个人偏好")
        if reference.source == "extension" {
            let label = reference.label.flatMap { $0.isEmpty ? nil : $0 } ?? reference.sourceId
            source = L10n.text("扩展") + ": " + label
        }
        return subject + " · " + source
    }
    var body: some View {
        if let trace = entry.personalization {
            DisclosureGroup(L10n.text("本次参考与修改")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(trace.disabled ? "本次未使用个性化资料。" : "以下是提供给模型的参考，不表示模型一定采用了它们。"))
                        .font(.caption).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(trace.references.prefix(64).enumerated()), id: \.offset) { _, reference in
                        HStack {
                            Text(referenceTitle(reference)).font(.caption)
                            Spacer()

                        }
                    }
                    if trace.restored == true { Text(L10n.text("本次替换已撤销，已粘贴到其他程序的内容未改动。")).font(.caption) }
                    ForEach(trace.replacements) { replacement in Text((replacement.heard ?? "") + " → " + (replacement.word ?? "")).font(.caption) }
                    if !trace.blocked.isEmpty { Text(L10n.text("部分高级替换因本次表达或校验未执行。")).font(.caption).foregroundColor(Theme.secondary) }
                    if trace.beforeReplacements != nil { Button(L10n.text("恢复替换前结果并复制")) { model.actions?.undoEntryReplacement(id: entry.id) } }
                }.padding(.top, 6)
            }.font(.system(size: 12))
        }
    }
}
