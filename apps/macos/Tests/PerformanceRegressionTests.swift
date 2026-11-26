import AppKit
import Foundation
import SwiftUI

func dashboardMotionTests() {
    let homeDividers = ThemeRevealLayout.home.boundaries(in: 944)
    checkEq("the home fade follows the sidebar and column boundaries", homeDividers, [0, 210, 695.32, 944])
    checkEq("two-column windows use their own sidebar width", ThemeRevealLayout.settings.boundaries(in: 900),
            [0, 202, 900])
    checkEq("other hub pages split only at the sidebar", ThemeRevealLayout.sidebar.boundaries(in: 944),
            [0, 210, 944])
    checkEq("a sheet fades as one section", ThemeRevealLayout.single.boundaries(in: 480), [0, 480])
    checkEq("short windows omit dividers outside their bounds", ThemeRevealLayout.home.boundaries(in: 210),
            [0, 210])
    let dayDelays = (0..<3).map { ThemeRevealLayout.delay(for: $0, count: 3, toDark: false) }
    let nightDelays = (0..<3).map { ThemeRevealLayout.delay(for: $0, count: 3, toDark: true) }
    checkEq("light fades from the sidebar to the engine", dayDelays, [0, 0.083, 0.166])
    checkEq("dark fades through the same sections in reverse", nightDelays, Array(dayDelays.reversed()))
    for toDark in [false, true] {
        let delays = (0..<3).map { ThemeRevealLayout.delay(for: $0, count: 3, toDark: toDark) }
        let settingsDelays = (0..<2).map { ThemeRevealLayout.delay(for: $0, count: 2, toDark: toDark) }
        checkEq("overlapping hub and settings animations share their first and last fade",
                settingsDelays, [delays[0], delays[2]])
    }

    let start = Date(timeIntervalSinceReferenceDate: 0)
    var count = CountUpTransition(initial: nil)
    check("a fresh count has no target before data arrives", count.target == nil)
    checkEq("a fresh count starts at zero", count.value(at: start), 0)
    count.retarget(800, at: start, reduceMotion: false)
    let quarter = start.addingTimeInterval(CountUpTransition.duration / 4)
    let halfway = start.addingTimeInterval(CountUpTransition.duration / 2)
    let threeQuarters = start.addingTimeInterval(3 * CountUpTransition.duration / 4)
    check("the slower count is still moving after 320 ms", count.value(at: start.addingTimeInterval(0.320)) < 800)
    checkEq("count starts slower than a linear transition", count.value(at: quarter), 125)
    checkEq("count reaches the midpoint halfway through 1.2 seconds", count.value(at: halfway), 400)
    check("the count is easing toward the end after the third quarter",
          abs(count.value(at: threeQuarters) - 675) < 0.000001)
    count.retarget(900, at: halfway, reduceMotion: false)
    checkEq("updates start from the current interpolation", count.value(at: halfway), 400)
    checkEq("count finishes on its new target", count.value(at: halfway.addingTimeInterval(CountUpTransition.duration)), 900)
    count.retarget(123, at: halfway, reduceMotion: true)
    checkEq("reduced motion skips count interpolation", count.value(at: halfway), 123)
    checkEq("a cached count can display immediately", CountUpTransition(initial: 91).value(at: start), 91)
    checkEq("unavailable statistics render dashes", InsightFormat.count.parts(for: nil).first?.digits, "--")
    checkEq("thousands suffix applies after rounding", InsightFormat.count.parts(for: 999.6).first?.suffix, "k")
    checkEq("duration formats the interpolated total", InsightFormat.duration.parts(for: 3659.6).map(\.digits), ["1", "1"])

    let covered = HeatmapMotion.Sample(scale: 1, cover: 1)
    let final = HeatmapMotion.Sample(scale: 1, cover: 0)
    let beforeSecondColumn = HeatmapMotion.columnDelay - 0.001
    let halfPulse = HeatmapMotion.cellDuration / 2
    checkEq("waiting columns keep the placeholder", HeatmapMotion.sample(elapsed: beforeSecondColumn, column: 1), covered)
    check("the first column has already begun", HeatmapMotion.sample(elapsed: beforeSecondColumn, column: 0).cover < 1)
    checkEq("a cell is uncovered at half the reveal duration", HeatmapMotion.sample(elapsed: halfPulse, column: 0),
            .init(scale: 1.2, cover: 0))
    checkEq("a cell settles after 825 ms", HeatmapMotion.sample(elapsed: 0.825, column: 0), final)
    checkEq("column-local samples match at the same time", HeatmapMotion.sample(elapsed: 0.25, column: 0),
            HeatmapMotion.sample(elapsed: 0.25 + 2 * HeatmapMotion.columnDelay, column: 2))
    checkEq("the activity tile returns to the grid plane",
            HeatmapMotion.depth(elapsed: HeatmapMotion.cellDuration, column: 0, row: 6), 0)
    check("the leading row rises before the following row or column",
          HeatmapMotion.depth(elapsed: beforeSecondColumn, column: 0, row: 0) > 0
          && HeatmapMotion.depth(elapsed: beforeSecondColumn, column: 0, row: 6) == 0
          && HeatmapMotion.depth(elapsed: beforeSecondColumn, column: 1, row: 0) == 0)
    checkEq("the first tile lifts to full depth halfway through its pulse",
            HeatmapMotion.depth(elapsed: halfPulse, column: 0, row: 0), 1)
    check("the 20-column homepage heatmap finishes in 1.87 seconds",
          abs(HeatmapMotion.finishTime(columns: 20) - 1.87) < 0.000001)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 1
    let rhythmHours = [4, 5, 7, 8, 11, 12, 16, 17, 19, 20, 23]
    let rhythmWords = rhythmHours.map { hour in
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: hour))!
        return RhythmPeriod.current(at: date, calendar: calendar)
    }
    checkEq("the Rhythm word follows the local hour and includes overnight",
            rhythmWords, [.nights, .dawns, .dawns, .morns, .morns, .noons, .noons, .dusks, .dusks, .nights, .nights])
    let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12))!
    let firstDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
    let saturdayRange = ActivityRange(endingOn: saturday, calendar: calendar)
    checkEq("the 133-day range includes today and survives a daylight saving change", saturdayRange.firstDay, firstDay)
    checkEq("a range ending Saturday occupies exactly 19 week columns", saturdayRange.weekCount, 19)
    calendar.locale = Locale(identifier: "en_US")
    let shadeSamples = [0, 45, 80, 132].map { age in
        let date = calendar.date(byAdding: .day, value: -age, to: saturdayRange.today)!
        return saturdayRange.emptyShade(for: date, calendar: calendar, region: "US")
    }
    checkEq("unused heatmap days have four progressively lighter age bands", shadeSamples, [0, 1, 2, 3])
    let sundayBoundary = calendar.date(byAdding: .day, value: -27, to: saturdayRange.today)!
    checkEq("weekends can lighten an unused day near a band boundary",
            saturdayRange.emptyShade(for: sundayBoundary, calendar: calendar, region: "US"), 1)
    let thanksgiving = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26))!
    let december = calendar.date(byAdding: .day, value: 24, to: thanksgiving)!
    let decemberRange = ActivityRange(endingOn: december, calendar: calendar)
    check("recognized regional holidays gently lighten an unused day",
          decemberRange.emptyShade(for: thanksgiving, calendar: calendar, region: "US") >
            decemberRange.emptyShade(for: thanksgiving, calendar: calendar, region: "CA"))
    for offset in 1...6 {
        let day = calendar.date(byAdding: .day, value: offset, to: saturday)!
        let range = ActivityRange(endingOn: day, calendar: calendar)
        checkEq("a 133-day range ending \(offset) days past Saturday occupies 20 aligned columns", range.weekCount, 20)
        checkEq("column coverage keeps the inclusive range at 133 days for weekday offset \(offset)",
                calendar.dateComponents([.day], from: range.firstDay, to: range.today).day, 132)
    }

    checkEq("Doubao dictation keeps the Doubao mark regardless of the installed local model",
            EngineBrand.speech(provider: .doubao, modelID: "mlx-qwen3-asr-1.7b-8bit"), .doubao)
    checkEq("the local Qwen speech model has the Qwen mark",
            EngineBrand.speech(provider: .local, modelID: "mlx-qwen3-asr-1.7b-8bit"), .qwen)
    checkEq("OpenRouter selects the DeepSeek whale for a routed DeepSeek model",
            EngineBrand.cleanup(providerID: "openrouter", modelID: "deepseek/deepseek-flash"), .deepseek)
    checkEq("Ollama selects the loaded model family when it is recognizable",
            EngineBrand.cleanup(providerID: "ollama", modelID: "qwen3:8b"), .qwen)
    checkEq("a custom OpenAI-compatible endpoint gets no inferred brand for an unknown model",
            EngineBrand.cleanup(providerID: "custom", modelID: "custom/private"), nil)
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
    cancelledTranscriptionToastTests()
    pageTransitionRenderingTests()
    homeEntryMaskTests()

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

    hub.applicationDidBecomeActive()
    let initialPresentation = model.homePresentationID
    hub.reopenMainWindow()
    checkEq("a repeated Dock entry keeps the visible Home presentation", model.homePresentationID, initialPresentation)
    hub.applicationDidBecomeActive()
    let nextPresentation = model.homePresentationID
    checkEq("foreground activation keeps the existing Home presentation", nextPresentation, initialPresentation)
    hub.applicationDidBecomeActive()
    hub.reopenMainWindow()
    checkEq("repeated activation and Dock callbacks share the same presentation", model.homePresentationID, nextPresentation)

    model.settingsPresented = true
    hub.applicationDidBecomeActive()
    model.settingsPresented = false
    hub.applicationDidBecomeActive()
    checkEq("returning from Settings preserves the visible Home presentation", model.homePresentationID, nextPresentation)

    window.miniaturize(nil)
    check("Home window minimizes", waitFor { window.isMiniaturized })
    hub.reopenMainWindow()
    check("Dock restores the minimized Home window", waitFor { window.isVisible && !window.isMiniaturized })
    hub.applicationDidBecomeActive()
    checkEq("restoring the minimized window does not restart the Home mask", model.homePresentationID, nextPresentation)
    check("restoring does not suspend the existing Home view", !model.homePresentationSuspended)

    let initialPalette = model.sidebarBrandPalette
    model.navigate(to: .history)
    check("sidebar navigation keeps the current brand palette", model.sidebarBrandPalette == initialPalette)
    hub.reopenMainWindow()
    checkEq("the Dock leaves the visible History page open", model.page, .history)
    hub.applicationDidBecomeActive()
    check("returning to a History window preserves the page and Home presentation",
          model.page == .history && model.homePresentationID == nextPresentation)
    hub.show(page: .history)
    checkEq("explicit history navigation is preserved", model.page, .history)
    hub.openMainWindow()
    checkEq("the explicit Home action opens Home", model.page, .home)
    hub.show(page: .history)
    let beforeReopening = model.homePresentationID
    window.close()
    let previousPalette = model.sidebarBrandPalette
    hub.reopenMainWindow()
    hub.applicationDidBecomeActive()
    check("closed window reopens at Home", window.isVisible && model.page == .home)
    check("reopening the window draws a different brand palette", model.sidebarBrandPalette != previousPalette)
    checkEq("reopening Home runs one new presentation", model.homePresentationID, beforeReopening + 1)

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

