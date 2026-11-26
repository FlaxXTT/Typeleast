import AppKit
import CryptoKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryOrigin: Decodable, Hashable {
    let agent: String
    let path: String
}

private struct LibraryItem: Decodable, Identifiable {
    let id: String
    let kind: String
    let imported: Bool?
    let ignored: Bool?
    let name: String
    let suggestedName: String?
    let renamed: Bool?
    let description: String?
    let category: String?
    let folderCategory: String?
    let wheelPreview: SpeakWheelPreview?
    let importMode: String?
    let sources: [LibraryOrigin]
    let savedMarkdownPath: String?
    let invocationText: String?
    var group: String { HarnessFolders.category(folderCategory ?? category) }
    var canOrganize: Bool { kind == "skill" || imported == true }
    var needsOrganization: Bool { kind == "skill" && (group == "pending" || wheelPreview == nil) }
    var localPath: String? { savedMarkdownPath ?? sources.first(where: { $0.agent == "manual" })?.path }
    var githubSource: URL? {
        guard let path = sources.first(where: { $0.agent == "github" })?.path, let url = URL(string: path),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private struct LibraryAgent: Decodable, Identifiable {
    let id: String
    let name: String
}

private struct LibraryChange: Decodable, Identifiable {
    let resource: String
    let agent: String
    let item: String
    let state: String
    let path: String?
    var id: String { agent + "|" + resource }
}

private struct ManagedLibraryItem: Decodable {
    let item: String
    let agent: String
}

private struct LibraryFileImportResult: Decodable {
    let skills: Int
    let skillReferences: Int?
    let mcp: Int
    let references: Int
    let duplicates: Int
    let conflicts: Int
    let skipped: Int
    let dependentSkills: Int
}

private struct LibraryImportRow: Decodable, Identifiable {
    let selectionID: String?
    let path: String
    let name: String
    let kind: String
    let dependencies: Bool
    let fields: [String]?
    let usesFiles: Bool?
    let relatedFiles: [String]?
    let providers: [String]?
    let canSaveMarkdown: Bool?
    let authorization: Bool?
    let enabled: Bool?
    var id: String { selectionID ?? path }
    var initialMode: String { kind == "unknown" || kind == "skill" && dependencies ? "skip" : "full" }
}

private struct SavedSkillMarkdown: Codable {
    let source: String
    let digest: String

    func trashOriginal() -> Bool {
        let original = URL(fileURLWithPath: source)
        guard matches(original) else { return false }
        do {
            try FileManager.default.trashItem(at: original, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }

    private func matches(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink == false, let size = values.fileSize, size <= 512 * 1024,
              let data = try? Data(contentsOf: url), data.count == size else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest
    }
}

private struct GitHubImportRevision: Codable {
    let ref: String
    let commit: String
}

private struct LibraryReply: Decodable {
    let agents: [LibraryAgent]?
    let items: [LibraryItem]?
    let managed: [ManagedLibraryItem]?
    let rows: [LibraryChange]?
    let error: String?
    let token: String?
    let text: String?
    let revision: String?
    let omitted: [String]?
    let importedFiles: LibraryFileImportResult?
    let savedMarkdown: [SavedSkillMarkdown]?
    let speakIds: [String]?
    let speakDrafts: [SpeakDraft]?
    let organized: Int?
    let imports: [LibraryImportRow]?
    let githubRevision: GitHubImportRevision?
    let pendingCleanup: Int?
}

private enum LocalLibraryCommand {
    static let wheelInvalidated = Notification.Name("TypeLeast.libraryWheelInvalidated")
    private static let queue = DispatchQueue(label: "com.dsh.voice.agent-library", qos: .userInitiated)

    static func run(_ input: Data, readOnly: Bool = false, timeout: TimeInterval = 30,
                    completion: @escaping (LibraryReply?) -> Void) {
        let workQueue = readOnly ? DispatchQueue.global(qos: .userInitiated) : queue
        workQueue.async {
            let reply = run(input, timeout: timeout)
            DispatchQueue.main.async { completion(reply) }
        }
    }

    private static func run(_ input: Data, timeout: TimeInterval) -> LibraryReply? {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let resources = Bundle.main.resourcePath
        guard let directory = ServiceLocator.serviceDirectory(resources: resources, environment: environment,
                                                               exists: fileManager.fileExists(atPath:)) else { return nil }
        let executable: (String) -> Bool = { fileManager.isExecutableFile(atPath: $0) }
        let node = ServiceLocator.bundledNode(resources: resources, exists: executable)
            ?? ServiceLocator.nodeCandidates(home: fileManager.homeDirectoryForCurrentUser.path,
                                              list: { (try? fileManager.contentsOfDirectory(atPath: $0)) ?? [] }).first(where: executable)
        guard let node else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        let storage = URL(fileURLWithPath: ServiceClient.stateDirectory).appendingPathComponent("agent-library.json").path
        process.arguments = [directory + "/bin/typeleast-agent-library.mjs", storage]
        process.environment = ServiceLocator.serviceEnvironment(environment)
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
        defer { stop.cancel() }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            return nil
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode(LibraryReply.self, from: output)
    }
}

private final class SkillInvocationHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SkillFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Pure selection and pagination state for Harness EQ skill invocation.
/// Guarantees unified index bounds, clean wrap-around, and zero duplicate items on the final page.
struct SkillInvocationState: Equatable {
    static let pageSize = 6
    var selectedIndex: Int = 0

    func pageCount(for total: Int) -> Int {
        guard total > 0 else { return 0 }
        return (total + Self.pageSize - 1) / Self.pageSize
    }

    func currentPage(for total: Int) -> Int {
        guard total > 0 else { return 0 }
        let clamped = max(0, min(selectedIndex, total - 1))
        return clamped / Self.pageSize
    }

    func pageIndices(for total: Int) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        let start = currentPage(for: total) * Self.pageSize
        let end = min(start + Self.pageSize, total)
        return start..<end
    }

    mutating func clamp(for total: Int) {
        if total <= 0 { selectedIndex = 0 }
        else { selectedIndex = max(0, min(selectedIndex, total - 1)) }
    }

    mutating func step(_ delta: Int, total: Int) {
        guard total > 1 else { selectedIndex = 0; return }
        selectedIndex = ((selectedIndex + delta) % total + total) % total
    }

    mutating func stepPage(_ delta: Int, total: Int) {
        let pages = pageCount(for: total)
        guard pages > 1 else { clamp(for: total); return }
        let nextPage = ((currentPage(for: total) + delta) % pages + pages) % pages
        let offsetInPage = max(0, selectedIndex) % Self.pageSize
        selectedIndex = min(nextPage * Self.pageSize + offsetInPage, total - 1)
    }

    @discardableResult
    mutating func selectSlot(_ slot: Int, total: Int) -> Bool {
        let range = pageIndices(for: total)
        let target = range.lowerBound + slot
        guard slot >= 0, range.contains(target) else { return false }
        selectedIndex = target
        return true
    }
}

enum SkillRadialGeometry {
    static let wheelSize: CGFloat = 348
    static let centerDiameter: CGFloat = 96
    static let innerMinRadius: CGFloat = 60
    static let innerMaxRadius: CGFloat = 122
    static let outerMinRadius: CGFloat = 128
    static let outerMaxRadius: CGFloat = 168
    static let outerHitMaxRadius: CGFloat = wheelSize / 2 - 0.5

    enum Slot: Equatable { case root(Int), child(Int) }

    static func sectorAngle(slot: Int, count: Int) -> Double {
        -90 + Double(slot) * 360 / Double(max(1, count))
    }

    static func sectorSweep(count: Int) -> Double {
        count > 1 ? 360 / Double(count) - 3.5 : 360
    }

    static func containsAngle(_ angle: Double, center: Double, sweep: Double) -> Bool {
        abs((angle - center).remainder(dividingBy: 360)) <= sweep / 2
    }

    static func hit(at point: CGPoint, roots: [RoundedAnnularSector], children: [RoundedAnnularSector]) -> Slot? {
        let dx = point.x - wheelSize / 2
        let dy = point.y - wheelSize / 2
        let radius = hypot(dx, dy)
        let angle = atan2(dy, dx) * 180 / .pi
        func contains(_ zone: RoundedAnnularSector) -> Bool {
            radius >= zone.innerRadius && radius <= zone.outerRadius
                && containsAngle(angle, center: zone.centerAngle, sweep: zone.sweep)
        }
        // Once a branch is visible, the inner edge of its child ring overlaps the root ring.
        if let slot = children.firstIndex(where: contains) { return .child(slot) }
        return roots.firstIndex(where: contains).map(Slot.root)
    }

    static func branchCorridorContains(_ point: CGPoint, from anchor: CGPoint, angle: Double) -> Bool {
        let center = CGPoint(x: wheelSize / 2, y: wheelSize / 2)
        guard hypot(point.x - center.x, point.y - center.y) >= hypot(anchor.x - center.x, anchor.y - center.y) else {
            return false
        }
        func edge(_ offset: Double) -> CGPoint {
            let direction = (angle + offset) * .pi / 180
            let radius = outerHitMaxRadius
            return CGPoint(x: center.x + cos(direction) * radius, y: center.y + sin(direction) * radius)
        }
        return SkillPointerCorridor.contains(point, apex: anchor, edgeStart: edge(-37), edgeEnd: edge(37))
    }
}

enum SkillPointerCorridor {
    static func contains(_ point: CGPoint, apex: CGPoint, edgeStart: CGPoint, edgeEnd: CGPoint) -> Bool {
        func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        guard abs(cross(apex, edgeStart, edgeEnd)) > 1 else { return false }
        let sides = [cross(apex, edgeStart, point), cross(edgeStart, edgeEnd, point), cross(edgeEnd, apex, point)]
        return sides.allSatisfy { $0 >= 0 } || sides.allSatisfy { $0 <= 0 }
    }
}

struct SkillWheelHoverState {
    enum Hit: Equatable {
        case root(String), child(String), transit, outside

        var isChild: Bool {
            if case .child = self { return true }
            return false
        }
    }

    enum Pending: Equatable {
        case switchRoot(String), collapse
    }

    private(set) var hit = Hit.outside
    private(set) var active: String?
    private(set) var pending: Pending?

    mutating func move(to hit: Hit) {
        self.hit = hit
        switch hit {
        case .root(let id):
            if active == nil || active == id { selectRoot(id) }
            else { pending = .switchRoot(id) }
        case .child, .transit:
            pending = nil
        case .outside:
            pending = active == nil ? nil : .collapse
        }
    }

    mutating func selectRoot(_ id: String) {
        hit = .root(id)
        active = id
        pending = nil
    }

    mutating func settle(_ pending: Pending) {
        guard self.pending == pending else { return }
        switch pending {
        case .switchRoot(let id): selectRoot(id)
        case .collapse:
            active = nil
            self.pending = nil
        }
    }
}

private enum HarnessFolders {
    static let organizationThreshold = 6
    static let definitions: [(id: String, title: String, ringTitle: String?)] = [
        ("writing", "写作与编辑", "写作"), ("research", "资料与研究", "研究"), ("coding", "代码与开发", "代码"),
        ("planning", "规划与决策", "规划"), ("analysis", "数据与分析", "分析"),
        ("design", "设计与创作", "设计"), ("education", "学习与教学", "学习"),
        ("operations", "运维与自动化", "运维"), ("pending", "待整理", nil),
    ]

    static func category(_ id: String?) -> String {
        guard let id, definitions.contains(where: { $0.id == id }) else { return "pending" }
        return id
    }

    static func shouldSuggestOrganization(_ skills: [LibraryItem]) -> Bool {
        skills.count >= organizationThreshold && skills.contains(where: \.needsOrganization)
    }
}

private enum HarnessSkillPreview {
    private static let symbols = [
        "checklist": "checklist", "document": "doc.text", "code": "chevron.left.forwardslash.chevron.right",
        "search": "magnifyingglass", "chart": "chart.bar.xaxis", "calendar": "calendar",
        "message": "bubble.left", "edit": "pencil.line", "translate": "character.bubble",
        "idea": "lightbulb", "table": "tablecells", "book": "book", "link": "link", "folder": "folder",
    ]
    private static let groupSymbols = [
        "writing": "pencil.line", "research": "book", "coding": "chevron.left.forwardslash.chevron.right",
        "planning": "calendar", "analysis": "chart.bar.xaxis", "design": "paintbrush",
        "education": "graduationcap", "operations": "gearshape.2",
    ]

    static func symbol(for item: LibraryItem) -> String {
        if let icon = item.wheelPreview?.icon, let symbol = symbols[icon] { return symbol }
        return groupSymbols[item.group] ?? "doc.text"
    }

    static func summary(for item: LibraryItem) -> String {
        if let summary = shortPhrase(item.wheelPreview?.summary) ?? shortPhrase(item.description) { return summary }
        return L10n.text("用途待确认")
    }

    private static func shortPhrase(_ text: String?) -> String? {
        guard let text else { return nil }
        let phrase = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "。.!！?？"))
        guard !phrase.isEmpty, phrase.rangeOfCharacter(from: CharacterSet(charactersIn: "<>[]#`*")) == nil else { return nil }
        let han = phrase.unicodeScalars.filter { $0.properties.isIdeographic }.count
        let fits = han > 0 ? han <= 12 && phrase.count <= 30 : phrase.split(separator: " ").count <= 5 && phrase.count <= 40
        return fits ? phrase : nil
    }
}

private enum SkillInvocationPalette {
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let paperInk = adaptive(.black, .white)
    static let paperHairline = adaptive(.black.withAlphaComponent(0.32), .white.withAlphaComponent(0.38))
}

private final class SkillHoverPreview: ObservableObject {
    static let hoverDelay: TimeInterval = 2
    private static let exitDelay: TimeInterval = 0.30
    @Published private(set) var focused = false
    @Published private(set) var shownID: String?
    @Published private(set) var title = ""
    @Published private(set) var editsSource = false
    @Published var draft = ""
    @Published private(set) var saving = false
    @Published private(set) var error = ""
    @Published private(set) var refreshRevision = 0
    private var original = ""
    private var revision = ""
    private var requestedID: String?
    private var entryPoint = CGPoint.zero
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var wheel: NSPanel?
    private var panel: NSPanel?
    var didClose: (() -> Void)?
    private let mouseLocation: () -> CGPoint

