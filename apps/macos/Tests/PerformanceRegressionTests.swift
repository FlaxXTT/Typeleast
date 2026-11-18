import AppKit
import Foundation

func performanceRegressionTests() {
    // Attributes only: repeated configured-state rendering must not query Keychain.
    do {
        let original = KeychainStore.stub
        defer {
            KeychainStore.presenceQueryOverride = nil
            KeychainStore.stub = original
        }
        KeychainStore.stub = ["presence-fixture": "fictional-key"]
        var queries = 0
        KeychainStore.presenceQueryOverride = { account in
            // Activation also starts background queries for configured providers.
            guard account == "presence-fixture" || account == "missing-fixture" else { return false }
            queries += 1
            return KeychainStore.stub?[account] != nil
        }
        for _ in 0..<100 { _ = KeychainStore.exists(account: "presence-fixture") }
        checkEq("100 configured-state reads use one attributes query", queries, 1)
        for _ in 0..<100 { _ = KeychainStore.exists(account: "missing-fixture") }
        checkEq("missing-key metadata is cached too", queries, 2)
        check("a missing key stays missing", !KeychainStore.exists(account: "missing-fixture"))
        let model = AppModel()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        _ = KeychainStore.exists(account: "presence-fixture")
        checkEq("app activation invalidates display metadata", queries, 3)
        let activityRevision = model.activityRevision
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        checkEq("midnight refreshes the activity view without new dictation", model.activityRevision, activityRevision + 1)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        checkEq("timezone changes refresh the activity view", model.activityRevision, activityRevision + 2)
        _ = model.hint // retain the observer through activation
        KeychainStore.write("fictional-new-key", account: "missing-fixture")
        check("saving a key invalidates missing-key metadata", KeychainStore.exists(account: "missing-fixture"))
        KeychainStore.write("", account: "presence-fixture")
        check("deleting a key invalidates present-key metadata", !KeychainStore.exists(account: "presence-fixture"))
    }

    // A slow health check must not fan a burst of window/menu refreshes into IPC.
    func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    do {
        let gate = CoalescingRefresh<Int>()
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var starts = 0, active = 0, peak = 0
        var results: [Int] = []
        func work(_ value: Int, block: Bool) -> Int {
            lock.lock(); starts += 1; active += 1; peak = max(peak, active); lock.unlock()
            if block { _ = release.wait(timeout: .now() + 2) }
            lock.lock(); active -= 1; lock.unlock()
            return value
        }
        gate.request(work: { work(0, block: true) }) { if case .success(let value) = $0 { results.append(value) } }
        for value in 1...30 {
            gate.request(work: { work(value, block: false) }) {
                check("refresh completion runs on main", Thread.isMainThread)
                if case .success(let value) = $0 { results.append(value) }
            }
        }
        release.signal()
        settle { results.count == 2 }
        checkEq("refresh burst runs initial and latest follow-up only", results, [0, 30])
        lock.lock(); let counts = (starts, peak); lock.unlock()
        checkEq("30 pending refreshes start only two workers", counts.0, 2)
        checkEq("refresh workers never overlap", counts.1, 1)
    }
    do {
        let gate = CoalescingRefresh<Int>()
        let release = DispatchSemaphore(value: 0)
        var results: [Int] = []
        gate.request(work: { _ = release.wait(timeout: .now() + 2); return 1 }) {
            if case .success(let value) = $0 { results.append(value) }
        }
        gate.invalidate()
        gate.request(work: { 2 }) { if case .success(let value) = $0 { results.append(value) } }
        release.signal()
        settle { results.count == 1 }
        checkEq("service restart discards old result and runs new request", results, [2])
        gate.request(work: { throw ServiceError.transport("fixture") }) { result in
            check("failed refresh returns an error", (try? result.get()) == nil)
            gate.request(work: { 3 }) { if case .success(let value) = $0 { results.append(value) } }
        }
        settle { results.count == 2 }
        checkEq("failure does not wedge later refreshes", results, [2, 3])
    }

    // No old model test may save a new draft or report a different provider ready.
    do {
        let context = ["provider-a", "https://example.invalid/v1", "model-a", "fictional-draft"]
        var request = FormRequest<[String]>()
        for index in context.indices {
            let token = request.begin(context: context)
            var edited = context; edited[index] += "-changed"
            check("model result rejects changed input \(index)", !request.finish(token, context: edited))
        }
        let old = request.begin(context: context)
        let newer = request.begin(context: context)
        check("old callback cannot finish a newer model test", !request.finish(old, context: context))
        check("matching model test is accepted", request.finish(newer, context: context))
        let hidden = request.begin(context: context)
        request.invalidate()
        check("leaving the model form rejects late results", !request.finish(hidden, context: context))
    }

    do {
        check("idle app can update", UpdateController.blockingReason(practiceBusy: false, phase: .idle, promptPending: false, meetingBusy: false) == nil)
        for phase: AppPhase in [.starting, .recording, .thinking] {
            check("active dictation blocks update", UpdateController.blockingReason(practiceBusy: false, phase: phase, promptPending: false, meetingBusy: false) != nil)
        }
        check("meeting recording and transcription block update", UpdateController.blockingReason(practiceBusy: false, phase: .idle, promptPending: false, meetingBusy: true) != nil)
        check("pending prompt blocks update", UpdateController.blockingReason(practiceBusy: false, phase: .idle, promptPending: true, meetingBusy: false) != nil)
        check("practice blocks update", UpdateController.blockingReason(practiceBusy: true, phase: .idle, promptPending: false, meetingBusy: false) != nil)
        let hugeSlot = "{" + String(repeating: "9", count: 100) + "}"
        checkEq("oversized translation slot cannot crash the UI", L10n.render(hugeSlot, arguments: ["fixture"]), hugeSlot)
        checkEq("missing translation slots remain literal", L10n.render("{1} {0}", arguments: ["a {1}"]), "{1} a {1}")
        checkEq("cached numeric formatting preserves rounding", L10n.render("{0}", arguments: [12345.6789], language: "en"), "12,345.679")
    }

    do {
        let suite = "typeleast.tests.activity-cache." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 12))!
        let log = ActivityLog(defaults: defaults, calendar: calendar)
        log.seedIfNeeded(from: (0..<1000).map { (date: calendar.date(byAdding: .day, value: -$0, to: today)!, words: 1) })
        for _ in 0..<100 { _ = log.streaks(today: today) }
        checkEq("100 heatmap redraws scan 1000 activity days only once", log.streakBuildCount, 1)
        checkEq("cached streak preserves all active days", log.streaks(today: today).current, 1000)
        log.record(words: 2, at: today)
        _ = log.streaks(today: today)
        checkEq("recording invalidates cached statistics", log.streakBuildCount, 2)
        let later = calendar.date(byAdding: .day, value: 2, to: today)!
        checkEq("cached streak expires after a missed calendar day", log.streaks(today: later).current, 0)
        checkEq("new calendar day rebuilds statistics once", log.streakBuildCount, 3)
        log.clear()
        checkEq("clearing invalidates active-day count", log.activeDays, 0)
        checkEq("clearing invalidates streaks", log.streaks(today: later).longest, 0)
    }
}
