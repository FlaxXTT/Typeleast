import SwiftUI

/// Main-window notices have their own observable state, separate from live recording.
final class HubFeedback: ObservableObject {
    static let shared = HubFeedback()
    struct Notice: Identifiable {
        let id = UUID()
        let message: String
        let undo: (() -> Void)?
        let expired: (() -> Void)?
    }
    @Published private(set) var notices: [Notice] = []
    private var dismissals: [UUID: DispatchWorkItem] = [:]

    func show(_ message: String, undo: (() -> Void)? = nil, expired: (() -> Void)? = nil) {
        if notices.count == 3, let first = notices.first { dismiss(first.id) }
        let notice = Notice(message: message, undo: undo, expired: expired)
        notices.append(notice)
        let work = DispatchWorkItem { [weak self] in self?.dismiss(notice.id) }
        dismissals[notice.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func dismiss(_ id: UUID, undo: Bool = false) {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        dismissals.removeValue(forKey: id)?.cancel()
        let notice = notices.remove(at: index)
        if undo { notice.undo?() } else { notice.expired?() }
    }

    func dismissAll() {
        for id in notices.map(\.id) { dismiss(id) }
    }
}

struct HubNoticeStack: View {
    @ObservedObject private var feedback = HubFeedback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(feedback.notices) { notice in
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.success)
                    Text(notice.message).font(InterfaceTypography.localized(14)).foregroundColor(Theme.ink)
                    if notice.undo != nil {
                        Button(L10n.text("撤销")) { feedback.dismiss(notice.id, undo: true) }
                            .buttonStyle(FlatActionButtonStyle(feedback: .compact)).foregroundColor(Theme.accent)
                    }
                    Button { feedback.dismiss(notice.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(Theme.tertiary)
                    }.buttonStyle(FlatActionButtonStyle(feedback: .fixed)).help(L10n.text("关闭"))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(24)
        .animation(reduceMotion ? nil : Theme.standard, value: feedback.notices.map(\.id))
    }
}