    init(mouseLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.mouseLocation = mouseLocation
    }

    var isVisible: Bool { panel?.isVisible == true }
    var isDirty: Bool { isVisible && draft != original }
    var blocksWheel: Bool { focused || isDirty || saving }

    func attach(to wheel: NSPanel) { self.wheel = wheel }

    func consider(_ item: LibraryItem?) {
        let skill = item.flatMap { $0.kind == "skill" ? $0 : nil }
        let point = mouseLocation()
        if isVisible && (blocksWheel || protectsSelection(at: point)) { return }
        if requestedID == skill?.id { return }
        openWork?.cancel()
        requestedID = skill?.id
        if isVisible && shownID != skill?.id { scheduleClose() }
        guard let skill, shownID != skill.id else {
            if skill != nil { cancelClose() }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.requestedID == skill.id else { return }
            self.request("skill-preview", id: skill.id, readOnly: true) { [weak self] reply in
                guard let self, self.requestedID == skill.id, let wheel = self.wheel, wheel.isVisible,
                      wheel.frame.contains(self.mouseLocation()),
                      let text = reply?.text, let revision = reply?.revision else { return }
                self.show(skill, text: text, revision: revision)
            }
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    func protectsSelection(at point: CGPoint) -> Bool {
        guard let panel, panel.isVisible, let wheel else { return false }
        if panel.frame.contains(point) { return true }
        let edgeX = panel.frame.midX >= wheel.frame.midX ? panel.frame.minX : panel.frame.maxX
        return SkillPointerCorridor.contains(point, apex: entryPoint,
            edgeStart: CGPoint(x: edgeX, y: panel.frame.minY),
            edgeEnd: CGPoint(x: edgeX, y: panel.frame.maxY))
    }

    private func show(_ item: LibraryItem, text: String, revision: String) {
        guard let wheel, let screen = wheel.screen ?? NSScreen.main else { return }
        dismiss(notify: false)
        requestedID = item.id
        title = item.name
        editsSource = item.importMode != nil
        draft = text
        original = text
        self.revision = revision
        error = ""
        entryPoint = mouseLocation()
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(394, visible.width), height: min(312, visible.height))
        let right = wheel.frame.maxX + 8
        let left = wheel.frame.minX - size.width - 8
        let preferRight = right + size.width <= visible.maxX
            || left < visible.minX && visible.maxX - right >= wheel.frame.minX - visible.minX - 8
        let x = min(max(preferRight ? right : left, visible.minX), visible.maxX - size.width)
        let y = min(max(wheel.frame.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        let panel = SkillFloatingPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.text("Skill 原文")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        let hosting = SkillInvocationHostingView(rootView: SkillHoverPreviewView(preview: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        shownID = item.id
        wheel.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in self?.pointerMoved() }
        pointerMoved()
    }

    private func pointerMoved() {
        guard let panel, panel.isVisible, let wheel else { return }
        let point = mouseLocation()
        let inside = panel.frame.contains(point)
        if focused != inside { focused = inside }
        if inside || protectsSelection(at: point) || wheel.frame.contains(point) && shownID == requestedID {
            cancelClose()
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose() {
        guard closeWork == nil, isVisible, !isDirty && !saving else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard !self.isDirty, !self.saving, !self.protectsSelection(at: self.mouseLocation()) else { return }
            self.dismiss(preserveRequest: true)
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDelay, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    func dismiss(notify: Bool = true, preserveRequest: Bool = false) {
        let wasVisible = isVisible
        if !preserveRequest { requestedID = nil; openWork?.cancel(); openWork = nil }
        cancelClose()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let panel { wheel?.removeChildWindow(panel); panel.close() }
        panel = nil
        if shownID != nil { shownID = nil }
        if focused { focused = false }
        if notify && wasVisible { didClose?() }
    }

    func save() {
        guard isDirty, !saving, let shownID else { return }
        saving = true
        error = ""
        let text = draft
        request("save-skill-edit", id: shownID, fields: ["revision": revision, "text": text]) { [weak self] reply in
            guard let self else { return }
            self.saving = false
            if reply?.revision != nil {
                self.original = text
                self.refreshRevision += 1
                self.dismiss()
                return
            }
            switch reply?.error {
            case "changed": self.error = L10n.text("原文已在别处修改，请重新打开预览。")
            case "skill-dependencies": self.error = L10n.text("这条 Skill 已独立保存，无法加入文件或工具依赖。")
            case "duplicate-skill": self.error = L10n.text("库中已有同样的 Skill 正文。")
            case "invalid-skill": self.error = L10n.text("请输入有效的 Markdown 正文。")
            default: self.error = L10n.text("无法保存 Skill 修改。")
            }
        }
    }

    private func request(_ action: String, id: String, readOnly: Bool = false, fields: [String: Any] = [:],
                         completion: @escaping (LibraryReply?) -> Void) {
        var payload = fields
        payload["action"] = action
        payload["items"] = [id]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { completion(nil); return }
        LocalLibraryCommand.run(data, readOnly: readOnly, completion: completion)
    }
}

private struct SkillHoverPreviewView: View {
    @ObservedObject var preview: SkillHoverPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(preview.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button {
                    preview.dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text(preview.isDirty ? "放弃修改" : "关闭预览"))
                .disabled(preview.saving)
            }
            TextEditor(text: $preview.draft)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.64), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(L10n.text("Skill 原文"))
                .disabled(preview.saving)
            HStack {
                if !preview.error.isEmpty {
                    Text(preview.error).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
                }
                Spacer()
                if preview.isDirty {
                    Button(L10n.text("放弃修改")) { preview.dismiss() }.buttonStyle(.plain)
                }
                Button(L10n.text(preview.editsSource ? "保存源文件" : "保存修改"), action: preview.save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!preview.isDirty || preview.saving)
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(preview.focused ? 0 : 0.09))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(preview.focused ? Color.accentColor.opacity(0.72) : Theme.border)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.16), value: preview.focused)
    }
}

struct HarnessInvocation {
    let text: String
    let isMCP: Bool
}

final class SkillInvocationPanel: NSObject, NSWindowDelegate {
    private static let frameName = NSWindow.FrameAutosaveName("typeleast.harness-invocation")
    static let panelSize = NSSize(width: SkillRadialGeometry.wheelSize, height: SkillRadialGeometry.wheelSize)
    private var panel: NSPanel?
    private var releaseItem: LibraryItem?
    private var waitsForShortcutRelease = false
    private var preview: SkillHoverPreview?
    private var awaitingPreview = false
    private var invocation: ((HarnessInvocation) -> Void)?
    private(set) var generation = 0

    var isOpen: Bool { panel?.isVisible == true }
    var panelWindow: NSPanel? { panel }

    func show(targetName: String?, targetIcon: NSImage?, canInvoke: Bool = true, waitsForShortcutRelease: Bool = false,
              onSettings: @escaping () -> Void, onInvoke: @escaping (HarnessInvocation) -> Void) {
        guard !isOpen else { return }
        close()
        let size = Self.panelSize
        let window = SkillFloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        window.title = L10n.harnessTitle
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.minSize = size
        window.maxSize = size
        window.level = .normal
        window.isFloatingPanel = false
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        let preview = SkillHoverPreview()
        self.preview = preview
        preview.attach(to: window)
        preview.didClose = { [weak self] in
            guard let self, self.awaitingPreview else { return }
            self.close()
        }
        let hosting = SkillInvocationHostingView(rootView: SkillInvocationView(targetName: targetName, targetIcon: targetIcon, preview: preview,
            canInvoke: canInvoke, waitsForShortcutRelease: waitsForShortcutRelease,
            onClose: { [weak self] in self?.close() },
            onSettings: { [weak self] in self?.close(); onSettings() },
            onHoverSkill: { [weak self, weak window] id in
                guard let self, let window, self.panel === window, window.isVisible else { return }
                self.releaseItem = id
            },
            onInvoke: { [weak self, weak window] id in
                guard let self, let window, self.panel === window else { return }
                self.invoke(id)
            }))
        hosting.sizingOptions = []
        window.contentView = hosting
        panel = window
        generation += 1
        self.waitsForShortcutRelease = waitsForShortcutRelease
        invocation = canInvoke ? onInvoke : nil
        place(window, size: size)
        AppWindowStyle.fixSize(window, to: size)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func place(_ window: NSWindow, size: NSSize) {
        let restored = window.setFrameUsingName(Self.frameName)
        var frame = window.frame
        if restored {
            // Preserve the remembered top-left anchor while enforcing current panel dimensions.
            let topY = frame.maxY
            frame = NSRect(x: frame.minX, y: topY - size.height, width: size.width, height: size.height)
        }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if restored, let display = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            window.setFrame(window.constrainFrameRect(frame, to: display), display: false)
        } else {
            let cursor = NSEvent.mouseLocation
            if let display = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main {
                let visible = display.visibleFrame
                window.setFrame(NSRect(x: max(visible.minX, visible.maxX - size.width - 18),
                                       y: max(visible.minY, visible.maxY - size.height - 18),
                                       width: size.width, height: size.height), display: false)
            } else {
                window.setFrame(NSRect(origin: .zero, size: size), display: false)
                window.center()
            }
        }
    }

    func close() {
        awaitingPreview = false
        preview?.dismiss(notify: false)
        panel?.close()
    }

    func finishShortcut() {
        waitsForShortcutRelease = false
        if preview?.blocksWheel == true { awaitingPreview = true; return }
        if let item = releaseItem { invoke(item) } else { close() }
    }

    private func invoke(_ item: LibraryItem) {
        guard isOpen, preview?.blocksWheel != true, let invocation else { return }
        if waitsForShortcutRelease {
            releaseItem = item
            return
        }
        let currentGeneration = generation
        close()
        if item.kind == "mcp", let text = item.invocationText, !text.isEmpty {
            invocation(HarnessInvocation(text: text, isMCP: true))
            return
        }
        SkillInvocationRequest.read(item.id) { [weak self] result in
            guard self?.generation == currentGeneration else { return }
            switch result {
            case .success(let text): invocation(HarnessInvocation(text: text, isMCP: item.kind == "mcp"))
            case .failure(let error): HubFeedback.shared.show(error.message)
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, window.isVisible else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        panel = nil
        releaseItem = nil
        waitsForShortcutRelease = false
        preview?.dismiss(notify: false)
        preview = nil
        awaitingPreview = false
        invocation = nil
    }
}

private enum SkillInvocationFailure: Error {
    case sourceUnavailable
    case serviceUnavailable
    case ignored

    var message: String {
        switch self {
        case .sourceUnavailable: return L10n.text("来源已移动或不可读，请重新导入。")
        case .serviceUnavailable: return L10n.text("无法读取调用内容，请重试。")
        case .ignored: return L10n.text("此项目已从快捷滚轮隐藏。")
        }
    }
}

private enum SkillInvocationRequest {
    static func read(_ id: String, completion: @escaping (Result<String, SkillInvocationFailure>) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["action": "invoke", "items": [id]]) else {
            completion(.failure(.serviceUnavailable))
            return
        }
        LocalLibraryCommand.run(data, readOnly: true) { reply in
            guard let reply else {
                completion(.failure(.serviceUnavailable))
                return
            }
            if reply.error == "item-ignored" {
                completion(.failure(.ignored))
                return
            }
            guard let text = reply.text, !text.isEmpty else {
                completion(.failure(.sourceUnavailable))
                return
            }
            completion(.success(text))
        }
    }
}

private struct SkillInvocationView: View {
    let targetName: String?
    let targetIcon: NSImage?
    @ObservedObject var preview: SkillHoverPreview
    let canInvoke: Bool
    let waitsForShortcutRelease: Bool
    let onClose: () -> Void
    let onSettings: () -> Void
    let onHoverSkill: (LibraryItem?) -> Void
    let onInvoke: (LibraryItem) -> Void

    @State private var items: [LibraryItem] = []
    @State private var nav = SkillInvocationState()
    @State private var hover = SkillWheelHoverState()
    @State private var childNav = SkillInvocationState()
    // Pointer coordinates guide hit testing. Moving inside the same sector does not change the view.
    @State private var pointer = PointerTracking()

    private final class PointerTracking {
        var branchAnchor: CGPoint?
        var lastLocation: CGPoint?
    }

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let symbol: String?
        var fullTitle: String? = nil
        var skill: LibraryItem? = nil
        var children: [LibraryItem] = []
    }

    private static let organizeID = "organize"

    private var roots: [Entry] {
        let skills = items.filter { $0.kind == "skill" }
        let mcps = items.filter { $0.kind == "mcp" }
        let mcpFolder = mcps.isEmpty ? [] : [Entry(id: "folder:mcp", title: "MCP", symbol: "powerplug", children: mcps)]
        if skills.count <= 1 { return mcpFolder + skills.map(Self.entry(for:)) }
        var folders: [Entry] = []
        var assigned = Set<String>()
        for folder in HarnessFolders.definitions {
            guard let ringTitle = folder.ringTitle else { continue }
            let children = skills.filter { $0.group == folder.id }
            guard !children.isEmpty else { continue }
            folders.append(Entry(id: "folder:" + folder.id, title: L10n.text(ringTitle),
                                 symbol: "folder", fullTitle: L10n.text(folder.title), children: children))
            assigned.formUnion(children.map(\.id))
        }
        // Keep the settings entry on the first page when the library reaches the threshold.
        let needsOrganization = HarnessFolders.shouldSuggestOrganization(skills)
        let guide = needsOrganization ? [Entry(id: Self.organizeID, title: L10n.text("归类"), symbol: "gearshape",
                                              fullTitle: L10n.text("整理 Skill"))] : []
        return guide + mcpFolder + folders + skills.filter { !assigned.contains($0.id) }.map(Self.entry(for:))
    }

    private static func entry(for item: LibraryItem) -> Entry {
        Entry(id: item.id, title: item.name, symbol: nil, skill: item)
    }

    private var selection: LibraryItem? {
        switch hover.hit {
        case .root(let id) where hover.active == id:
            return roots.first { $0.id == id }?.skill
        case .child(let id):
            return roots.first { $0.id == hover.active }?.children.first { $0.id == id }
        default:
            return nil
        }
    }

    var body: some View {
        let all = roots
        let visible = Array(all[nav.pageIndices(for: all.count)])
        let root = visible.firstIndex { $0.id == hover.active }
        let children = root.map { visible[$0].children } ?? []
        let outer = Array(children[childNav.pageIndices(for: children.count)])
        let start = root.map { SkillRadialGeometry.sectorAngle(slot: $0, count: visible.count) } ?? -90
        let size = SkillRadialGeometry.wheelSize
        let innerSectors = visible.indices.map { slot in
            RoundedAnnularSector(centerAngle: SkillRadialGeometry.sectorAngle(slot: slot, count: visible.count),
                                 sweep: SkillRadialGeometry.sectorSweep(count: visible.count),
                                 innerRadius: SkillRadialGeometry.innerMinRadius, outerRadius: SkillRadialGeometry.innerMaxRadius)
        }
        let outerSectors = outer.indices.map { slot in
            RoundedAnnularSector(centerAngle: outerAngle(slot: slot, count: outer.count, start: start),
                                 sweep: SkillRadialGeometry.sectorSweep(count: outer.count),
                                 innerRadius: SkillRadialGeometry.outerMinRadius, outerRadius: SkillRadialGeometry.outerMaxRadius)
        }
        let rootZones = innerSectors.map(\.interactionShape)
        let childZones = outerSectors.map(\.interactionShape)
        let focusedGlass = innerSectors.indices.compactMap { $0 == root ? innerSectors[$0] : nil }
            + outerSectors.indices.compactMap { hover.hit == .child(outer[$0].id) ? outerSectors[$0] : nil }
        let selectedSector = outer.firstIndex { $0.id == selection?.id }.map { outerSectors[$0] }
            ?? root.flatMap { visible[$0].skill?.id == selection?.id ? innerSectors[$0] : nil }
        ZStack {
            center(selectedSector: selectedSector).zIndex(2)
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                Button {
                    if entry.id == Self.organizeID { onSettings() }
                    else if let skill = entry.skill, canInvoke { onInvoke(skill) }
                    else { selectRoot(entry.id) }
                } label: {
                    sector(title: entry.title, symbol: entry.symbol, shape: innerSectors[index], hitZone: rootZones[index])
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: entry.fullTitle ?? entry.title))
                .modifier(SkillWheelDrag(itemID: entry.skill?.id, onDrag: disarm))
                .accessibilityAddTraits(index == root ? .isSelected : [])
                .disabled(preview.blocksWheel)
            }
            ForEach(Array(outer.enumerated()), id: \.element.id) { slot, skill in
                Button {
                    if canInvoke { onInvoke(skill) }
                } label: {
                    sector(title: skill.name, symbol: skill.kind == "mcp" ? "powerplug" : nil,
                           shape: outerSectors[slot], hitZone: childZones[slot])
                }
                .buttonStyle(.plain)
                .modifier(SkillWheelDrag(itemID: skill.id, invocationText: skill.invocationText, onDrag: disarm))
                .accessibilityAddTraits(hover.hit == .child(skill.id) ? .isSelected : [])
                .disabled(preview.blocksWheel)
                .zIndex(1)
            }
        }
        .frame(width: size, height: size)
        .background {
            SkillRingGlass(sectors: innerSectors + outerSectors, focused: focusedGlass)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            if preview.focused {
                ZStack {
                    Circle().fill(.black.opacity(0.16))
                        .frame(width: SkillRadialGeometry.centerDiameter, height: SkillRadialGeometry.centerDiameter)
                    ForEach(innerSectors + outerSectors, id: \.self) { $0.fill(.black.opacity(0.16)) }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: preview.focused)
        .onContinuousHover { phase in
            guard !preview.blocksWheel else { return }
            switch phase {
            case .active(let point):
                pointer.lastLocation = point
                if preview.protectsSelection(at: NSEvent.mouseLocation) {
                    updateHover(.transit, trackPreview: false)
                    return
                }
                let next: SkillWheelHoverState.Hit
                switch SkillRadialGeometry.hit(at: point, roots: rootZones, children: childZones) {
                case .root(let slot): next = .root(visible[slot].id)
                case .child(let slot): next = .child(outer[slot].id)
                case nil: next = .outside
                }
                if let root, !children.isEmpty {
                    if next == .root(visible[root].id) {
                        pointer.branchAnchor = point
                    } else if !next.isChild, let branchAnchor = pointer.branchAnchor,
                              SkillRadialGeometry.branchCorridorContains(point, from: branchAnchor,
                                                                        angle: innerSectors[root].centerAngle) {
                        updateHover(.transit)
                        return
                    }
                }
                updateHover(next)
                if case .root(let id) = next, hover.active == id,
                   visible.contains(where: { $0.id == id && !$0.children.isEmpty }) {
                    pointer.branchAnchor = point
                }
            case .ended:
                pointer.lastLocation = nil
                let protected = preview.protectsSelection(at: NSEvent.mouseLocation)
                updateHover(protected ? .transit : .outside, trackPreview: !protected)
            }
        }
        .task(id: hover.pending) {
            guard let pending = hover.pending else { return }
            do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
            let before = hover.active
            hover.settle(pending)
            if before != hover.active { childNav = SkillInvocationState(); pointer.branchAnchor = pointer.lastLocation }
            syncSelection()
            preview.consider(selection)
        }
        .background {
            SkillInvocationKeyMonitor(
                onStep: { direction in
                    guard !preview.blocksWheel else { return }
                    guard !all.isEmpty else { return }
                    if let active = hover.active, let index = all.firstIndex(where: { $0.id == active }) {
                        nav.selectedIndex = index
                        nav.step(direction, total: all.count)
                    }
                    selectRoot(all[nav.selectedIndex].id)
                },
                onStepPage: changePage,
                onSelectSlot: { slot in
                    guard !preview.blocksWheel else { return }
                    if nav.selectSlot(slot, total: all.count) { selectRoot(all[nav.selectedIndex].id) }
                },
                onInvoke: {
                    if canInvoke, let selection { onInvoke(selection) }
                    else if hover.active == Self.organizeID { onSettings() }
                    else if let item = outer.first {
                        updateHover(.child(item.id))
                    }
                },
                onClose: onClose
            )
        }
        .background { SkillWheelScroll(stepItem: changePage, stepPage: changePage) }
        .onReceive(NotificationCenter.default.publisher(for: LocalLibraryCommand.wheelInvalidated)) { _ in onClose() }
        .task(id: preview.refreshRevision) {
            LocalLibraryCommand.run(Data(#"{"action":"list","surface":"wheel"}"#.utf8), readOnly: true) { reply in
                items = (reply?.items ?? [])
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                syncSelection()
            }
        }
    }

    private func center(selectedSector: RoundedAnnularSector?) -> some View {
        Group {
            if let selection {
                let showRelease = canInvoke && waitsForShortcutRelease && !preview.blocksWheel
                let showName = selectedSector.map {
                    let label = WheelSectorLabel(title: selection.name, symbol: nil, sector: $0)
                    let side = SkillRadialGeometry.wheelSize
                    let layout = label.layout(in: CGRect(x: 0, y: 0, width: side, height: side))
                    return layout.lines > 1 || label.titleWidth > layout.rect.width
                } ?? false
                VStack(spacing: showName ? 3 : 5) {
                    Image(systemName: selection.kind == "mcp" ? "powerplug" : HarnessSkillPreview.symbol(for: selection))
                        .font(.system(size: showName ? 14 : 19, weight: .medium))
                        .accessibilityHidden(true)
                    if showName {
                        Text(verbatim: selection.name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(showRelease ? 2 : 3)
                            .multilineTextAlignment(.center)
                    }
                    Text(verbatim: HarnessSkillPreview.summary(for: selection))
                        .font(.system(size: showName ? 9.5 : 11.5, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if showRelease {
                        Text(L10n.text("松开即可调用"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: showName ? 70 : 69)
                .frame(width: SkillRadialGeometry.centerDiameter, height: SkillRadialGeometry.centerDiameter)
                .clipShape(Circle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: selection.name))
                .accessibilityValue(Text(verbatim: HarnessSkillPreview.summary(for: selection)))
                .accessibilityHint(showRelease ? L10n.text("松开即可调用") : "")
            } else {
                HStack(spacing: 4) {
                    Group {
                        if let targetIcon { Image(nsImage: targetIcon).resizable().scaledToFit() }
                        else { Image(systemName: "app").resizable().scaledToFit() }
                    }
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
                    if let targetName {
                        Text(verbatim: targetName)
                            .font(.custom("AvenirNext-DemiBold", size: 11.5))
                            .lineLimit(2)
                            .frame(maxWidth: 54, alignment: .leading)
                    }
                }
            }
        }
        .foregroundStyle(SkillInvocationPalette.paperInk)
        .frame(width: SkillRadialGeometry.centerDiameter, height: SkillRadialGeometry.centerDiameter)
        .overlay(Circle().strokeBorder(SkillInvocationPalette.paperHairline))
    }

    private func sector(title: String, symbol: String?, shape: RoundedAnnularSector, hitZone: RoundedAnnularSector) -> some View {
        shape
            .stroke(SkillInvocationPalette.paperHairline, lineWidth: 1)
            .overlay {
                WheelSectorLabel(title: title, symbol: symbol, sector: shape)
                    .equatable()
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
            .contentShape(hitZone)
            .accessibilityLabel(Text(verbatim: title))
    }

    private func outerAngle(slot: Int, count: Int, start: Double) -> Double {
        start + SkillRadialGeometry.sectorAngle(slot: slot, count: count) + 90
    }

    private struct SkillRingGlass: NSViewRepresentable {
        let sectors: [RoundedAnnularSector]
        let focused: [RoundedAnnularSector]

        func makeNSView(context: Context) -> Backdrop { Backdrop(frame: .zero) }

        func updateNSView(_ view: Backdrop, context: Context) {
            view.update(sectors: sectors, focused: focused)
        }

        final class Backdrop: NSView {
            private let center = FrostedMaterial()
            private let rim = FrostedMaterial(sectors: [])
            private var sectors: [RoundedAnnularSector] = []
            private var focused: Set<RoundedAnnularSector> = []
            private var highlights: [RoundedAnnularSector: FrostedMaterial] = [:]
            private var retiring: [RoundedAnnularSector: UUID] = [:]

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                rim.isHidden = true
                addSubview(rim)

                let diameter = SkillRadialGeometry.centerDiameter
                center.identifier = NSUserInterfaceItemIdentifier("harness.center-glass")
                center.maskImage = NSImage(size: NSSize(width: diameter, height: diameter), flipped: true) { bounds in
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    context.setFillColor(NSColor.white.cgColor)
                    context.fillEllipse(in: bounds)
                    return true
                }
                addSubview(center)
            }

            required init?(coder: NSCoder) { fatalError("Harness EQ glass is created in code") }

            override func layout() {
                super.layout()
                let diameter = SkillRadialGeometry.centerDiameter
                center.frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                      width: diameter, height: diameter)
                rim.frame = bounds
                for highlight in highlights.values { highlight.frame = bounds }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            func update(sectors: [RoundedAnnularSector], focused next: [RoundedAnnularSector]) {
                if self.sectors != sectors {
                    self.sectors = sectors
                    rim.maskImage = Self.mask(for: sectors)
                    rim.veil.sectors = sectors
                    rim.isHidden = sectors.isEmpty
                }

                let nextFocus = Set(next)
                guard focused != nextFocus else { return }
                let entering = nextFocus.subtracting(focused)
                let leaving = focused.subtracting(nextFocus)
                focused = nextFocus

                let transition = UUID()
                for sector in leaving { retiring[sector] = transition }
                for sector in entering {
                    retiring.removeValue(forKey: sector)
                    if highlights[sector] == nil {
                        let material = FrostedMaterial(sectors: [sector], highlighted: true)
                        material.frame = bounds
                        material.maskImage = Self.mask(for: [sector])
                        material.alphaValue = 0
                        addSubview(material, positioned: .below, relativeTo: center)
                        highlights[sector] = material
                    }
                }

                let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reducedMotion ? 0 : 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    for sector in leaving { highlights[sector]?.animator().alphaValue = 0 }
                    for sector in entering { highlights[sector]?.animator().alphaValue = 0.94 }
                } completionHandler: { [weak self] in
                    guard let self else { return }
                    for sector in leaving where self.retiring[sector] == transition {
                        self.highlights.removeValue(forKey: sector)?.removeFromSuperview()
                        self.retiring.removeValue(forKey: sector)
                    }
                }
            }

            private static func mask(for sectors: [RoundedAnnularSector]) -> NSImage {
                let side = SkillRadialGeometry.wheelSize
                return NSImage(size: NSSize(width: side, height: side), flipped: true) { bounds in
                    guard let context = NSGraphicsContext.current?.cgContext else { return false }
                    context.setFillColor(NSColor.white.cgColor)
                    for sector in sectors { context.addPath(sector.path(in: bounds).cgPath) }
                    context.fillPath()
                    return true
                }
            }
        }

        private final class FrostedMaterial: NSVisualEffectView {
            let veil: FrostedVeil

            init(sectors: [RoundedAnnularSector]? = nil, highlighted: Bool = false) {
                veil = FrostedVeil(sectors: sectors, highlighted: highlighted)
                super.init(frame: .zero)
                material = highlighted ? .popover : .menu
                blendingMode = .behindWindow
                state = .active
                addSubview(veil)
            }

            required init?(coder: NSCoder) { fatalError("Harness EQ glass is created in code") }

            override func layout() {
                super.layout()
                veil.frame = bounds
            }
        }

        private final class FrostedVeil: NSView {
            var sectors: [RoundedAnnularSector]? {
                didSet { needsDisplay = true }
            }
            private let highlighted: Bool
            override var isFlipped: Bool { true }

            init(sectors: [RoundedAnnularSector]?, highlighted: Bool) {
                self.sectors = sectors
                self.highlighted = highlighted
                super.init(frame: .zero)
                identifier = NSUserInterfaceItemIdentifier("harness.frosted-veil")
            }

            required init?(coder: NSCoder) { fatalError("Harness EQ glass is created in code") }

            override func viewDidChangeEffectiveAppearance() {
                super.viewDidChangeEffectiveAppearance()
                needsDisplay = true
            }

            override func draw(_ dirtyRect: NSRect) {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                let background = NSColor.windowBackgroundColor
                let tint = highlighted ? background.blended(withFraction: 0.09, of: .labelColor) ?? background : background
                // A dense veil suppresses backdrop text even when System Settings allows transparency.
                context.setFillColor(tint.withAlphaComponent(0.98).cgColor)
                if let sectors {
                    for sector in sectors { context.addPath(sector.path(in: bounds).cgPath) }
                } else {
                    context.addEllipse(in: bounds)
                }
                context.fillPath()
            }
        }
    }

    private func updateHover(_ hit: SkillWheelHoverState.Hit, trackPreview: Bool = true) {
        guard hover.hit != hit else { return }
        let before = hover.active
        hover.move(to: hit)
        if before != hover.active { childNav = SkillInvocationState(); pointer.branchAnchor = nil }
        syncSelection()
        if trackPreview { preview.consider(selection) }
    }

    private func selectRoot(_ id: String) {
        if hover.active != id { childNav = SkillInvocationState(); pointer.branchAnchor = nil }
        hover.selectRoot(id)
        syncSelection()
        preview.consider(nil)
    }

    private func syncSelection() { onHoverSkill(canInvoke ? selection : nil) }

    private func disarm() { updateHover(.outside) }

    private func changePage(_ direction: Int) {
        guard !preview.blocksWheel else { return }
        if case .child = hover.hit, let branch = roots.first(where: { $0.id == hover.active }), childNav.pageCount(for: branch.children.count) > 1 {
            childNav.stepPage(direction, total: branch.children.count)
            if let index = branch.children.indices.contains(childNav.selectedIndex) ? childNav.selectedIndex : nil {
                updateHover(.child(branch.children[index].id))
            }
            return
        }
        guard nav.pageCount(for: roots.count) > 1 else { return }
        nav.stepPage(direction, total: roots.count)
        hover = SkillWheelHoverState()
        childNav = SkillInvocationState()
        pointer.branchAnchor = nil
        onHoverSkill(nil)
        preview.consider(nil)
    }
}

private struct SkillWheelDrag: ViewModifier {
    let itemID: String?
    var invocationText: String? = nil
    let onDrag: () -> Void

    func body(content: Content) -> some View {
        if let itemID {
            content.onDrag {
                onDrag()
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                    if let invocationText {
                        completion(Data(invocationText.utf8), nil)
                        return nil
                    }
                    SkillInvocationRequest.read(itemID) { result in
                        switch result {
                        case .success(let text): completion(Data(text.utf8), nil)
                        case .failure: completion(nil, CocoaError(.fileReadNoSuchFile))
                        }
                    }
                    return nil
                }
                return provider
            }
        } else {
            content
        }
    }
}

private struct WheelSectorLabel: View, Equatable {
    let title: String
    let symbol: String?
    let sector: RoundedAnnularSector
    private var isOuter: Bool { sector.innerRadius >= SkillRadialGeometry.outerMinRadius }
    private var keepsOneLine: Bool { symbol != nil && !isOuter }
    private var fontSize: CGFloat { isOuter || keepsOneLine ? 12 : 13 }
    var titleWidth: CGFloat {
        (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize,
                                                                          weight: symbol == nil ? .medium : .semibold)]).width
    }

    func layout(in bounds: CGRect) -> WheelSectorLabelLayout {
        sector.labelLayout(in: bounds, singleLineWidth: keepsOneLine ? 0 : titleWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = self.layout(in: CGRect(origin: .zero, size: geometry.size))
            HStack(spacing: 3) {
                if let symbol, layout.rect.width >= max(54, titleWidth + 15) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .medium))
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(.system(size: fontSize, weight: symbol == nil ? .medium : .semibold))
                    .lineLimit(layout.lines)
                    .lineSpacing(-1)
                    .minimumScaleFactor(keepsOneLine ? 0.88 : 1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(SkillInvocationPalette.paperInk)
            .frame(width: layout.rect.width, height: layout.rect.height)
            .rotationEffect(.radians(layout.angle))
            .position(x: layout.rect.midX, y: layout.rect.midY)
        }
    }
}

struct WheelSectorLabelLayout {
    let rect: CGRect
    let lines: Int
    let angle: Double

    func rotate(_ point: CGPoint, around center: CGPoint, by angle: Double) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(angle) - dy * sin(angle),
                       y: center.y + dx * sin(angle) + dy * cos(angle))
    }

    func pointInSector(_ point: CGPoint) -> CGPoint {
        rotate(point, around: CGPoint(x: rect.midX, y: rect.midY), by: angle)
    }
}

/// Visible outline and the matching, more forgiving hit zone.
struct RoundedAnnularSector: Shape, Hashable {
    let centerAngle: Double
    let sweep: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    var roundsCorners = true

    var interactionShape: Self {
        let outer = innerRadius >= SkillRadialGeometry.outerMinRadius
        return Self(centerAngle: centerAngle, sweep: min(360, sweep + (outer ? 2.75 : 2)),
                    innerRadius: innerRadius - (outer ? 14 : 7),
                    outerRadius: outer ? SkillRadialGeometry.outerHitMaxRadius : outerRadius + 4,
                    roundsCorners: false)
    }

    func labelLayout(in bounds: CGRect, singleLineWidth: CGFloat = .infinity) -> WheelSectorLabelLayout {
        let outline = path(in: bounds).cgPath
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let angle = centerAngle * .pi / 180
        let tangent = (angle + .pi / 2).remainder(dividingBy: .pi)
        let maxTilt = 50 * Double.pi / 180
        let tilt = innerRadius >= SkillRadialGeometry.outerMinRadius ? min(max(tangent, -maxTilt), maxTilt) : 0
        let radius = (innerRadius + outerRadius) / 2
        let inset: CGFloat = 3

        func widestRect(height: CGFloat) -> CGRect {
            var best = CGRect.zero
            for offset: CGFloat in [0, -2, 2, -4, 4] {
                let x = center.x + cos(angle) * (radius + offset)
                let y = center.y + sin(angle) * (radius + offset)
                func rect(width: CGFloat) -> CGRect {
                    CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
                }
                func fits(width: CGFloat) -> Bool {
                    let box = WheelSectorLabelLayout(rect: rect(width: width), lines: 1, angle: tilt)
                    let padded = box.rect.insetBy(dx: -inset, dy: -inset)
                    let axis = box.rotate(center, around: CGPoint(x: x, y: y), by: -tilt)
                    let nearest = CGPoint(x: min(max(axis.x, padded.minX), padded.maxX),
                                          y: min(max(axis.y, padded.minY), padded.maxY))
                    guard hypot(nearest.x - axis.x, nearest.y - axis.y) >= innerRadius else { return false }
                    return [padded.minY, padded.midY, padded.maxY].allSatisfy { sampleY in
                        [padded.minX, padded.midX, padded.maxX].allSatisfy { sampleX in
                            outline.contains(box.pointInSector(CGPoint(x: sampleX, y: sampleY)))
                        }
                    }
                }
                var minWidth: CGFloat = 0
                var maxWidth: CGFloat = 112
                while maxWidth - minWidth >= 1 {
                    let width = (minWidth + maxWidth) / 2
                    if fits(width: width) { minWidth = width } else { maxWidth = width }
                }
                if minWidth > best.width { best = rect(width: minWidth) }
            }
            return best
        }

        let oneLine = widestRect(height: 18)
        if oneLine.width >= singleLineWidth + 1 {
            return WheelSectorLabelLayout(rect: oneLine, lines: 1, angle: tilt)
        }
        let twoLines = widestRect(height: 29)
        if twoLines.width >= 30, twoLines.width * 1.65 >= oneLine.width {
            return WheelSectorLabelLayout(rect: twoLines, lines: 2, angle: tilt)
        }
        return WheelSectorLabelLayout(rect: oneLine, lines: 1, angle: tilt)
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        if sweep >= 359.5 {
            path.addArc(center: center, radius: outerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            path.move(to: CGPoint(x: center.x + innerRadius, y: center.y))
            path.addArc(center: center, radius: innerRadius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
            path.closeSubpath()
            return path
        }

        let startDeg = centerAngle - sweep / 2
        let endDeg = centerAngle + sweep / 2
        let thickness = outerRadius - innerRadius
        let availableArc = innerRadius * CGFloat(sweep * .pi / 180)
        let cr = roundsCorners ? min(thickness * 0.23, availableArc * 0.17) : 0
        let outerInsetDeg = Double(cr / max(outerRadius, 1)) * 180.0 / .pi
        let innerInsetDeg = Double(cr / max(innerRadius, 1)) * 180.0 / .pi

        let oStart = Angle.degrees(startDeg + outerInsetDeg)
        let oEnd = Angle.degrees(endDeg - outerInsetDeg)
        let iEnd = Angle.degrees(endDeg - innerInsetDeg)
        let iStart = Angle.degrees(startDeg + innerInsetDeg)

        func pt(_ r: CGFloat, _ deg: Double) -> CGPoint {
            let rad = deg * .pi / 180.0
            return CGPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad))
        }

        func direction(_ deg: Double) -> CGVector {
            let rad = deg * .pi / 180
            return CGVector(dx: cos(rad), dy: sin(rad))
        }

        // Match the line and arc tangents so each corner eases into both edges.
        func corner(to end: CGPoint, from startDirection: Double, to endDirection: Double) {
            let start = path.currentPoint ?? end
            let incoming = direction(startDirection)
            let outgoing = direction(endDirection)
            let handle = cr * 0.63
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + incoming.dx * handle, y: start.y + incoming.dy * handle),
                          control2: CGPoint(x: end.x - outgoing.dx * handle, y: end.y - outgoing.dy * handle))
        }

        path.move(to: pt(outerRadius - cr, startDeg))
        corner(to: pt(outerRadius, oStart.degrees), from: startDeg, to: oStart.degrees + 90)
        path.addArc(center: center, radius: outerRadius, startAngle: oStart, endAngle: oEnd, clockwise: false)
        corner(to: pt(outerRadius - cr, endDeg), from: oEnd.degrees + 90, to: endDeg + 180)
        path.addLine(to: pt(innerRadius + cr, endDeg))
        corner(to: pt(innerRadius, iEnd.degrees), from: endDeg + 180, to: iEnd.degrees - 90)
        path.addArc(center: center, radius: innerRadius, startAngle: iEnd, endAngle: iStart, clockwise: true)
        corner(to: pt(innerRadius + cr, startDeg), from: iStart.degrees - 90, to: startDeg)
        path.closeSubpath()
        return path
    }
}

private struct SkillInvocationKeyMonitor: NSViewRepresentable {
    let onStep: (Int) -> Void
    let onStepPage: (Int) -> Void
    let onSelectSlot: (Int) -> Void
    let onInvoke: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> KeyMonitorView { KeyMonitorView() }

