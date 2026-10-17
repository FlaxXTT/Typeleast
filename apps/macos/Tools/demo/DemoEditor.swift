// DemoEditor.swift - a plain editor window for recording the README demo.
//
// A standard NSWindow with an NSTextView (the same control TextEdit uses), large
// type, placed at the bottom centre of the screen so TypeLeast's voice bar shows
// over it. Once it is in front and nothing covers it, it writes its own frame as
// the capture rectangle (screencapture -R format: x,y,w,h in points from the
// top-left) to the path given as the first argument; otherwise it writes
// "BLOCKED …" and the recording does not start.
import AppKit

let rectFile = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let title = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "会议通知"
let initial = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘V reaches a text view through Edit > Paste, as in every real app.
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main!
        let visible = screen.visibleFrame
        let size = NSSize(width: 860, height: 380)
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 4, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = false
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = NSFont(name: "PingFang SC", size: 26) ?? .systemFont(ofSize: 26)
        text.textContainerInset = NSSize(width: 34, height: 30)
        text.textColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: text.font!, .foregroundColor: text.textColor!, .paragraphStyle: paragraph]
        text.string = initial
        text.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        scroll.documentView = text
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(text)
        NSApp.activate(ignoringOtherApps: true)

        // Give the window a moment to come to the front, then make sure nothing
        // covers it before handing out the capture rectangle (exactly the window,
        // so nothing else on the screen can be recorded).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            let primaryHeight = NSScreen.screens[0].frame.height
            let f = window.frame
            let cgRect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                   CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
            let covering = above.filter { info in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return r.intersects(cgRect)
            }
            let ok = NSApp.isActive && window.isKeyWindow && covering.isEmpty
            let result = ok ? String(format: "%.0f,%.0f,%.0f,%.0f", cgRect.minX, cgRect.minY, cgRect.width, cgRect.height)
                            : "BLOCKED active=\(NSApp.isActive) key=\(window.isKeyWindow) covering=\(covering.count)"
            if let path = rectFile { try? result.write(toFile: path, atomically: true, encoding: .utf8) }
            // Keep the pointer out of the recording: top-right corner of the same screen.
            CGWarpMouseCursorPosition(CGPoint(x: screen.frame.maxX - 30, y: primaryHeight - screen.frame.maxY + 30))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
