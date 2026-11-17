import SwiftUI
import AppKit

struct HubCommandAction { let run: () -> Void }

struct HubCommandPalette: View {
    let select: (HubCommandAction) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0

    private struct Result: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let run: () -> Void
    }

    private var results: [Result] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var commands = HubPage.allCases.map { page in
            Result(id: "page-" + page.rawValue, title: page.title, detail: L10n.text("打开页面"), symbol: page.symbol) {
                model.page = page
            }
        }
        commands += AppearancePreference.allCases.map { appearance in
            Result(id: "theme-" + appearance.rawValue, title: L10n.text("外观") + " · " + appearance.label,
                   detail: L10n.text("切换主题"), symbol: "circle.lefthalf.filled") {
                model.settings.appearance = appearance
                model.actions?.applyGeneralSettings()
            }
        }
        if model.phase == .idle || model.phase == .recording {
            commands.append(Result(id: "dictation", title: model.phase == .recording ? L10n.text("结束听写") : L10n.text("开始听写"),
                                   detail: model.hotkeyLabel, symbol: "mic") { model.actions?.toggleDictation() })
        }
        let matches = commands.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
        let history = Array(model.history.lazy.filter {
            !query.isEmpty && ($0.displayText.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query))
        }.prefix(8)).map { entry in
            Result(id: "entry-" + entry.id, title: entry.title,
                   detail: Formatters.dayTitle(entry.ts) + " · " + AppNames.name(for: entry.app), symbol: "text.alignleft") {
                model.selectedHistoryID = entry.id
                model.page = .history
            }
        }
        return matches + history
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.tertiary)
                CommandSearchField(text: $query, move: move, submit: { activate(selected) }, cancel: { dismiss() })
                    .frame(maxWidth: .infinity).frame(height: 24)
                Button { dismiss() } label: { Keycap(label: "esc") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            Divider().overlay(Theme.border)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 4) {
                        if results.isEmpty {
                            Text(L10n.text("没有匹配的记录或命令"))
                                .foregroundColor(Theme.secondary).frame(maxWidth: .infinity).padding(32)
                        }
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button { activate(index) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: result.symbol).frame(width: 20).foregroundColor(Theme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(result.detail).font(.system(size: 11)).foregroundColor(Theme.tertiary).lineLimit(1)
                                    }
                                    Spacer()
                                    if selected == index { Image(systemName: "return").foregroundColor(Theme.tertiary) }
                                }
                                .foregroundColor(Theme.ink).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(selected == index ? Theme.selection : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(index)
                            .onHover { if $0 { selected = index } }
                        }
                    }.padding(8)
                }
                .onChange(of: selected) { _, value in scroll.scrollTo(value) }
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                Text(L10n.text("↑↓ 选择 · Enter 打开 · Esc 关闭"))
                Spacer()
                Text("⌘K")
            }
            .font(.system(size: 11)).foregroundColor(Theme.tertiary).padding(.horizontal, 40).padding(.vertical, 24)
        }
        .frame(width: 560, height: 420)
        .background(Theme.window).foregroundColor(Theme.ink)
        .background(RoundedWindowMarker()).buttonBorderShape(.capsule)
        .onChange(of: query) { _, _ in selected = 0 }
        .onMoveCommand { direction in
            switch direction {
            case .down: move(1)
            case .up: move(-1)
            default: break
            }
        }
        .onExitCommand { dismiss() }
    }

    private func activate(_ index: Int) {
        let matches = results
        guard matches.indices.contains(index) else { return }
        select(HubCommandAction(run: matches[index].run))
    }

    private func move(_ delta: Int) {
        selected = min(max(0, results.count - 1), max(0, selected + delta))
    }
}

/// Route navigation keys through the field editor while preserving native text input.
private struct CommandSearchField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CommandQueryField {
        let field = CommandQueryField()
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 16)
        field.placeholderString = L10n.text("搜索记录、页面或命令")
        field.setAccessibilityLabel(L10n.text("搜索记录、页面或命令"))
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: CommandQueryField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = NSColor(Theme.ink)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandSearchField
        init(_ parent: CommandSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Let the input method handle candidate navigation and confirmation.
            if textView.hasMarkedText() { return false }
            switch NSStringFromSelector(selector) {
            case "moveDown:": parent.move(1)
            case "moveUp:": parent.move(-1)
            case "insertNewline:": parent.submit()
            case "cancelOperation:": parent.cancel()
            default: return false
            }
            return true
        }
    }
}

private final class CommandQueryField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