    func updateNSView(_ view: KeyMonitorView, context: Context) {
        view.onStep = onStep
        view.onStepPage = onStepPage
        view.onSelectSlot = onSelectSlot
        view.onInvoke = onInvoke
        view.onClose = onClose
    }

    final class KeyMonitorView: NSView {
        var onStep: ((Int) -> Void)?
        var onStepPage: ((Int) -> Void)?
        var onSelectSlot: ((Int) -> Void)?
        var onInvoke: (() -> Void)?
        var onClose: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                    if let digit = Int(chars), (1...SkillInvocationState.pageSize).contains(digit) {
                        self.onSelectSlot?(digit - 1)
                        return nil
                    }
                }

                switch event.keyCode {
                case 126: // Up Arrow
                    guard flags.isEmpty || flags == .numericPad || flags == .function else { return event }
                    self.onStep?(-1)
                    return nil
                case 125: // Down Arrow
                    guard flags.isEmpty || flags == .numericPad || flags == .function else { return event }
                    self.onStep?(1)
                    return nil
                case 123: // Left Arrow
                    guard flags.isEmpty || flags == .numericPad || flags == .function else { return event }
                    self.onStepPage?(-1)
                    return nil
                case 124: // Right Arrow
                    guard flags.isEmpty || flags == .numericPad || flags == .function else { return event }
                    self.onStepPage?(1)
                    return nil
                case 116: // Page Up
                    self.onStepPage?(-1)
                    return nil
                case 121: // Page Down
                    self.onStepPage?(1)
                    return nil
                case 36, 76: // Return / Keypad Enter
                    guard flags.isEmpty else { return event }
                    self.onInvoke?()
                    return nil
                case 53: // Escape
                    self.onClose?()
                    return nil
                default:
                    return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct SkillWheelScroll: NSViewRepresentable {
    let stepItem: (Int) -> Void
    let stepPage: (Int) -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) {
        view.stepItem = stepItem
        view.stepPage = stepPage
    }

    final class WheelView: NSView {
        var stepItem: ((Int) -> Void)?
        var stepPage: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulatedY: CGFloat = 0
        private var accumulatedX: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                    return event
                }
                if event.phase == .began || event.phase == .ended {
                    self.accumulatedY = 0
                    self.accumulatedX = 0
                }
                if !event.momentumPhase.isEmpty { return nil }

                let shiftHeld = event.modifierFlags.contains(.shift)
                let horizontal = shiftHeld || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5
                let delta = horizontal
                    ? (abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY)
                    : event.scrollingDeltaY

                if event.hasPreciseScrollingDeltas {
                    if horizontal {
                        self.accumulatedX += delta
                        guard abs(self.accumulatedX) >= 34 else { return nil }
                        let dir = self.accumulatedX < 0 ? 1 : -1
                        self.accumulatedX = 0
                        self.stepPage?(dir)
                    } else {
                        self.accumulatedY += delta
                        guard abs(self.accumulatedY) >= 22 else { return nil }
                        let dir = self.accumulatedY < 0 ? 1 : -1
                        self.accumulatedY = 0
                        self.stepItem?(dir)
                    }
                } else if delta != 0 {
                    let dir = delta < 0 ? 1 : -1
                    if horizontal { self.stepPage?(dir) } else { self.stepItem?(dir) }
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct LibraryFileImportView: View {
    let kind: LibraryKind
    let enabled: Bool
    let onImport: (LibraryFileImportResult, [String]) -> Void
    @Environment(\.windowHoverPointer) private var windowPointer

    @State private var dragOver = false
    @State private var importing = false
    @State private var result: LibraryFileImportResult?
    @State private var failure = ""
    @State private var paths: [String] = []
    @State private var rows: [LibraryImportRow] = []
    @State private var modes: [String: String] = [:]
    @State private var savedOriginals: [SavedSkillMarkdown] = []
    @State private var confirmingTrash = false
    @State private var movedToTrash = 0
    @State private var token: String?
    @State private var reviewing = false
    @State private var scanning = false
    @State private var scannedKind: LibraryKind?
    @State private var providersByID: [String: [String]] = [:]
    @State private var githubURL = ""
    @State private var githubImport: GitHubImport?

    private struct GitHubImport {
        let url: String
        let kind: LibraryKind
        let revision: GitHubImportRevision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryFileDropArea(enabled: enabled && !importing && !scanning, targeted: { dragOver = $0 }, receive: submit) {
                HStack(alignment: .center, spacing: 14) {
                    if importing || scanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "tray.and.arrow.down").font(.system(size: 24)).foregroundStyle(Theme.secondary) }
                    Text(L10n.text("拖入 Skill、Markdown 或 MCP 配置")).font(Theme.rowFont)
                    Spacer(minLength: 0)
                    Button(L10n.text(kind == .mcp ? "扫描本机 MCP" : "扫描本机 Skill")) { scanLocal(kind) }
                        .buttonStyle(SecondaryButtonStyle(feedback: .magnetic))
                        .disabled(importing || scanning || !enabled)
                    Button(L10n.text("选择文件"), action: chooseFiles)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(importing || scanning || !enabled)
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 92)
                .environment(\.windowHoverPointer, windowPointer)
            }
            .hoverCard(dragOver ? Theme.selection : Theme.card, radius: Theme.listGroupRadius,
                       border: dragOver ? Theme.accent : Theme.border,
                       stroke: StrokeStyle(lineWidth: dragOver ? 2 : 1, dash: [5, 4]), enabled: !dragOver)
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                TextField(L10n.text("GitHub 链接"), text: $githubURL)
                    .onSubmit(startGitHubImport)
                Button(L10n.text("从 GitHub 导入"), action: startGitHubImport)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(githubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(!enabled || importing || scanning)
            if let result {
                Text(L10n.text("已导入 {0} 个 Skill 和 {1} 个 MCP",
                               result.skills + (result.skillReferences ?? 0),
                               result.mcp + result.references))
                    .font(Theme.rowFont)
                if result.dependentSkills > 0 {
                    Text(L10n.text("跳过 {0} 个依赖其他文件或工具的 Markdown。", result.dependentSkills))
                }
                if result.duplicates > 0 {
                    Text(L10n.text("{0} 项已在库里。", result.duplicates))
                }
                if result.conflicts > 0 {
                    Text(L10n.text("{0} 个同名 MCP 配置不同，保留库里的版本。", result.conflicts))
                }
                if result.skipped > 0 {
                    Text(L10n.text("{0} 个文件无法识别或读取。", result.skipped))
                }
                if movedToTrash > 0 {
                    Text(L10n.text("已将 {0} 个原文件移到废纸篓。", movedToTrash))
                }
            }
            if !failure.isEmpty { Text(failure).foregroundStyle(Theme.warning) }
        }
        .font(Theme.captionFont)
        .sheet(isPresented: $reviewing, onDismiss: showTrashConfirmation) { importReview }
        .alert(L10n.text("把原文件移到废纸篓？"), isPresented: $confirmingTrash) {
            Button(L10n.text("保留原文件"), role: .cancel) { savedOriginals = [] }
            Button(L10n.text("移到废纸篓"), role: .destructive, action: trashSavedOriginals)
        } message: {
            Text(L10n.text("{0} 份 Markdown 已保存在 TypeLeast。", savedOriginals.count))
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            if response == .OK && !importing {
                submit(panel.urls)
            }
        }
    }

    private func submit(_ files: [URL]) {
        result = nil
        failure = ""
        scannedKind = nil
        githubImport = nil
        providersByID = [:]
        paths = files.filter(\.isFileURL).map(\.path)
        previewImport()
    }

    private func scanLocal(_ scanKind: LibraryKind, sourceChanged: Bool = false) {
        result = nil
        failure = sourceChanged ? L10n.text("源文件变了，请重新核对后再确认。") : ""
        scanning = true
        githubImport = nil
        let request = scanKind == .mcp ? #"{"action":"scan-mcps"}"# : #"{"action":"scan-skills"}"#
        LocalLibraryCommand.run(Data(request.utf8), readOnly: true) { reply in
            scanning = false
            guard let imports = reply?.imports, let proof = reply?.token else {
                failure = L10n.text("扫描失败，请重试。")
                return
            }
            guard !imports.isEmpty else {
                reviewing = false
                failure = L10n.text(scanKind == .mcp ? "没有找到可导入的新 MCP。" : "没有找到可导入的新 Skill。")
                return
            }
            scannedKind = scanKind
            providersByID = Dictionary(uniqueKeysWithValues: imports.map { ($0.id, $0.providers ?? []) })
            paths = imports.map(\.path)
            presentReview(imports, token: proof)
        }
    }

    private func startGitHubImport() {
        let url = githubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !importing, !scanning, !url.isEmpty else { return }
        let requestedKind = kind
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "action": "preview-github-import", "url": url, "kind": requestedKind.rawValue
        ]) else { return }
        result = nil
        failure = ""
        scannedKind = nil
        githubImport = nil
        providersByID = [:]
        paths = []
        token = nil
        movedToTrash = 0
        importing = true
        LocalLibraryCommand.run(data, readOnly: true, timeout: 65) { reply in
            importing = false
            guard let imports = reply?.imports, let proof = reply?.token, let revision = reply?.githubRevision else {
                failure = githubFailure(reply?.error)
                return
            }
            guard !imports.isEmpty else {
                failure = L10n.text(requestedKind == .skill ? "链接中没有可导入的 Skill。" : "链接中没有可导入的 MCP 配置。")
                return
            }
            githubImport = GitHubImport(url: url, kind: requestedKind, revision: revision)
            presentReview(imports, token: proof, showingSheet: imports.count > 1)
            if let only = imports.first, imports.count == 1 {
                modes[only.id] = "full"
                confirmImport()
            }
        }
    }

