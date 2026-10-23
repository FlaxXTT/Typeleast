import AppKit
import SwiftUI

// UpdateProgressWindow.swift - a small window while an in-app update runs: what it is doing
// (下载 → 核对 → 签名 → 交接 Key → 安装) with a progress bar, so it never looks stuck.

final class UpdateProgressModel: ObservableObject {
    @Published var version = ""
    @Published var stage: UpdateStage = .preparing
}

final class UpdateProgressWindow {
    private var window: NSWindow?
    private let model = UpdateProgressModel()

    func show(version: String) {
        model.version = version
        model.stage = .preparing
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                         styleMask: [.titled], backing: .buffered, defer: false)
            w.title = L10n.text("更新 TypeLeast")
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = NSHostingView(rootView: UpdateProgressView(model: model))
            window = w
        }
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func update(_ stage: UpdateStage) { model.stage = stage }

    func close() { window?.orderOut(nil) }
}

struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("正在更新到 {0}", model.version)).font(.system(size: 13, weight: .semibold))
            if let fraction = model.stage.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(model.stage.label).font(.system(size: 12)).foregroundColor(Theme.secondary)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
    }
}
