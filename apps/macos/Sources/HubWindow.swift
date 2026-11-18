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
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // AppKit lays out the title bar again on first presentation. Reposition the
        // native buttons afterwards so they stay inside the window curve.
        DispatchQueue.main.async { [weak window] in
            if let window { AppWindowStyle.round(window) }
        }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: HubRootView().environmentObject(model))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
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
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { AppWindowStyle.round(window) }
        model.refreshPermissions()
        // The service may have restarted on a new port since the last check.
        model.actions?.recheckHealth()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !dismissSettingsIfVisible()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        let page = requestedRestorePage ?? .home
        requestedRestorePage = nil
        present(page)
    }

    private func present(_ page: HubPage) {
        if page == .home {
            settingsWindow.closeImmediately()
            model.homePresentationID &+= 1
        }
        model.navigate(to: page)
    }
}

struct HubRootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        pageLayout
        .frame(width: HubWindowController.size.width, height: HubWindowController.size.height)
        .background(Theme.window)
        .font(Theme.bodyFont)
        .foregroundColor(Theme.ink)
        .tint(Theme.accent)
        .overlay(alignment: .top) { WindowDragRegion().frame(height: 44).padding(.leading, 84) }
        .overlay(alignment: .bottomTrailing) { HubNoticeStack() }
        .overlay {
            Color.black
                .opacity(model.settingsPresented ? 0.30 : 0)
                .animation(reduceMotion ? nil : Theme.standard, value: model.settingsPresented)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .circular))
        .overlay(alignment: .bottomTrailing) { FixedWindowCornerRegion().frame(width: 16, height: 16) }
        .ignoresSafeArea()
    }

    @ViewBuilder private var pageLayout: some View {
        switch model.page {
        case .home, .settings:
            DashboardEntrance { elapsed in
                layout { HomePage(elapsed: elapsed) }
            }
            .id(model.homePresentationID)
        case .history:
            layout { HistoryPage() }
        case .meetings:
            layout { MeetingsPage().environmentObject(model.meeting) }
        }
    }

    private func layout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Theme.sidebarWidth - 8)
                .background(RoundedRectangle(cornerRadius: Theme.sidebarRadius).fill(Theme.sidebar))
                .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
            ZStack {
                Theme.window
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                sidebarWaveform
                Text("TYPELEAST")
                    .font(InterfaceTypography.localized(Theme.homeHeadingSize * Theme.homeRatio * Theme.homeRatio, weight: .light))
                    .tracking(1)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityLabel("TypeLeast")
                Spacer(minLength: 0)
            }
            .padding(.bottom, 16)
            .overlay { WindowDragRegion() }

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
                .buttonStyle(FlatActionButtonStyle()).foregroundColor(Theme.secondary)
                .help(L10n.text("联系我们"))
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

    private var sidebarWaveform: some View {
        let size: CGFloat = 26
        let ratios = AppIconArtwork.barRatios
        HStack(spacing: size * 0.03) {
            ForEach(ratios.indices, id: \.self) { index in
                Capsule()
                    .fill(index == ratios.count - 1 ? Theme.accent : Theme.ink)
                    .frame(width: size * 0.10, height: size * AppIconArtwork.waveformOccupancy * ratios[index])
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
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
        .transientHover($hovering)
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
            InterfaceTypography.text(badgeText, size: 14, weight: .medium)
                .foregroundColor(Theme.secondary)
                .lineLimit(1)
            Spacer()
            if model.modelsMissing {
                Button(L10n.text("下载模型")) { model.actions?.downloadModels() }
                    .buttonStyle(FlatActionButtonStyle())
                    .font(InterfaceTypography.localized(12, weight: .semibold))
                    .foregroundColor(Theme.ink)
            } else if !model.serviceUp && !model.modelsDownloading {
                Button(L10n.text("重启")) { model.actions?.restartService() }
                    .buttonStyle(FlatActionButtonStyle())
                    .font(InterfaceTypography.localized(12, weight: .semibold))
                    .foregroundColor(Theme.ink)
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
                .foregroundColor(selected ? Theme.accent : Theme.secondary).multilineTextAlignment(.center)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(selected ? Theme.selection : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(FlatActionButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
