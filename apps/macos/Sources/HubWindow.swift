import SwiftUI
import AppKit

// HubWindow.swift - the main window, laid out like Reference's desktop app: a quiet
// sidebar (Home, History, Dictionary; Settings at the bottom left) and one page.

final class HubWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(page: HubPage? = nil) {
        if let page = page { model.page = page }
        if window == nil { window = makeWindow() }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: HubRootView().environmentObject(model))
        let window = NSWindow(contentViewController: host)
        window.title = "TypeLeast"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 940, height: 640))
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("typeleast.hub")
        window.delegate = self
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPermissions()
        // The service may have restarted on a new port since the last check.
        model.actions?.recheckHealth()
    }
}

struct HubRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 214)
                .background(Theme.sidebar)
            Divider().opacity(0.6)
            ZStack {
                Theme.window
                switch model.page {
                case .home: HomePage()
                case .history: HistoryPage()
                case .dictionary: DictionaryPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                AppMarkView(size: 26)
                Text("TypeLeast").font(.system(size: 16, weight: .bold))
            }
            .padding(.top, 44)
            .padding(.horizontal, 18)
            .padding(.bottom, 22)

            ForEach([HubPage.home, .history, .dictionary]) { page in
                SidebarItem(page: page)
            }

            Spacer()

            ServiceBadge()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            SidebarItem(page: .settings)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 8)
    }
}

private struct SidebarItem: View {
    @EnvironmentObject var model: AppModel
    let page: HubPage
    @State private var hovering = false

    var body: some View {
        let selected = model.page == page
        Button {
            model.page = page
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 18)
                Text(page.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundColor(selected ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Compact service state at the bottom of the sidebar.
private struct ServiceBadge: View {
    @EnvironmentObject var model: AppModel

    private var badgeText: String {
        if model.serviceUp { return L10n.text("本地服务已就绪") }
        if model.modelsDownloading {
            return L10n.text("下载模型 ") + (model.speech?.downloadFraction.map { String(Int($0 * 100)) + "%" } ?? "…")
        }
        if model.modelsMissing { return L10n.text("语音模型未下载") }
        if case .running = model.serviceState { return L10n.text("语音模型加载中") }
        return L10n.text("本地服务未就绪")
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.serviceUp ? Theme.success : Theme.warning)
                .frame(width: 7, height: 7)
            Text(badgeText)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.secondary)
                .lineLimit(1)
            Spacer()
            if model.modelsMissing {
                Button(L10n.text("下载模型")) { model.actions?.downloadModels() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.ink)
            } else if !model.serviceUp && !model.modelsDownloading {
                Button(L10n.text("重启")) { model.actions?.restartService() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.ink)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
    }
}

/// Large page title plus optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold))
                if let subtitle = subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundColor(Theme.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 18)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
