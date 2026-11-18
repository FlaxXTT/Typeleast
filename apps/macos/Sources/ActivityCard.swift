import SwiftUI
import AppKit
import QuartzCore

/// A single elapsed-time animation drives the readouts and week columns.
private enum DashboardMotion {
    static let countDuration = 0.460
    static let gridDelay = 0.260
    static let columnDuration = 0.300
    static let columnStagger = 0.052
    static let maximumWave = 0.950
    static let duration = gridDelay + maximumWave + columnDuration

    static func columnStart(_ column: Int, weeks: Int) -> Double {
        gridDelay + Double(column) * min(columnStagger, maximumWave / Double(max(1, weeks - 1)))
    }

    static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

struct InsightsPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false
    @State private var elapsed: Double = 0

    static let shareText = "TypeLeast · https://typeleast.promptking.workers.dev · https://github.com/FlaxXTT/Typeleast"
    static let shareItems: [Any] = [shareText, URL(string: "https://typeleast.promptking.workers.dev")!, URL(string: "https://github.com/FlaxXTT/Typeleast")!]

    var body: some View {
        let stats = model.stats
        let timingNote = stats.hasIncompleteTiming
            ? L10n.text("旧活动仅保留字数；时间相关统计仅包含已记录时长的听写。") : nil
        let timingUnavailable = stats.dictations > 0 && !stats.hasTiming
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                InitialHeading(title: "Insight", initialSize: 50, bodySize: 29)
                    .foregroundColor(Theme.homeLabel)
                Spacer()
                ShareButton(items: Self.shareItems).frame(width: 94, height: 40)
            }
            .frame(height: 52)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 16) {
                Figure(parts: Self.count(stats.words, unit: L10n.text("字")), label: L10n.text("口述字数"), elapsed: displayedElapsed, compact: compact)
                Figure(parts: Self.duration(stats.savedSeconds), label: L10n.text("节省时间"), elapsed: displayedElapsed, compact: compact,
                       unavailable: timingUnavailable, note: timingNote)
                Figure(parts: [InsightPart(value: Double(stats.wordsPerMinute), unit: L10n.text("每分钟字数"))], label: L10n.text("平均口述速度"), elapsed: displayedElapsed, compact: compact,
                       unavailable: timingUnavailable, note: timingNote)
                Figure(parts: Self.duration(stats.speakingSeconds), label: L10n.text("总口述时间"), elapsed: displayedElapsed, compact: compact,
                       unavailable: timingUnavailable, note: timingNote)
            }
            ActivityCard(elapsed: displayedElapsed, compact: compact)
        }
        .task(id: reduceMotion) {
            if reduceMotion {
                elapsed = DashboardMotion.duration
                return
            }
            // Leave time for the initial zero values and outlined grid to render.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, elapsed == 0 else { return }
            withAnimation(.linear(duration: DashboardMotion.duration)) {
                elapsed = DashboardMotion.duration
            }
        }
    }

    private var displayedElapsed: Double {
        reduceMotion ? DashboardMotion.duration : elapsed
    }

    /// The reference uses K in both languages. Units stay fixed during count-up.
    private static func count(_ value: Int, unit: String) -> [InsightPart] {
        if value >= 1000 { return [InsightPart(value: Double(value) / 1000, unit: unit, format: .thousands)] }
        return [InsightPart(value: Double(value), unit: unit)]
    }

    private static func duration(_ seconds: Double) -> [InsightPart] {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return [InsightPart(value: Double(total), unit: L10n.text("秒"))] }
        let value = Double(total)
        if total < 3600 { return [InsightPart(value: value, unit: L10n.text("分钟"), format: .minutes)] }
        return [InsightPart(value: value, unit: L10n.text("小时"), format: .hours),
                InsightPart(value: value, unit: L10n.text("分钟"), format: .minuteRemainder)]
    }
}

private struct InsightPart {
    enum Format { case whole, thousands, hours, minutes, minuteRemainder }
    let value: Double
    let unit: String
    var format: Format = .whole

    var widthSample: String {
        format == .minuteRemainder ? Formatters.number(59) : string(at: 1)
    }

    func string(at progress: Double) -> String {
        let scaled = value * progress
        switch format {
        case .whole: return Formatters.number(Int(scaled))
        case .thousands: return String(format: "%.1f", locale: L10n.locale, scaled) + "K"
        case .hours: return Formatters.number(Int(scaled) / 3600)
        case .minutes: return Formatters.number(Int(scaled) / 60)
        case .minuteRemainder: return Formatters.number((Int(scaled) / 60) % 60)
        }
    }
}

private struct CountingNumber: View, Animatable {
    let part: InsightPart
    var elapsed: Double
    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        let progress = DashboardMotion.ease(elapsed / DashboardMotion.countDuration)
        Text(part.widthSample).hidden()
            .overlay(alignment: .trailing) {
                Text(part.string(at: progress)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(part.string(at: 1))
    }
}

/// One metric tile with a large figure, a smaller unit and a label.
private struct Figure: View {
    let parts: [InsightPart]
    let label: String
    let elapsed: Double
    let compact: Bool
    var unavailable = false
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if unavailable {
                    Text("—").font(.system(size: compact ? 23 : 26, weight: .bold))
                        .accessibilityLabel(L10n.text("尚无时长记录"))
                } else {
                    ForEach(parts.indices, id: \.self) { index in
                        CountingNumber(part: parts[index], elapsed: elapsed)
                            .font(.system(size: compact ? 23 : 26, weight: .bold)).tracking(-0.6)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(parts[index].unit).font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8).padding(.trailing, 2)
                    }
                }
            }
            HStack(spacing: 5) {
                Text(label)
                if let note {
                    Image(systemName: "info.circle").font(.system(size: 11))
                        .help(note).accessibilityLabel(note)
                }
            }
            .font(Theme.rowFont).foregroundColor(Theme.homeLabel)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.homeMetricRadius, style: .circular).fill(Theme.tile))
        .help(note ?? label)
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

