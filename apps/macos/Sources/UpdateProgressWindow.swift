import AppKit
import SwiftUI

// UpdateProgressWindow.swift - a small window while an in-app update runs, so it never looks
// stuck: a ring that fills with the download (percentage and MB in the middle), then turns
// while the update is checked, signed, handed its Keys and installed, with the five steps
// underneath. The ring always moves; the steps say where it is.

final class UpdateProgressModel: ObservableObject {
    @Published var version = ""
    @Published var summary = ""
    @Published var stage: UpdateStage = .preparing
}

final class UpdateProgressWindow {
    private var window: NSWindow?
    private let model = UpdateProgressModel()

    func show(version: String, summary: String = "") {
        model.version = version
        model.summary = summary
        model.stage = .preparing
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
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
        w.setContentSize(NSHostingView(rootView: UpdateProgressView(model: model)).fittingSize)
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
        VStack(spacing: 18) {
            UpdateRing(stage: model.stage)
                .frame(width: 136, height: 136)
                .padding(.top, 8)
            VStack(spacing: 5) {
                Text(L10n.text("正在更新到 {0}", model.version))
                    .font(.system(size: 14, weight: .semibold))
                Text(model.stage.label)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            UpdateStepTrail(current: model.stage.step)
            if !model.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("更新内容")).font(.system(size: 12, weight: .semibold))
                    Text(model.summary).font(.system(size: 12)).foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 28, bottom: 24, trailing: 28))
        .frame(width: 360)
        .background(Theme.window)
    }
}

/// The ring: filled by the download, a turning arc for the steps without a size.
struct UpdateRing: View {
    let stage: UpdateStage
    private let width: CGFloat = 10

    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.13), lineWidth: width)
            if let fraction = stage.fraction {
                Circle()
                    .trim(from: 0, to: max(0.004, fraction))
                    .stroke(AngularGradient(colors: [Theme.accent.opacity(0.45), Theme.accent],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(0.004, fraction))),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
                VStack(spacing: 2) {
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let amount = stage.amount {
                        Text(amount).font(.system(size: 11)).foregroundColor(Theme.secondary).monospacedDigit()
                    }
                }
            } else {
                // Always moving, so an update that takes a while never looks stuck.
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Circle()
                        .trim(from: 0, to: 0.24)
                        .stroke(AngularGradient(colors: [Theme.accent.opacity(0.05), Theme.accent],
                                                center: .center, startAngle: .degrees(0), endAngle: .degrees(86)),
                                style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360 - 90))
                }
                Image(systemName: stage.symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(width / 2)
    }
}

/// 下载 · 核对 · 签名 · 交接 · 安装: done steps ticked, the current one ringed.
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
