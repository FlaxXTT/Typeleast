import SwiftUI
import AppKit
import Combine

// HubWindow.swift - the main window: a quiet
// sidebar (Home, History; Settings at the bottom left) and one page.

final class HubWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settingsWindow: SettingsWindowController
    private var settingsPresentation: AnyCancellable?
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        settingsWindow = SettingsWindowController(model: model)
        super.init()
        settingsPresentation = model.$settingsPresented.receive(on: DispatchQueue.main).sink { [weak self] presented in
            guard let self else { return }
            if presented { self.settingsWindow.show(relativeTo: self.window) }
            else { self.settingsWindow.close() }
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var themeTransitionWindow: NSWindow? { isVisible ? window : nil }
    var settingsThemeTransitionWindow: NSWindow? { settingsWindow.visibleWindow }

    func show(page: HubPage? = nil) {
        if model.settings.needsPractice && page != .settings { model.actions?.showOnboarding(); return }
        if let page = page { model.navigate(to: page) }
        model.homePresentationID &+= 1
        if window == nil { window = makeWindow() }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        // AppKit lays out the title bar again on first presentation. Reposition the
        // native buttons afterwards so they stay inside the window curve.
        DispatchQueue.main.async { [weak window] in
            if let window { AppWindowStyle.round(window) }
        }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: HubRootView().environmentObject(model))
        let window = NSWindow(contentViewController: host)
        window.title = "TypeLeast"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        let size = NSSize(width: 1080, height: 750)
        window.setContentSize(size)
        AppWindowStyle.fixSize(window, to: size)
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.center()
        // Keep this frame record separate from the old resizable window.
        window.setFrameAutosaveName("typeleast.hub.1080x750")
        window.delegate = self
        AppWindowStyle.round(window)
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { AppWindowStyle.round(window) }
        model.refreshPermissions()
        // The service may have restarted on a new port since the last check.
        model.actions?.recheckHealth()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.homePresentationID &+= 1
    }
}

struct HubRootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showsCommands = false
    @State private var pendingCommand: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(showsCommands: $showsCommands)
                .frame(width: Theme.sidebarWidth - 8)
                .background(RoundedRectangle(cornerRadius: Theme.sidebarRadius).fill(Theme.sidebar))
                .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
            ZStack {
                Theme.window
                switch model.page {
                case .home: HomePage()
                case .history: HistoryPage()
                case .meetings: MeetingsPage().environmentObject(model.meeting)
                case .settings: HomePage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1080, height: 750)
        .background(Theme.window)
        .font(Theme.bodyFont)
        .foregroundColor(Theme.ink)
        .tint(Theme.accent)
        .overlay(alignment: .top) { WindowDragRegion().frame(height: 44).padding(.leading, 84) }
        .overlay(alignment: .bottomTrailing) { HubNoticeStack() }
        .overlay(alignment: .bottomTrailing) { FixedWindowCornerRegion().frame(width: 16, height: 16) }
        .sheet(isPresented: $showsCommands, onDismiss: {
            let action = pendingCommand
            pendingCommand = nil
            action?()
        }) {
            HubCommandPalette { command in
                pendingCommand = command.run
                showsCommands = false
            }.environmentObject(model)
        }
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showsCommands: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                AppMarkView(size: 26).accessibilityHidden(true)
                Text("TypeLeast").font(.custom("Prompt-SemiBold", size: 20)).tracking(-0.4)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)
            .overlay { WindowDragRegion() }

            Button { showsCommands = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(L10n.text("搜索与命令"))
                    Spacer()
                    Text("⌘K").font(.system(size: 11)).foregroundColor(Theme.tertiary)
                }
                .font(Theme.rowFont).foregroundColor(Theme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(Theme.cardHover))
            }
            .buttonStyle(.plain).hoverInteraction()
            .keyboardShortcut("k", modifiers: .command)
            .padding(.bottom, 12)
            .disabled(model.settings.needsPractice)

            ForEach([HubPage.home, .history, .meetings]) { page in
                SidebarItem(page: page).disabled(model.settings.needsPractice)
            }

            Spacer()

            SidebarModes()
                .padding(.bottom, 8)
            ServiceBadge()
                .padding(.bottom, 8)
            Divider().overlay(Theme.border).padding(.vertical, 8)
            HStack(spacing: 4) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/FlaxXTT/Typeleast")!)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope").font(.system(size: 16))
                        Text(L10n.text("联系我们")).font(Theme.rowFont)
                    }
                    .frame(minHeight: 32)
                }
                .buttonStyle(.plain).foregroundColor(Theme.secondary).hoverInteraction()
                .help(L10n.text("联系我们"))
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", help: L10n.text("设置"), size: 32) { model.navigate(to: .settings) }
                    .background(RoundedRectangle(cornerRadius: Theme.radius)
                        .fill(model.settingsPresented ? Theme.selection : Color.clear))
                IconButton(symbol: "questionmark.circle", help: L10n.text("帮助"), size: 32) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/FlaxXTT/Typeleast#readme")!)
                }
            }
        }
        .padding(EdgeInsets(top: 44, leading: 12, bottom: 8, trailing: 12))
    }
}

