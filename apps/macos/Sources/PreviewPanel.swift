import AppKit

// PreviewPanel.swift - non-activating panel used by insertion mode "preview".

final class PreviewPanel {
    private var panel: NSPanel?
    private var textView: NSTextView?

    func show(text: String) {
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                        styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
            p.title = L10n.text("听写预览（已复制到剪贴板）")
            p.isFloatingPanel = true
            p.level = .floating
            p.becomesKeyOnlyIfNeeded = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = false
            tv.isSelectable = true
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            scroll.documentView = tv
            p.contentView = scroll
            textView = tv
            panel = p
        }
        textView?.string = text
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 230, y: f.midY - 100))
        }
        p.orderFrontRegardless()
    }
}
