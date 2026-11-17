import SwiftUI
import AppKit

// Screenshot-matched Home insights. Only number and cell-effect views interpolate;
// animation frames do not publish through AppModel or rebuild the activity log.

private enum DashboardMotion {
    static let countDuration = 0.250
    static let columnDuration = 0.300
    static let columnStagger = 0.040

    static func heatmapDuration(weeks: Int) -> Double {
        columnDuration + Double(max(0, weeks - 1)) * columnStagger
    }
}

struct InsightsPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact = false
    @State private var countProgress: Double = 0

    static let shareText = "TypeLeast · https://typeleast.promptking.workers.dev · https://github.com/FlaxXTT/Typeleast"
    static let shareItems: [Any] = [shareText, URL(string: "https://typeleast.promptking.workers.dev")!, URL(string: "https://github.com/FlaxXTT/Typeleast")!]

    var body: some View {
        let stats = model.stats
        let timingNote = stats.hasIncompleteTiming
            ? L10n.text("旧活动仅保留字数；时间相关统计仅包含已记录时长的听写。") : nil
        let timingUnavailable = stats.dictations > 0 && !stats.hasTiming
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.text("洞察")).font(Theme.homeTitleFont).tracking(-0.6)
                    .foregroundColor(Theme.homeLabel)
                Spacer()
                ShareButton(items: Self.shareItems).frame(width: 94, height: 40)
            }
            .frame(height: 54)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                Figure(parts: Self.count(stats.words, unit: L10n.text("字")), label: L10n.text("口述字数"), progress: countProgress, compact: compact)
                Figure(parts: Self.duration(stats.savedSeconds), label: L10n.text("节省时间"), progress: countProgress, compact: compact,
                       unavailable: timingUnavailable, note: timingNote)
                Figure(parts: [InsightPart(value: Double(stats.wordsPerMinute), unit: L10n.text("每分钟字数"))], label: L10n.text("平均口述速度"), progress: countProgress, compact: compact,
                       unavailable: timingUnavailable, note: timingNote)
                Figure(parts: Self.duration(stats.speakingSeconds), label: L10n.text("总口述时间"), progress: countProgress, compact: compact,
                       unavailable: timingUnavailable, note: timingNote)
            }
            ActivityCard(countProgress: countProgress, compact: compact)
        }
        .onChange(of: model.homePresentationID, initial: true) { _, _ in replay() }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { countProgress = 1 }
            }
        }
    }

    private func replay() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            countProgress = reduceMotion ? 1 : 0
        }
        guard !reduceMotion else { return }
        DispatchQueue.main.async {
            guard !reduceMotion else { return }
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: DashboardMotion.countDuration)) { countProgress = 1 }
        }
    }

    /// The reference uses K in both languages. Units stay fixed during count-up.
    static func count(_ value: Int, unit: String) -> [InsightPart] {
        if value >= 1000 { return [InsightPart(value: Double(value) / 1000, unit: unit, decimals: 1, numberSuffix: "K")] }
        return [InsightPart(value: Double(value), unit: unit)]
    }

    static func duration(_ seconds: Double) -> [InsightPart] {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return [InsightPart(value: Double(total), unit: L10n.text("秒"))] }
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours == 0 { return [InsightPart(value: Double(minutes), unit: L10n.text("分钟"))] }
        return [InsightPart(value: Double(hours), unit: L10n.text("小时")), InsightPart(value: Double(minutes), unit: L10n.text("分钟"))]
    }
}

struct InsightPart {
    let value: Double
    let unit: String
    var decimals = 0
    var numberSuffix = ""

    func string(at progress: Double) -> String {
        let value = value * min(1, max(0, progress))
        if decimals == 1 { return String(format: "%.1f", locale: L10n.locale, value) + numberSuffix }
        return Formatters.number(Int(value.rounded(.down))) + numberSuffix
    }
}

