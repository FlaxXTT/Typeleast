import SwiftUI
import AppKit
import QuartzCore

/// Finite frame schedules leave the dashboard idle once each animation finishes.
private func animationFrames(from start: Date, duration: TimeInterval) -> [Date] {
    let frameCount = Int(ceil(duration * 60))
    return (0...frameCount).map { start.addingTimeInterval(min(Double($0) / 60, duration)) }
}

struct CountUpTransition {
    static let duration = 0.250
    private var from: Double
    private(set) var target: Double?
    private(set) var startedAt: Date?

    init(initial: Double?) {
        let value = initial.flatMap { $0.isFinite ? $0 : nil }
        from = value ?? 0
        target = value
    }

    func value(at date: Date) -> Double {
        guard let target, let startedAt else { return target ?? from }
        let progress = max(0, date.timeIntervalSince(startedAt)) / Self.duration
        guard progress < 1 else { return target }
        return from + (target - from) * (1 - pow(1 - progress, 3))
    }

    mutating func retarget(_ next: Double?, at date: Date, reduceMotion: Bool) {
        from = value(at: date)
        target = next.flatMap { $0.isFinite ? $0 : nil }
        startedAt = !reduceMotion && target.map { $0 != from } == true ? date : nil
    }
}

private struct CountUpReadout<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: Double?
    let target: Double?
    let animateOnAppear: Bool
    @ViewBuilder var content: (Double?) -> Content

    private struct Target: Equatable {
        let value: Double?
        let reduceMotion: Bool
    }

    init(_ target: Double?, animateOnAppear: Bool = false, @ViewBuilder content: @escaping (Double?) -> Content) {
        let value = target.flatMap { $0.isFinite ? $0 : nil }
        self.target = value
        self.animateOnAppear = animateOnAppear
        self.content = content
        _displayedValue = State(initialValue: animateOnAppear ? 0 : value)
    }

    var body: some View {
        let next = Target(value: target, reduceMotion: reduceMotion)
        content(reduceMotion ? (target ?? displayedValue) : displayedValue)
            .task(id: next) {
                await animate(to: next)
            }
    }

    @MainActor
    private func animate(to next: Target) async {
        guard !Task.isCancelled else { return }
        let initial = displayedValue ?? 0
        let idleValue: Double? = animateOnAppear ? 0 : nil
        guard let target = next.value, !next.reduceMotion, initial != target else {
            displayedValue = next.value ?? idleValue
            return
        }
        displayedValue = initial
        if animateOnAppear && initial == 0 {
            // Give SwiftUI a chance to present zero before starting the clock.
            do { try await Task.sleep(for: .milliseconds(34)) }
            catch { return }
            guard !Task.isCancelled else { return }
        }
        let start = Date()
        let end = start.addingTimeInterval(CountUpTransition.duration)
        var transition = CountUpTransition(initial: initial)
        transition.retarget(target, at: start, reduceMotion: false)
        while !Task.isCancelled {
            let remainder = end.timeIntervalSinceNow
            do { try await Task.sleep(for: .seconds(min(1.0 / 60, max(0, remainder)))) }
            catch { return }
            guard !Task.isCancelled else { return }
            let now = Date()
            displayedValue = transition.value(at: now)
            if now >= end { return }
        }
    }
}

struct InsightsPanel: View {
    @EnvironmentObject var model: AppModel

    private func figures(height: CGFloat, gap: CGFloat) -> some View {
        let stats = model.stats
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible())], spacing: gap) {
            Figure(value: stats.map { Double($0.words) }, format: .count, label: "Words dictated", height: height)
            Figure(value: stats?.savedSeconds, format: .duration, label: "Time saved", height: height)
            Figure(value: stats.map { Double($0.wordsPerMinute) }, format: .speed, label: "Average speed", height: height)
            Figure(value: stats?.speakingSeconds, format: .duration, label: "Total dictation time", height: height)
        }
        .id(model.homePresentationID)
    }

    static let shareText = "TypeLeast · https://typeleast.promptking.workers.dev · https://github.com/FlaxXTT/Typeleast"
    static let shareItems: [Any] = [shareText, URL(string: "https://typeleast.promptking.workers.dev")!, URL(string: "https://github.com/FlaxXTT/Typeleast")!]

    var body: some View {
        GeometryReader { geometry in
            let headerHeight: CGFloat = 54
            let spacing: CGFloat = 14
            let tileGap: CGFloat = 12
            let contentHeight = max(0, geometry.size.height - headerHeight - 2 * spacing)
            let activityHeight = contentHeight * Theme.homeRatio
            let tileHeight = max(0, (contentHeight - activityHeight - tileGap) / 2)
            VStack(alignment: .leading, spacing: spacing) {
                HStack {
                    Text(verbatim: "Instinct")
                        .font(.system(size: 36, weight: .medium, design: .serif))
                        .tracking(-0.65)
                        .foregroundColor(Theme.homeLabel)
                        .padding(.leading, 8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    ShareButton(items: Self.shareItems).frame(width: 94, height: 40)
                }
                .frame(height: headerHeight)
                figures(height: tileHeight, gap: tileGap)
                ActivityCard()
                    .id(model.homePresentationID)
                    .frame(height: activityHeight)
            }
        }
    }
}

