import SwiftUI
import AppKit
import Combine

// HubWindow.swift - the main window: a quiet
// sidebar (Home, History; Settings at the bottom left) and one page.

final class HubWindowController: NSObject, NSWindowDelegate {
    fileprivate static let size = NSSize(width: 944, height: 656)
    private var window: NSWindow?
    private let settingsWindow: SettingsWindowController
    private var settingsPresentation: AnyCancellable?
    private var requestedRestorePage: HubPage?
    private var startupMask: NSView?
    private var maskTimeout: DispatchWorkItem?
    private var homePresentationPending = true
    private(set) var shellCommitted = false
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
    func dismissSettingsIfVisible() -> Bool { settingsWindow.closeIfVisible() }

    var updateDialogWindow: NSWindow? {
        if let settings = settingsWindow.visibleWindow, settings.isKeyWindow { return settings }
        return themeTransitionWindow ?? settingsWindow.visibleWindow
    }

    func prepareForUpdate() {
        for parent in [window, settingsWindow.visibleWindow].compactMap({ $0 }) {
            if let sheet = parent.attachedSheet {
                parent.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
        settingsWindow.closeImmediately()
    }

    func openMainWindow() { show(page: .home) }

    func reopenMainWindow() {
        guard let window, !window.isMiniaturized,
              window.isVisible || (NSApp.isHidden && !model.homePresentationSuspended) else {
            openMainWindow()
            return
        }
        guard !NSApp.isActive || NSApp.keyWindow == nil else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        (settingsWindow.visibleWindow ?? window).makeKeyAndOrderFront(nil)
    }

    func applicationDidBecomeActive() { playHomePresentationIfVisible() }

    func applicationDidResignActive() {
        if !model.settingsPresented { homePresentationPending = true }
    }

    func show(page: HubPage = .home) {
        if model.settings.needsPractice && page != .settings { model.actions?.showOnboarding(); return }
        if window == nil { window = makeWindow() }
        guard let window else { return }
        if window.isMiniaturized {
            requestedRestorePage = page
        } else {
            present(page)
        }
        model.refreshPermissions()
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive { playHomePresentationIfVisible() }
        // AppKit lays out the title bar again on first presentation. Reposition the
        // native buttons afterwards so they stay inside the window curve.
        DispatchQueue.main.async { [weak window] in
            if let window { AppWindowStyle.round(window) }
        }
    }

    private func makeWindow() -> NSWindow {
        let container = NSViewController()
        container.view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let mask = NSHostingView(rootView: HomeEntryMask().ignoresSafeArea())
        mask.frame = container.view.bounds
        mask.autoresizingMask = [.width, .height]
        container.view.addSubview(mask)
        startupMask = mask

        let window = NSWindow(contentViewController: container)
        window.title = "TypeLeast"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        AppWindowStyle.fixSize(window, to: Self.size)
        window.collectionBehavior.insert(.fullScreenNone)
        window.isReleasedWhenClosed = false
        window.center()
        // Keep this frame record separate from the old resizable window.
        window.setFrameAutosaveName("typeleast.hub.944x656")
        window.delegate = self
        AppWindowStyle.round(window)

        let timeout = DispatchWorkItem { [weak self] in self?.removeStartupMask() }
        maskTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let host = NSHostingController(rootView: HubRootView().environmentObject(self.model))
            host.sizingOptions = []
            container.addChild(host)
            host.view.frame = container.view.bounds
            host.view.autoresizingMask = [.width, .height]
            container.view.addSubview(host.view, positioned: .below, relativeTo: self.startupMask)
            container.view.layoutSubtreeIfNeeded()
            container.view.displayIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.shellCommitted = true
                self.userCacheDidLoad()
            }
        }
        return window
    }

    func userCacheDidLoad() {
        guard model.userCacheReady, shellCommitted else { return }
        removeStartupMask()
        model.loadDashboard()
    }

    private func removeStartupMask() {
        maskTimeout?.cancel()
        maskTimeout = nil
        startupMask?.removeFromSuperview()
        startupMask = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { AppWindowStyle.round(window) }
        if NSApp.isActive { playHomePresentationIfVisible() }
        model.refreshPermissions()
        // The service may have restarted on a new port since the last check.
        model.actions?.recheckHealth()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !dismissSettingsIfVisible()
    }

    func windowWillClose(_ notification: Notification) {
        homePresentationPending = true
        model.homePresentationSuspended = true
    }

    func windowWillMiniaturize(_ notification: Notification) {
        homePresentationPending = true
        model.homePresentationSuspended = true
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        let page = requestedRestorePage ?? .home
        requestedRestorePage = nil
        present(page)
        if NSApp.isActive { playHomePresentationIfVisible() }
    }