    private func githubFailure(_ code: String?) -> String {
        switch code {
        case "github-link": return L10n.text("请填写 GitHub 仓库、目录或文件的 HTTPS 链接。")
        case "github-rate-limit": return L10n.text("GitHub 暂时限制了请求，请稍后再试。")
        case "github-too-large": return L10n.text("链接范围过大，请打开要导入的目录或文件。")
        case "github-no-skill": return L10n.text("链接中没有可导入的 Skill。")
        case "library-full": return L10n.text("{0} 空间已满。", L10n.harnessTitle)
        case "changed": return L10n.text("请重新打开链接并确认导入。")
        default: return L10n.text("无法读取公开 GitHub 链接，请检查链接或网络。")
        }
    }

    private func previewImport(automaticallySave: Bool = true) {
        guard !paths.isEmpty,
              let request = try? JSONSerialization.data(withJSONObject: ["action": "preview-import", "paths": paths]) else {
            importing = false
            failure = L10n.text("没有找到可导入的文件。")
            return
        }
        token = nil
        importing = true
        LocalLibraryCommand.run(request) { reply in
            importing = false
            guard let imports = reply?.imports, !imports.isEmpty, let proof = reply?.token else {
                failure = L10n.text("无法导入工具文件，请重试。")
                return
            }
            let automatic = automaticallySave && scannedKind == nil && imports.allSatisfy { $0.canSaveMarkdown == true }
            presentReview(imports, token: proof, showingSheet: !automatic)
            if automatic { confirmImport() }
        }
    }

