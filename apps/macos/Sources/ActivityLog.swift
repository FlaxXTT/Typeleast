import Foundation

// ActivityLog.swift - per-day usage for Home: dates, counts and measured durations only,
// never any text. It is kept apart from the history so that a short "保留历史" setting
// does not erase the record of which days were active; "删除全部历史" clears it too.

struct ActivityDay: Codable, Equatable {
    var dictations = 0
    var words = 0
    // Optional fields keep existing count-only activity records readable.
    var speakingSeconds: Double?
    var savedSeconds: Double?
    var timedWords: Int?
    var timedDictations: Int?
}

final class ActivityLog {
    static let shared = ActivityLog(defaults: .standard)
    static let didChange = Notification.Name("TypeLeastActivityDidChange")

    private let key = "voice.activity.v1"
    private let d: UserDefaults
    private let calendar: Calendar
    /// "yyyy-MM-dd" in the local calendar -> that day's counts.
    private(set) var days: [String: ActivityDay] = [:] {
        didSet { cachedStreaks = nil; cachedActiveDays = nil; cachedStats = nil }
    }
    private var cachedStreaks: (day: Date, current: Int, longest: Int)?
    private var cachedActiveDays: Int?
    private var cachedStats: DictationStats?
    /// Lets regression tests prove redraws do not rescan the full log.
    private(set) var streakBuildCount = 0

    init(defaults: UserDefaults, calendar: Calendar = .autoupdatingCurrent) {
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

    func record(words: Int, seconds: Double? = nil, typingSeconds: Double? = nil, at date: Date = Date()) {
        var day = days[dayKey(date)] ?? ActivityDay()
        day.dictations += 1
        day.words += max(0, words)
        if let seconds, let typingSeconds {
            day.speakingSeconds = (day.speakingSeconds ?? 0) + seconds
            day.savedSeconds = (day.savedSeconds ?? 0) + max(0, typingSeconds - seconds)
            day.timedWords = (day.timedWords ?? 0) + max(0, words)
            day.timedDictations = (day.timedDictations ?? 0) + 1
        }
        days[dayKey(date)] = day
        save()
    }

    /// Home totals do not depend on whether transcript history is retained.
    var stats: DictationStats {
        if let cachedStats { return cachedStats }
        var result = DictationStats()
        var timedWords = 0
        var timedDictations = 0
        for day in days.values {
            result.dictations += day.dictations
            result.words += day.words
            result.speakingSeconds += day.speakingSeconds ?? 0
            result.savedSeconds += day.savedSeconds ?? 0
            timedWords += day.timedWords ?? 0
            timedDictations += day.timedDictations ?? 0
        }
        result.timedWords = timedWords
        result.timedDictations = timedDictations
        cachedStats = result
        return result
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

    var activeDays: Int {
        if let cachedActiveDays { return cachedActiveDays }
        let count = days.values.filter { $0.dictations > 0 }.count
        cachedActiveDays = count
        return count
    }

    /// The current streak runs back from today, or from yesterday while today has
    /// nothing yet (a streak is not broken until the day is over).
    func streaks(today: Date = Date()) -> (current: Int, longest: Int) {
        let day = calendar.startOfDay(for: today)
        if let cachedStreaks, cachedStreaks.day == day { return (cachedStreaks.current, cachedStreaks.longest) }
        streakBuildCount += 1
        let active = Set(days.filter { $0.value.dictations > 0 }.keys)
        var current = 0
        var cursor = day
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
        cachedStreaks = (day, current, longest)
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