/// 分享: the system share menu with the website and GitHub links.
struct ShareButton: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> HoverShareButton {
        let button = HoverShareButton(title: L10n.text("分享"), image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.font = .systemFont(ofSize: 16, weight: .medium)
        button.image = button.image?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        button.wantsLayer = true
        button.controlSize = .regular
        button.toolTip = L10n.text("分享官网和 GitHub 链接")
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
                                       attributes: [.font: font ?? .systemFont(ofSize: 16, weight: .medium),
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
    var compact = false
    @State private var weekOffset = 0

    private let cell: CGFloat = 14
    private let gap: CGFloat = 8
    private let dayColumn: CGFloat = 30

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
            GeometryReader { geo in
                let width = max(cell, geo.size.width - dayColumn)
                let weeks = max(1, min(20, Int((width + gap) / (cell + gap))))
                let gridWidth = dayColumn + CGFloat(weeks) * (cell + gap) - gap
                grid(weeks: weeks, width: gridWidth, log: log)
                    .frame(width: gridWidth)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 7 * (cell + gap) + 18)
            .padding(.top, 18)
            HStack(spacing: 6) {
                Text(L10n.text("更少")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                ForEach(1..<5) { level in square(level, size: 12) }
                Text(L10n.text("更多")).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.homeActivityRadius, style: .circular).fill(Theme.tile))
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountingNumber(part: InsightPart(value: Double(value), unit: L10n.text("天")), elapsed: elapsed)
                    .font(.system(size: compact ? 23 : 26, weight: .bold)).tracking(-0.6)
                Text(L10n.text("天")).font(.system(size: 12, weight: .semibold))
            }
            Text(label).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(weeks: Int, width: CGFloat, log: ActivityLog) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        calendar.firstWeekday = 1
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .day, value: 7 * (weekOffset - weeks + 1), to: thisWeek) ?? thisWeek
        let earliest = log.days.keys.min().flatMap { ActivityLog.parse($0, calendar: calendar) }
        let step = cell + gap
        let weekdays = ["S", "M", "T", "W", "T", "F", "S"]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { row in
                Text(weekdays[row]).font(.system(size: 11)).foregroundColor(Theme.homeLabel)
                    .frame(width: 16, height: cell)
                    .offset(x: 0, y: CGFloat(row) * step)
                // A hatched leading edge marks the cropped range, not extra usage data.
                Path { path in
                    for y in stride(from: -cell, through: cell, by: 5) {
                        path.move(to: CGPoint(x: 0, y: y + 10))
                        path.addLine(to: CGPoint(x: 10, y: y))
                    }
                }
                .stroke(Theme.border.opacity(0.6), lineWidth: 1)
                .frame(width: 10, height: cell).clipped()
                .offset(x: 19, y: CGFloat(row) * step)
                .accessibilityHidden(true)
            }
            ForEach(0..<weeks, id: \.self) { column in
                let weekStart = calendar.date(byAdding: .day, value: 7 * column, to: first) ?? first
                let x = dayColumn + CGFloat(column) * step
                ForEach(0..<7, id: \.self) { row in
                    let date = calendar.date(byAdding: .day, value: row, to: weekStart) ?? weekStart
                    Group {
                        if date <= today {
                            let day = log.day(date)
                            let level = ActivityLog.level(day.dictations)
                            let description = tooltip(date, day)
                            if weekOffset == 0 {
                                outlinedCell.overlay {
                                    square(level).modifier(HeatmapColumnReveal(
                                        elapsed: elapsed, start: DashboardMotion.columnStart(column, weeks: weeks)))
                                }
                                .help(description).accessibilityLabel(description)
                            } else {
                                square(level).help(description).accessibilityLabel(description)
                            }
                        } else {
                            outlinedCell.accessibilityHidden(true)
                        }
                    }
                    .offset(x: x, y: CGFloat(row) * step)
                }
                if let label = monthLabel(weekStart: weekStart, calendar: calendar, first: column == 0) {
                    Text(label).font(.system(size: 11)).foregroundColor(Theme.homeLabel)
                        .fixedSize()
                        .offset(x: max(dayColumn, min(x, width - 56)), y: 7 * step + 2)
                }
            }
            HStack {
                Button { weekOffset -= weeks } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                    .disabled(earliest.map { first <= $0 } ?? true)
                    .help(L10n.text("较早的活动"))
                Spacer()
                Button { weekOffset = min(0, weekOffset + weeks) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                    .disabled(weekOffset >= 0)
                    .help(L10n.text("较新的活动"))
            }
            .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.homeLabel).buttonStyle(.plain)
            .offset(y: 7 * step)
        }
    }

    private var outlinedCell: some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1)
            .frame(width: cell, height: cell)
    }

    private func square(_ level: Int, size: CGFloat = 14) -> some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
            .fill(level == 0 ? Theme.heatEmpty : Theme.heat[min(3, level - 1)])
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

/// The slot stays fixed; only the fill fades and settles within it.
private struct HeatmapColumnReveal: AnimatableModifier {
    var elapsed: Double
    let start: Double
    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    func body(content: Content) -> some View {
        let progress = DashboardMotion.ease((elapsed - start) / DashboardMotion.columnDuration)
        content
            .opacity(progress)
            .scaleEffect(0.94 + 0.06 * progress + 0.07 * sin(.pi * progress))
    }
}