private func pageTransitionRenderingTests() {
    var mounted: Set<HubPage> = []
    func page(_ selection: HubPage) -> some View {
        HubPageTransition(selection: selection) { page in
            Text(page.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { mounted.insert(page) }
                .onDisappear { mounted.remove(page) }
        }
    }
    let view = NSHostingView(rootView: page(.home))
    let frame = NSRect(x: 0, y: 0, width: 280, height: 150)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    func waitFor(_ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while !ready() && Date() < deadline
        return ready()
    }

    check("the first page mounts without an outgoing page", waitFor { mounted == [.home] })
    view.rootView = page(.history)
    check("changing tabs mounts the destination", waitFor { mounted.contains(.history) })
    view.rootView = page(.meetings)
    check("the latest page is the only one left after the transition", waitFor { mounted == [.meetings] })
}

private func homeEntryMaskTests() {
    var covered = false
    func home(_ request: Int?) -> some View {
        HomeEntryTransition(request: request) { isCovered in
            Text("Home").onChange(of: isCovered, initial: true) { _, value in covered = value }
        }
    }
    let view = NSHostingView(rootView: home(nil))
    let frame = NSRect(x: 0, y: 0, width: 280, height: 150)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFront(nil)
    defer { window.orderOut(nil) }

    func waitFor(_ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while !ready() && Date() < deadline
        return ready()
    }

    view.rootView = home(1)
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        check("reduced motion reveals the Home statistics without a mask", waitFor { !covered })
        return
    }
    check("the Logo mask holds the Home statistics on entry", waitFor { covered })
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    check("the Home statistics stay held during the Logo pause", covered)
    check("the Home statistics are released when the mask finishes fading", waitFor { !covered })
    view.rootView = home(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    view.rootView = home(1)
    check("returning to Home plays the mask even with the same window presentation", waitFor { covered })
    view.rootView = home(nil)
    check("leaving Home dismisses an in-flight mask", waitFor { !covered })
}

private func cancelledTranscriptionToastTests() {
    let language = L10n.language
    let toast = LearnedToast()
    defer {
        toast.finish()
        L10n.language = language
    }

    var previousPanel: NSPanel?
    var expired = 0
    for (locale, expected) in [("zh-Hans", "转录已取消"), ("en", "Cancelled")] {
        L10n.language = locale
        toast.show(message: L10n.text("转录已取消"), undo: {}, expired: { expired += 1 })
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSHostingView<LearnedToastView> }) as? NSPanel,
              let host = panel.contentView as? NSHostingView<LearnedToastView> else {
            check("the cancelled transcription toast opens in \(locale)", false)
            return
        }
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        checkEq("the cancellation message is localized in \(locale)", host.rootView.message, expected)
        check("the cancellation panel fits its content in \(locale)",
              host.bounds.width >= fitting.width && host.bounds.height >= fitting.height,
              "bounds=\(host.bounds.size) fitting=\(fitting)")
        check("the cancellation toast is as compact as the recording capsule in \(locale)",
              panel.frame.height == PillView.height &&
              (RecordingBarMode.handsFree.width...PillView.thinkingWidth).contains(panel.frame.width))
        check("the cancellation card is free of a native corner mask in \(locale)",
              (host.layer?.cornerRadius ?? 0) == 0)
        if let previousPanel {
            check("both languages reuse the same compact panel", previousPanel === panel)
        }
        previousPanel = panel
    }
    toast.finish()
    check("replacing and dismissing the toast each expire one pending undo",
          expired == 2 && previousPanel?.isVisible == false)

    toast.show(message: L10n.text("转录已取消"), undo: {}, expired: { expired += 1 })
    let deadline = Date().addingTimeInterval(3.5)
    while previousPanel?.isVisible == true, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    }
    check("the cancellation toast expires and fades in under three and a half seconds",
          expired == 3 && previousPanel?.isVisible == false)
}

