import AppKit
import SwiftUI

// ModelAdvisor.swift - the end of 提示词模式: once the prompt is delivered, a card says in large type
// which of the current app's models suits it. The service reads the vendor's official page for
// this (tasks/model-recommend.js); the card is apart from the prompt and never pasted.

enum ModelCardState: Equatable {
    case loading
    case done(ModelRecommendation)
    case failed(String)
}

final class ModelAdvisor {
    /// How long a card that recommends nothing stays.
    static let failureSeconds: TimeInterval = 6

    private let client: ServiceClient
    private let panel = SelectionPanel()
    private var generation = 0
    private var closeTimer: Timer?

    init(client: ServiceClient) { self.client = client }

    /// In a browser or a terminal only the window title says which tool it is (ChatGPT in Chrome,
    /// Claude Code in iTerm). Elsewhere the title is not needed, so it is not read.
    static func titleNamesTool(bundleId: String) -> Bool {
        bundleId == "com.apple.Safari" || Inserter.readsSelectionByCopy(bundleId) || TerminalGuard.isTerminal(bundleId)
    }

    func recommend(task: String, appBundleId: String, field: FocusedField?, route: LLMRoute) {
        var title = ""
        if ModelAdvisor.titleNamesTool(bundleId: appBundleId) {
            title = field?.context.windowTitle ?? ""
            if title.isEmpty, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == appBundleId {
                title = FieldContextReader.windowTitle(ofApp: appBundleId) ?? ""
            }
        }
        generation += 1
        let token = generation
        closeTimer?.invalidate()
        panel.hide()
        // An app without a model list answers at once: only a real wait shows the card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.generation == token else { return }
            self.show(.loading)
        }
        let windowTitle = title
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.client.recommendModelSync(task: task, appBundleId: appBundleId, windowTitle: windowTitle, llm: route) }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.generation += 1 // The pending "loading" card must not appear after this.
                self.finish(result)
            }
        }
    }

    private func finish(_ result: Result<ModelRecommendationReply, Error>) {
        switch result {
        case .success(let reply):
            if let recommendation = reply.recommendation {
                show(.done(recommendation))
            } else if reply.notice == "page-unavailable" {
                fail(L10n.text("暂时查不到 {0} 的模型，这次不推荐", reply.app ?? ""))
            } else if reply.notice == "no-match" {
                fail(L10n.text("这次没有合适的模型可推荐"))
            } else {
                panel.hide()
            }
        case .failure:
            fail(L10n.text("这次没有合适的模型可推荐"))
        }
    }

    private func fail(_ message: String) {
        show(.failed(message))
        let token = generation
        let timer = Timer(timeInterval: ModelAdvisor.failureSeconds, repeats: false) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.panel.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func show(_ state: ModelCardState) {
        // The top right corner of the screen the mouse is on, clear of the text being worked on.
        let mouse = NSEvent.mouseLocation
        let frame = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.showCard(at: NSPoint(x: frame.maxX - 1, y: frame.maxY - 1)) { [weak self] drag, ended in
            ModelRecommendationCard(state: state, close: { [weak self] in
                self?.generation += 1
                self?.closeTimer?.invalidate()
                self?.panel.hide()
            }, drag: drag, dragEnded: ended)
        }
    }
}

/// The recommendation: the model's name is the largest thing on it, so it can be read at a glance.
struct ModelRecommendationCard: View {
    let state: ModelCardState
    let close: () -> Void
    let drag: () -> Void
    let dragEnded: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(heading).font(.system(size: 15, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("关闭"))
            }
            switch state {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在联网查当前软件的模型…")).font(.system(size: 17))
                }
            case .done(let recommendation):
                Text(recommendation.model)
                    .font(.system(size: 36, weight: .bold))
                    .lineLimit(2).minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                if !recommendation.reason.isEmpty {
                    Text(recommendation.reason).font(.system(size: 19)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("来自 {0}", recommendation.source)).font(.system(size: 12)).foregroundColor(.secondary)
            case .failed(let message):
                Text(message).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { _ in drag() }.onEnded { _ in dragEnded() })
        .padding(4)
    }

    private var heading: String {
        if case .done(let recommendation) = state { return L10n.text("推荐在 {0} 里使用", recommendation.app) }
        return L10n.text("推荐模型")
    }
}
