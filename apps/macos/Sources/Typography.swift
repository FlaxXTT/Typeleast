import AppKit
import SwiftUI

enum InterfaceTypography {
    private static func name(for weight: NSFont.Weight) -> String {
        switch weight {
        case .light: return "PingFangSC-Light"
        case .medium: return "PingFangSC-Medium"
        case .semibold, .bold, .heavy, .black: return "PingFangSC-Semibold"
        default: return "PingFangSC-Regular"
        }
    }

    static func localized(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        .custom(name(for: weight), size: size)
    }

    static func localizedAppKit(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: name(for: weight), size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func figure(_ size: CGFloat) -> Font {
        localized(size, weight: .semibold).monospacedDigit()
    }

    static func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular) -> Text {
        Text(value).font(localized(size, weight: weight))
    }
}
