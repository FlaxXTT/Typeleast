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

    mutating func include(_ activity: ActivityDay) {
        dictations += activity.dictations
        words += activity.words
        if let duration = activity.speakingSeconds {
            speakingSeconds = (speakingSeconds ?? 0) + duration
            savedSeconds = (savedSeconds ?? 0) + (activity.savedSeconds ?? 0)
            timedWords = (timedWords ?? 0) + (activity.timedWords ?? 0)
            timedDictations = (timedDictations ?? 0) + (activity.timedDictations ?? 0)
        }
    }
}

final class ActivityLog {
    static let shared = ActivityLog(defaults: .standard)
    static let didChange = Notification.Name("TypeLeastActivityDidChange")

    private let key = "voice.activity.v1"
    private let d: UserDefaults
    private let calendar: Calendar
    /// "yyyy-MM-dd" in the local calendar -> that day's counts.
    private(set) var days: [String: ActivityDay] = [:] {
        didSet { cachedStreaks = nil; cachedActiveDays = nil }
    }
    private var cachedStreaks: (day: Date, current: Int, longest: Int)?
    private var cachedActiveDays: Int?
    private var totals = ActivityDay()
    /// Updated incrementally on a completed dictation. Independent of retained transcript history.
    private(set) var stats = DictationStats()
    /// Lets regression tests prove redraws do not rescan the full log.
    private(set) var streakBuildCount = 0

    init(defaults: UserDefaults, calendar: Calendar = .autoupdatingCurrent) {
        d = defaults
        self.calendar = calendar
        if let data = d.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: ActivityDay].self, from: data) {
            days = saved
            for day in saved.values { totals.include(day) }
            updateStats()
        }
    }

    /// True once anything was ever saved (seeding from the history happens only before that).
    var isStarted: Bool { d.data(forKey: key) != nil }

    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(words: Int, seconds: Double? = nil, typingSeconds: Double? = nil, at date: Date = Date()) {
        let day = dayKey(date)
        var activity = ActivityDay(dictations: 1, words: max(0, words))
        if let seconds, let typingSeconds {
            activity.speakingSeconds = seconds
            activity.savedSeconds = max(0, typingSeconds - seconds)
            activity.timedWords = activity.words
            activity.timedDictations = 1
        }
        days[day, default: ActivityDay()].include(activity)
        totals.include(activity)
        updateStats()
        save()
    }

    private func updateStats() {
        // Count-only records do not contain the language mix. Use the existing CJK rates.
        let estimatedWords = max(0, totals.words - (totals.timedWords ?? 0))
        let estimatedSpeech = DictationStats.estimatedSpeechSeconds(cjk: estimatedWords)
        let estimatedTyping = DictationStats.estimatedTypingSeconds(cjk: estimatedWords)
        stats = DictationStats(dictations: totals.dictations, words: totals.words,
                               speakingSeconds: (totals.speakingSeconds ?? 0) + estimatedSpeech,
                               savedSeconds: (totals.savedSeconds ?? 0) + max(0, estimatedTyping - estimatedSpeech),
                               hasEstimatedTiming: estimatedWords > 0)
        stats.updateRate()
    }

    /// First run after an update: rebuild the past from whatever history is still kept.
    func seedIfNeeded(from items: [(date: Date, words: Int)]) {
        guard !isStarted else { return }
        for item in items {
            let activity = ActivityDay(dictations: 1, words: max(0, item.words))
            days[dayKey(item.date), default: ActivityDay()].include(activity)
            totals.include(activity)
        }
        updateStats()
        save()
    }

    func clear() {
        days = [:]
        totals = ActivityDay()
        updateStats()
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