private func dashboardCountRenderingTests() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
        print("SKIP native count rendering when macOS Reduce Motion is enabled")
        return
    }

    let size = NSRect(x: 0, y: 0, width: 600, height: 90)
    let columnWidth = size.width / 3
    func figures(words: Double?, seconds: Double?, activeDays: Int?, presentation: Int) -> some View {
        HStack(spacing: 0) {
            Figure(value: words, format: .count, label: "Words dictated", height: size.height)
                .frame(width: columnWidth)
            Figure(value: seconds, format: .duration, label: "Time saved", height: size.height, openEdge: .trailing)
                .frame(width: columnWidth)
            ActiveDaysReadout(value: activeDays)
                .frame(width: columnWidth)
        }
        .frame(width: size.width, height: size.height)
        .id(presentation)
    }
    let view = NSHostingView(rootView: figures(words: 0, seconds: 0, activeDays: 0, presentation: 0))
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

    let words = NSRect(x: 0, y: 0, width: columnWidth, height: size.height)
    let time = words.offsetBy(dx: words.width, dy: 0)
    let active = time.offsetBy(dx: time.width, dy: 0)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let zeroWords = snapshot(words)
    let zeroTime = snapshot(time)
    let zeroActive = snapshot(active)

    view.rootView = figures(words: nil, seconds: nil, activeDays: nil, presentation: 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    check("the first frame before data arrives renders numeric zeros", zeroWords != nil && zeroTime != nil &&
          zeroWords == snapshot(words) && zeroTime == snapshot(time))
    let unavailableActive = snapshot(active)
    check("active days have a placeholder until activity data arrives",
          unavailableActive != nil && zeroActive != nil && unavailableActive != zeroActive)

    view.rootView = figures(words: 64_300, seconds: 45_900, activeDays: 20, presentation: 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    check("reopening with cached statistics renders zeros before the animation", zeroWords != nil && zeroTime != nil &&
          zeroWords == snapshot(words) && zeroTime == snapshot(time))
    check("reopening with cached active days starts from zero", zeroActive != nil && zeroActive == snapshot(active))
    var wordsFrames = Set<Data>()
    var timeFrames = Set<Data>()
    var activeFrames = Set<Data>()
    let deadline = Date().addingTimeInterval(CountUpTransition.duration + 0.10)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        if let frame = snapshot(words) { wordsFrames.insert(frame) }
        if let frame = snapshot(time) { timeFrames.insert(frame) }
        if let frame = snapshot(active) { activeFrames.insert(frame) }
    }
    check("cached word count renders intermediate frames on appearance", wordsFrames.count >= 3,
          "rendered \(wordsFrames.count) distinct frames")
    check("cached saved time renders intermediate frames on appearance", timeFrames.count >= 3,
          "rendered \(timeFrames.count) distinct frames")
    check("cached active days render intermediate frames on appearance", activeFrames.count >= 3,
          "rendered \(activeFrames.count) distinct frames")
    let finalWords = snapshot(words)
    let finalTime = snapshot(time)
    let finalActive = snapshot(active)
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    check("the rendered word and time counts settle", finalWords != nil && finalTime != nil &&
          finalWords == snapshot(words) && finalTime == snapshot(time))
    check("the rendered active day count settles", finalActive != nil && finalActive != zeroActive &&
          finalActive == snapshot(active))

    let leadingEdge = NSRect(x: 0, y: 18, width: 10, height: size.height - 36)
    let trailingEdge = leadingEdge.offsetBy(dx: time.maxX - leadingEdge.width, dy: 0)
    let edges = [leadingEdge, trailingEdge]
    let startingBorders = edges.map(snapshot)
    view.rootView = figures(words: 9.1e18, seconds: 9.1e18, activeDays: 20, presentation: 3)
    RunLoop.current.run(until: Date().addingTimeInterval(CountUpTransition.duration + 0.15))
    check("very long counts and durations still render in their tiles",
          finalWords != nil && finalTime != nil && finalWords != snapshot(words) && finalTime != snapshot(time))
    check("longer readouts leave both outside borders fixed and clear of text",
          startingBorders.allSatisfy { $0 != nil } && startingBorders == edges.map(snapshot))
}

