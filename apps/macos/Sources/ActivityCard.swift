import SwiftUI
import AppKit
import CoreText
import QuartzCore

/// Finite frame schedules leave the dashboard idle once each animation finishes.
private func animationFrames(from start: Date, duration: TimeInterval) -> [Date] {
    let frameCount = Int(ceil(duration * 60))
    return (0...frameCount).map { start.addingTimeInterval(min(Double($0) / 60, duration)) }
}

struct CountUpTransition {
    static let duration = 1.2
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
        let eased = progress * progress * (3 - 2 * progress)
        return from + (target - from) * eased
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
    var animationsReady = true

    private func figures(height: CGFloat, gap: CGFloat) -> some View {
        let stats = animationsReady ? model.stats : nil
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
                }
                .frame(height: headerHeight)
                figures(height: tileHeight, gap: tileGap)
                ActivityCard(animationsReady: animationsReady)
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

private enum InsightTypography {
    static let number = Font.system(size: 32, weight: .medium, design: .serif).monospacedDigit()
    static let numberTracking: CGFloat = -0.9
    static let unit = Font.system(size: 12)
    static let label = Font.system(size: Theme.homeSecondarySize)
}

/// One metric tile with a large figure, a smaller unit and a label.
struct Figure: View {
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
                            (Text(verbatim: part.digits).font(InsightTypography.number)
                                + Text(verbatim: part.suffix).font(.system(size: 21, weight: .medium, design: .serif)))
                                .tracking(InsightTypography.numberTracking)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            if !part.unit.isEmpty {
                                Text(verbatim: part.unit)
                                    .font(InsightTypography.unit)
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
                .font(InsightTypography.label)
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
    static let size = NSSize(width: 94, height: 40)
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
    override var intrinsicContentSize: NSSize { ShareButton.size }

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
        let radius = bounds.height / 2
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let pressed = isHighlighted && !pickerOpen
        if pressed || (hovering && window?.isKeyWindow == true) {
            NSColor(Theme.cardHover).setFill()
            capsule.fill()
        }

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

/// Today and the preceding 132 calendar days, aligned to the calendar's week grid.
struct ActivityRange {
    static let dayCount = 133
    let firstDay: Date
    let today: Date
    let lastWeek: Date
    let weekCount: Int

    init(endingOn date: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: date)
        let firstDay = calendar.date(byAdding: .day, value: 1 - Self.dayCount, to: today) ?? today
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start ?? firstDay
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = calendar.dateComponents([.day], from: firstWeek, to: lastWeek).day ?? 0
        self.firstDay = firstDay
        self.today = today
        self.lastWeek = lastWeek
        self.weekCount = days / 7 + 1
    }

    func emptyShade(for date: Date, calendar: Calendar, region: String?) -> Int {
        let age = max(0, calendar.dateComponents([.day], from: date, to: today).day ?? 0)
        let relief = Self.isHoliday(date, calendar: calendar, region: region) ? 12
            : calendar.isDateInWeekend(date) ? 7 : 0
        // Slightly stagger the band boundaries across rows to soften vertical seams.
        let weekdayOffset = (calendar.component(.weekday, from: date) * 3) % 7 - 3
        return min(3, max(0, (age + relief + weekdayOffset) / 33))
    }

    private static func isHoliday(_ date: Date, calendar: Calendar, region: String?) -> Bool {
        let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
        guard let month = parts.month, let day = parts.day else { return false }
        if month == 1 && day == 1 { return true }
        switch region {
        case "US":
            return (month == 7 && day == 4) || (month == 12 && day == 25)
                || (month == 9 && day <= 7 && parts.weekday == 2)
                || (month == 11 && (22...28).contains(day) && parts.weekday == 5)
        case "CN":
            if (month == 5 && day == 1) || (month == 10 && day <= 3) { return true }
            var lunar = Calendar(identifier: .chinese)
            lunar.timeZone = calendar.timeZone
            let parts = lunar.dateComponents([.month, .day], from: date)
            return parts.isLeapMonth != true && ((parts.month == 1 && parts.day == 1)
                || (parts.month == 5 && parts.day == 5) || (parts.month == 8 && parts.day == 15))
        default:
            return false
        }
    }
}

/// Cadence heatmap with weekdays down the side and months along the bottom.
struct ActivityCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var animationsReady = true
    @State private var weekOffset = 0
    @State private var animation: (target: Reveal, startedAt: Date)?