enum InsightFormat {
    case count, duration, speed

    struct Part: Equatable {
        let digits: String
        var suffix = ""
        var unit = ""
    }

    func parts(for value: Double?) -> [Part] {
        guard let value, value.isFinite else { return [Part(digits: "--")] }
        let whole = Int(clamping: Int64(exactly: max(0, value.rounded())) ?? Int64.max)
        switch self {
        case .count where whole >= 1000:
            let digits = String(format: "%.1f", locale: Locale(identifier: "en_US"), Double(whole) / 1000)
            return [Part(digits: digits, suffix: "k", unit: "chars")]
        case .count, .speed:
            let digits = L10n.formattedNumber(NSNumber(value: whole), language: "en")
            return [Part(digits: digits, unit: self == .count ? "chars" : "chars/min")]
        case .duration where whole < 60:
            return [Part(digits: String(whole), unit: "s")]
        case .duration where whole < 3600:
            return [Part(digits: String(whole / 60), unit: "min")]
        case .duration:
            return [Part(digits: String(whole / 3600), unit: "h"), Part(digits: String(whole / 60 % 60), unit: "min")]
        }
    }
}

/// One metric tile with a large figure, a smaller unit and a label.
struct Figure: View {
    private static let numberFont = Font.system(size: 32, weight: .medium, design: .serif).monospacedDigit()
    let value: Double?
    let format: InsightFormat
    let label: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CountUpReadout(value, animateOnAppear: true) { number in
                let parts = format.parts(for: number)
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    ForEach(parts.indices, id: \.self) { index in
                        let part = parts[index]
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            (Text(verbatim: part.digits).font(Self.numberFont)
                                + Text(verbatim: part.suffix).font(.system(size: 21, weight: .medium, design: .serif)))
                                .tracking(-0.9)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            if !part.unit.isEmpty {
                                Text(verbatim: part.unit)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.ink.opacity(0.8))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(parts.map { $0.digits + $0.suffix + " " + $0.unit }.joined(separator: " "))
            }
            Text(verbatim: label)
                .font(.system(size: Theme.homeSecondarySize))
                .lineLimit(1).minimumScaleFactor(0.85)
                .foregroundColor(Theme.homeLabel)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Theme.homeMetricRadius, style: .circular).fill(Theme.tile))
    }
}

/// A faint grid of dots behind the insights.
struct HomeDotGrid: View {
    var body: some View {
        HomeDotPattern()
            .background {
                LinearGradient(colors: [Theme.homeBackdrop, Theme.window], startPoint: .bottomLeading, endPoint: .topTrailing)
                    .overlay(LinearGradient(colors: [.clear, Theme.window.opacity(0.3)], startPoint: .top, endPoint: .bottom))
            }
    }
}

private struct HomeDotPattern: NSViewRepresentable {
    func makeNSView(context: Context) -> HomeDotGridView { HomeDotGridView() }
    func updateNSView(_ view: HomeDotGridView, context: Context) {}
}

