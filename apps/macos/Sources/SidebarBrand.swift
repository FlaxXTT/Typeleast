import AppKit
import CoreText
import SwiftUI

struct SidebarBrandPalette: Equatable {
    struct Bar: Equatable {
        let fill: UInt32
        let edge: UInt32?
    }

    struct Appearance: Equatable {
        let bars: [Bar]
        let t: UInt32
        let l: UInt32

        var initialTint: Color { brandColor(t) }
    }

    let light: Appearance
    let dark: Appearance

    func appearance(for colorScheme: ColorScheme) -> Appearance {
        colorScheme == .dark ? dark : light
    }

    static let all = [
        Self([0xE5B63E, 0x24405D]),                         // 教养黄、古蓝
        Self([0xC24438, 0xCDB7BF, 0x292123]),               // 朱砂红、羊皮紫米、书卷浓黑
        Self([0xE5E8F5, 0xE26B30]),                         // 月光白、热力珠菊
        Self([0xEEF4F7, 0x212A32, 0xD82453]),               // 冷感纸白、科技炭黑、信号绯红
        Self([0x171829, 0xD9E3F3, 0x834AF5]),               // 午夜深黑、银月冷白、电光紫罗兰
        Self([0xD6A67D, 0x82738E, 0x2B52BA, 0xF08A4B]),     // 暖杏沙色、灰紫、半调克莱因蓝、落日暖橙
        Self([0x285F9B, 0x32746D], darkInitialBackground: Theme.tileDarkRGB), // 青瓷蓝、海松绿
        Self([0x2B604B, 0x5F7971], darkInitialBackground: Theme.tileDarkRGB), // 杉绿、青灰
        Self([0x5A4A9A, 0x43739C], darkInitialBackground: Theme.tileDarkRGB), // 鸢尾紫、雾蓝
        Self([0x823F62, 0xA75564], darkInitialBackground: Theme.tileDarkRGB), // 桑椹、干玫瑰
        Self([0x2D4279, 0xA45442], darkInitialBackground: Theme.tileDarkRGB), // 靛青、赤陶
        Self([0xB54C7A, 0x5973C9], darkInitialBackground: Theme.tileDarkRGB), // 蔷薇粉、矢车菊蓝
        Self([0xB94167, 0x258273], darkInitialBackground: Theme.tileDarkRGB), // 草莓粉、薄荷青
        Self([0xBD5773, 0xD1804F], darkInitialBackground: Theme.tileDarkRGB), // 蜜桃粉、杏子橙
        Self([0xC8588D, 0x8661B5], darkInitialBackground: Theme.tileDarkRGB), // 樱花粉、绣球紫
        Self([0xAE386E, 0xE9C647], darkInitialBackground: Theme.tileDarkRGB), // 覆盆子粉、柠檬黄
        Self([0x930F2C, 0x265B53], darkInitialBackground: Theme.tileDarkRGB), // 雨巷绯灯
        Self([0x244983, 0x579A96], darkInitialBackground: Theme.tileDarkRGB), // 海面微光
        Self([0x5242A2, 0xB66C97], darkInitialBackground: Theme.tileDarkRGB), // 黄昏二重奏
        Self([0xB94D24, 0x445D76], darkInitialBackground: Theme.tileDarkRGB), // 橙雾尽头
        Self([0xA13732, 0x465B81], darkInitialBackground: Theme.tileDarkRGB), // 海岸篝火
        Self([0x683E83, 0xBD7F94], darkInitialBackground: Theme.tileDarkRGB), // 雪夜糖盒
    ]

    static func random(excluding previous: Self? = nil) -> Self {
        all.filter { $0 != previous }.randomElement() ?? all[0]
    }

    private init(_ colors: [UInt32], darkInitialBackground: UInt32 = Theme.sidebarDarkRGB) {
        light = Self.appearance(colors, barInk: AppIconArtwork.waveformInk, background: Theme.sidebarLightRGB, towards: 0x000000)
        dark = Self.appearance(colors, barInk: 0xFFFFFF, background: Theme.sidebarDarkRGB,
                               towards: 0xFFFFFF, initialBackground: darkInitialBackground)
    }

    private static func appearance(_ colors: [UInt32], barInk: UInt32, background: UInt32,
                                   towards ink: UInt32, initialBackground: UInt32? = nil) -> Appearance {
        let accentFill = colors[colors.count > 3 ? 2 : colors.count - 1]
        let bars = AppIconArtwork.barRatios.indices.map { index in
            let fill = index == AppIconArtwork.barRatios.count - 1 ? accentFill : barInk
            // Keep even the lightest swatches intact, with an edge when needed.
            let edge = contrast(fill, background) < 3
                ? readable(fill, background: background, towards: ink, minimum: 3) : nil
            return Bar(fill: fill, edge: edge)
        }
        return Appearance(bars: bars,
                          t: readable(colors[0], background: initialBackground ?? background, towards: ink, minimum: 4.5),
                          l: readable(colors[colors.count - 1], background: background, towards: ink, minimum: 4.5))
    }