    private func presentReview(_ imports: [LibraryImportRow], token: String, showingSheet: Bool = true) {
        rows = imports
        let askForSelection = scannedKind != nil || githubImport != nil
        modes = Dictionary(uniqueKeysWithValues: imports.map { ($0.id, askForSelection ? "skip" : $0.initialMode) })
        self.token = token
        reviewing = showingSheet
    }

    private func confirmImport() {
        if let githubImport {
            confirmGitHubImport(githubImport)
            return
        }
        let confirmAction = scannedKind == .mcp ? "confirm-mcp-scan" : "confirm-import"
        guard let token,
              let request = try? JSONSerialization.data(withJSONObject: [
                "action": confirmAction, "paths": paths, "token": token, "modes": modes, "centralizeMarkdown": true
              ]) else { return }
        movedToTrash = 0
        failure = ""
        importing = true
        LocalLibraryCommand.run(request) { reply in
            if reply?.error == "changed" {
                if scannedKind == .mcp {
                    importing = false
                    self.token = nil
                    scanLocal(.mcp, sourceChanged: true)
                    return
                }
                failure = L10n.text("源文件变了，请重新核对后再确认。")
                previewImport(automaticallySave: false)
                return
            }
            guard let imported = reply?.importedFiles else {
                importing = false
                failure = reply?.error == "library-full"
                    ? L10n.text("{0} 空间已满。", L10n.harnessTitle) : L10n.text("无法导入工具文件，请重试。")
                return
            }
            finishImport(imported, reply: reply)
        }
    }