    private let dayColumn: CGFloat = 24
    private let navigationHeight: CGFloat = 18
    private let navigationGap: CGFloat = 6

    private struct Reveal: Equatable {
        let ready: Bool
        let reduced: Bool
        let presentation: Int
    }

    var body: some View {
        let log = model.activityReady ? ActivityLog.shared : nil
        let _ = model.activityRevision
        let revealReady = animationsReady && model.activityReady && !model.homePresentationSuspended
        let calendar = ActivityTrack.calendar
        let range = ActivityRange(endingOn: Date(), calendar: calendar)
        let reveal = Reveal(ready: revealReady, reduced: reduceMotion, presentation: model.homePresentationID)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Cadence")
                .font(.system(size: 24, weight: .medium, design: .serif))
                .tracking(-0.45)
                .foregroundColor(Theme.ink)
                .frame(height: 28)
                .padding(.horizontal, 7)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { geo in
                let weeks = range.weekCount
                let availableWidth = max(0, geo.size.width - dayColumn)
                let columnStep = min(ActivityTrack.preferredColumnStep,
                                     (availableWidth + ActivityTrack.columnGap) / CGFloat(weeks))
                let cell = max(0, columnStep - ActivityTrack.columnGap)
                let width = CGFloat(weeks - 1) * columnStep + cell
                let rowStep = max(cell + 2, (geo.size.height - cell - navigationHeight - navigationGap) / 6)
                let navigationY = 6 * rowStep + cell + navigationGap
                let duration = HeatmapMotion.finishTime(columns: weeks)
                ZStack(alignment: .topLeading) {
                    weekdays(cell: cell, rowStep: rowStep)
                    let elapsed = reduceMotion ? duration : 0
                    Group {
                        if let animation, animation.target == reveal {
                            TimelineView(.explicit(animationFrames(from: animation.startedAt, duration: duration))) { frame in
                                track(log: log, range: range, columnStep: columnStep, cell: cell,
                                      rowStep: rowStep, navigationY: navigationY,
                                      elapsed: frame.date.timeIntervalSince(animation.startedAt))
                            }
                        } else {
                            track(log: revealReady ? log : nil, range: range, columnStep: columnStep, cell: cell,
                                  rowStep: rowStep, navigationY: navigationY, elapsed: elapsed)
                        }
                    }
                    .frame(width: width, height: navigationY + navigationHeight, alignment: .topLeading)
                    .padding(.top, ActivityTrack.revealHeadroom)
                    .clipped()
                    .padding(.top, -ActivityTrack.revealHeadroom)
                    .offset(x: dayColumn)
                    navigation(log: log, range: range, calendar: calendar)
                        .frame(width: dayColumn + width)
                        .offset(y: navigationY)
                }
                .frame(width: dayColumn + width, height: geo.size.height, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 6)
            HStack(spacing: 6) {
                Text(L10n.text("更少")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                ForEach(1..<5) { level in ActivityTrack.square(level, size: 13) }
                Text(L10n.text("更多")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                Spacer(minLength: 12)
                ActiveDaysReadout(value: log.map { animationsReady ? $0.activeDays : 0 },
                                  periodTint: model.sidebarBrandPalette.appearance(for: colorScheme).initialTint)
            }
            .padding(.horizontal, 7)
            .padding(.top, 8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.homeActivityRadius, style: .circular).fill(Theme.tile))
        .onChange(of: reveal, initial: true) { _, target in
            animation = target.ready && !target.reduced ? (target, Date()) : nil
        }
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
            .stroke(Theme.heatHatch, lineWidth: 1)
            .frame(width: hatchWidth, height: cell).clipped()
            .offset(x: 16, y: CGFloat(row) * rowStep)
            .accessibilityHidden(true)
        }
    }

    private func track(log: ActivityLog?, range: ActivityRange, columnStep: CGFloat, cell: CGFloat,
                       rowStep: CGFloat, navigationY: CGFloat, elapsed: Double) -> some View {
        ActivityTrack(log: log, range: range, columnStep: columnStep, cell: cell, rowStep: rowStep,
                      navigationY: navigationY, elapsed: elapsed, position: Double(weekOffset))
    }

    private func navigation(log: ActivityLog?, range: ActivityRange, calendar: Calendar) -> some View {
        let first = calendar.date(byAdding: .day, value: 7 * weekOffset, to: range.firstDay) ?? range.firstDay
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.64)) {
            weekOffset = min(0, weekOffset + weeks)
        }
    }
}

