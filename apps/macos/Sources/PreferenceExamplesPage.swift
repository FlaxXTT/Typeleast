import SwiftUI

/// Preference review is a page, not a modal dialog over the user's work.
struct DictionaryPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var examples = PreferenceExamples.shared
    @State private var selected = 0
    init(initialTab: Int = 0) { _selected = State(initialValue: initialTab) }
    var body: some View {
        VStack(spacing: 0) {
            ChipPicker(options: [(0, L10n.text("表达示例（{0}）", examples.pending.count)), (1, L10n.text("个人词汇")), (2, L10n.text("排除与高级规则"))], selection: $selected)
                .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 14)
            if selected == 1 { PersonalVocabularyPage() }
            else if selected == 2 { PersonalizationRulesPage() }
            else {
                PageHeader(title: L10n.text("偏好示例"), subtitle: L10n.text("保存真实识别与用户确认的修改，不自动训练模型。")) {}
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Card { ExplanationMarkerPicker() }
                        Text(L10n.text("仅在本机加密保存。只有相关且已确认、启用的短示例会随自然整理或 AI 整理发给当前模型；涉及名称或数值变化的示例不作为自动替换依据。"))
                            .font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("已确认资料独立保存，清空历史不会删除；可在本页删除。")).font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        if examples.problem != nil {
                            Text(L10n.text("偏好资料无法保存或已达上限，原资料已保留。"))
                                .font(.system(size: 12)).foregroundColor(Theme.warning)
                        }
                        if !examples.pending.isEmpty {
                            Text(L10n.text("待确认的修改")).font(.headline)
                            ForEach(examples.pending) { item in PreferenceReviewCard(item: item) }
                        }
                        if examples.entries.isEmpty && examples.pending.isEmpty {
                            Text(L10n.text("在历史中选择一条 AI 整理记录，点击「记录偏好」，再填写最终修改。旧词典仍保留在手工词典中。"))
                                .foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(examples.entries) { item in
                            Card {
                                VStack(alignment: .leading, spacing: 12) {
                                    PreferencePair(item: item)
                                    HStack {
                                        Toggle(L10n.text("启用相关示例"), isOn: Binding(get: { examples.entries.first(where: { $0.id == item.id })?.enabled ?? false }, set: { examples.setEnabled(item.id, $0) }))
                                        Spacer()
                                        Button(L10n.text("删除"), role: .destructive) { examples.remove(item.id) }.buttonStyle(SecondaryButtonStyle())
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 36).padding(.bottom, 24)
                }
            }
        }
    }
}

private struct PreferencePair: View {
    let item: PreferenceExample
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("AI 整理前（识别原文）")).font(.caption).foregroundColor(Theme.secondary)
            Text(item.raw).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("用户修改后")).font(.caption).foregroundColor(Theme.secondary)
            Text(item.correctedText).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L10n.text("处理结果（供对照）")) { Text(item.aiText).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct PreferenceReviewCard: View {
    @ObservedObject private var examples = PreferenceExamples.shared
    let item: PreferenceExample
    @State private var edited = ""
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("AI 整理前（识别原文）")).font(.caption).foregroundColor(Theme.secondary)
                Text(item.raw).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(L10n.text("处理结果（供对照）")) { Text(item.aiText).font(.system(size: 12)).textSelection(.enabled) }
                Text(L10n.text("用户修改后")).font(.caption).foregroundColor(Theme.secondary)
                TextEditor(text: $edited).font(.system(size: 13)).frame(minHeight: 100, maxHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                Text(L10n.text("确认后才保存并允许作为相关示例；不修改模型权重。待确认内容只保留在内存中。"))
                    .font(.system(size: 12)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.text("确认并启用")) {
                        var confirmed = item; confirmed.correctedText = edited.trimmingCharacters(in: .whitespacesAndNewlines)
                        _ = examples.confirm(confirmed)
                    }.buttonStyle(PrimaryButtonStyle()).disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || edited == item.aiText || edited.count > 4000)
                    Button(L10n.text("忽略")) { examples.dismiss(item.id) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }.onAppear { edited = item.correctedText }.onDisappear { examples.stageRevision(item.id, edited) }
    }
}
