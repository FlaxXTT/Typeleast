import SwiftUI
import AppKit

// ActivityCard.swift - the Home insights: four figures (字数, 节省时间, 速度, 口述时间), then
// active days and streaks above a heatmap (one square per day, a column per week), on a
// lightly dotted panel. ShareButton (on the Home hero) shares the website and GitHub links.

struct InsightsPanel: View {
    @EnvironmentObject var model: AppModel

    static let shareText = "TypeLeast · https://typeleast.promptking.workers.dev · https://github.com/FlaxXTT/Typeleast"
    static let shareItems: [Any] = [shareText, URL(string: "https://typeleast.promptking.workers.dev")!, URL(string: "https://github.com/FlaxXTT/Typeleast")!]

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                Figure(parts: InsightsPanel.count(stats.words, unit: L10n.text("字")), label: L10n.text("口述字数"))
                Figure(parts: InsightsPanel.duration(stats.savedSeconds), label: L10n.text("节省时间"))
                Figure(parts: [(Formatters.number(stats.wordsPerMinute), L10n.text("每分钟字数"))], label: L10n.text("平均口述速度"))
                Figure(parts: InsightsPanel.duration(stats.speakingSeconds), label: L10n.text("总口述时间"))
            }
            ActivityCard()
        }
        .padding(16)
        .background(DotGrid().clipShape(RoundedRectangle(cornerRadius: Theme.radius + 4, style: .continuous)))
    }

    /// 34.9K 字 / 3.5万 字: large counts are shortened.
    static func count(_ value: Int, unit: String) -> [(String, String)] {
        if value >= 10_000 {
            if L10n.language == "en" { return [(String(format: "%.1fK", locale: L10n.locale, Double(value) / 1000), unit)] }
            return [(String(format: "%.1f", locale: L10n.locale, Double(value) / 10_000), L10n.text("万") + unit)]
        }
        return [(Formatters.number(value), unit)]
    }

    /// 17 小时 47 分钟, 12 分钟, 40 秒.
    static func duration(_ seconds: Double) -> [(String, String)] {
        let total = Int(seconds.rounded())
        if total < 60 { return [(String(total), L10n.text("秒"))] }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours == 0 ? [(String(minutes), L10n.text("分钟"))] : [(String(hours), L10n.text("小时")), (String(minutes), L10n.text("分钟"))]
    }
}

/// One white tile: a large number with its small unit, the label below.
private struct Figure: View {
    let parts: [(String, String)]
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(parts.indices, id: \.self) { index in
                    Text(parts[index].0).font(.system(size: 30, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(parts[index].1).font(.system(size: 13, weight: .semibold)).padding(.trailing, 4)
                }
            }
            Text(label).font(.system(size: 13)).foregroundColor(Theme.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius + 2, style: .continuous).fill(Theme.tile))
    }
}

/// A faint grid of dots behind the insights.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 12
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(Theme.dot))
                    x += step
                }
                y += step
            }
        }
        .background(Theme.panel)
    }
}

/// 分享: the system share menu with the website and GitHub links.
struct ShareButton: NSViewRepresentable {
    let items: [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: " " + L10n.text("分享"), image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.toolTip = L10n.text("分享官网和 GitHub 链接")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) { context.coordinator.items = items }
    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: [Any]
        init(items: [Any]) { self.items = items }
        @objc func share(_ sender: NSButton) {
            NSSharingServicePicker(items: items).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

/// Active days and streaks above the heatmap: weekdays down the side, months along the bottom.
struct ActivityCard: View {
    @EnvironmentObject var model: AppModel

    private let cell: CGFloat = 18
    private let gap: CGFloat = 6
    private let dayColumn: CGFloat = 22

    var body: some View {
        let log = ActivityLog.shared
        let streaks = log.streaks()
        let _ = model.activityRevision   // redraw when a dictation is recorded
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 0) {
                figure(log.activeDays, L10n.text("活跃天数"))
                figure(streaks.current, L10n.text("当前连续天数"))
                figure(streaks.longest, L10n.text("最长连续天数"))
            }
            GeometryReader { geo in
                let weeks = max(8, min(53, Int((geo.size.width - dayColumn + gap) / (cell + gap))))
                grid(weeks: weeks, log: log)
            }
            .frame(height: 7 * (cell + gap) + 18)
            HStack(spacing: 6) {
                Text(L10n.text("更少")).font(.system(size: 12)).foregroundColor(Theme.secondary)
                ForEach(1..<5) { level in square(level) }
                Text(L10n.text("更多")).font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius + 2, style: .continuous).fill(Theme.tile))
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Formatters.number(value)).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(L10n.text("天")).font(.system(size: 13, weight: .semibold))
            }
            Text(label).font(.system(size: 13)).foregroundColor(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(weeks: Int, log: ActivityLog) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek) ?? thisWeek
        let step = cell + gap
        var symbols = calendar.veryShortStandaloneWeekdaySymbols
        if L10n.language != "en" {
            var zh = Calendar(identifier: .gregorian); zh.locale = Locale(identifier: "zh-Hans")
            symbols = zh.veryShortStandaloneWeekdaySymbols
        }
        let shift = calendar.firstWeekday - 1
        let weekdays = Array(symbols[shift...] + symbols[..<shift])
        return ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { row in
                Text(weekdays[row]).font(.system(size: 11)).foregroundColor(Theme.secondary)
                    .frame(width: dayColumn - 6, height: cell)
                    .offset(x: 0, y: CGFloat(row) * step)
            }
            ForEach(0..<weeks, id: \.self) { column in
                let weekStart = calendar.date(byAdding: .day, value: 7 * column, to: first) ?? first
                let x = dayColumn + CGFloat(column) * step
                ForEach(0..<7, id: \.self) { row in
                    let date = calendar.date(byAdding: .day, value: row, to: weekStart) ?? weekStart
                    Group {
                        if date <= today {
                            let day = log.day(date)
                            square(ActivityLog.level(day.dictations)).help(tooltip(date, day))
                        } else {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1).frame(width: cell, height: cell)
                        }
                    }
                    .offset(x: x, y: CGFloat(row) * step)
                }
                if let label = monthLabel(weekStart: weekStart, calendar: calendar) {
                    Text(label).font(.system(size: 11)).foregroundColor(Theme.secondary)
                        .fixedSize()
                        .offset(x: x, y: 7 * step + 2)
                }
            }
        }
    }

    private func square(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(level == 0 ? Theme.heatEmpty : Theme.heat[min(3, level - 1)])
            .frame(width: cell, height: cell)
    }

    /// The month's name under the week that contains its 1st.
    private func monthLabel(weekStart: Date, calendar: Calendar) -> String? {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        guard let startsMonth = days.first(where: { calendar.component(.day, from: $0) == 1 }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: startsMonth)
    }

    private func tooltip(_ date: Date, _ day: ActivityDay) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let when = formatter.string(from: date)
        return day.dictations == 0
            ? when + " · " + L10n.text("没有活动")
            : when + " · " + L10n.text("{0} 次 · {1} 字", day.dictations, day.words)
    }
}
