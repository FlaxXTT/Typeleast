import Foundation

// ActivityLog.swift - per-day usage for the Home heatmap (活动): dates and counts only,
// never any text. It is kept apart from the history so that a short "保留历史" setting
// does not erase the record of which days were active; "删除全部历史" clears it too.

struct ActivityDay: Codable, Equatable {
    var dictations = 0
    var words = 0
}

final class ActivityLog {
    static let shared = ActivityLog(defaults: .standard)
    static let didChange = Notification.Name("TypeLeastActivityDidChange")

    private let key = "voice.activity.v1"
    private let d: UserDefaults
    private let calendar: Calendar
    /// "yyyy-MM-dd" in the local calendar -> that day's counts.
    private(set) var days: [String: ActivityDay] = [:]

    init(defaults: UserDefaults, calendar: Calendar = .current) {
        d = defaults
        self.calendar = calendar
        if let data = d.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: ActivityDay].self, from: data) {
            days = saved
        }
    }

    /// True once anything was ever saved (seeding from the history happens only before that).
    var isStarted: Bool { d.data(forKey: key) != nil }

    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(words: Int, at date: Date = Date()) {
        var day = days[dayKey(date)] ?? ActivityDay()
        day.dictations += 1
        day.words += max(0, words)
        days[dayKey(date)] = day
        save()
    }

    /// First run after an update: rebuild the past from whatever history is still kept.
    func seedIfNeeded(from items: [(date: Date, words: Int)]) {
        guard !isStarted else { return }
        for item in items {
            var day = days[dayKey(item.date)] ?? ActivityDay()
            day.dictations += 1
            day.words += max(0, item.words)
            days[dayKey(item.date)] = day
        }
        save()
    }

    func clear() {
        days = [:]
        save()
    }

    func day(_ date: Date) -> ActivityDay { days[dayKey(date)] ?? ActivityDay() }

    var activeDays: Int { days.values.filter { $0.dictations > 0 }.count }

    /// The current streak runs back from today, or from yesterday while today has
    /// nothing yet (a streak is not broken until the day is over).
    func streaks(today: Date = Date()) -> (current: Int, longest: Int) {
        let active = Set(days.filter { $0.value.dictations > 0 }.keys)
        var current = 0
        var cursor = calendar.startOfDay(for: today)
        if !active.contains(dayKey(cursor)) { cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor }
        while active.contains(dayKey(cursor)) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var longest = 0
        var run = 0
        var previous: Date?
        for key in active.sorted() {
            guard let date = ActivityLog.parse(key, calendar: calendar) else { continue }
            if let p = previous, calendar.dateComponents([.day], from: p, to: date).day == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previous = date
        }
        return (current, longest)
    }

    /// 0 = no activity, 1 light ... 4 power use, by the number of dictations that day.
    static func level(_ dictations: Int) -> Int {
        switch dictations {
        case ..<1: return 0
        case 1...3: return 1
        case 4...9: return 2
        case 10...24: return 3
        default: return 4
        }
    }

    static func parse(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) { d.set(data, forKey: key) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: ActivityLog.didChange, object: nil) }
    }
}
