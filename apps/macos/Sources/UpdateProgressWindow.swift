import AppKit
import SwiftUI

enum UpdateDialogState {
    case checking
    case latest
    case available(Updater.Release)
    case progress(String, UpdateStage)
    case ready(String, note: String? = nil)
    case message(String, String)
}

final class UpdateProgressModel: ObservableObject {
    @Published var state: UpdateDialogState = .checking
}

private final class UpdateDialogHost: NSHostingView<UpdateProgressView> {
    var dismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// Keep all stages in one dialog, anchored to the window that opened it.
final class UpdateProgressWindow {
    private let model = UpdateProgressModel()
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var host: UpdateDialogHost?
    private var standalone: NSWindow?
    private var closeObserver: NSObjectProtocol?

    var isVisible: Bool { host?.window?.isVisible == true }

    @discardableResult
    func raiseIfVisible() -> Bool {
        guard let window = host?.window, window.isVisible else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func present(in owner: NSWindow?, state: UpdateDialogState,
                 download: @escaping () -> Void, restart: @escaping () -> Void) {
        model.state = state
        if raiseIfVisible() { return }
        close()
        let view = UpdateProgressView(model: model, close: { [weak self] in self?.close() },
                                      download: download, restart: restart)
        let hosting = UpdateDialogHost(rootView: view)
        hosting.dismiss = { [weak self] in self?.close() }
        hosting.sizingOptions = []
        host = hosting

        if let owner, let content = owner.contentView, let frame = content.superview {
            parent = owner
            previousResponder = owner.firstResponder
            hosting.frame = frame.convert(content.bounds, from: content)
            hosting.autoresizingMask = [.width, .height]
            frame.addSubview(hosting, positioned: .above, relativeTo: content)
            NSApp.activate(ignoringOtherApps: true)
            owner.makeKeyAndOrderFront(nil)
            owner.makeFirstResponder(hosting)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                   object: owner, queue: .main) { [weak self] _ in
                self?.close()
            }
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 370),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L10n.text("更新 TypeLeast")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            standalone = window
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func update(_ state: UpdateDialogState) { model.state = state }

    func close() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        if let host, let parent,
           let focused = parent.firstResponder as? NSView,
           focused === host || focused.isDescendant(of: host) {
            parent.makeFirstResponder(previousResponder)
        }
        if let standalone { standalone.orderOut(nil); standalone.contentView = nil }
        else { host?.removeFromSuperview() }
        standalone = nil
        host = nil
        parent = nil
        previousResponder = nil
    }
}

struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel
    let close: () -> Void
    let download: () -> Void
    let restart: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.34).contentShape(Rectangle())
                .onTapGesture(perform: dismissFromBackdrop)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(title).font(InterfaceTypography.localized(20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    IconButton(symbol: "xmark", help: L10n.text("关闭"), size: 24, action: close)
                }
                content
                buttons
            }
            .padding(22)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.tile))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(Theme.bodyFont)
        .foregroundColor(Theme.ink)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
    }

    private func dismissFromBackdrop() {
        switch model.state {
        case .checking, .progress: break
        default: close()
        }
    }

    private var title: String {
        switch model.state {
        case .latest: return L10n.text("已是最新版本")
        case .available(let release): return L10n.text("新版本 ") + release.version
        case .ready: return L10n.text("更新已就绪")
        case .message(let title, _): return title
        default: return L10n.text("更新 TypeLeast")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .checking:
            detail(L10n.text("正在检查更新…"))
            LoadingLinearProgress()
        case .latest:
            detail(L10n.text("TypeLeast {0} 是当前最新版本。", Updater.currentVersion))
        case .available(let release):
            detail(L10n.text("当前版本 ") + Updater.currentVersion)
            if !release.summary.isEmpty {
                ViewThatFits(in: .vertical) {
                    detail(release.summary).fixedSize(horizontal: false, vertical: true)
                    HubScrollView(showsChrome: false) { detail(release.summary) }
                }
                .frame(maxHeight: 150, alignment: .topLeading)
            }
        case .progress(let version, let stage):
            detail(L10n.text("正在更新到 {0}", version))
            detail(stage.label)
            LoadingLinearProgress(value: stage.fraction)
            if let fraction = stage.fraction {
                HStack {
                    InterfaceTypography.text("\(Int(fraction * 100))%", size: 12)
                    Spacer()
                    if let amount = stage.amount { InterfaceTypography.text(amount, size: 12) }
                }.foregroundColor(Theme.secondary)
            }
        case .ready(let version, let note):
            detail(L10n.text("TypeLeast {0} 已下载，重启后完成安装。", version))
            if let note { detail(note) }
        case .message(_, let message):
            detail(message).textSelection(.enabled)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.state {
        case .checking, .progress:
            EmptyView()
        case .available, .ready, .latest, .message:
            HStack {
                Spacer()
                switch model.state {
                case .available:
                    later
                    Button(L10n.text("立即更新"), action: download).buttonStyle(PrimaryButtonStyle())
                case .ready:
                    later
                    Button(L10n.text("立即重启"), action: restart).buttonStyle(PrimaryButtonStyle())
                default:
                    Button(L10n.text("知道了"), action: close).buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var later: some View {
        Button(L10n.text("稍后"), action: close).buttonStyle(SecondaryButtonStyle())
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(Theme.rowFont).foregroundColor(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