private struct SidebarItem: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let page: HubPage
    @State private var hovering = false

    private var icon: some View {
        SidebarMotionIcon(page: page, selected: page == .settings ? model.settingsPresented : model.page == page,
                          hovering: hovering)
    }

    var body: some View {
        let selected = page == .settings ? model.settingsPresented : model.page == page
        Button {
            model.navigate(to: page)
        } label: {
            HStack(spacing: 10) {
                icon
                    .frame(width: 16, height: 16)
                Text(page.title).font(Theme.rowFont)
                Spacer()
            }
            .foregroundColor(selected ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular)
                .fill(selected ? Theme.selection : (hovering ? Theme.cardHover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Theme.fast, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Compact service state at the bottom of the sidebar.
private struct ServiceBadge: View {
    @EnvironmentObject var model: AppModel

    private var badgeText: String {
        if model.serviceUp { return L10n.text("本地服务就绪") }
        if model.modelsDownloading {
            return L10n.text("正在下载模型 ") + (model.speech?.downloadFraction.map { String(Int($0 * 100)) + "%" } ?? "…")
        }
        if model.modelsMissing { return L10n.text("语音模型未下载") }
        if case .running = model.serviceState { return L10n.text("正在加载语音模型") }
        return L10n.text("本地服务未就绪")
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.serviceUp ? Theme.success : Theme.warning)
                .frame(width: 7, height: 7)
            Text(badgeText)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.secondary)
                .lineLimit(1)
            Spacer()
            if model.modelsMissing {
                Button(L10n.text("下载模型")) { model.actions?.downloadModels() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .hoverInteraction()
            } else if !model.serviceUp && !model.modelsDownloading {
                Button(L10n.text("重启")) { model.actions?.restartService() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .hoverInteraction()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(Theme.card))
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
                Text(title).font(Theme.titleFont).tracking(-0.6).frame(height: 40, alignment: .leading)
                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(Theme.captionFont).foregroundColor(Theme.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.pageInset)
        .padding(.top, 44)
        .padding(.bottom, 16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The cleanup modes, in the sidebar so they are one click away on every page and apart
/// from Settings. The chosen one shows what it does in a few words.
struct SidebarModes: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { model.actions?.startAssistant() } label: {
                Label(L10n.text("提示词模式"), systemImage:"text.bubble")
                    .font(.system(size: 14,weight:.medium)).padding(10)
            }.buttonStyle(.plain).hoverInteraction()
        }
        .disabled(model.phase != .idle)
        .help(model.phase == .idle ? "" : L10n.text("说完再切换"))
    }
}

/// Equal-width segments can wrap translated labels without widening the window.
struct FlexibleSegment: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: selected ? .medium : .regular))
                .foregroundColor(selected ? Theme.accent : Theme.secondary).multilineTextAlignment(.center)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(selected ? Theme.selection : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).hoverInteraction()
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