    private static func components(_ rgb: UInt32) -> [Double] {
        [16, 8, 0].map { Double(rgb >> $0 & 255) }
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        let linear = components(rgb).map { value in
            let channel = value / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func readable(_ color: UInt32, background: UInt32, towards ink: UInt32, minimum: Double) -> UInt32 {
        if contrast(color, background) >= minimum { return color }
        let start = components(color)
        let end = components(ink)
        var low: Double = 0
        var high: Double = 1
        var result = ink
        for _ in 0..<9 {
            let amount = (low + high) / 2
            let shade = zip(start, end).reduce(UInt32(0)) { rgb, pair in
                (rgb << 8) | UInt32((pair.0 + (pair.1 - pair.0) * amount).rounded())
            }
            if contrast(shade, background) >= minimum {
                result = shade
                high = amount
            } else {
                low = amount
            }
        }
        return result
    }
}

struct SidebarBrand: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: SidebarBrandPalette

    private static let iconSize: CGFloat = 36

    var body: some View {
        let appearance = palette.appearance(for: colorScheme)
        HStack(spacing: 9) {
            waveform(appearance)
            SidebarWordmark(tintT: appearance.initialTint, tintL: brandColor(appearance.l))
            Spacer(minLength: 0)
        }
    }

    private func waveform(_ appearance: SidebarBrandPalette.Appearance) -> some View {
        let size = Self.iconSize
        return HStack(spacing: size * 0.03 * AppIconArtwork.barGapScale) {
            ForEach(appearance.bars.indices, id: \.self) { index in
                let bar = appearance.bars[index]
                Capsule()
                    .fill(brandColor(bar.fill))
                    .overlay {
                        if let edge = bar.edge { Capsule().strokeBorder(brandColor(edge), lineWidth: 0.6) }
                    }
                    .frame(width: size * 0.10, height: size * AppIconArtwork.waveformOccupancy * AppIconArtwork.barRatios[index])
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private func brandColor(_ rgb: UInt32) -> Color {
    Color(.sRGB, red: Double(rgb >> 16 & 255) / 255,
          green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
}

private struct SidebarWordmark: View {
    let tintT: Color
    let tintL: Color

    private static let design = WordmarkOutline()
    private static let nominalScale: CGFloat = 0.212

    var body: some View {
        let design = Self.design
        Canvas { context, size in
            let scale = min(Self.nominalScale, size.width / design.bounds.width)
            context.translateBy(x: -design.bounds.minX * scale, y: size.height / 2 - design.bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.fill(design.capital, with: .color(tintT))
            context.fill(design.lowercase, with: .color(Theme.ink))
            context.fill(design.ligature, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Theme.ink, location: 40 / 112),
                    .init(color: tintL, location: 47 / 112),
                    .init(color: tintL, location: 73 / 112),
                    .init(color: Theme.ink, location: 84 / 112),
                ]), startPoint: CGPoint(x: design.joinX, y: 0), endPoint: CGPoint(x: design.joinX + 112, y: 0)
            ), style: FillStyle(eoFill: true))
        }
        .frame(maxWidth: design.bounds.width * Self.nominalScale)
        .frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("TypeLeast")
    }
}

private struct WordmarkOutline {
    let capital: Path
    let lowercase: Path
    let ligature: Path
    let joinX: CGFloat
    let bounds: CGRect

    init() {
        let times = Self.font("TimesNewRomanPSMT", size: 95)
        let caslon = Self.font("BigCaslon-Medium", size: 100)
        var t = Path()
        var letters = Path()
        Self.append("T", font: times, x: 0, y: -9.5, to: &t)
        // The left serif of y crosses the bottom of T's right terminal.
        let yX = t.boundingRect.maxX - 10
        let pX = yX + Self.append("y", font: caslon, x: yX, y: -11.8, to: &letters) - 3.7
        let joint = pX + Self.append("p", font: caslon, x: pX, y: 0, to: &letters) - 3.4
        var x = joint + 111.2
        for character in "ast" {
            x += Self.append(character, font: caslon, x: x, y: 0, to: &letters) - 3.7
        }
        let middle = Self.eLe.applying(CGAffineTransform(translationX: joint, y: 0))
        capital = t
        lowercase = letters
        ligature = middle
        joinX = joint
        bounds = t.boundingRect.union(letters.boundingRect).union(middle.boundingRect)
    }

    private static func font(_ name: String, size: CGFloat) -> CTFont {
        let face = NSFont(name: name, size: size) ?? NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        return face as CTFont
    }

    @discardableResult
    private static func append(_ character: Character, font: CTFont, x: CGFloat, y: CGFloat, to path: inout Path) -> CGFloat {
        guard var codeUnit = String(character).utf16.first else { return 0 }
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &codeUnit, &glyph, 1)
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: y)
        if let outline = CTFontCreatePathForGlyph(font, glyph, &transform) { path.addPath(Path(outline)) }
        return CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
    }

    private static let eLe = Path { path in
        path.move(to: .init(x: 35, y: -67))
        path.addLine(to: .init(x: 64, y: -67))
        path.addLine(to: .init(x: 64, y: -65))
        path.addCurve(to: .init(x: 55, y: -56), control1: .init(x: 57, y: -65), control2: .init(x: 55, y: -62))
        path.addLine(to: .init(x: 55, y: -9))
        path.addCurve(to: .init(x: 66, y: 4), control1: .init(x: 55, y: 1), control2: .init(x: 58, y: 4))
        path.addCurve(to: .init(x: 77, y: 0), control1: .init(x: 71, y: 4), control2: .init(x: 75, y: 3))
        path.addCurve(to: .init(x: 66, y: -24), control1: .init(x: 70, y: -4), control2: .init(x: 66, y: -12))
        path.addCurve(to: .init(x: 90, y: -49), control1: .init(x: 66, y: -39), control2: .init(x: 76, y: -49))
        path.addCurve(to: .init(x: 111, y: -31), control1: .init(x: 102, y: -49), control2: .init(x: 110, y: -40))
        path.addLine(to: .init(x: 75, y: -31))
        path.addCurve(to: .init(x: 92, y: -6), control1: .init(x: 74, y: -15), control2: .init(x: 80, y: -6))
        path.addCurve(to: .init(x: 108, y: -16), control1: .init(x: 99, y: -6), control2: .init(x: 105, y: -10))
        path.addLine(to: .init(x: 110, y: -15))
        path.addCurve(to: .init(x: 90, y: 2), control1: .init(x: 107, y: -3), control2: .init(x: 100, y: 2))
        path.addCurve(to: .init(x: 65, y: 8), control1: .init(x: 83, y: 5), control2: .init(x: 74, y: 8))
        path.addLine(to: .init(x: 35, y: 8))
        path.addLine(to: .init(x: 35, y: 6))
        path.addCurve(to: .init(x: 46, y: -6), control1: .init(x: 43, y: 6), control2: .init(x: 46, y: 2))
        path.addLine(to: .init(x: 46, y: -29))
        path.addLine(to: .init(x: 11, y: -29))
        path.addCurve(to: .init(x: 27, y: -6), control1: .init(x: 10, y: -15), control2: .init(x: 16, y: -6))
        path.addCurve(to: .init(x: 41, y: -15), control1: .init(x: 33, y: -6), control2: .init(x: 38, y: -9))
        path.addLine(to: .init(x: 43, y: -14))
        path.addCurve(to: .init(x: 23, y: 1), control1: .init(x: 40, y: -5), control2: .init(x: 33, y: 1))
        path.addCurve(to: .init(x: 2, y: -24), control1: .init(x: 10, y: 1), control2: .init(x: 2, y: -10))
        path.addCurve(to: .init(x: 24, y: -49), control1: .init(x: 2, y: -38), control2: .init(x: 12, y: -49))
        path.addCurve(to: .init(x: 44, y: -33), control1: .init(x: 35, y: -49), control2: .init(x: 43, y: -41))
        path.addLine(to: .init(x: 46, y: -33))
        path.addLine(to: .init(x: 46, y: -56))
        path.addCurve(to: .init(x: 35, y: -65), control1: .init(x: 46, y: -62), control2: .init(x: 43, y: -65))
        path.closeSubpath()
        path.move(to: .init(x: 11, y: -33))
        path.addLine(to: .init(x: 34, y: -33))
        path.addCurve(to: .init(x: 24, y: -46), control1: .init(x: 35, y: -40), control2: .init(x: 30, y: -46))
        path.addCurve(to: .init(x: 11, y: -33), control1: .init(x: 18, y: -46), control2: .init(x: 13, y: -40))
        path.closeSubpath()
        path.move(to: .init(x: 76, y: -34))
        path.addLine(to: .init(x: 101, y: -34))
        path.addCurve(to: .init(x: 90, y: -46), control1: .init(x: 101, y: -41), control2: .init(x: 96, y: -46))
        path.addCurve(to: .init(x: 76, y: -34), control1: .init(x: 83, y: -46), control2: .init(x: 78, y: -41))
        path.closeSubpath()
    }
}
