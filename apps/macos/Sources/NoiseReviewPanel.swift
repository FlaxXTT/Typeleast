import AppKit
import SwiftUI

private final class NoiseReviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A non-modal review for an uncertain recognition. Each pending result gets
/// its own panel so a later dictation cannot silently replace it.
final class NoiseReviewPanel {
    private var panels: [UUID: NSPanel] = [:]

    func show(candidate: String, repeated: Bool, use: @escaping (String) -> Bool) {
        let id = UUID()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dismiss: () -> Void = { [weak self] in
            if let panel = self?.panels.removeValue(forKey: id) { panel.orderOut(nil) }
        }
        panel.contentView = NoiseReviewHostingView(rootView: NoiseReviewView(
            candidate: candidate, repeated: repeated,
            use: { if use(candidate) { dismiss() } }, dismiss: dismiss))
        panels[id] = panel
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.maxX - panel.frame.width - 24),
                                         y: max(frame.minY, frame.maxY - panel.frame.height - 24)))
        } else { panel.center() }
        panel.orderFrontRegardless()
    }
}

struct NoiseReviewView: View {
    let candidate: String
    let repeated: Bool
    let use: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(repeated ? L10n.text("识别结果出现异常重复") : L10n.text("可能主要是背景噪声"))
                .font(.headline).foregroundColor(Theme.ink)
            Text(L10n.text("没有自动输入。继续后按当前设置处理；如使用联网整理模型，文字会发送给该服务。"))
                .font(.subheadline).foregroundColor(Theme.secondary)
            ScrollView {
                Text(candidate.isEmpty ? L10n.text("没有识别到文字") : candidate)
                    .textSelection(.enabled)
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Button(L10n.text("忽略"), action: dismiss).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("继续处理"), action: use)
                    .buttonStyle(PrimaryButtonStyle()).disabled(candidate.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 260)
        .background(Theme.window)
    }
}

/// The response stays out of the paste path until the user chooses a version.
final class QuantityReviewPanel {
    enum Choice { case original, candidate }
    private var panels: [UUID: NSPanel] = [:]

    func show(review: QualityReview, choose: @escaping (Choice) -> Bool) {
        let id = UUID()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dismiss: () -> Void = { [weak self] in
            if let panel = self?.panels.removeValue(forKey: id) { panel.orderOut(nil) }
        }
        panel.contentView = NoiseReviewHostingView(rootView: QuantityReviewView(
            review: review,
            original: { if choose(.original) { dismiss() } },
            candidate: { if choose(.candidate) { dismiss() } },
            dismiss: dismiss))
        panels[id] = panel
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.maxX - panel.frame.width - 24),
                                         y: max(frame.minY, frame.maxY - panel.frame.height - 24)))
        } else { panel.center() }
        panel.orderFrontRegardless()
    }
}

struct QuantityReviewView: View {
    let review: QualityReview
    let original: () -> Void
    let candidate: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("数量或单位可能发生变化")).font(.headline).foregroundColor(Theme.ink)
            Text(L10n.text("请比较识别原文和整理结果，再选择要使用的内容。"))
                .font(.subheadline).foregroundColor(Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("原始识别")).font(.caption).foregroundColor(Theme.secondary)
                    Text(review.original).textSelection(.enabled).foregroundColor(Theme.ink)
                    Text(L10n.text("整理结果")).font(.caption).foregroundColor(Theme.secondary)
                    Text(review.candidate).textSelection(.enabled).foregroundColor(Theme.ink)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Button(L10n.text("暂不使用"), action: dismiss).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("使用识别原文"), action: original).buttonStyle(SecondaryButtonStyle())
                Button(L10n.text("使用整理结果"), action: candidate).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(20).frame(width: 520, height: 370).background(Theme.window)
    }
}