enum RhythmPeriod: String, CaseIterable {
    case dawns = "Dawns", morns = "Morns", noons = "Noons", dusks = "Dusks", nights = "Nights"

    private var startHour: Int {
        switch self {
        case .dawns: return 5
        case .morns: return 8
        case .noons: return 12
        case .dusks: return 17
        case .nights: return 20
        }
    }

    static func current(at date: Date, calendar: Calendar) -> Self {
        let hour = calendar.component(.hour, from: date)
        return allCases.last { $0.startHour <= hour } ?? .nights
    }

    struct Schedule: TimelineSchedule {
        func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
            let calendar = Calendar.autoupdatingCurrent
            return AnySequence(sequence(first: startDate) { date in
                RhythmPeriod.allCases.compactMap { period in
                    calendar.nextDate(after: date, matching: DateComponents(hour: period.startHour, minute: 0, second: 0),
                                      matchingPolicy: .nextTime)
                }.min()
            })
        }
    }
}

struct ActiveDaysReadout: View {
    let value: Int?
    var periodTint = Theme.homeLabel

    private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "GoeistSerif-Regular", withExtension: "otf", subdirectory: "Fonts"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        return descriptors.first
    }()
    private static let numberFont = font(24).monospacedDigit()
    private static let rhythmFont = font(11, italic: true)
    private static let periodFont = font(10)

    private static func font(_ size: CGFloat, italic: Bool = false) -> Font {
        guard let descriptor else {
            let fallback = Font.system(size: size, design: .serif)
            return italic ? fallback.italic() : fallback
        }
        // Upstream ships an upright face. Slant only the superscript.
        var slant = CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: 0, ty: 0)
        let face = italic ? CTFontCreateWithFontDescriptor(descriptor, size, &slant)
                          : CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return Font(face)
    }

    var body: some View {
        let description = L10n.text("活跃天数")
        CountUpReadout(value.map(Double.init), animateOnAppear: value != nil) { number in
            HStack(alignment: .center, spacing: 4) {
                let digits = number.map { L10n.formattedNumber(NSNumber(value: $0.rounded())) } ?? "--"
                Text(verbatim: digits)
                    .font(Self.numberFont)
                    .tracking(-0.55)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if number != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "Rhythm")
                            .font(Self.rhythmFont)
                            .tracking(-0.24)
                        TimelineView(RhythmPeriod.Schedule()) { context in
                            Text(verbatim: RhythmPeriod.current(at: context.date, calendar: .autoupdatingCurrent).rawValue)
                                .font(Self.periodFont)
                                .foregroundStyle(periodTint)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityValue(value.map { L10n.formattedNumber(NSNumber(value: $0)) + " " + L10n.text("天") } ?? "--")
        .help(description)
    }
}

private struct ActivityTrack: View, Animatable {
    static let scrollWeeks = 4
    static let preferredColumnStep: CGFloat = 22
    static let columnGap: CGFloat = 3
    static let revealHeadroom: CGFloat = 6
    private static let englishMonth = Date.FormatStyle(locale: Locale(identifier: "en_US"),
                                                       calendar: Calendar(identifier: .gregorian),
                                                       timeZone: .autoupdatingCurrent).month(.abbreviated)
    let log: ActivityLog?
    let range: ActivityRange
    let columnStep: CGFloat
    let cell: CGFloat
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
        let region = Locale.autoupdatingCurrent.region?.identifier
        let weeks = range.weekCount
        let firstWeek = position - Double(weeks - 1)
        let first = Int(floor(firstWeek))
        ZStack(alignment: .topLeading) {
            ForEach(first...(first + weeks), id: \.self) { week in
                let date = calendar.date(byAdding: .day, value: 7 * week, to: range.lastWeek) ?? range.lastWeek
                let x = (Double(week) - firstWeek) * columnStep
                let offscreen = x <= -cell || x >= CGFloat(weeks) * columnStep
                let column = max(0, week + weeks - 1)
                let motion = HeatmapMotion.sample(elapsed: elapsed, column: column)
                ForEach(0..<7, id: \.self) { row in
                    if let day = calendar.date(byAdding: .day, value: row, to: date) {
                        let depth = HeatmapMotion.depth(elapsed: elapsed, column: column, row: row)
                        cellView(date: day, calendar: calendar, region: region, motion: motion, depth: depth)
                            .offset(x: x, y: CGFloat(row) * rowStep)
                            .accessibilityHidden(offscreen)
                    }
                }
                if week <= 0, let label = monthLabel(weekStart: date, calendar: calendar) {
                    InterfaceTypography.text(label, size: 11).foregroundColor(Theme.homeLabel)
                        .fixedSize()
                        .offset(x: x, y: navigationY + 2)
                        .accessibilityHidden(offscreen)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func cellView(date: Date, calendar: Calendar, region: String?, motion: HeatmapMotion.Sample, depth: Double) -> some View {
        if let log {
            let face = Group {
                if date <= range.today && (position < 0 || date >= range.firstDay) {
                    let day = log.day(date)
                    let description = tooltip(date, day)
                    let level = ActivityLog.level(day.dictations)
                    let shade = level == 0 ? range.emptyShade(for: date, calendar: calendar, region: region) : 0
                    Self.square(level, size: cell, emptyShade: shade)
                        .help(description).accessibilityLabel(description)
                } else {
                    RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                        .frame(width: cell, height: cell)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if motion.cover > 0 {
                    Self.square(0, size: cell).opacity(motion.cover)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .scaleEffect(motion.scale)
            if depth > 0 {
                face
                    .rotation3DEffect(.degrees(24 * depth), axis: (x: 1, y: -0.3, z: 0), perspective: 0.45)
                    .offset(y: -3 * depth)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.heatCellRadius)
                            .fill(.black.opacity(0.28 * depth))
                            .frame(width: cell, height: cell)
                            .blur(radius: 2 * depth)
                            .offset(x: depth, y: 2 * depth)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            } else {
                face
            }
        } else {
            Self.square(0, size: cell).accessibilityHidden(true)
        }
    }

    static func square(_ level: Int, size: CGFloat, emptyShade: Int = 0) -> some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
            .fill(level == 0 ? Theme.heatEmptyShades[emptyShade] : Theme.heat[min(3, level - 1)])
            .frame(width: size, height: size)
    }

    private func monthLabel(weekStart: Date, calendar: Calendar) -> String? {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        guard let startsMonth = days.first(where: {
            calendar.component(.day, from: $0) == 1 && $0 <= range.today && (position < 0 || $0 >= range.firstDay)
        }) else { return nil }
        return startsMonth.formatted(Self.englishMonth)
    }

    private func tooltip(_ date: Date, _ day: ActivityDay) -> String {
        let when = date.formatted(Self.englishMonth.day())
        return day.dictations == 0
            ? when + " · " + L10n.text("没有活动")
            : when + " · " + L10n.text("{0} 次 · {1} 字", day.dictations, day.words)
    }
}

enum HeatmapMotion {
    static let columnDelay = 0.055
    static let cellDuration = 0.825
    private static let rowDelay = columnDelay / 4

    struct Sample: Equatable {
        let scale: Double
        let cover: Double
    }

    static func finishTime(columns: Int) -> Double {
        max(0, Double(columns - 1)) * columnDelay + cellDuration
    }

    static func depth(elapsed: Double, column: Int, row: Int) -> Double {
        let delay = Double(row) * rowDelay
        let time = elapsed - Double(column) * columnDelay - delay
        let duration = cellDuration - delay
        guard time > 0, time < duration else { return 0 }
        // A staggered rise and fall makes the pulse travel down the tile faces.
        let rise = sin(.pi * time / duration)
        return rise * rise
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
