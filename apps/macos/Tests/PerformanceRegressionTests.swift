import AppKit
import Foundation
import SwiftUI

func dashboardMotionTests() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var count = CountUpTransition(initial: nil)
    check("a fresh count has no target before data arrives", count.target == nil)
    checkEq("a fresh count starts at zero", count.value(at: start), 0)
    count.retarget(800, at: start, reduceMotion: false)
    let halfway = start.addingTimeInterval(0.125)
    checkEq("count uses cubic ease-out halfway through 250 ms", count.value(at: halfway), 700)
    count.retarget(900, at: halfway, reduceMotion: false)
    checkEq("updates start from the current interpolation", count.value(at: halfway), 700)
    checkEq("count finishes on its new target", count.value(at: halfway.addingTimeInterval(0.250)), 900)
    count.retarget(123, at: halfway, reduceMotion: true)
    checkEq("reduced motion skips count interpolation", count.value(at: halfway), 123)
    checkEq("a cached count can display immediately", CountUpTransition(initial: 91).value(at: start), 91)
    checkEq("unavailable statistics render dashes", InsightFormat.count.parts(for: nil).first?.digits, "--")
    checkEq("thousands suffix applies after rounding", InsightFormat.count.parts(for: 999.6).first?.suffix, "k")
    checkEq("duration formats the interpolated total", InsightFormat.duration.parts(for: 3659.6).map(\.digits), ["1", "1"])

    let covered = HeatmapMotion.Sample(scale: 1, cover: 1)
    let final = HeatmapMotion.Sample(scale: 1, cover: 0)
    checkEq("waiting columns keep the placeholder", HeatmapMotion.sample(elapsed: 0.019, column: 1), covered)
    check("the first column has already begun", HeatmapMotion.sample(elapsed: 0.019, column: 0).cover < 1)
    checkEq("a cell is uncovered and at peak scale at 150 ms", HeatmapMotion.sample(elapsed: 0.150, column: 0),
            .init(scale: 1.2, cover: 0))
    checkEq("a cell settles after 300 ms", HeatmapMotion.sample(elapsed: 0.300, column: 0), final)
    checkEq("column-local samples match at the same time", HeatmapMotion.sample(elapsed: 0.125, column: 0),
            HeatmapMotion.sample(elapsed: 0.165, column: 2))
    check("34 columns finish in 960 ms", abs(HeatmapMotion.finishTime(columns: 34) - 0.960) < 0.000001)
}

func dashboardWindowTests() {
    func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { wait(0.01) }
        return condition()
    }

    let onboardingDone = Settings.shared.onboardingDone
    let activationPolicy = NSApp.activationPolicy()
    Settings.shared.onboardingDone = true
    NSApp.setActivationPolicy(.accessory)
    defer {
        Settings.shared.onboardingDone = onboardingDone
        NSApp.setActivationPolicy(activationPolicy)
    }

    dashboardCountRenderingTests()

    let model = AppModel(loadCacheImmediately: false)
    let hub = HubWindowController(model: model)
    hub.openMainWindow()
    guard let window = hub.themeTransitionWindow, let container = window.contentView,
          let mask = container.subviews.first else {
        check("the startup window creates a mask before mounting its shell", false)
        return
    }
    defer { window.close() }
    checkEq("the mask is initially the only content view", container.subviews.count, 1)
    let shellReady = waitFor { hub.shellCommitted }
    check("the shell mounts underneath while the cache is pending", shellReady && container.subviews.count >= 2 && mask.superview != nil)
    check("separate dashboard data remains unavailable during startup", model.stats == nil && !model.activityReady)
    model.finishUserCacheLoad()
    hub.userCacheDidLoad()
    check("the mask is removed once shell and cache are ready", mask.superview == nil)
    check("the shell is visible before its dashboard deliveries", model.stats == nil && !model.activityReady)
    check("statistics and activity both reach the visible shell", waitFor { model.stats != nil && model.activityReady })

    hub.show(page: .history)
    checkEq("explicit history navigation is preserved", model.page, .history)
    hub.openMainWindow()
    checkEq("opening the visible window goes Home", model.page, .home)
    hub.show(page: .history)
    window.close()
    hub.openMainWindow()
    check("closed window reopens at Home", window.isVisible && model.page == .home)

    let pending = AppModel(loadCacheImmediately: false)
    let slowHub = HubWindowController(model: pending)
    slowHub.openMainWindow()
    guard let slowWindow = slowHub.themeTransitionWindow,
          let slowMask = slowWindow.contentView?.subviews.first else {
        check("slow startup shows a mask", false)
        return
    }
    defer { slowWindow.close() }
    wait(5.2)
    check("the five-second fallback removes the mask with cache pending", slowMask.superview == nil && !pending.userCacheReady)
    pending.finishUserCacheLoad()
    slowHub.userCacheDidLoad()
    check("a late cache completion still loads both dashboard sections", waitFor { pending.stats != nil && pending.activityReady })
}

private func dashboardCountRenderingTests() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
        print("SKIP native count rendering when macOS Reduce Motion is enabled")
        return
    }

    let size = NSRect(x: 0, y: 0, width: 400, height: 90)
    func figures(words: Double?, seconds: Double?, presentation: Int) -> some View {
        HStack(spacing: 0) {
            Figure(value: words, format: .count, label: "Words dictated", height: size.height)
            Figure(value: seconds, format: .duration, label: "Time saved", height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .id(presentation)
    }
    let view = NSHostingView(rootView: figures(words: 0, seconds: 0, presentation: 0))
    let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    func snapshot(_ region: NSRect) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: region) else { return nil }
        view.cacheDisplay(in: region, to: image)
        return image.representation(using: .png, properties: [:])
    }

    let words = NSRect(x: 0, y: 0, width: size.width / 2, height: size.height)
    let time = words.offsetBy(dx: words.width, dy: 0)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let zeroWords = snapshot(words)
    let zeroTime = snapshot(time)

    view.rootView = figures(words: nil, seconds: nil, presentation: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check("the first frame before data arrives renders numeric zeros", zeroWords != nil && zeroTime != nil &&
          zeroWords == snapshot(words) && zeroTime == snapshot(time))

    view.rootView = figures(words: 64_300, seconds: 45_900, presentation: 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    check("reopening with cached statistics renders zeros before the animation", zeroWords != nil && zeroTime != nil &&
          zeroWords == snapshot(words) && zeroTime == snapshot(time))
    var wordsFrames = Set<Data>()
    var timeFrames = Set<Data>()
    let deadline = Date().addingTimeInterval(CountUpTransition.duration + 0.10)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        if let frame = snapshot(words) { wordsFrames.insert(frame) }
        if let frame = snapshot(time) { timeFrames.insert(frame) }
    }
    check("cached word count renders intermediate frames on appearance", wordsFrames.count >= 3,
          "rendered \(wordsFrames.count) distinct frames")
    check("cached saved time renders intermediate frames on appearance", timeFrames.count >= 3,
          "rendered \(timeFrames.count) distinct frames")
    let finalWords = snapshot(words)
    let finalTime = snapshot(time)
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    check("the rendered word and time counts settle", finalWords != nil && finalTime != nil &&
          finalWords == snapshot(words) && finalTime == snapshot(time))
}

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