/// Retain the backdrop geometry instead of creating thousands of dot paths on redraw.
final class HomeDotGridView: NSView {
    private let dots = CAShapeLayer()
    private let dotOpacity = CAGradientLayer()
    private var pathSize = NSSize.zero
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(dots)
        dotOpacity.startPoint = CGPoint(x: 0, y: 0.5)
        dotOpacity.endPoint = CGPoint(x: 1, y: 0.5)
        dotOpacity.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.5).cgColor]
        dots.mask = dotOpacity
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("Created in code") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }

    override func layout() {
        super.layout()
        guard pathSize != bounds.size else { return }
        pathSize = bounds.size
        let path = CGMutablePath()
        let step: CGFloat = 11
        for y in stride(from: step / 2, to: bounds.height, by: step) {
            for x in stride(from: step / 2, to: bounds.width, by: step) {
                path.addEllipse(in: CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots.frame = bounds
        dotOpacity.frame = bounds
        dots.path = path
        CATransaction.commit()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dots.fillColor = NSColor(Theme.homeDot).cgColor
            CATransaction.commit()
        }
    }
}

/// The system share menu with the website and GitHub links.
struct ShareButton: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> HoverShareButton {
        let button = HoverShareButton(title: "Share", image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.image = button.image?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        button.wantsLayer = true
        button.controlSize = .regular
        button.toolTip = "Share the website and GitHub links"
        return button
    }

    func updateNSView(_ nsView: HoverShareButton, context: Context) {
        context.coordinator.items = items
    }
    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var items: [Any]
        private var picker: NSSharingServicePicker?
        private weak var button: HoverShareButton?

        init(items: [Any]) { self.items = items }

        @objc func share(_ sender: HoverShareButton) {
            guard picker == nil else { return }
            let picker = NSSharingServicePicker(items: items)
            self.picker = picker
            button = sender
            sender.setPickerOpen(true)
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            button?.setPickerOpen(false)
            button = nil
            picker = nil
        }
    }
}

final class HoverShareButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    private var hovering = false
    private var pickerOpen = false
    override var intrinsicContentSize: NSSize { NSSize(width: 94, height: 40) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func mouseMoved(with event: NSEvent) { setHovered(true) }

    private func setHovered(_ hovering: Bool) {
        let next = hovering && !pickerOpen
        guard self.hovering != next else { return }
        self.hovering = next
        needsDisplay = true
    }

    func setPickerOpen(_ open: Bool) {
        pickerOpen = open
        hovering = false
        highlight(false)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 20, yRadius: 20)
        NSColor(Theme.tile).setFill()
        capsule.fill()
        let pressed = isHighlighted && !pickerOpen
        if pressed || (hovering && window?.isKeyWindow == true) {
            NSColor(Theme.cardHover).setFill()
            capsule.fill()
        }
        NSColor(Theme.border).setStroke()
        capsule.lineWidth = 0.5
        capsule.stroke()

        let ink = NSColor(Theme.ink)
        let label = NSAttributedString(string: title,
                                       attributes: [.font: font ?? InterfaceTypography.localizedAppKit(16, weight: .medium),
                                                    .foregroundColor: ink])
        let labelSize = label.size()
        let iconSize: CGFloat = 18
        let gap: CGFloat = 8
        let x = bounds.midX - (iconSize + gap + labelSize.width) / 2
        let icon = image?.withSymbolConfiguration(.init(paletteColors: [ink]))
        icon?.draw(in: NSRect(x: x, y: bounds.midY - iconSize / 2,
                             width: iconSize, height: iconSize),
                   from: .zero, operation: .sourceOver, fraction: pressed ? 0.75 : 1,
                   respectFlipped: true, hints: nil)
        label.draw(at: NSPoint(x: x + iconSize + gap, y: bounds.midY - labelSize.height / 2))
    }
}

