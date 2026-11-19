import Foundation

/// Points map to CSS pixels. Standard circular arcs, clamped like border-radius: 99px.
enum VoiceBarGeometry {
    static let radius: CGFloat = 99
    static let idle = CGSize(width: 40, height: 6)
    static let hover = CGSize(width: 70, height: 34)
    static let starting = CGSize(width: 54, height: 12)
    static let overlay = CGSize(width: 750, height: 500)
    static let bottomInset: CGFloat = 60 // room for the downward 25px shadow
    static let waveformBarWidth: CGFloat = 2
    static let waveformBarGap: CGFloat = 2
    static let waveform = CGSize(
        width: CGFloat(VoiceWaveform.count) * (waveformBarWidth + waveformBarGap) - waveformBarGap,
        height: CGFloat(VoiceWaveform.peakHeight)
    )
    static let shapeDuration: Double = 0.20
    static let opacityDuration: Double = 0.50

    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(Self.radius, min(rect.width, rect.height) / 2)
        let x = min(max(point.x, rect.minX + radius), rect.maxX - radius)
        let y = min(max(point.y, rect.minY + radius), rect.maxY - radius)
        let dx = point.x - x, dy = point.y - y
        return dx * dx + dy * dy <= radius * radius
    }

    /// Invert the x coordinate of cubic-bezier(.05,.6,.4,.95), then evaluate y.
    static func shapeProgress(_ progress: Double) -> Double {
        cubicProgress(progress, x1: 0.05, y1: 0.6, x2: 0.4, y2: 0.95)
    }

    static func opacityProgress(_ progress: Double) -> Double {
        cubicProgress(progress, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    }

    private static func cubicProgress(_ progress: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let progress = min(1, max(0, progress))
        if progress == 0 || progress == 1 { return progress }
        func curve(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<14 {
            let t = (lower + upper) / 2
            if curve(t, x1, x2) < progress { lower = t } else { upper = t }
        }
        return curve((lower + upper) / 2, y1, y2)
    }
}

enum RecordingBarMode {
    case recording, dictating, handsFree
    var width: CGFloat {
        switch self {
        case .recording: return 70
        case .dictating: return 82
        case .handsFree: return 116
        }
    }
}