    private func confirmGitHubImport(_ source: GitHubImport) {
        guard let token,
              let request = try? JSONSerialization.data(withJSONObject: [
                "action": "confirm-github-import", "url": source.url, "kind": source.kind.rawValue,
                "revision": ["ref": source.revision.ref, "commit": source.revision.commit],
                "token": token, "modes": modes
              ]) else { return }
        importing = true
        failure = ""
        LocalLibraryCommand.run(request, timeout: 65) { reply in
            guard let imported = reply?.importedFiles else {
                importing = false
                failure = githubFailure(reply?.error)
                return
            }
            githubURL = ""
            finishImport(imported, reply: reply)
        }
    }

    private func finishImport(_ imported: LibraryFileImportResult, reply: LibraryReply?) {
        result = imported
        savedOriginals = reply?.savedMarkdown ?? []
        importing = false
        if reviewing { reviewing = false } else { showTrashConfirmation() }
        onImport(imported, reply?.speakIds ?? [])
    }

    private func showTrashConfirmation() {
        if !savedOriginals.isEmpty { confirmingTrash = true }
    }

    private func trashSavedOriginals() {
        let originals = savedOriginals
        savedOriginals = []
        struct Request: Encodable {
            let action = "verify-markdown-trash"
            let copies: [SavedSkillMarkdown]
        }
        guard let data = try? JSONEncoder().encode(Request(copies: originals)) else { return }
        importing = true
        LocalLibraryCommand.run(data, readOnly: true) { reply in
            let copies = reply?.savedMarkdown ?? []
            DispatchQueue.global(qos: .utility).async {
                let trashed = copies.reduce(0) { $0 + ($1.trashOriginal() ? 1 : 0) }
                DispatchQueue.main.async {
                    movedToTrash = trashed
                    let failed = originals.count - trashed
                    if failed > 0 { failure = L10n.text("{0} 个原文件未能移到废纸篓。", failed) }
                    importing = false
                }
            }
        }
    }

    private var importReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scannedKind.map { L10n.text($0 == .mcp ? "扫描到 {0} 个 MCP" : "扫描到 {0} 个 Skill", rows.count) }
                 ?? L10n.text("确认导入"))
                .font(.title3.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(row.name).font(Theme.rowFont)
                                Spacer(minLength: 0)
                                ForEach(row.providers ?? providersByID[row.id] ?? [], id: \.self) { provider in
                                    SkillSourceIcon(provider: provider)
                                }
                            }
                            Text(row.path).textSelection(.enabled)
                                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
                            if row.kind == "unknown" {
                                Text(L10n.text("找不到可读的 SKILL.md 或 MCP 配置。"))
                            } else {
                                if row.kind == "skill" && githubImport == nil {
                                    Text(L10n.text(row.dependencies ? "有文件或工具依赖" : "纯提示词"))
                                    let details = (row.fields ?? []) + (row.relatedFiles ?? [])
                                    if !details.isEmpty { Text(details.joined(separator: " · ")) }
                                    if row.usesFiles == true { Text(L10n.text("正文引用了其他文件。")) }
                                }
                                Picker(L10n.text("导入方式"), selection: Binding(
                                    get: { modes[row.id] ?? "skip" }, set: { modes[row.id] = $0 }
                                )) {
                                    let full = row.kind == "mcp" ? "保存调用头" :
                                        row.canSaveMarkdown == true || (githubImport != nil && row.kind == "skill") ? "存入 TypeLeast" :
                                        row.selectionID != nil && row.dependencies ? "保存来源" :
                                        row.kind == "skill" && row.dependencies ? "导入正文与来源" : "完整导入"
                                    Label(L10n.text(full), systemImage: "doc.text").tag("full")
                                    if row.kind == "skill" && githubImport == nil {
                                        Label(L10n.text("保存来源"), systemImage: "link").tag("reference")
                                    }
                                    Label(L10n.text("不导入"), systemImage: "minus.circle").tag("skip")
                                }
                                .fixedSize()
                                .hoverFeedback(.fixed)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.listGroupRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.listGroupRadius).strokeBorder(
                            modes[row.id, default: "skip"] == "skip" ? Theme.border : Theme.accent, lineWidth: 1))
                    }
                }
            }
            .disabled(importing || scanning)
            if !failure.isEmpty { Text(failure).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button(L10n.text("取消")) { reviewing = false }.keyboardShortcut(.cancelAction).hoverFeedback(.fixed).disabled(importing)
                Button(L10n.text("确认导入"), action: confirmImport).keyboardShortcut(.defaultAction)
                    .hoverFeedback()
                    .disabled(importing || scanning || token == nil || !modes.values.contains { $0 != "skip" })
            }
        }
        .padding(20)
        .frame(width: 590, height: 450)
        .interactiveDismissDisabled(importing)
    }
}

private struct SkillSourceIcon: View {
    let provider: String