    private func present(_ page: HubPage) {
        model.homePresentationSuspended = false
        model.sidebarBrandPalette = SidebarBrandPalette.random(excluding: model.sidebarBrandPalette)
        if page == .home {
            settingsWindow.closeImmediately()
            model.settingsPresented = false
        }
        model.navigate(to: page)
    }

    private func playHomePresentationIfVisible() {
        guard homePresentationPending, let window, window.isVisible, !window.isMiniaturized,
              !model.homePresentationSuspended, !model.settingsPresented, model.page == .home else { return }
        homePresentationPending = false
        model.homePresentationID &+= 1
    }
}

struct HubRootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var homeEntryRequest: Int? {
        guard model.page == .home, !model.homePresentationSuspended else { return nil }
        return model.homePresentationID
    }

    var body: some View {
        HomeEntryTransition(request: homeEntryRequest) { covered in
            content(homeCovered: covered)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .circular))
        .overlay(alignment: .bottomTrailing) {
            if !model.settingsPresented {
                FixedWindowCornerRegion().frame(width: 16, height: 16)
            }
        }
        .ignoresSafeArea()
    }

    private func content(homeCovered: Bool) -> some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Theme.sidebarWidth - 8)
                .background(RoundedRectangle(cornerRadius: Theme.sidebarRadius).fill(Theme.sidebar))
                .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
            HubPageTransition(selection: model.page, animate: model.page != .home) { page in
                Group {
                    switch page {
                    case .home, .settings:
                        HomePage(animationsReady: !homeCovered)
                            .allowsHitTesting(!homeCovered)
                            .accessibilityHidden(homeCovered)
                    case .history: HistoryPage()
                    case .meetings: MeetingsPage().environmentObject(model.meeting)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
            }
        }
        .frame(width: HubWindowController.size.width, height: HubWindowController.size.height)
        .background(Theme.window)
        .font(Theme.bodyFont)
        .foregroundColor(Theme.ink)
        .tint(Theme.accent)
        .accessibilityHidden(model.settingsPresented)
        .overlay(alignment: .top) {
            if !model.settingsPresented {
                WindowDragRegion().frame(height: 44).padding(.leading, 84)
                    .padding(.trailing, model.page == .home ? 128 : 0)
            }
        }
        .overlay(alignment: .bottomTrailing) { HubNoticeStack() }
        .overlay {
            Color.black
                .opacity(model.settingsPresented ? 0.30 : 0)
                .animation(reduceMotion ? nil : Theme.standard, value: model.settingsPresented)
                .contentShape(Rectangle())
                .onTapGesture { model.settingsPresented = false }
                .allowsHitTesting(model.settingsPresented)
                .accessibilityHidden(true)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarBrand(palette: model.sidebarBrandPalette)
                .padding(.bottom, 12)
                .overlay { if !model.settingsPresented { WindowDragRegion() } }

            ForEach([HubPage.home, .history, .meetings]) { page in
                SidebarItem(page: page).disabled(model.settings.needsPractice)
            }

            Spacer()

            SidebarModes()
                .padding(.bottom, 8)
            Divider().overlay(Theme.border).padding(.vertical, 8)
            HStack(spacing: 4) {
                IconButton(symbol: "envelope", help: L10n.text("联系我们")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/FlaxXTT/Typeleast")!)
                }
                .accessibilityLabel(L10n.text("联系我们"))
                Spacer(minLength: 0)
                IconButton(symbol: "gearshape", help: L10n.settingTitle, size: 32) { model.navigate(to: .settings) }
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
            .foregroundColor(selected ? Theme.ink : Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular)
                .fill(selected ? Theme.selection : (hovering ? Theme.cardHover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : Theme.fast, value: hovering)
        .transientHover($hovering)
    }
}

/// Large page title plus optional trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            Text(verbatim: title)
                .font(.system(size: 36, weight: .medium, design: .serif))
                .tracking(-0.65)
                .frame(height: 40, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.pageInset)
        .padding(.top, 44)
        .padding(.bottom, 16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// The cleanup modes, in the sidebar so they are one click away on every page and apart
/// from Settings. The chosen one shows what it does in a few words.
struct SidebarModes: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { model.actions?.startAssistant() } label: {
                Label {
                    InterfaceTypography.text(L10n.text("提示词模式"), size: 14, weight: .medium)
                } icon: {
                    Image(systemName: "text.bubble").font(.system(size: 14, weight: .medium))
                }
                .padding(10)
            }.buttonStyle(FlatActionButtonStyle())
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
            Text(label).font(InterfaceTypography.localized(14, weight: selected ? .medium : .regular))
                .foregroundColor(selected ? Theme.ink : Theme.secondary).multilineTextAlignment(.center)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(selected ? Theme.selection : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(FlatActionButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
