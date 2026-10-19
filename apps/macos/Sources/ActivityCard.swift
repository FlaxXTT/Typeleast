import SwiftUI

// ActivityCard.swift - the Home heatmap (活动): one square per day, a column per week,
// darker for busier days, plus active days and the current and longest streaks.

struct ActivityCard: View {
    @EnvironmentObject var model: AppModel

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private let monthRow: CGFloat = 16

    var body: some View {
        let log = ActivityLog.shared
        let streaks = log.streaks()
        let _ = model.activityRevision   // redraw when a dictation is recorded
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("活动")).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    figure(log.activeDays, L10n.text("活跃天数"))
                    figure(streaks.current, L10n.text("当前连续"))
                    figure(streaks.longest, L10n.text("最长连续"))
                }
                GeometryReader { geo in
                    let weeks = max(8, min(53, Int((geo.size.width + gap) / (cell + gap))))
                    grid(weeks: weeks, log: log)
                }
                .frame(height: monthRow + 7 * (cell + gap))
                HStack(spacing: 4) {
                    Spacer()
                    Text(L10n.text("更少")).font(.system(size: 10.5)).foregroundColor(Theme.tertiary)
                    ForEach(0..<5) { level in square(level) }
                    Text(L10n.text("更多")).font(.system(size: 10.5)).foregroundColor(Theme.tertiary)
                }
            }
        }
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
            Text(Formatters.number(value)).font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(L10n.text("天")).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
        }
        .padding(.leading, 12)
    }

    private func grid(weeks: Int, log: ActivityLog) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek) ?? thisWeek
        let step = cell + gap
        return ZStack(alignment: .topLeading) {
            ForEach(0..<weeks, id: \.self) { column in
                let weekStart = calendar.date(byAdding: .day, value: 7 * column, to: first) ?? first
                if let label = monthLabel(weekStart: weekStart, first: column == 0, calendar: calendar) {
                    Text(label).font(.system(size: 10)).foregroundColor(Theme.tertiary)
                        .fixedSize()
                        .offset(x: CGFloat(column) * step, y: 0)
                }
                ForEach(0..<7, id: \.self) { row in
                    let date = calendar.date(byAdding: .day, value: row, to: weekStart) ?? weekStart
                    if date <= today {
                        let day = log.day(date)
                        square(ActivityLog.level(day.dictations))
                            .help(tooltip(date, day))
                            .offset(x: CGFloat(column) * step, y: monthRow + CGFloat(row) * step)
                    }
                }
            }
        }
    }

    private func square(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(level == 0 ? Theme.border : Theme.accent.opacity([0, 0.3, 0.5, 0.75, 1][min(4, level)]))
            .frame(width: cell, height: cell)
    }

    /// A month name above the first week that contains the 1st (and the very first column).
    private func monthLabel(weekStart: Date, first: Bool, calendar: Calendar) -> String? {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        guard let startsMonth = days.first(where: { calendar.component(.day, from: $0) == 1 }) ?? (first ? weekStart : nil)
        else { return nil }
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