/// Total active days above the heatmap, with weekdays down the side and months along the bottom.
struct ActivityCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weekOffset = 0
    @State private var revealStart: Date?

    private let dayColumn: CGFloat = 24
    private let navigationHeight: CGFloat = 18
    private let navigationGap: CGFloat = 6

    var body: some View {
        let log = model.activityReady ? ActivityLog.shared : nil
        let _ = model.activityRevision
        let revealReady = model.activityReady && !model.homePresentationSuspended
        VStack(alignment: .leading, spacing: 0) {
            activeDays(log?.activeDays)
                .padding(.horizontal, 7)
            GeometryReader { geo in
                let weeks = max(1, min(20, Int((geo.size.width - dayColumn + ActivityTrack.columnGap) / ActivityTrack.columnStep)))
                let cell = ActivityTrack.columnStep - ActivityTrack.columnGap
                let width = CGFloat(weeks) * ActivityTrack.columnStep - ActivityTrack.columnGap
                let rowStep = max(cell + 2, (geo.size.height - cell - navigationHeight - navigationGap) / 6)
                let navigationY = 6 * rowStep + cell + navigationGap
                let duration = HeatmapMotion.finishTime(columns: weeks)
                ZStack(alignment: .topLeading) {
                    weekdays(cell: cell, rowStep: rowStep)
                    let elapsed = reduceMotion ? duration : 0
                    Group {
                        if let revealStart, revealReady, !reduceMotion {
                            TimelineView(.explicit(animationFrames(from: revealStart, duration: duration))) { frame in
                                track(log: log, weeks: weeks, rowStep: rowStep, navigationY: navigationY,
                                      elapsed: frame.date.timeIntervalSince(revealStart))
                            }
                        } else {
                            track(log: revealReady ? log : nil, weeks: weeks, rowStep: rowStep,
                                  navigationY: navigationY, elapsed: elapsed)
                        }
                    }
                    .frame(width: width, height: navigationY + navigationHeight, alignment: .topLeading)
                    .clipped()
                    .offset(x: dayColumn)
                    navigation(log: log, weeks: weeks)
                        .frame(width: dayColumn + width)
                        .offset(y: navigationY)
                }
                .frame(width: dayColumn + width, height: geo.size.height, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                Text(L10n.text("更少")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                ForEach(1..<5) { level in ActivityTrack.square(level, size: 13) }
                Text(L10n.text("更多")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
            }
            .padding(.horizontal, 7)
            .padding(.top, 8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.homeActivityRadius, style: .circular).fill(Theme.tile))
        .onChange(of: revealReady, initial: true) { _, ready in
            revealStart = ready ? (reduceMotion ? .distantPast : Date()) : nil
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced, revealStart != nil { revealStart = .distantPast }
        }
    }

    private func activeDays(_ value: Int?) -> some View {
        let description = L10n.text("活跃天数")
        return VStack(alignment: .leading, spacing: 6) {
            CountUpReadout(value.map(Double.init)) { number in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    let digits = number.map { L10n.formattedNumber(NSNumber(value: $0.rounded())) } ?? "--"
                    Text(verbatim: digits)
                        .font(InterfaceTypography.figure(Theme.homeFigureSize))
                        .tracking(-0.6)
                    if number != nil {
                        InterfaceTypography.text("d", size: Theme.homeSecondarySize, weight: .semibold)
                    }
                }
            }
            InterfaceTypography.text("Active", size: Theme.homeSecondarySize)
                .foregroundColor(Theme.homeLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityValue(value.map { L10n.formattedNumber(NSNumber(value: $0)) + " " + L10n.text("天") } ?? "--")
        .help(description)
    }

    private func weekdays(cell: CGFloat, rowStep: CGFloat) -> some View {
        let weekdays = ["S", "M", "T", "W", "T", "F", "S"]
        let hatchWidth: CGFloat = 7
        return ForEach(0..<7, id: \.self) { row in
            Text(weekdays[row]).font(InterfaceTypography.localized(11)).foregroundColor(Theme.homeLabel)
                .frame(width: 14, height: cell)
                .offset(y: CGFloat(row) * rowStep)
            Path { path in
                for y in stride(from: -cell, through: cell, by: 5) {
                    path.move(to: CGPoint(x: 0, y: y + hatchWidth))
                    path.addLine(to: CGPoint(x: hatchWidth, y: y))
                }
            }
            .stroke(Theme.border.opacity(0.6), lineWidth: 1)
            .frame(width: hatchWidth, height: cell).clipped()
            .offset(x: 16, y: CGFloat(row) * rowStep)
            .accessibilityHidden(true)
        }
    }

    private func track(log: ActivityLog?, weeks: Int, rowStep: CGFloat, navigationY: CGFloat, elapsed: Double) -> some View {
        ActivityTrack(log: log, weeks: weeks, rowStep: rowStep,
                      navigationY: navigationY, elapsed: elapsed, position: Double(weekOffset))
    }

    private func navigation(log: ActivityLog?, weeks: Int) -> some View {
        let calendar = ActivityTrack.calendar
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .day, value: 7 * (weekOffset - weeks + 1), to: thisWeek) ?? thisWeek
        let earliest = log?.days.keys.min().flatMap { ActivityLog.parse($0, calendar: calendar) }
        return HStack {
            Button { move(-ActivityTrack.scrollWeeks) } label: {
                Image(systemName: "chevron.left").frame(width: navigationHeight, height: navigationHeight)
            }
            .disabled(earliest.map { first <= $0 } ?? true)
            .help(L10n.text("较早的活动"))
            Spacer()
            Button { move(ActivityTrack.scrollWeeks) } label: {
                Image(systemName: "chevron.right").frame(width: navigationHeight, height: navigationHeight)
            }
            .disabled(weekOffset >= 0)
            .help(L10n.text("较新的活动"))
        }
        .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.homeLabel).buttonStyle(.plain)
    }

    private func move(_ weeks: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.320)) {
            weekOffset = min(0, weekOffset + weeks)
        }
    }
}