    private static let appIcons: [String: NSImage] = {
        let workspace = NSWorkspace.shared
        let applications = [
            ("OpenCode", "ai.opencode.desktop"),
            ("Codex", "local.codex.shadowrocket-dock"),
            ("VS Code", "com.microsoft.VSCode"),
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ]
        return Dictionary(uniqueKeysWithValues: applications.compactMap { name, id in
            guard let url = workspace.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (name, workspace.icon(forFile: url.path))
        })
    }()

    @ViewBuilder
    var body: some View {
        let title = provider == "Shared" ? L10n.text("共享目录") : provider
        Group {
            switch provider {
            case "DeepSeek Harness": EngineLogo(brand: .deepseek)
            case "ChatGPT": EngineLogo(brand: .openai)
            case "Claude Code", "Claude Desktop": EngineLogo(brand: .claude)
            default:
                if let image = Self.appIcons[provider] {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 22, height: 22)
                } else {
                    Image(systemName: provider == "Shared" ? "folder" : provider == "GitHub" ? "link" : "terminal")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                        .frame(width: 22, height: 22)
                }
            }
        }
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

private struct LibraryFileDropArea<Content: View>: NSViewRepresentable {
    let enabled: Bool
    let targeted: (Bool) -> Void
    let receive: ([URL]) -> Void
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> DropArea {
        DropArea(rootView: content)
    }

    func updateNSView(_ view: DropArea, context: Context) {
        view.rootView = content
        view.enabled = enabled
        view.targeted = targeted
        view.receive = receive
        view.registerForDraggedTypes([.fileURL])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DropArea, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    final class DropArea: NSHostingView<Content> {
        var enabled = false
        var targeted: ((Bool) -> Void)?
        var receive: (([URL]) -> Void)?
        private let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            let accepted = accepts(sender)
            targeted?(accepted)
            return accepted ? .copy : []
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { accepts(sender) ? .copy : [] }
        override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted?(false) }
        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { accepts(sender) }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            targeted?(false)
            guard enabled else { return false }
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            receive?(urls)
            return true
        }

        private func accepts(_ sender: any NSDraggingInfo) -> Bool {
            enabled && sender.draggingSourceOperationMask.contains(.copy)
                && sender.draggingPasteboard.availableType(from: [.fileURL]) != nil
        }
    }
}

private enum LibraryKind: String, CaseIterable, Identifiable {
    case skill, mcp
    var id: Self { self }
    var title: String { self == .skill ? "Skill" : "MCP" }
}

private struct LibraryKindPicker: View {
    @Binding var selection: LibraryKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: LibraryKind?

    private let segmentWidth: CGFloat = 72

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.selection)
            Capsule()
                .fill(Theme.accent)
                .frame(width: segmentWidth, height: 28)
                .offset(x: selection == .skill ? 0 : segmentWidth)
                .padding(.leading, 2)
                .animation(reduceMotion ? nil : .smooth(duration: 0.26, extraBounce: 0), value: selection)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                ForEach(LibraryKind.allCases) { kind in
                    Button {
                        selection = kind
                    } label: {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selection == kind ? Theme.inkInverse : Theme.ink)
                            .frame(width: segmentWidth, height: 32)
                            .contentShape(Rectangle())
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: selection)
                    }
                    .buttonStyle(LibrarySegmentButtonStyle(hovered: hovered == kind, selected: selection == kind))
                    .onHover { inside in
                        if inside { hovered = kind }
                        else if hovered == kind { hovered = nil }
                    }
                    .accessibilityAddTraits(selection == kind ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 2 * segmentWidth + 4, height: 32)
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(Theme.border).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.harnessTitle)
        .onMoveCommand { direction in
            if direction == .left { selection = .skill }
            if direction == .right { selection = .mcp }
        }
    }
}

private struct LibrarySegmentButtonStyle: ButtonStyle {
    let hovered: Bool
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule()
                    .fill(selected ? .black : Theme.ink)
                    .opacity(configuration.isPressed ? 0.14 : hovered ? 0.055 : 0)
                    .padding(2)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private final class AgentToolLibraryModel: ObservableObject {
    static let shared = AgentToolLibraryModel()

    @Published var kind: LibraryKind = .skill
    @Published var query = ""
    @Published var selected: Set<String> = []
    @Published var targets: Set<String> = []
    @Published var items: [LibraryItem] = []
    @Published var agents: [LibraryAgent] = []
    @Published var managed: [ManagedLibraryItem] = []
    @Published var rows: [LibraryChange] = []
    @Published var busy = false
    @Published var message = ""
    @Published var pasteText = ""
    @Published var omitted: [String] = []
    @Published var project: String?
    @Published var projectScope = false
    @Published private(set) var organizing = false
    @Published private(set) var pendingCleanup = 0
    @Published private var organizationMessages: [LibraryKind: String] = [:]

    var token: String?
    private var pendingChange: [String: Any]?
    private var needsReload = false
    private var pendingAutoOrganization = Set<LibraryKind>()
    private var pendingOrganizationIDs: ArraySlice<String> = []
    private var incompleteOrganization = false

    var visible: [LibraryItem] {
        items.filter {
            $0.kind == kind.rawValue && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.description?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var selectedItems: [LibraryItem] { items.filter { selected.contains($0.id) } }
    var hasManaged: Bool { managed.contains { selected.contains($0.item) } }
    var hasStandaloneSelection: Bool { selectedItems.contains { $0.kind == "skill" && $0.importMode == nil } }
    var canExportMarkdown: Bool { selectedItems.count == 1 && hasStandaloneSelection }
    private var organizationSelection: [LibraryItem] {
        items.filter { $0.kind == kind.rawValue && $0.canOrganize && (selected.isEmpty || selected.contains($0.id)) }
    }
    var canOrganizeCurrentKind: Bool { !organizationSelection.isEmpty }
    var organizationMessage: String { organizationMessages[kind] ?? "" }

    func open() {
        kind = .skill
        query = ""
        selected = []
        targets = []
        project = nil
        projectScope = false
        message = ""
        showingPastePreview = false
        invalidateChanges()
        reload()
    }

    func reload() {
        if busy { needsReload = true; return }
        needsReload = false
        request(["action": "list"]) { reply in
            self.items = (reply.items ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.agents = reply.agents ?? []
            self.managed = reply.managed ?? []
            self.pendingCleanup = reply.pendingCleanup ?? 0
            self.selected.formIntersection(self.items.map(\.id))
            if !self.needsReload { self.startAutoOrganization() }
        }
    }

    func toggleIgnored(_ item: LibraryItem) {
        NotificationCenter.default.post(name: LocalLibraryCommand.wheelInvalidated, object: nil)
        request(["action": "set-library-ignored", "items": [item.id], "ignored": item.ignored != true]) { _ in
            NotificationCenter.default.post(name: LocalLibraryCommand.wheelInvalidated, object: nil)
            self.message = ""
            self.reload()
        }
    }

    func deleteItems(_ ids: [String]) {
        NotificationCenter.default.post(name: LocalLibraryCommand.wheelInvalidated, object: nil)
        request(["action": "delete-library-items", "items": ids]) { reply in
            NotificationCenter.default.post(name: LocalLibraryCommand.wheelInvalidated, object: nil)
            self.message = ""
            self.pendingCleanup = reply.pendingCleanup ?? 0
            self.invalidateChanges()
            self.reload()
        }
    }

    func didImport(_ imported: LibraryFileImportResult, _ speakIDs: [String]) {
        NotificationCenter.default.post(name: LocalLibraryCommand.wheelInvalidated, object: nil)
        if !speakIDs.isEmpty { kind = .skill; query = "" }
        if imported.skills + (imported.skillReferences ?? 0) > 0 { pendingAutoOrganization.insert(.skill) }
        if imported.mcp + imported.references > 0 { pendingAutoOrganization.insert(.mcp) }
        reload()
    }

    func organizeCurrentKind() {
        if organize(kind, ids: organizationSelection.map(\.id), suggestNames: kind == .skill), selected.isEmpty {
            pendingAutoOrganization.remove(kind)
        }
    }

    func reviewSkillName(_ item: LibraryItem, suggestion: String, accept: Bool) {
        request(["action": "review-skill-name", "items": [item.id], "suggestedName": suggestion, "accept": accept]) { _ in
            self.message = ""
            if accept { NotificationCenter.default.post(name: LocalLibraryCommand.wheelInvalidated, object: nil) }
            self.reload()
        }
    }

    func startAutoOrganization() {
        guard !busy, !organizing else { return }
        for kind in LibraryKind.allCases where pendingAutoOrganization.contains(kind) {
            let ids = items.filter { $0.kind == kind.rawValue && $0.canOrganize }.map(\.id)
            if ids.isEmpty || organize(kind, ids: ids) { pendingAutoOrganization.remove(kind) }
            if organizing { break }
        }
    }

    private func organize(_ kind: LibraryKind, ids: [String], suggestNames: Bool = false) -> Bool {
        guard !organizing, !ids.isEmpty else { return false }
        let settings = Settings.shared
        guard let selectedRoute = settings.activeLLMRoute else {
            organizationMessages[kind] = L10n.text("请先解锁或设置整理模型。")
            return false
        }
        organizing = true
        incompleteOrganization = false
        pendingOrganizationIDs = ids[...]
        organizationMessages[kind] = L10n.text(kind == .skill ? "正在整理 Skill 并生成用途预览…" : "正在整理 MCP…")
        let route = settings.configuredCleanupRoute(selectedRoute, full: false)
        organizeNextBatch(kind, route: route, language: L10n.language, suggestNames: suggestNames)
        return true
    }

    private func organizeNextBatch(_ kind: LibraryKind, route: LLMRoute, language: String, suggestNames: Bool) {
        guard !pendingOrganizationIDs.isEmpty else {
            organizing = false
            organizationMessages[kind] = incompleteOrganization ? L10n.text("部分项目未能整理，可选中后重试。") : ""
            reload()
            return
        }
        let ids = Array(pendingOrganizationIDs.prefix(6))
        pendingOrganizationIDs.removeFirst(ids.count)
        let finish: (Int) -> Void = { [weak self] saved in
            guard let self else { return }
            self.incompleteOrganization = self.incompleteOrganization || saved < ids.count
            self.organizeNextBatch(kind, route: route, language: language, suggestNames: suggestNames)
        }
        guard let input = try? JSONSerialization.data(withJSONObject: [
            "action": "speak-drafts", "kind": kind.rawValue, "items": ids, "suggestNames": suggestNames
        ]) else { finish(0); return }
        LocalLibraryCommand.run(input, readOnly: true) { [weak self] reply in
            guard let drafts = reply?.speakDrafts, !drafts.isEmpty else { finish(0); return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let categories = (try? ServiceClient.shared.classifySpeaksSync(drafts, llm: route, language: language,
                                                                             includePreview: true)) ?? []
                DispatchQueue.main.async {
                    self?.saveOrganization(categories.filter { ids.contains($0.id) }, kind: kind,
                                           suggestNames: suggestNames, completion: finish)
                }
            }
        }
    }

    private func saveOrganization(_ categories: [SpeakCategory], kind: LibraryKind, suggestNames: Bool,
                                  completion: @escaping (Int) -> Void) {
        struct Update: Encodable {
            let id: String
            let category: String
            let preview: SpeakWheelPreview?
            let suggestedName: String?
        }
        struct Request: Encodable {
            let action = "save-speak-categories"
            let kind: String
            let suggestNames: Bool
            let categories: [Update]
        }
        let rows = categories.map {
            Update(id: $0.id, category: $0.category, preview: $0.preview, suggestedName: $0.suggestedName)
        }
        guard !rows.isEmpty,
              let input = try? JSONEncoder().encode(Request(kind: kind.rawValue, suggestNames: suggestNames,
                                                            categories: rows)) else { completion(0); return }
        LocalLibraryCommand.run(input) { reply in completion(reply?.organized ?? 0) }
    }

    func previewText(copy: Bool = false) {
        let action = kind == .skill ? "preview-skills" : "paste"
        request(["action": action, "items": Array(selected)]) { reply in
            self.omitted = reply.omitted ?? []
            self.pasteText = reply.text ?? ""
            if copy, !self.pasteText.isEmpty { Inserter.shared.setString(self.pasteText) }
            else { self.showingPastePreview = true }
        }
    }

    func exportMarkdown() {
        guard canExportMarkdown, let item = selectedItems.first else { return }
        request(["action": "export-speak", "items": [item.id]]) { reply in
            guard let text = reply.text else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = item.name.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-") + ".md"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Data(text.utf8).write(to: url, options: .atomic)
                    self.message = ""
                } catch {
                    self.message = L10n.text("无法保存 Markdown。")
                }
            }
        }
    }

    @Published var showingPastePreview = false

    func previewUndo() {
        let payload: [String: Any] = ["action": "preview", "items": Array(selected), "targets": targets.sorted(),
                                      "operation": "undo", "scope": projectScope ? "project" : "global"]
        request(payload) { reply in
            self.pendingChange = payload
            self.rows = reply.rows ?? []
            self.token = reply.token
        }
    }

    func invalidateChanges() {
        token = nil
        rows = []
        pendingChange = nil
    }

    func applyChanges() {
        guard var payload = pendingChange, let token else { return }
        payload["action"] = "apply"
        payload["token"] = token
        request(payload) { reply in
            self.invalidateChanges()
            self.rows = reply.rows ?? []
            self.reload()
        }
    }

    private func request(_ fields: [String: Any], done: @escaping (LibraryReply) -> Void) {
        guard !busy else { return }
        var payload = fields
        payload["project"] = project
        guard let input = try? JSONSerialization.data(withJSONObject: payload) else { return }
        busy = true
        LocalLibraryCommand.run(input) { [weak self] reply in
            guard let self else { return }
            self.busy = false
            defer {
                if self.needsReload && !self.busy {
                    self.needsReload = false
                    self.reload()
                }
            }
            guard let reply, reply.error == nil else {
                if reply?.error == "changed" {
                    self.invalidateChanges()
                    self.message = L10n.text("配置已在别处更改。请重新预览。")
                } else {
                    self.message = L10n.text("无法读取 {0}。", L10n.harnessTitle)
                }
                return
            }
            done(reply)
        }
    }
}

struct AgentToolLibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var model = AgentToolLibraryModel.shared
    @State private var deletionTarget: LibraryItem?
    @State private var confirmingDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryFileImportView(kind: model.kind, enabled: !model.busy, onImport: model.didImport)
            if !model.message.isEmpty {
                Text(model.message).font(Theme.captionFont).foregroundStyle(Theme.warning)
            }
            if model.pendingCleanup > 0 {
                HStack {
                    Text(L10n.text("部分本地副本尚未清理。")).font(Theme.captionFont).foregroundStyle(Theme.warning)
                    Spacer()
                    Button(L10n.text("重试清理")) { model.deleteItems([]) }.hoverFeedback(.fixed).disabled(model.busy)
                }
            }
            if model.showingPastePreview {
                pastePreview
            } else {
                HStack(spacing: 12) {
                    LibraryKindPicker(selection: $model.kind)
                    TextField(L10n.text("搜索工具"), text: $model.query)
                    Button(L10n.text(model.kind == .skill ? "整理 Skill" : "整理 MCP"), action: model.organizeCurrentKind)
                        .hoverFeedback()
                        .disabled(model.organizing || !model.canOrganizeCurrentKind)
                }
                .disabled(model.busy)
                if !model.organizationMessage.isEmpty {
                    Text(model.organizationMessage).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.rows.isEmpty { changePreview }
                        resources
                    }
                }
                footer
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .alert(L10n.text("从 TypeLeast 删除？"), isPresented: $confirmingDeletion, presenting: deletionTarget) { item in
            Button(L10n.text("删除"), role: .destructive) { model.deleteItems([item.id]) }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { item in
            Text(L10n.text("将删除「{0}」及其在 TypeLeast 内的副本。外部原件会保留。", item.name))
        }
        .onAppear { model.open() }
        .onChange(of: appModel.credentialsLocked) { _, locked in
            if !locked { model.startAutoOrganization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChange).receive(on: RunLoop.main)) { _ in
            model.startAutoOrganization()
        }
        .onChange(of: model.kind) { _, _ in
            model.selected.removeAll()
            model.query = ""
            model.invalidateChanges()
        }
    }

    @ViewBuilder
    private var resources: some View {
        let visible = model.visible
        if visible.isEmpty {
            SettingsSection {
                Text(L10n.text(model.kind == .skill ? "导入独立的 Markdown 提示词后会显示在这里。" : "导入 MCP 配置文件后会显示在这里。"))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.secondary)
                    .padding(.vertical, 4)
            }
        } else {
            ForEach(HarnessFolders.definitions.filter { group in visible.contains { $0.group == group.id } }, id: \.id) { group in
                SettingsSection(title: L10n.text(group.title)) {
                    ForEach(visible.filter { $0.group == group.id }) { resourceRow($0) }
                }
            }
        }
    }

