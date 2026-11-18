import SwiftUI
import AppKit
import QuartzCore

/// A single elapsed-time animation drives the readouts and the activity grid.
private enum DashboardMotion {
    static let countDuration = 0.250
    static let duration = 0.380

    static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

struct InsightsPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var elapsed: Double = 0

    static let shareText = "TypeLeast · https://typeleast.promptking.workers.dev · https://github.com/FlaxXTT/Typeleast"
    static let shareItems: [Any] = [shareText, URL(string: "https://typeleast.promptking.workers.dev")!, URL(string: "https://github.com/FlaxXTT/Typeleast")!]

    var body: some View {
        let stats = model.stats
        let time = reduceMotion ? DashboardMotion.duration : model.homePresentationSuspended ? 0 : elapsed
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
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    ShareButton(items: Self.shareItems).frame(width: 94, height: 40)
                }
                .frame(height: headerHeight)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: tileGap), GridItem(.flexible())], spacing: tileGap) {
                    Figure(parts: Self.count(stats.words), label: "Words dictated", elapsed: time, height: tileHeight)
                    Figure(parts: Self.duration(stats.savedSeconds), label: "Time saved", elapsed: time, height: tileHeight)
                    Figure(parts: [InsightPart(value: Double(stats.wordsPerMinute), unit: "chars/min")],
                           label: "Average speed", elapsed: time, height: tileHeight)
                    Figure(parts: Self.duration(stats.speakingSeconds), label: "Total dictation time", elapsed: time, height: tileHeight)
                }
                ActivityCard(elapsed: time).frame(height: activityHeight)
            }
        }
        .onAppear {
            if reduceMotion {
                elapsed = DashboardMotion.duration
                return
            }
            guard !model.homePresentationSuspended, elapsed == 0 else { return }
            withAnimation(.linear(duration: DashboardMotion.duration)) {
                elapsed = DashboardMotion.duration
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { elapsed = DashboardMotion.duration }
        }
    }

    private static func count(_ value: Int) -> [InsightPart] {
        if value >= 1000 { return [InsightPart(value: Double(value) / 1000, unit: "chars", format: .thousands)] }
        return [InsightPart(value: Double(value), unit: "chars")]
    }

    private static func duration(_ seconds: Double) -> [InsightPart] {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return [InsightPart(value: Double(total), unit: "s")] }
        let minutes = total / 60
        if minutes < 60 { return [InsightPart(value: Double(minutes), unit: "min")] }
        return [InsightPart(value: Double(minutes / 60), unit: "h"),
                InsightPart(value: Double(minutes % 60), unit: "min")]
    }
}

private struct InsightPart {
    enum Format { case whole, thousands }
    private static let englishLocale = Locale(identifier: "en_US")
    let value: Double
    let unit: String
    var format: Format = .whole

    var suffix: String { format == .thousands ? "k" : "" }

    func digits(at progress: Double, language: String?) -> String {
        let scaled = value * progress
        switch format {
        case .whole: return L10n.formattedNumber(NSNumber(value: Int(scaled)), language: language)
        case .thousands: return String(format: "%.1f", locale: Self.englishLocale, scaled)
        }
    }
}

private struct CountingNumber: View, Animatable {
    let part: InsightPart
    var elapsed: Double
    let font: Font
    var language: String? = nil
    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        let progress = DashboardMotion.ease(elapsed / DashboardMotion.countDuration)
        number(at: 1).hidden()
            .overlay(alignment: .trailing) {
                number(at: progress)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .font(font)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(part.digits(at: 1, language: language) + part.suffix)
    }

    private func number(at progress: Double) -> Text {
        let digits = Text(verbatim: part.digits(at: progress, language: language))
        guard !part.suffix.isEmpty else { return digits }
        let suffix = Text(verbatim: part.suffix).font(.system(size: 21, weight: .medium, design: .serif))
        return Text("\(digits)\(suffix)")
    }
}

/// One metric tile with a large figure, a smaller unit and a label.
private struct Figure: View {
    private static let numberFont = Font.system(size: 32, weight: .medium, design: .serif).monospacedDigit()
    let parts: [InsightPart]
    let label: String
    let elapsed: Double
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                ForEach(parts.indices, id: \.self) { index in
                    let part = parts[index]
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        CountingNumber(part: part, elapsed: elapsed, font: Self.numberFont, language: "en")
                            .tracking(-0.9)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(verbatim: part.unit)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink.opacity(0.8))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
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

/// Active days and streaks above the heatmap: weekdays down the side, months along the bottom.
struct ActivityCard: View {
    @EnvironmentObject var model: AppModel
    let elapsed: Double
    @State private var weekOffset = 0

    private let minimumCell: CGFloat = 16.5
    private let columnGap: CGFloat = 3
    private let dayColumn: CGFloat = 24
    private let navigationHeight: CGFloat = 18
    private let navigationGap: CGFloat = 6

