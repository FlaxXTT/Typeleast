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
                            if let word = reference.word { Button(L10n.text(preferences.isExcluded(word) ? "恢复参考" : "不再参考")) { if let saved = preferences.excluded.first(where: { $0.precomposedStringWithCompatibilityMapping.lowercased() == word.precomposedStringWithCompatibilityMapping.lowercased() }) { preferences.restore(saved) } else { preferences.exclude(word) } }.buttonStyle(.plain) }
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
struct PersonalizationRulesPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var preferences = PreferenceExamples.shared
    @State private var term = ""
    @State private var heard = ""
    @State private var spelling = ""
    @State private var undo: (() -> Void)?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("排除与高级规则")).font(.title2)
                if model.settings.vocabularyProblem != nil { Text(L10n.text("偏好资料无法保存或已达上限，原资料已保留。")).foregroundColor(Theme.warning) }
                Text(L10n.text("不再参考会暂停所有来源对该词的推荐和替换，不禁止你当次说出它。扩展更新不会恢复这些影响。"))
                    .font(.caption).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { TextField(L10n.text("要排除的词"), text: $term); Button(L10n.text("不再参考")) { let saved = term; preferences.exclude(saved); term = ""; undo = { preferences.restore(saved) } }.disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(preferences.excluded, id: \.self) { word in HStack { Text(word); Spacer(); Button(L10n.text("恢复参考")) { preferences.restore(word); undo = { preferences.exclude(word) } } } }
                Divider()
                Text(L10n.text("高级显式替换")).font(.headline)
                Text(L10n.text("旧替换保留但默认停用，需逐条开启。当前明确改口、条件和事实校验优先；不会保证每次替换。"))
                    .font(.caption).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(L10n.text("识别成"), text: $heard)
                TextField(L10n.text("正确写法"), text: $spelling)
                Button(L10n.text("保存为停用规则")) { if Settings.shared.addWord(spelling, heardAs: heard, source: .manual, localOnly: true) { heard = ""; spelling = "" } }
                    .disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || spelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || heard == spelling)
                ForEach(model.words.filter { $0.replacementHeard != nil }) { word in
                    Card { VStack(alignment: .leading, spacing: 8) {
                        Text((word.replacementHeard ?? "") + " → " + word.word)
                        Toggle(L10n.text("启用本机替换"), isOn: Binding(get: { preferences.replaces(word) }, set: { value in let old = preferences.replaces(word); preferences.setRule(word, value); undo = { preferences.setRule(word, old) } })).disabled(preferences.isExcluded(word.word) || preferences.isExcluded(word.replacementHeard ?? ""))
                        HStack { Button(L10n.text("不再参考")) { preferences.exclude(word.word); undo = { preferences.restore(word.word) } }; Spacer(); Button(L10n.text("删除"), role: .destructive) { let old = word; Settings.shared.removeWord(id: word.id); undo = { var list = Settings.shared.words; list.insert(old, at: 0); Settings.shared.words = list } } }
                    } }
                }
                if preferences.problem != nil { Text(L10n.text("偏好资料无法保存或已达上限，原资料已保留。")).foregroundColor(Theme.warning) }
                if undo != nil { Button(L10n.text("撤销上次变更")) { undo?(); undo = nil } }
            }.padding(28)
        }.buttonStyle(SecondaryButtonStyle())
    }
}
struct PersonalVocabularyPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var preferences = PreferenceExamples.shared
    @State private var term = ""
    @State private var undo: (() -> Void)?
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("个人词汇")).font(.title2)
            if model.settings.vocabularyProblem != nil { Text(L10n.text("偏好资料无法保存或已达上限，原资料已保留。")).foregroundColor(Theme.warning) }
            Text(L10n.text("词汇只帮助理解，不强制替换。旧自动词汇保留为停用资料，需要你确认后才能参考。"))
                .font(.caption).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { TextField(L10n.text("新词"), text: $term); Button(L10n.text("添加")) { let saved = term; if Settings.shared.addWord(saved, source: .manual) { term = ""; if let item = Settings.shared.words.first(where: { $0.word == saved }) { undo = { Settings.shared.removeWord(id: item.id) } } } }.disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            ForEach(model.words.filter { $0.replacementHeard == nil }) { word in
                Card { VStack(alignment: .leading, spacing: 8) {
                    Text(word.word)
                    Toggle(L10n.text("作为相关参考"), isOn: Binding(get: { preferences.references(word) }, set: { value in let old = preferences.references(word); preferences.setReference(word.id, value); undo = { preferences.setReference(word.id, old) } })).disabled(word.localOnly == true || preferences.isExcluded(word.word))
                    HStack { Button(L10n.text("不再参考")) { preferences.exclude(word.word); undo = { preferences.restore(word.word) } }; Spacer(); Button(L10n.text("删除"), role: .destructive) { let old = word; Settings.shared.removeWord(id: word.id); undo = { var words = Settings.shared.words; words.insert(old, at: 0); Settings.shared.words = words } } }
                } }
            }
            if undo != nil { Button(L10n.text("撤销上次变更")) { undo?(); undo = nil } }
            DisclosureGroup(L10n.text("导入与旧资料管理")) { ManualDictionaryPage().frame(minHeight: 500) }
        }.padding(28) }.buttonStyle(SecondaryButtonStyle())
    }
}
