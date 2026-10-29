import SwiftUI
import AppKit

// Theme.swift - the look: quiet greys, one strong ink colour for
// primary actions, soft cards, generous spacing, light and dark.

enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static let window = dynamic(hex(0xFFFFFF), hex(0x1C1B1B))
    static let sidebar = dynamic(hex(0xF6F6F5), hex(0x151414))
    static let card = dynamic(hex(0xF4F4F3), hex(0x262525))
    static let cardHover = dynamic(hex(0xEDEDEC), hex(0x2E2D2D))
    static let border = dynamic(hex(0xE7E7E5), hex(0x333232))
    static let ink = dynamic(hex(0x141313), hex(0xF4F3F3))
    static let inkInverse = dynamic(hex(0xFFFFFF), hex(0x141313))
    static let secondary = dynamic(hex(0x6E6D6B), hex(0x9C9B99))
    static let tertiary = dynamic(hex(0xA3A29F), hex(0x6E6D6B))
    static let selection = dynamic(hex(0xE9E9E7), hex(0x2F2E2E))
    /// The blue for "your microphone is heard".
    static let accent = dynamic(hex(0x3E9BE9), hex(0x62BBF3))
    /// Style plugins; dictionary packs use `accent`.
    static let style = dynamic(hex(0x8A5CD8), hex(0xB591F2))
    static let success = dynamic(hex(0x2E9E5B), hex(0x4CC27A))
    static let warning = dynamic(hex(0xD9822B), hex(0xF0A04B))

    static let radius: CGFloat = 14

    /// The Home insights: white tiles on a lightly dotted panel, and the heatmap's blues.
    static let tile = dynamic(hex(0xFFFFFF), hex(0x262525))
    static let panel = dynamic(hex(0xF7F7F6), hex(0x1F1E1E))
    static let dot = dynamic(hex(0xDCDCD9), hex(0x343333))
    static let heatEmpty = dynamic(hex(0xF1F1EF), hex(0x2C2B2B))
    static let heat = [dynamic(hex(0xE6EBFD), hex(0x26304F)), dynamic(hex(0xC3CEF9), hex(0x34458A)),
                       dynamic(hex(0x9BAEF3), hex(0x4A63C9)), dynamic(hex(0x4468EC), hex(0x6E8BF5))]
}

/// A rounded, softly filled container.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
    }
}

/// Black pill (white in dark mode): the one primary action on a page.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.inkInverse)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// Quiet outlined pill for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(configuration.isPressed ? Theme.cardHover : Theme.card))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Icon-only button that shows on row hover.
struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(role == .destructive && hovering ? .red : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.selection : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// A key drawn as a keycap, for shortcuts.
struct Keycap: View {
    let label: String
    var large = false

    var body: some View {
        Text(label)
            .font(.system(size: large ? 15 : 12, weight: .semibold, design: .rounded))
            .foregroundColor(Theme.ink)
            .padding(.horizontal, large ? 12 : 8)
            .frame(minWidth: large ? 40 : 28, minHeight: large ? 32 : 24)
            .background(RoundedRectangle(cornerRadius: large ? 8 : 6, style: .continuous).fill(Theme.window))
            .overlay(RoundedRectangle(cornerRadius: large ? 8 : 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.06), radius: 0, x: 0, y: 1)
    }
}

/// Filter chip row ("全部 / 自动添加 / 手动添加").
struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? Theme.ink : Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(selected ? Theme.selection : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Small rounded label ("自动添加", "已用原文").
struct Badge: View {
    let text: String
    var tint: Color = Theme.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Search box with a magnifier, as on the History and Dictionary pages.
struct SearchField: View {
    @Binding var text: String
    var placeholder = L10n.text("搜索")

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 220)
        .background(Capsule().fill(Theme.card))
    }
}

/// Live microphone bars that turn blue when the app hears you (the mic test).
struct LevelBars: View {
    let level: Float
    var count = 12

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                let threshold = Float(index + 1) / Float(count)
                let lit = level * 1.15 >= threshold
                RoundedRectangle(cornerRadius: 2)
                    .fill(lit ? Theme.accent : Theme.border)
                    .frame(width: 5, height: 8 + CGFloat(index % 4) * 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// The app mark: a dark rounded square with five sound bars. Used for the Dock icon,
/// the sidebar and onboarding; drawn in code so no image asset is needed.
enum AppMark {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.width * 0.08
            let box = rect.insetBy(dx: inset, dy: inset)
            // A white tile with a hairline edge, so it still reads on white backgrounds.
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: box.width * 0.23, yRadius: box.width * 0.23)
            NSColor.white.setFill()
            path.fill()
            NSColor(white: 0, alpha: 0.12).setStroke()
            path.lineWidth = max(1, box.width * 0.012)
            path.stroke()
            let heights: [CGFloat] = [0.26, 0.48, 0.70, 0.48, 0.26]
            let barWidth = box.width * 0.085
            let gap = box.width * 0.065
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = box.midX - total / 2
            NSColor(srgbRed: 0.08, green: 0.075, blue: 0.075, alpha: 1).setFill()
            for h in heights {
                let height = box.height * h
                let bar = NSRect(x: x, y: box.midY - height / 2, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
    }
}

struct AppMarkView: View {
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: AppMark.image(size: size * 2))
            .resizable()
            .frame(width: size, height: size)
    }
}
