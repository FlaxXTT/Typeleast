import SwiftUI

struct VocabularyPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab = .hotwords
    @State private var search = ""
    @State private var draft: Draft?

    private enum Tab: String, CaseIterable {
        case hotwords, replacements

        var title: String {
            switch self {
            case .hotwords: return L10n.text("热词")
            case .replacements: return L10n.text("替换规则")
            }
        }
        var addTitle: String {
            self == .hotwords ? L10n.text("新增热词") : L10n.text("新增替换")
        }
    }

    private struct Draft: Identifiable {
        let id = UUID()
        let tab: Tab
        var oldWord: String?
        var ruleID: UUID?
        var original = ""
        var replacement = ""
        var context = ""

        var editing: Bool { oldWord != nil || ruleID != nil }
        var word: String { original.trimmingCharacters(in: .whitespacesAndNewlines) }
        var target: String { replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
        var condition: String { context.trimmingCharacters(in: .whitespacesAndNewlines) }
        var fieldsAreValid: Bool {
            guard !word.isEmpty, !word.contains(where: \.isNewline) else { return false }
            return tab == .hotwords || (!target.isEmpty && target != word)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: HubPage.vocabulary.title) {
                Button { draft = Draft(tab: tab) } label: {
                    Label(tab.addTitle, systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            VStack(alignment: .leading, spacing: 14) {
                controls
                if tab == .hotwords { hotwordList }
                else { replacementList }
            }
            .padding(.horizontal, Theme.pageInset)
            .padding(.bottom, 20)
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(item: $draft) { entry in
            VocabularyEditor(draft: entry, duplicate: isDuplicate, save: save)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                Picker(HubPage.vocabulary.title, selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { option in Text(option.title).tag(option) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                        .accessibilityHidden(true)
                    TextField(L10n.text("搜索词表"), text: $search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).frame(width: 192, height: 29)
                .background(Theme.detail, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border).allowsHitTesting(false) }
            }
            Text(tab == .hotwords ? L10n.text("热词随识别请求发送给豆包。") : L10n.text("替换在本机应用于听写和会议转写结果。"))
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
        }
        .onChange(of: tab) { _, _ in search = "" }
    }

    private var hotwordList: some View {
        let items = Vocabulary.hotwords(from: model.settings.doubaoHotwords)
        let visible = items.filter { matches($0) }
        return Group {
            if visible.isEmpty { emptyState(items.isEmpty ? "还没有热词" : "没有匹配的词条") }
            else {
                HubScrollView(key: "vocabulary.hotwords") {
                    LazyVStack(spacing: 7) {
                        ForEach(visible, id: \.self) { word in
                            row(symbol: "waveform", edit: {
                                draft = Draft(tab: .hotwords, oldWord: word, original: word)
                            }, delete: { removeWord(word) }) {
                                Text(word).lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private var replacementList: some View {
        let items = model.settings.vocabularyReplacements
        let visible = items.filter { matches($0.original, $0.replacement, $0.context) }
        return Group {
            if visible.isEmpty { emptyState(items.isEmpty ? "还没有替换规则" : "没有匹配的词条") }
            else {
                HubScrollView(key: "vocabulary.replacements") {
                    LazyVStack(spacing: 7) {
                        ForEach(visible) { rule in
                            row(symbol: "arrow.left.arrow.right", edit: {
                                draft = Draft(tab: .replacements, ruleID: rule.id, original: rule.original,
                                              replacement: rule.replacement, context: rule.context)
                            }, delete: { removeRule(rule) }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(rule.original).foregroundStyle(Theme.secondary)
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                                            .accessibilityHidden(true)
                                        Text(rule.replacement).fontWeight(.medium)
                                    }
                                    .lineLimit(2)
                                    if !rule.context.isEmpty {
                                        Text(L10n.text("同句包含 {0}", rule.context))
                                            .font(Theme.captionFont).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row<Content: View>(symbol: String, edit: @escaping () -> Void, delete: @escaping () -> Void,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                .frame(width: 25, height: 25)
                .background(Theme.selection, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            content().font(Theme.rowFont).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: edit) {
                Image(systemName: "pencil").frame(width: 25, height: 25)
            }
            .buttonStyle(FlatActionButtonStyle(feedback: .compact))
            .help(L10n.text("编辑")).accessibilityLabel(L10n.text("编辑"))
            Button(action: delete) {
                Image(systemName: "trash").frame(width: 25, height: 25)
            }
            .buttonStyle(FlatActionButtonStyle(feedback: .fixed))
            .help(L10n.text("删除")).accessibilityLabel(L10n.text("删除"))
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Theme.detail, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border).allowsHitTesting(false)
        }
    }

    private func emptyState(_ message: String) -> some View {
        Label(L10n.text(message), systemImage: "text.book.closed")
            .font(Theme.rowFont).foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ values: String...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func isDuplicate(_ entry: Draft) -> Bool {
        if entry.tab == .hotwords {
            return Vocabulary.hotwords(from: model.settings.doubaoHotwords).contains {
                $0 != entry.oldWord && $0.caseInsensitiveCompare(entry.word) == .orderedSame
            }
        }
        return model.settings.vocabularyReplacements.contains {
            $0.id != entry.ruleID && $0.original.caseInsensitiveCompare(entry.word) == .orderedSame
                && $0.context.caseInsensitiveCompare(entry.condition) == .orderedSame
        }
    }

    private func save(_ entry: Draft) {
        guard entry.fieldsAreValid, !isDuplicate(entry) else { return }
        if entry.tab == .hotwords {
            var words = Vocabulary.hotwords(from: model.settings.doubaoHotwords)
            if let old = entry.oldWord, let index = words.firstIndex(of: old) { words[index] = entry.word }
            else { words.append(entry.word) }
            model.settings.doubaoHotwords = words.joined(separator: "\n")
        } else {
            var rules = model.settings.vocabularyReplacements
            let rule = VocabularyRule(id: entry.ruleID ?? UUID(), original: entry.word,
                                      replacement: entry.target, context: entry.condition)
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule }
            else { rules.append(rule) }
            model.settings.vocabularyReplacements = rules
        }
    }

    private func removeWord(_ word: String) {
        let settings = model.settings
        var words = Vocabulary.hotwords(from: settings.doubaoHotwords)
        guard let index = words.firstIndex(of: word) else { return }
        words.remove(at: index)
        settings.doubaoHotwords = words.joined(separator: "\n")
        HubFeedback.shared.show(L10n.text("已删除热词"), undo: {
            var latest = Vocabulary.hotwords(from: settings.doubaoHotwords)
            guard !latest.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
            latest.insert(word, at: min(index, latest.count))
            settings.doubaoHotwords = latest.joined(separator: "\n")
        })
    }

    private func removeRule(_ rule: VocabularyRule) {
        let settings = model.settings
        var rules = settings.vocabularyReplacements
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules.remove(at: index)
        settings.vocabularyReplacements = rules
        HubFeedback.shared.show(L10n.text("已删除替换规则"), undo: {
            var latest = settings.vocabularyReplacements
            guard !latest.contains(where: {
                $0.original.caseInsensitiveCompare(rule.original) == .orderedSame
                    && $0.context.caseInsensitiveCompare(rule.context) == .orderedSame
            }) else { return }
            latest.insert(rule, at: min(index, latest.count))
            settings.vocabularyReplacements = latest
        })
    }

    private struct VocabularyEditor: View {
        @Environment(\.dismiss) private var dismiss
        @State var draft: Draft
        let duplicate: (Draft) -> Bool
        let save: (Draft) -> Void

        var body: some View {
            let conflict = duplicate(draft)
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.editing ? L10n.text("编辑 {0}", draft.tab.title) : draft.tab.addTitle)
                    .font(.headline)
                if draft.tab == .hotwords { field("热词", text: $draft.original) }
                else {
                    field("识别文字", text: $draft.original)
                    field("替换为", text: $draft.replacement)
                    field("同句包含（可选）", text: $draft.context)
                }
                if conflict {
                    Text(L10n.text("已有相同的词条。")).font(Theme.captionFont).foregroundStyle(Theme.warning)
                }
                HStack {
                    Spacer()
                    Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("保存")) { save(draft); dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.fieldsAreValid || conflict)
                }
            }
            .padding(22).frame(width: 395)
        }

        private func field(_ label: String, text: Binding<String>) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(label)).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                TextField(L10n.text(label), text: text).labelsHidden().textFieldStyle(.roundedBorder)
            }
        }
    }
}