private struct ActivityTrack: View, Animatable {
    // Four weeks on the same 22-point pitch move both rows and labels exactly 88 points.
    static let scrollWeeks = 4
    static let columnStep: CGFloat = 22
    static let columnGap: CGFloat = 3
    let log: ActivityLog?
    let weeks: Int
    let rowStep: CGFloat
    let navigationY: CGFloat
    let elapsed: Double
    var position: Double

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        calendar.firstWeekday = 1
        return calendar
    }

    var body: some View {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let cell = Self.columnStep - Self.columnGap
        let firstWeek = position - Double(weeks - 1)
        let first = Int(floor(firstWeek))
        ZStack(alignment: .topLeading) {
            ForEach(first...(first + weeks), id: \.self) { week in
                let date = calendar.date(byAdding: .day, value: 7 * week, to: thisWeek) ?? thisWeek
                let x = (Double(week) - firstWeek) * Self.columnStep
                let motion = HeatmapMotion.sample(elapsed: elapsed, column: max(0, week + weeks - 1))
                ForEach(0..<7, id: \.self) { row in
                    let day = calendar.date(byAdding: .day, value: row, to: date) ?? date
                    cellView(date: day, today: today, size: cell, motion: motion)
                        .offset(x: x, y: CGFloat(row) * rowStep)
                        .accessibilityHidden(x <= -cell || x >= CGFloat(weeks) * Self.columnStep)
                }
                if week <= 0, let label = monthLabel(weekStart: date, calendar: calendar) {
                    InterfaceTypography.text(label, size: 11).foregroundColor(Theme.homeLabel)
                        .fixedSize()
                        .offset(x: x, y: navigationY + 2)
                        .accessibilityHidden(x <= -cell || x >= CGFloat(weeks) * Self.columnStep)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func cellView(date: Date, today: Date, size: CGFloat, motion: HeatmapMotion.Sample) -> some View {
        if let log {
            Group {
                if date <= today {
                    let day = log.day(date)
                    let description = tooltip(date, day)
                    Self.square(ActivityLog.level(day.dictations), size: size)
                        .help(description).accessibilityLabel(description)
                } else {
                    RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                        .frame(width: size, height: size)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if motion.cover > 0 {
                    Self.square(0, size: size).opacity(motion.cover)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .scaleEffect(motion.scale)
        } else {
            Self.square(0, size: size).accessibilityHidden(true)
        }
    }

    static func square(_ level: Int, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
            .fill(level == 0 ? Theme.heatEmpty : Theme.heat[min(3, level - 1)])
            .frame(width: size, height: size)
    }

    private func monthLabel(weekStart: Date, calendar: Calendar) -> String? {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        guard let startsMonth = days.first(where: { calendar.component(.day, from: $0) == 1 }) else { return nil }
        if L10n.language != "en" {
            return ["一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"][calendar.component(.month, from: startsMonth) - 1]
        }
        return startsMonth.formatted(.dateTime.locale(L10n.locale).month(.abbreviated))
    }

    private func tooltip(_ date: Date, _ day: ActivityDay) -> String {
        let when = date.formatted(.dateTime.locale(L10n.locale).month(.abbreviated).day())
        return day.dictations == 0
            ? when + " · " + L10n.text("没有活动")
            : when + " · " + L10n.text("{0} 次 · {1} 字", day.dictations, day.words)
    }
}

enum HeatmapMotion {
    static let columnDelay = 0.020
    static let cellDuration = 0.300

    struct Sample: Equatable {
        let scale: Double
        let cover: Double
    }

    static func finishTime(columns: Int) -> Double {
        max(0, Double(columns - 1)) * columnDelay + cellDuration
    }

    static func sample(elapsed: Double, column: Int) -> Sample {
        let time = elapsed - Double(column) * columnDelay
        guard time > 0 else { return Sample(scale: 1, cover: 1) }
        guard time < cellDuration else { return Sample(scale: 1, cover: 0) }
        let half = cellDuration / 2
        if time <= half {
            let progress = ease(time / half)
            return Sample(scale: 1 + 0.2 * progress, cover: 1 - progress)
        }
        let progress = ease((time - half) / half)
        return Sample(scale: 1.2 - 0.2 * progress, cover: 0)
    }

    /// Invert the Bézier's x coordinate to sample cubic-bezier(.22, .61, .36, 1).
    private static func ease(_ x: Double) -> Double {
        if x == 0 || x == 1 { return x }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<16 {
            let t = (lower + upper) / 2
            if bezier(t, 0.22, 0.36) < x { lower = t } else { upper = t }
        }
        return bezier((lower + upper) / 2, 0.61, 1)
    }

    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }
}
