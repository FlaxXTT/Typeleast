import AppKit
import SwiftUI

// Update checks use dual travelling bars; downloads use their measured fraction.

final class UpdateProgressModel: ObservableObject {
    @Published var version = ""
    @Published var summary = ""
    @Published var stage: UpdateStage = .preparing
    @Published var checking = false
}

final class UpdateProgressWindow {
    private var window: NSWindow?
    private let model = UpdateProgressModel()

    func show(version: String, summary: String = "") {
        model.version = version
        model.summary = summary
        model.stage = .preparing
        model.checking = false
        present()
    }

    func showChecking() {
        model.checking = true
        model.summary = ""
        present()
    }

    private func present() {
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 500),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = L10n.text("更新 TypeLeast")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = NSHostingView(rootView: UpdateProgressView(model: model))
            window = w
        }
        let size = NSSize(width: 350, height: 500)
        w.setContentSize(size)
        AppWindowStyle.fixSize(w, to: size)
        AppWindowStyle.round(w)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func update(_ stage: UpdateStage) { model.stage = stage }

    func bringToFront() { window?.makeKeyAndOrderFront(nil) }

    func close() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel

    var body: some View {
        HubScrollView(showsChrome: false) {
        VStack(spacing: 18) {
            AppMarkView(size: 64)
                .padding(.top, 8)
            VStack(spacing: 5) {
                Text(model.checking ? L10n.text("正在检查更新…") : L10n.text("正在更新到 {0}", model.version))
                    .font(.system(size: 14, weight: .semibold))
                Text(model.checking ? L10n.text("当前版本 ") + Updater.currentVersion : model.stage.label)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LoadingLinearProgress(value: model.checking ? nil : model.stage.fraction)
            if !model.checking {
                if let fraction = model.stage.fraction {
                    HStack {
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                        Spacer()
                        if let amount = model.stage.amount { Text(amount) }
                    }
                    .font(.system(size: 12)).foregroundColor(Theme.secondary).monospacedDigit()
                }
                UpdateStepTrail(current: model.stage.step)
            }
            if !model.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("更新内容")).font(.system(size: 12, weight: .semibold))
                    Text(model.summary).font(.system(size: 12)).foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 28, bottom: 24, trailing: 28))
        }
        .frame(width: 350, height: 500)
        .background(Theme.window)
    }
}

/// 下载 · 核对 · 签名 · 安装: done steps ticked, the current one ringed.
struct UpdateStepTrail: View {
    let current: Int

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(UpdateStage.steps.enumerated()), id: \.offset) { index, name in
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(index < current ? Theme.accent : Color.clear)
                            .overlay(Circle().stroke(index <= current ? Theme.accent : Theme.tertiary.opacity(0.6),
                                                     lineWidth: index == current ? 2.5 : 1.5))
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                        } else if index == current {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(L10n.text(name))
                        .font(.system(size: 11, weight: index == current ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundColor(index <= current ? Theme.ink : Theme.tertiary)
                }
                .frame(width: 44)
                if index < UpdateStage.steps.count - 1 {
                    Rectangle()
                        .fill(index < current ? Theme.accent : Theme.tertiary.opacity(0.35))
                        .frame(height: 1.5)
                        .padding(.top, 7)
                }
            }
        }
        .frame(width: 300)
    }
}
