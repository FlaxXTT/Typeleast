import AppKit
import Combine
import SwiftUI

final class WindowHoverPointer: ObservableObject {
    @Published private(set) var location: CGPoint?
    @Published private(set) var overControl = false

    private var lastUpdate: TimeInterval = 0
    private var pendingLocation: CGPoint?
    private var pendingUpdate: DispatchWorkItem?
    private var controls: Set<UUID> = []

    func move(to point: CGPoint) {
        pendingLocation = point
        guard pendingUpdate == nil else { return }
        let delay = lastUpdate + 1.0 / 30 - ProcessInfo.processInfo.systemUptime
        if delay <= 0 {
            publishLocation()
        } else {
            let update = DispatchWorkItem { [weak self] in self?.publishLocation() }
            pendingUpdate = update
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: update)
        }
    }

    func control(_ id: UUID, hovering: Bool) {
        if hovering { controls.insert(id) } else { controls.remove(id) }
        let next = !controls.isEmpty
        if next != overControl { overControl = next }
    }

    func clear() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        pendingLocation = nil
        lastUpdate = 0
        if location != nil { location = nil }
        controls.removeAll()
        if overControl { overControl = false }
    }

    private func publishLocation() {
        pendingUpdate = nil
        lastUpdate = ProcessInfo.processInfo.systemUptime
        if location != pendingLocation { location = pendingLocation }
        pendingLocation = nil
    }
}

private struct WindowHoverPointerKey: EnvironmentKey {
    static let defaultValue: WindowHoverPointer? = nil
}

extension EnvironmentValues {
    var windowHoverPointer: WindowHoverPointer? {
        get { self[WindowHoverPointerKey.self] }
        set { self[WindowHoverPointerKey.self] = newValue }
    }
}

extension View {
    func windowHoverEffects(enabled: Bool = true) -> some View {
        modifier(WindowHoverEffects(enabled: enabled))
    }

    func hoverCard<Fill: ShapeStyle>(_ fill: Fill, radius: CGFloat, border: Color = .clear,
                                    stroke: StrokeStyle = StrokeStyle(lineWidth: 1),
                                    edgeHighlightShape: AnyShape? = nil,
                                    enabled: Bool = true) -> some View {
        background {
            HoverCardBackground(fill: fill, radius: radius, border: border, stroke: stroke,
                                edgeHighlightShape: edgeHighlightShape, enabled: enabled)
        }
    }
}

struct WindowHoverEffects: ViewModifier {
    static let coordinates = "typeleast.window-hover"
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorScheme) private var colorScheme
    // Only the decorations observe changes within this reference.
    @State private var pointer: WindowHoverPointer

    init(enabled: Bool, pointer: WindowHoverPointer = WindowHoverPointer()) {
        self.enabled = enabled
        _pointer = State(initialValue: pointer)
    }

    private var tracksPointer: Bool { enabled && appearsActive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .environment(\.windowHoverPointer, tracksPointer ? pointer : nil)
            .overlay {
                if tracksPointer && colorScheme == .dark {
                    PointerSpotlight(pointer: pointer)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .coordinateSpace(.named(Self.coordinates))
            .onContinuousHover { phase in
                guard tracksPointer else { return }
                switch phase {
                case .active(let location): pointer.move(to: location)
                case .ended: pointer.clear()
                }
            }
            .onChange(of: tracksPointer) { _, active in if !active { pointer.clear() } }
            .onReceive(HoverFeedbackReset.events) { _ in pointer.clear() }
            .onDisappear { pointer.clear() }
    }
}

private struct PointerSpotlight: View {
    @ObservedObject var pointer: WindowHoverPointer

    var body: some View {
        let location = pointer.location
        return Canvas { context, _ in
            guard let location else { return }
            let radius: CGFloat = 120
            let glow = Color(red: 1, green: 0.93, blue: 0.83).opacity(0.05)
            let area = CGRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: area),
                         with: .radialGradient(Gradient(colors: [glow, .clear]), center: location,
                                               startRadius: 0, endRadius: radius))
        }
    }
}

struct HoverCardAngle: Equatable {
    var pitch: Double = 0
    var yaw: Double = 0

    init() {}

    init(at location: CGPoint?, in frame: CGRect, overControl: Bool) {
        guard !overControl, let location, frame.width > 0, frame.height > 0,
              frame.contains(location) else { return }
        let vertical = Double((frame.midY - location.y) / (frame.height / 2))
        let horizontal = Double((location.x - frame.midX) / (frame.width / 2))
        let magnitude = max(1, hypot(vertical, horizontal))
        pitch = vertical / magnitude
        yaw = horizontal / magnitude
    }
}

private struct HoverCardBackground<Fill: ShapeStyle>: View {
    @Environment(\.windowHoverPointer) private var pointer
    let fill: Fill
    let radius: CGFloat
    let border: Color
    let stroke: StrokeStyle
    let edgeHighlightShape: AnyShape?
    let enabled: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        let surface = shape.fill(fill).overlay { shape.strokeBorder(border, style: stroke) }
        if let pointer, enabled {
            TiltedCardSurface(pointer: pointer, shape: shape, surface: surface, edgeHighlightShape: edgeHighlightShape)
        } else {
            surface.allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct TiltedCardSurface<Surface: View>: View {
    @ObservedObject var pointer: WindowHoverPointer
    let shape: RoundedRectangle
    let surface: Surface
    let edgeHighlightShape: AnyShape?
    @State private var frame = CGRect.zero

    var body: some View {
        let angle = HoverCardAngle(at: pointer.location, in: frame, overControl: pointer.overControl)
        let edge = UnitPoint(x: 0.5 + angle.yaw / 2, y: 0.5 - angle.pitch / 2)
        let highlight = LinearGradient(colors: [.white.opacity(0.24), .clear],
                                       startPoint: edge, endPoint: UnitPoint(x: 1 - edge.x, y: 1 - edge.y))
        surface
            .overlay {
                Group {
                    if let edgeHighlightShape {
                        edgeHighlightShape.stroke(highlight, style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    } else {
                        shape.strokeBorder(highlight, lineWidth: 1)
                    }
                }
                .opacity(min(1, hypot(angle.pitch, angle.yaw)))
            }
            .rotation3DEffect(.degrees(angle.pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
            .rotation3DEffect(.degrees(angle.yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
            .animation(.easeOut(duration: 0.16), value: angle)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(WindowHoverEffects.coordinates)) }) { frame = $0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
