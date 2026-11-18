import SwiftUI
import AppKit

// Main-window tokens adapted from Typeless_UI_范本. VoiceBarPalette stays independent.

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

    /// The Home reference is tagged Display P3. Keep its sampled colours in that space.
    private static func referenceColour(_ value: UInt32) -> NSColor {
        NSColor(displayP3Red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let window = dynamic(hex(0xFFFFFF), hex(0x242121))
    static let sidebar = dynamic(hex(0xF7F6F5), hex(0x1D1A1A))
    static let detail = dynamic(hex(0xFBFAF9), hex(0x1F1C1C))
    static let card = dynamic(hex(0xF2F1F0), hex(0x3C3B3B))
    static let cardHover = dynamic(hex(0x777777, 0.08), hex(0xF2F1F0, 0.06))
    static let border = dynamic(hex(0x777777, 0.15), hex(0xF2F1F0, 0.10))
    static let ink = dynamic(hex(0x111111), hex(0xF2F1F0))
    static let inkInverse = Color.white
    static let secondary = dynamic(hex(0x111111, 0.75), hex(0xF2F1F0, 0.75))
    static let tertiary = dynamic(hex(0x111111, 0.55), hex(0xF2F1F0, 0.55))
    static let selection = dynamic(hex(0x1F5DF2, 0.07), hex(0x4F7BFF, 0.12))
    static let accent = dynamic(hex(0x1F5DF2), hex(0x4F7BFF))
    static let style = accent
    static let success = dynamic(hex(0x008770), hex(0x00957C))
    static let warning = dynamic(hex(0xEA4D00), hex(0xFF5B00))
    static let loadingTrack = dynamic(hex(0x777777, 0.10), hex(0x777777, 0.40))
    static let skeletonHighlight = dynamic(hex(0x000000, 0.04), hex(0xFFFFFF, 0.04))

    static let radius: CGFloat = 8
    static let controlRadius: CGFloat = 8
    static let smallControlRadius: CGFloat = 6
    static let cardRadius: CGFloat = 12
    static let listGroupRadius: CGFloat = 10
    static let homeCardRadius: CGFloat = 20
    static let homeMetricRadius: CGFloat = 20
    static let homeActivityRadius: CGFloat = 16
    static let panelRadius: CGFloat = 24
    static let sidebarRadius: CGFloat = 20
    static let settingsRadius: CGFloat = 24
    static let capsuleRadius: CGFloat = 999
    static let heatCellRadius: CGFloat = 4
    static let pageInset: CGFloat = 24
    static let sidebarWidth: CGFloat = 210
    static let spacing: CGFloat = 8
    static let halfSpacing: CGFloat = 4
    static let titleFont = InterfaceTypography.localized(36, weight: .medium)
    static let homeTitleFont = InterfaceTypography.localized(48, weight: .medium)
    static let sectionTitleFont = InterfaceTypography.localized(24, weight: .medium)
    static let bodyFont = InterfaceTypography.localized(16)
    static let rowFont = InterfaceTypography.localized(14)
    static let captionFont = InterfaceTypography.localized(12)
    static let fast = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12)
    static let standard = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.20)

    /// The Home insights: white tiles on a lightly dotted panel, and the heatmap's blues.
    static let homeRatio: CGFloat = 0.618
    static let homeHeadingSize: CGFloat = 48
    static let homeFigureSize: CGFloat = 26
    static let tile = dynamic(hex(0xFFFFFF), hex(0x3C3B3B))
    static let panel = dynamic(hex(0xF7F6F5), hex(0x1D1A1A))
    static let dot = dynamic(hex(0xDCDCD9), hex(0x343333))
    static let homeBackdrop = dynamic(referenceColour(0xE9ECEF), hex(0x242121))
    static let homeDot = dynamic(referenceColour(0xD5D7DC), hex(0x444040))
    static let homeLabel = dynamic(hex(0x7C7C7C), hex(0xB6B2B2))
    static let heatEmpty = dynamic(hex(0xF8F8F8), hex(0x2C2B2B))
    static let heat = [dynamic(referenceColour(0xECF0FE), hex(0x26304F)), dynamic(referenceColour(0xC6D2FC), hex(0x34458A)),
                       dynamic(referenceColour(0xA0B4FB), hex(0x4A63C9)), dynamic(referenceColour(0x426AF6), hex(0x6E8BF5))]
}