    private func resourceRow(_ item: LibraryItem) -> some View {
        let selected = model.selected.contains(item.id)
        return HStack(spacing: 6) {
            Button {
                if selected { model.selected.remove(item.id) } else { model.selected.insert(item.id) }
                model.invalidateChanges()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.name).font(Theme.rowFont).lineLimit(1).help(item.name)
                            if item.renamed == true {
                                Text(L10n.text("已改名")).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                                    .fixedSize()
                            }
                            if item.ignored == true {
                                Text(L10n.text("已忽略")).font(Theme.captionFont).foregroundStyle(Theme.secondary)
                            }
                        }
                        if let description = item.description, !description.isEmpty {
                            Text(description).lineLimit(2).foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatActionButtonStyle(feedback: .fixed))
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let suggestion = item.suggestedName {
                nameReview(item, suggestion: suggestion)
            }
            if let path = item.localPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .hoverFeedback(.compact)
                    .help(L10n.text("显示来源"))
                    .accessibilityLabel(L10n.text("显示来源"))
            } else if let url = item.githubSource {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .hoverFeedback(.compact)
                    .help(L10n.text("打开 GitHub 来源"))
                    .accessibilityLabel(L10n.text("打开 GitHub 来源"))
            }
            Menu {
                Button(L10n.text(item.ignored == true ? "取消忽略" : "从滚轮忽略")) { model.toggleIgnored(item) }
                Button(role: .destructive) {
                    deletionTarget = item
                    confirmingDeletion = true
                } label: {
                    Label(L10n.text("删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(L10n.text("管理条目"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .font(Theme.captionFont)
        .disabled(model.busy)
    }

    private func nameReview(_ item: LibraryItem, suggestion: String) -> some View {
        HStack(spacing: 8) {
            Text(suggestion)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .help(L10n.text("建议名称") + " · " + suggestion)
                .accessibilityLabel(L10n.text("建议名称") + " " + suggestion)
                .frame(maxWidth: 176, alignment: .leading)
            Button(L10n.text("替换")) { model.reviewSkillName(item, suggestion: suggestion, accept: true) }
                .foregroundStyle(Theme.accent)
            Button(L10n.text("拒绝")) { model.reviewSkillName(item, suggestion: suggestion, accept: false) }
                .foregroundStyle(Theme.secondary)
        }
        .font(Theme.captionFont)
        .buttonStyle(.borderless)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasManaged && !model.agents.isEmpty {
                HStack {
                    Text(L10n.text("撤销旧配置"))
                    ForEach(model.agents) { agent in
                        Toggle(agent.name, isOn: targetBinding(agent.id)).toggleStyle(.checkbox).hoverFeedback(.fixed)
                    }
                    Spacer()
                }
                .font(Theme.captionFont)
                HStack {
                    Button(L10n.text("选择项目")) {
                        chooseFolder { model.project = $0; model.projectScope = true; model.invalidateChanges() }
                    }
                    .hoverFeedback()
                    if let project = model.project {
                        Text(URL(fileURLWithPath: project).lastPathComponent).lineLimit(1)
                        Toggle(L10n.text("仅撤销所选项目"), isOn: $model.projectScope).toggleStyle(.checkbox)
                            .hoverFeedback(.fixed)
                            .onChange(of: model.projectScope) { _, _ in model.invalidateChanges() }
                    }
                }
            }
            HStack {
                if !model.selected.isEmpty {
                    Text(L10n.text("已选 {0} 项", model.selected.count)).font(Theme.captionFont)
                }
                Spacer()
                if model.hasManaged {
                    Button(L10n.text("预览撤销"), action: model.previewUndo).hoverFeedback().disabled(model.targets.isEmpty)
                }
                if model.kind == .skill {
                    Button(L10n.text("预览")) { model.previewText() }.hoverFeedback().disabled(model.selected.isEmpty)
                    Button(L10n.text("另存为 .md"), action: model.exportMarkdown)
                        .hoverFeedback().disabled(!model.canExportMarkdown)
                    Button(L10n.text("复制")) { model.previewText(copy: true) }
                        .buttonStyle(.borderedProminent).hoverFeedback().disabled(model.selected.isEmpty)
                } else {
                    Button(L10n.text("预览")) { model.previewText() }.hoverFeedback().disabled(model.selected.isEmpty)
                    Button(L10n.text("复制调用头")) { model.previewText(copy: true) }
                        .buttonStyle(.borderedProminent).hoverFeedback().disabled(model.selected.isEmpty)
                }
            }
        }
        .disabled(model.busy)
    }

    private var changePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.rows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agentName(row.agent) + " · " + row.item + " · " + changeStatus(row.state))
                            if let path = row.path {
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 110)
            HStack {
                Button(L10n.text("关闭预览")) { model.invalidateChanges() }.hoverFeedback(.fixed)
                Spacer()
                if model.token != nil && model.rows.contains(where: { $0.state == "ready" }) {
                    Button(L10n.text("应用选中的更改")) { model.applyChanges() }.buttonStyle(.borderedProminent).hoverFeedback()
                }
            }
        }
        .font(Theme.captionFont)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.busy)
    }

    private var pastePreview: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !model.omitted.isEmpty {
                Text(L10n.text("找不到这些 Skill 的源文件：{0}", model.omitted.joined(separator: ", ")))
                    .font(Theme.captionFont)
            }
            ScrollView {
                Text(model.pasteText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 235)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(L10n.text("返回")) { model.showingPastePreview = false }.hoverFeedback()
                Spacer()
                Button(L10n.text("复制")) { Inserter.shared.setString(model.pasteText) }
                    .buttonStyle(.borderedProminent)
                    .hoverFeedback()
                    .disabled(model.pasteText.isEmpty)
            }
        }
    }

    private func chooseFolder(_ action: @escaping (String) -> Void) {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.begin { response in
            if response == .OK, let path = picker.url?.path { action(path) }
        }
    }

    private func targetBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.targets.contains(id) }, set: { selected in
            if selected { model.targets.insert(id) } else { model.targets.remove(id) }
            model.invalidateChanges()
        })
    }

    private func agentName(_ id: String) -> String { model.agents.first(where: { $0.id == id })?.name ?? id }

    private func changeStatus(_ state: String) -> String {
        switch state {
        case "ready": return L10n.text("待应用")
        case "applied": return L10n.text("已应用")
        case "already-configured": return L10n.text("已配置")
        case "conflict": return L10n.text("同名条目已有不同配置")
        case "authorization": return L10n.text("需在 Agent 中授权")
        case "changed": return L10n.text("配置已在别处更改。请重新预览。")
        case "not-managed": return L10n.text("没有可撤销的更改")
        default: return L10n.text("此条目无法自动更改")
        }
    }
}