private struct CountingNumber: View, Animatable {
    let part: InsightPart
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        // Reserve final width so a changing digit count cannot move its unit or label.
        Text(part.string(at: 1)).hidden()
            .overlay(alignment: .leading) {
                Text(part.string(at: progress)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(part.string(at: 1))
    }
}

/// One white tile: a large number with its small unit, the label below.
private struct Figure: View {
    let parts: [InsightPart]
    let label: String
    let progress: Double
    let compact: Bool
    var unavailable = false
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if unavailable {
                    Text("—").font(.system(size: compact ? 26 : 32, weight: .bold))
                        .accessibilityLabel(L10n.text("尚无时长记录"))
                } else {
                    ForEach(parts.indices, id: \.self) { index in
                        CountingNumber(part: parts[index], progress: progress)
                            .font(.system(size: compact ? 26 : 32, weight: .bold)).tracking(-0.8)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(parts[index].unit).font(.system(size: compact ? 11 : 14, weight: .semibold))
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
            .font(.system(size: compact ? 13 : 16)).foregroundColor(Theme.homeLabel)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.homeCardRadius, style: .circular).fill(Theme.tile))
        .help(note ?? label)
    }
}

/// A faint grid of dots behind the insights.
struct HomeDotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 11
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.opacity = 0.5 + 0.5 * (1 - x / max(1, size.width))
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3)), with: .color(Theme.homeDot))
                    x += step
                }
                y += step
            }
        }
        .background {
            LinearGradient(colors: [Theme.homeBackdrop, Theme.window], startPoint: .bottomLeading, endPoint: .topTrailing)
                .overlay(LinearGradient(colors: [.clear, Theme.window.opacity(0.3)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// 分享: the system share menu with the website and GitHub links.
struct ShareButton: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = HoverShareButton(title: " " + L10n.text("分享"), image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.isBordered = false
        button.font = .systemFont(ofSize: 16, weight: .medium)
        button.image = button.image?.withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        button.wantsLayer = true
        button.layer?.cornerRadius = 20 // 40-point capsule
        button.layer?.borderWidth = 0.5
        button.updateSurface()
        button.controlSize = .regular
        button.toolTip = L10n.text("分享官网和 GitHub 链接")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.items = items
        (nsView as? HoverShareButton)?.updateSurface()
    }
    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: [Any]
        init(items: [Any]) { self.items = items }
        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: items).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

private final class HoverShareButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    private var hovering = false
    override var intrinsicContentSize: NSSize { NSSize(width: 94, height: 40) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovering: Bool) {
        self.hovering = hovering
        updateSurface()
    }

    func updateSurface() {
        contentTintColor = NSColor(Theme.ink)
        layer?.backgroundColor = NSColor(hovering ? Theme.cardHover : Theme.tile).cgColor
        layer?.borderColor = NSColor(Theme.border).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // A borderless NSButton otherwise places its image against the leading edge.
        // Centre the icon and title as one group inside the 94×40 capsule.
        let ink = NSColor(Theme.ink)
        let label = NSAttributedString(string: title.trimmingCharacters(in: .whitespaces),
                                       attributes: [.font: font ?? .systemFont(ofSize: 16, weight: .medium),
                                                    .foregroundColor: ink])
        let labelSize = label.size()
        let iconSize: CGFloat = 18
        let gap: CGFloat = 8
        let x = bounds.midX - (iconSize + gap + labelSize.width) / 2
        let icon = image?.withSymbolConfiguration(.init(paletteColors: [ink]))
        icon?.draw(in: NSRect(x: x, y: bounds.midY - iconSize / 2,
                             width: iconSize, height: iconSize),
                   from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.6 : 1,
                   respectFlipped: true, hints: nil)
        label.draw(at: NSPoint(x: x + iconSize + gap, y: bounds.midY - labelSize.height / 2))
    }
}

/// Active days and streaks above the heatmap: weekdays down the side, months along the bottom.
struct ActivityCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var countProgress: Double = 1
    var compact = false
    @State private var weekOffset = 0
    @State private var heatmapElapsed: Double = 0

    private let cell: CGFloat = 16
    private let gap: CGFloat = 8
    private let dayColumn: CGFloat = 32

    var body: some View {
        let log = ActivityLog.shared
        let streaks = log.streaks()
        let _ = model.activityRevision   // redraw when a dictation is recorded
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 0) {
                figure(log.activeDays, L10n.text("活跃天数"))
                figure(streaks.current, L10n.text("当前连续天数"))
                figure(streaks.longest, L10n.text("最长连续天数"))
            }
            GeometryReader { geo in
                let weeks = max(6, min(53, Int((geo.size.width - dayColumn - 18 + gap) / (cell + gap))))
                grid(weeks: weeks, log: log)
                    .task(id: [model.homePresentationID, weeks, reduceMotion ? 1 : 0]) {
                        let duration = DashboardMotion.heatmapDuration(weeks: weeks)
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { heatmapElapsed = reduceMotion ? duration : 0 }
                        guard !reduceMotion else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(.linear(duration: duration)) { heatmapElapsed = duration }
                    }
            }
            .frame(height: 7 * (cell + gap) + 20)
            HStack(spacing: 6) {
                Text(L10n.text("更少")).font(.system(size: 14)).foregroundColor(Theme.homeLabel)
                ForEach(1..<5) { level in square(level) }
                Text(L10n.text("更多")).font(.system(size: 14)).foregroundColor(Theme.homeLabel)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.homeCardRadius, style: .circular).fill(Theme.tile))
        .onChange(of: model.homePresentationID) { _, _ in weekOffset = 0 }
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountingNumber(part: InsightPart(value: Double(value), unit: L10n.text("天")), progress: countProgress)
                    .font(.system(size: compact ? 26 : 32, weight: .bold)).tracking(-0.8)
                Text(L10n.text("天")).font(.system(size: 14, weight: .semibold))
            }
            Text(label).font(Theme.captionFont).foregroundColor(Theme.homeLabel)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(weeks: Int, log: ActivityLog) -> some View {
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
                .offset(x: 24, y: CGFloat(row) * step)
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
                            square(0)
                                .overlay {
                                    square(level).modifier(HeatmapColumnReveal(elapsed: heatmapElapsed, column: column))
                                }
                                .help(tooltip(date, day)).accessibilityLabel(tooltip(date, day))
                        } else {
                            RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
                                .stroke(Theme.border, lineWidth: 1).frame(width: cell, height: cell)
                                .modifier(HeatmapColumnReveal(elapsed: heatmapElapsed, column: column))
                        }
                    }
                    .offset(x: x, y: CGFloat(row) * step)
                }
                if let label = monthLabel(weekStart: weekStart, calendar: calendar, first: column == 0) {
                    Text(label).font(.system(size: 11)).foregroundColor(Theme.homeLabel)
                        .fixedSize()
                        .offset(x: x - (column == weeks - 1 ? 8 : 0), y: 7 * step + 2)
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

    private func square(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
            .fill(level == 0 ? Theme.heatEmpty : Theme.heat[min(3, level - 1)])
            .frame(width: cell, height: cell)
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

/// One shared timeline drives every column; cells in the same week stay in phase.
private struct HeatmapColumnReveal: AnimatableModifier {
    var elapsed: Double
    let column: Int
    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    func body(content: Content) -> some View {
        let start = Double(column) * DashboardMotion.columnStagger
        let fraction = min(1, max(0, (elapsed - start) / DashboardMotion.columnDuration))
        let pulse = fraction < 0.45
            ? 1 - pow(1 - fraction / 0.45, 3)
            : pow((1 - fraction) / 0.55, 2)
        let visible = fraction > 0 ? 1.0 : 0.0
        content
            .opacity(visible)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.heatCellRadius, style: .circular)
                    .fill(Color.white)
                    .opacity(visible * pow(1 - fraction, 2))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .scaleEffect(1 + 0.2 * pulse)
    }
}