    var body: some View {
        let log = ActivityLog.shared
        let streaks = log.streaks()
        let _ = model.activityRevision   // redraw when a dictation is recorded
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                figure(log.activeDays, L10n.text("活跃天数"))
                figure(streaks.current, L10n.text("当前连续天数"))
                figure(streaks.longest, L10n.text("最长连续天数"))
            }
            .padding(.horizontal, 7)
            GeometryReader { geo in
                let width = max(minimumCell, geo.size.width - dayColumn)
                let weeks = max(1, min(20, Int((width + columnGap) / (minimumCell + columnGap))))
                let cell = (width - CGFloat(weeks - 1) * columnGap) / CGFloat(weeks)
                let gridWidth = dayColumn + width
                let rowStep = max(cell + 2, (geo.size.height - cell - navigationHeight - navigationGap) / 6)
                grid(weeks: weeks, width: gridWidth, cell: cell, rowStep: rowStep, log: log)
                    .frame(width: gridWidth)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 12)
            HStack(spacing: 6) {
                square(active: false, size: 13)
                Text(L10n.text("没有活动")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                square(active: true, size: 13).padding(.leading, 4)
                Text(L10n.text("有活动")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
            }
            .padding(.horizontal, 7)
            .padding(.top, 8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.homeActivityRadius, style: .circular).fill(Theme.tile))
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountingNumber(part: InsightPart(value: Double(value), unit: L10n.text("天")),
                               elapsed: elapsed, font: InterfaceTypography.figure(Theme.homeFigureSize))
                    .tracking(-0.6)
                InterfaceTypography.text(L10n.text("天"), size: Theme.homeSecondarySize, weight: .semibold)
            }
            InterfaceTypography.text(label, size: Theme.homeSecondarySize)
                .foregroundColor(Theme.homeLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(weeks: Int, width: CGFloat, cell: CGFloat, rowStep: CGFloat, log: ActivityLog) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        calendar.firstWeekday = 1
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .day, value: 7 * (weekOffset - weeks + 1), to: thisWeek) ?? thisWeek
        let earliest = log.days.keys.min().flatMap { ActivityLog.parse($0, calendar: calendar) }
        let hatchWidth: CGFloat = 7
        let columnStep = cell + columnGap
        let navigationY = 6 * rowStep + cell + navigationGap
        let weekdays = ["S", "M", "T", "W", "T", "F", "S"]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { row in
                Text(weekdays[row]).font(InterfaceTypography.localized(11)).foregroundColor(Theme.homeLabel)
                    .frame(width: 14, height: cell)
                    .offset(y: CGFloat(row) * rowStep)
                // A hatched leading edge marks the cropped range, not extra usage data.
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
            ForEach(0..<weeks, id: \.self) { column in
                let weekStart = calendar.date(byAdding: .day, value: 7 * column, to: first) ?? first
                let x = dayColumn + CGFloat(column) * columnStep
                ForEach(0..<7, id: \.self) { row in
                    let date = calendar.date(byAdding: .day, value: row, to: weekStart) ?? weekStart
                    Group {
                        if date <= today {
                            let day = log.day(date)
                            let active = day.dictations > 0
                            let description = tooltip(date, day)
                            if active && weekOffset == 0 {
                                square(active: false, size: cell).overlay {
                                    square(active: true, size: cell).modifier(HeatmapReveal(elapsed: elapsed))
                                }
                                .help(description).accessibilityLabel(description)
                            } else {
                                square(active: active, size: cell).help(description).accessibilityLabel(description)
                            }
                        } else {
                            outlinedCell(size: cell).accessibilityHidden(true)
                        }
                    }
                    .offset(x: x, y: CGFloat(row) * rowStep)
                }
                if let label = monthLabel(weekStart: weekStart, calendar: calendar, first: column == 0) {
                    InterfaceTypography.text(label, size: 11).foregroundColor(Theme.homeLabel)
                        .fixedSize()
                        .offset(x: max(dayColumn, min(x, width - 56)), y: navigationY + 2)
                }
            }
            HStack {
                Button { weekOffset -= weeks } label: {
                    Image(systemName: "chevron.left").frame(width: navigationHeight, height: navigationHeight)
                }
                    .disabled(earliest.map { first <= $0 } ?? true)
                    .help(L10n.text("较早的活动"))
                Spacer()
                Button { weekOffset = min(0, weekOffset + weeks) } label: {
                    Image(systemName: "chevron.right").frame(width: navigationHeight, height: navigationHeight)
                }
                    .disabled(weekOffset >= 0)
                    .help(L10n.text("较新的活动"))
            }
            .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.homeLabel).buttonStyle(.plain)
            .offset(y: navigationY)
        }
    }

    private func outlinedCell(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1)
            .frame(width: size, height: size)
    }

    private func square(active: Bool, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
            .fill(active ? Theme.heatActive : Theme.heatEmpty)
            .frame(width: size, height: size)
    }

    /// The month's name under the week that contains its 1st.
    private func monthLabel(weekStart: Date, calendar: Calendar, first: Bool) -> String? {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let monthStart = days.first(where: { calendar.component(.day, from: $0) == 1 })
        guard let startsMonth = monthStart ?? (first ? weekStart : nil) else { return nil }
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

/// Every active cell reveals at the same rate, without a size or brightness pulse.
private struct HeatmapReveal: AnimatableModifier {
    var elapsed: Double
    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    func body(content: Content) -> some View {
        let time = min(1, max(0, elapsed / DashboardMotion.duration))
        content.opacity(1 - pow(1 - time, 3))
    }
}