func performanceRegressionTests() {
    let textField = NSRect(x: 0, y: 0, width: 280, height: 110)
    let selectedRow = NSRect(x: 18, y: 50, width: 130, height: 18)
    let followingRow = NSRect(x: 18, y: 32, width: 175, height: 18)
    let previousRow = NSRect(x: 18, y: 68, width: 135, height: 18)
    let rows = [selectedRow, followingRow, previousRow]
    let pointer = NSPoint(x: 145, y: 60)
    let offer = TranslationOfferPlacement.frame(near: pointer, anchor: selectedRow, in: textField, rows: rows)
    checkEq("translation offer keeps an 18-point hit area", offer?.size, NSSize(width: 18, height: 18))
    check("offer clears neighboring text as well as the selected row", offer.map { frame in
        frame.minX >= followingRow.maxX + 3 && rows.allSatisfy { !frame.intersects($0) }
    } ?? false)
    let narrowField = NSRect(x: 15, y: 0, width: 183, height: 110)
    check("no unoccupied margin means no floating translation offer",
          TranslationOfferPlacement.frame(near: pointer, anchor: selectedRow, in: narrowField, rows: rows) == nil)
    let thinLine = NSRect(x: 18, y: 55, width: 130, height: 14)
    check("an isolated measured row cannot claim adjoining unknown space",
          TranslationOfferPlacement.frame(near: pointer, anchor: thinLine, in: textField, rows: [thinLine]) == nil)
    check("a short single line can still show the translation offer",
          TranslationOfferPlacement.frame(near: pointer, anchor: thinLine, in: textField, rows: [thinLine], allVisibleRows: true) != nil)
    let fullLine = NSRect(x: 18, y: 68, width: 167, height: 18)
    let lineBelow = NSRect(x: 18, y: 20, width: 171, height: 18)
    let separated = [fullLine, lineBelow]
    let inGap = TranslationOfferPlacement.frame(near: NSPoint(x: 174, y: 70), anchor: fullLine,
                                                 in: narrowField, rows: separated)
    check("an empty band fits the complete button and leaves both text rows clear",
          inGap.map { frame in
              frame.minY >= lineBelow.maxY + 3 && frame.maxY <= fullLine.minY - 3 && narrowField.contains(frame)
          } ?? false)

    let screen = NSRect(x: 0, y: 0, width: 1440, height: 780)
    let nearBottom = NSRect(x: 450, y: 65, width: 18, height: 30)
    let nearTop = NSRect(x: 450, y: 700, width: 18, height: 30)
    let loadingSize = NSSize(width: 456, height: 90)
    let resultSize = NSSize(width: 456, height: 330)
    for selection in [nearBottom, nearTop] {
        let opening = TranslationBubblePlacement(near: selection, in: screen)
        let loadingFrame = NSRect(origin: opening.origin(for: loadingSize), size: loadingSize)
        let update = TranslationBubblePlacement(near: selection, in: screen, existing: loadingFrame, above: opening.above)
        let resultFrame = NSRect(origin: update.origin(for: resultSize), size: resultSize)
        check("translation grows away from the source line and stays on-screen",
              screen.contains(resultFrame) && (opening.above
                 ? resultFrame.minY == loadingFrame.minY && resultFrame.minY > selection.maxY
                 : resultFrame.maxY == loadingFrame.maxY && resultFrame.maxY < selection.minY))
    }

    let draft = "👋 预算三月，周四发送。"
    let quote = ReviewEditFocus.uniqueRange(of: "三月", in: draft)
    checkEq("review selects an exact UTF-16 edit range", quote.map { (draft as NSString).substring(with: $0) }, "三月")
    check("review never locates an ambiguous edit", ReviewEditFocus.uniqueRange(of: "aaa", in: "aaaa") == nil)
    check("review does not select a quote already edited or missing",
          ReviewEditFocus.uniqueRange(of: "三月", in: "预算三页") == nil && ReviewEditFocus.uniqueRange(of: "", in: draft) == nil)

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

    func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
    do {
        let originalStub = KeychainStore.stub
        let settings = Settings.shared
        let originalProvider = settings.onlineASRProvider
        let originalPreset = settings.llmPresetID
        defer {
            KeychainStore.stub = originalStub
            settings.onlineASRProvider = originalProvider
            settings.llmPresetID = originalPreset
        }
        let provider = OnlineASRProvider.doubao
        settings.onlineASRProvider = provider
        settings.llmPresetID = "deepseek"
        KeychainStore.stub = [provider.keychainAccount: "fixture-asr-key", settings.llmPresetID: "fixture-cleanup-key"]
        let model = AppModel(loadCacheImmediately: false)
        settle { model.onlineASRKeyPresence == true && model.llmKeyPresence == true }
        check("saved ASR and cleanup keys are marked present when readable",
              model.onlineASRKeyPresence == true && model.llmKeyPresence == true)

        model.credentialsLocked = true
        model.refreshOnlineASRKeyPresence()
        model.refreshLLMKeyPresence()
        check("a locked vault does not report saved keys as absent",
              model.onlineASRKeyPresence == nil && model.llmKeyPresence == nil)
        checkEq("speech setup shows the keychain lock", model.speechEngineSummary.detail, L10n.text("钥匙串已锁定"))
        checkEq("cleanup setup shows the keychain lock", model.cleanupEngineSummary.detail, L10n.text("钥匙串已锁定"))

        model.credentialsLocked = false
        checkEq("unlocking shows the existing ASR configuration", model.speechEngineSummary.detail, L10n.text("已配置"))
        check("unlocking exposes the saved cleanup key state", model.llmKeyPresence == true)
        KeychainStore.stub = [:]
        model.refreshOnlineASRKeyPresence()
        model.refreshLLMKeyPresence()
        settle { model.onlineASRKeyPresence == false && model.llmKeyPresence == false }
        checkEq("an actually missing ASR key still asks for configuration", model.speechEngineSummary.detail, L10n.text("待配置 API Key"))
        check("an actually missing cleanup key is reported as absent", model.llmKeyPresence == false)
    }

    // A slow health check must not fan a burst of window/menu refreshes into IPC.
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
