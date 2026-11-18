import AppKit
import SwiftUI

enum InterfaceTypography {
    private enum Face {
        case english, figure, system
    }

    private static let myriadRegular = NSFont(name: "MyriadPro-Regular", size: 12) != nil
    private static let myriadSemibold = NSFont(name: "MyriadPro-Semibold", size: 12) != nil
    private static let erasName = ["ErasITC-Medium", "ItcEras-Medium", "Eras Medium ITC"]
        .compactMap { NSFont(name: $0, size: 12)?.fontName }.first
    private static let sackersName = ["SackersGothicLightAT", "Sackers Gothic Light AT", "SackersGothicStd-Light"]
        .compactMap { NSFont(name: $0, size: 12)?.fontName }.first

    static func sackers(_ size: CGFloat) -> Font {
        .custom(sackersName ?? "AvenirNext-UltraLight", size: size)
    }

    static func english(_ size: CGFloat, emphasized: Bool = false) -> Font {
        .custom(englishName(emphasized: emphasized), size: size)
    }

    static func englishAppKit(_ size: CGFloat, emphasized: Bool = false) -> NSFont {
        NSFont(name: englishName(emphasized: emphasized), size: size)
            ?? .systemFont(ofSize: size, weight: emphasized ? .semibold : .regular)
    }

    private static func englishName(emphasized: Bool) -> String {
        if emphasized && myriadSemibold { return "MyriadPro-Semibold" }
        if myriadRegular { return "MyriadPro-Regular" }
        return emphasized ? "SourceSans3-Semibold" : "SourceSans3-Regular"
    }

    static func figure(_ size: CGFloat) -> Font {
        .custom(erasName ?? "AvenirNext-Medium", size: size).monospacedDigit()
    }

    static func text(_ value: String, size: CGFloat, weight: Font.Weight = .regular) -> Text {
        var result = AttributedString()
        var run = ""
        var current: Face?
        for character in value {
            let face = face(for: character)
            if let current, current != face {
                result.append(attributed(run, face: current, size: size, weight: weight))
                run.removeAll(keepingCapacity: true)
            }
            current = face
            run.append(character)
        }
        if let current {
            result.append(attributed(run, face: current, size: size, weight: weight))
        }
        return Text(result)
    }

    private static func attributed(_ run: String, face: Face, size: CGFloat, weight: Font.Weight) -> AttributedString {
        var text = AttributedString(run)
        switch face {
        case .english: text.font = english(size, emphasized: weight != .regular)
        case .figure: text.font = figure(size)
        case .system: text.font = .system(size: size, weight: weight)
        }
        return text
    }

    private static func face(for character: Character) -> Face {
        if let ascii = character.asciiValue, (65...90).contains(ascii) || (97...122).contains(ascii) {
            return .english
        }
        if character.unicodeScalars.allSatisfy({
            CharacterSet.decimalDigits.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }) {
            return .figure
        }
        return .system
    }
}