struct InitialHeading: View {
    let title: String
    let initialSize: CGFloat
    let bodySize: CGFloat
    var typeface: (CGFloat) -> Font = { InterfaceTypography.english($0, emphasized: true) }
    var tracking: CGFloat = -0.6

    var body: some View {
        let initial = Text(String(title.prefix(1))).font(typeface(initialSize))
        let rest = Text(String(title.dropFirst())).font(typeface(bodySize))
        Text("\(initial)\(rest)")
            .tracking(tracking)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Common pointer and press feedback for native-style controls.
extension View {
    func capsuleInput() -> some View {
        self.padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(Theme.window))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).strokeBorder(Theme.border, lineWidth: 1))
    }
}

struct CapsuleTextEditor: View {
    @Binding var text: String
    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(Theme.window))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .circular))
    }
}

/// A rounded, softly filled container.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Blue is reserved for primary actions and selection.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverPill(configuration: configuration, primary: true)
    }
}

/// Quiet rounded outline for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverPill(configuration: configuration, primary: false)
    }
}

/// The labels move within their original layout area; disabled controls stay still.
private struct HoverPill: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool

    var body: some View {
        configuration.label
            .font(InterfaceTypography.localized(14, weight: primary ? .semibold : .medium))
            .foregroundColor(primary ? Theme.inkInverse : Theme.ink)
            .padding(.horizontal, primary ? 16 : 14)
            .padding(.vertical, primary ? 8 : 7)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(primary ? Theme.accent : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(primary ? Color.clear : Theme.border, lineWidth: 1))
            .modifier(ControlMotion(pressed: configuration.isPressed, cornerRadius: Theme.controlRadius, primary: primary))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// Row actions use a flat hover state and short press feedback.
struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    var size: CGFloat = 32
    var symbolSize: CGFloat = 16
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundColor(role == .destructive && hovering ? .red : Theme.secondary)
                .frame(width: size, height: size)
                .contentShape(RoundedRectangle(cornerRadius: Theme.smallControlRadius, style: .circular))
        }
        .buttonStyle(FlatActionButtonStyle(cornerRadius: Theme.smallControlRadius))
        .help(help)
        .transientHover($hovering)
    }
}

/// A key drawn as a keycap, for shortcuts.
struct Keycap: View {
    let label: String
    var large = false

    var body: some View {
        InterfaceTypography.text(label, size: large ? 15 : 12, weight: .semibold)
            .foregroundColor(Theme.ink)
            .padding(.horizontal, large ? 12 : 8)
            .frame(minWidth: large ? 40 : 28, minHeight: large ? 32 : 24)
            .background(RoundedRectangle(cornerRadius: Theme.smallControlRadius, style: .circular).fill(Theme.window))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallControlRadius, style: .circular).stroke(Theme.border, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.06), radius: 0, x: 0, y: 1)
    }
}

/// Filter chip row ("全部 / 自动添加 / 手动添加").
struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 14, weight: selected ? .medium : .regular))
                        .foregroundColor(selected ? Theme.accent : Theme.secondary)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 40, minHeight: 32)
                        .background(Capsule().fill(selected ? Theme.selection : Color.clear))
                }
                .buttonStyle(HoverChipStyle())
            }
        }
        .padding(4).frame(height: 40)
        .background(Capsule().fill(Theme.card))
    }
}

private struct HoverChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverChipLabel(configuration: configuration)
    }
}

private struct HoverChipLabel: View {
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .modifier(ControlMotion(pressed: configuration.isPressed, cornerRadius: Theme.capsuleRadius))
            .contentShape(Capsule())
    }
}

/// Small rounded label ("自动添加", "已用原文").
struct Badge: View {
    let text: String
    var tint: Color = Theme.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
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
    var width: CGFloat = 220

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundColor(Theme.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.rowFont)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Theme.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: width, height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
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
                RoundedRectangle(cornerRadius: Theme.radius, style: .circular)
                    .fill(lit ? Theme.accent : Theme.border)
                    .frame(width: 5, height: 8 + CGFloat(index % 4) * 3)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Resolution-independent artwork, shared with the packaged icon generator.
enum AppMark {
    static func image(size: CGFloat) -> NSImage {
        AppIconArtwork.image(size: size)
    }
}

struct AppMarkView: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: AppIconArtwork.image(size: size, surface: .interface))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
