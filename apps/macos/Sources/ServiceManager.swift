import Foundation

// ServiceManager.swift - start, watch and stop the TypeLeast local service.
//
// The service (service/ in this repository) is a Node.js program bundled inside
// the app at Contents/Resources/service. A release build also carries its own
// Node.js at Contents/Resources/node/bin/node, so nothing has to be installed;
// a build from source uses the Node.js already on the Mac. This file starts the
// service with --parent-pid (so it exits when the app does, even after a crash),
// reads the port from its first stdout line, and restarts it with a back-off if
// it stops. Foundation only, so the test harness compiles it.

/// Pure decisions, kept apart from Process so they can be unit tested.
enum ServiceLocator {
    /// The service uses fetch, node:test globs and parseArgs from Node 22.
    static let minimumNodeMajor = 22

    /// "v22.11.0" -> (22, 11, 0).
    static func parseNodeVersion(_ text: String) -> (major: Int, minor: Int, patch: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = body.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let a = parts[0], let b = parts[1], let c = parts[2] else { return nil }
        return (a, b, c)
    }

    /// The port in the service's ready line: {"event":"ready","port":51234,...}.
    static func parseReadyLine(_ line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["event"] as? String == "ready",
              let port = object["port"] as? Int, port > 0, port < 65_536 else { return nil }
        return port
    }

    /// Where Node.js usually lives on a Mac, most specific first. Version-manager
    /// folders are listed newest version first. `list` returns a folder's entries.
    static func nodeCandidates(home: String, list: (String) -> [String]) -> [String] {
        var out = [
            "/opt/homebrew/bin/node",          // Homebrew, Apple silicon
            "/usr/local/bin/node",             // Homebrew on Intel, or the nodejs.org installer
            home + "/.volta/bin/node",
        ]
        func versions(_ dir: String, suffix: String) -> [String] {
            list(dir)
                .filter { parseNodeVersion($0) != nil }
                .sorted { lhs, rhs in
                    let a = parseNodeVersion(lhs)!, b = parseNodeVersion(rhs)!
                    return (a.major, a.minor, a.patch) > (b.major, b.minor, b.patch)
                }
                .map { dir + "/" + $0 + suffix }
        }
        out += versions(home + "/.nvm/versions/node", suffix: "/bin/node")
        out += versions(home + "/.local/share/fnm/node-versions", suffix: "/installation/bin/node")
        out += versions(home + "/Library/Application Support/fnm/node-versions", suffix: "/installation/bin/node")
        out += versions(home + "/.local/share/mise/installs/node", suffix: "/bin/node")
        out += [home + "/.asdf/shims/node", "/usr/bin/node"]
        return out
    }

    /// True when `version` is new enough.
    static func isSupported(_ version: String) -> Bool {
        guard let v = parseNodeVersion(version) else { return false }
        return v.major >= minimumNodeMajor
    }

    /// The Node.js a release build carries inside the app, if there is one.
    static func bundledNode(resources: String?, exists: (String) -> Bool) -> String? {
        guard let res = resources else { return nil }
        let path = res + "/node/bin/node"
        return exists(path) ? path : nil
    }

    /// The bundled service. TYPELEAST_SERVICE_DIR (development) is used only when the
    /// app carries no service of its own, so an environment variable can never swap
    /// the code an installed app runs.
    static func serviceDirectory(resources: String?, environment: [String: String],
                                 exists: (String) -> Bool) -> String? {
        var candidates: [String] = []
        if let res = resources { candidates.append(res + "/service") }
        if let dev = environment["TYPELEAST_SERVICE_DIR"], !dev.isEmpty { candidates.append(dev) }
        return candidates.first { exists($0 + "/bin/typeleast-service.mjs") }
    }

    /// The environment the service starts with: this app's, minus the variables that
    /// would load other code into Node.js or weaken its TLS checks (NODE_OPTIONS,
    /// NODE_PATH, NODE_TLS_REJECT_UNAUTHORIZED, DYLD_*, ...). NODE_EXTRA_CA_CERTS stays
    /// for networks that need their own certificate authority.
    static func serviceEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            let upper = key.uppercased()
            if upper == "NODE_EXTRA_CA_CERTS" { return true }
            return !["NODE_", "NPM_", "DYLD_", "LD_", "ELECTRON_"].contains { upper.hasPrefix($0) }
        }
    }

    /// Seconds to wait before restart number `attempt` (1-based); nil = give up.
    static func restartDelay(attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [1, 3, 10, 30]
        return attempt >= 1 && attempt <= delays.count ? delays[attempt - 1] : nil
    }
}

/// A Node.js found on this Mac.
struct NodeInstall: Equatable {
    var path: String
    var version: String
}

final class ServiceManager {
    static let shared = ServiceManager()

    enum State: Equatable {
        case stopped
        case noNode(found: String?)        // nothing found, or found one that is too old
        case noService                     // the app bundle has no service folder
        case starting
        case running(port: Int)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true } else { return false } }
        var needsNode: Bool { if case .noNode = self { return true } else { return false } }
    }

    /// Called on the main queue whenever the state changes.
    var onChange: ((State) -> Void)?
    private(set) var state: State = .stopped {
        didSet {
            let s = state
            DispatchQueue.main.async { [weak self] in self?.onChange?(s) }
        }
    }
    private(set) var node: NodeInstall?
    private(set) var serviceDirectory: String?
    /// Last lines the service wrote to stderr, for the settings page.
    private(set) var recentLog: [String] = []

    /// Settings: a Node.js path chosen by the user, and a model mirror.
    var nodePathOverride: String?
    var modelMirror: String?

    private let queue = DispatchQueue(label: "TypeLeast.service")
    private var process: Process?
    private var stopping = false
    private var restartAttempts = 0
    private var stdoutBuffer = ""
    private var integrityChecked = false
    private var integrityProblem: String?

    // MARK: lifecycle

    /// Start the service unless one is already answering.
    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    /// Stop the child (the service also exits by itself when this app does).
    func stop() {
        queue.sync {
            stopping = true
            process?.terminate()
            process = nil
            ServiceClient.shared.invalidatePort()
            state = .stopped
        }
    }

    /// Stop, rediscover Node.js, start again.
    func restart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopping = true
            self.process?.terminate()
            self.process = nil
            ServiceClient.shared.invalidatePort()
            self.node = nil
            self.restartAttempts = 0
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.startLocked() }
        }
    }

    private func startLocked() {
        stopping = false
        if case .running = state, process != nil { return }

        // Once per launch: a bundle whose sealed files changed does not get to run code.
        if !integrityChecked {
            integrityChecked = true
            integrityProblem = SelfIntegrity.problem()
            if integrityProblem != nil { DiagnosticsLog.write("integrity.fail", ["code": "signature"]) }
        }
        if integrityProblem != nil {
            state = .failed(L10n.text("TypeLeast 的文件被改动过，本地服务没有启动。请重新安装。"))
            return
        }

        // Always our own child: a service already listening could be anyone's, and the
        // app proves the identity of the one it talks to (ServiceClient.proofKey).
        let client = ServiceClient.shared

        guard let dir = ServiceLocator.serviceDirectory(resources: Bundle.main.resourcePath,
                                                        environment: ProcessInfo.processInfo.environment,
                                                        exists: { FileManager.default.fileExists(atPath: $0) }) else {
            state = .noService
            return
        }
        serviceDirectory = dir
        clearQuarantine(serviceDirectory: dir)
        if node == nil { node = findNode() }
        guard let node = node, ServiceLocator.isSupported(node.version) else {
            state = .noNode(found: self.node.map { $0.path + "（" + $0.version + "）" })
            self.node = nil
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node.path)
        p.arguments = ["--expose-gc", dir + "/bin/typeleast-service.mjs", "--parent-pid", String(getpid()), "--auth-stdin"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ServiceLocator.serviceEnvironment(ProcessInfo.processInfo.environment)
        if let mirror = modelMirror, !mirror.isEmpty { env["HF_ENDPOINT"] = mirror }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // The identity secret goes through stdin: not in the arguments or the environment,
        // which other processes of this user can read.
        let input = Pipe()
        p.standardInput = input
        var secret = [UInt8](repeating: 0, count: 32)
        // An all-zero secret would be a known one: without randomness, start nothing.
        guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
            state = .failed(L10n.text("无法生成服务密钥，请重启 TypeLeast。"))
            return
        }
        let secretHex = secret.map { String(format: "%02x", $0) }.joined()
        client.proofKey = secretHex
        stdoutBuffer = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consumeStdout(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consumeStderr(data) }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.handleExit(proc) }
        }
        do {
            try p.run()
            input.fileHandleForWriting.write(Data((secretHex + "\n").utf8))
            try? input.fileHandleForWriting.close()
            process = p
            state = .starting
            DiagnosticsLog.write("service.start", ["node": node.version, "pid": String(p.processIdentifier)])
        } catch {
            state = .failed(L10n.text("无法启动 Node.js：") + error.localizedDescription)
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer += String(decoding: data, as: UTF8.self)
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let line = String(stdoutBuffer[..<newline])
            stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: newline)...])
            if let port = ServiceLocator.parseReadyLine(line) {
                ServiceClient.shared.usePort(port)
                restartAttempts = 0
                state = .running(port: port)
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where !line.isEmpty {
            recentLog.append(String(line.prefix(300)))
        }
        if recentLog.count > 20 { recentLog.removeFirst(recentLog.count - 20) }
    }

    private func handleExit(_ proc: Process) {
        guard proc === process || process == nil else { return }
        process = nil
        // Until the next service is up, nothing that answers on the old port is trusted.
        ServiceClient.shared.invalidatePort()
        DiagnosticsLog.write("service.exit", ["code": String(proc.terminationStatus)])
        if stopping { return }
        restartAttempts += 1
        guard let delay = ServiceLocator.restartDelay(attempt: restartAttempts) else {
            let last = recentLog.last ?? L10n.text("退出码 ") + String(proc.terminationStatus)
            state = .failed(L10n.text("本地服务反复退出：") + last)
            return
        }
        state = .starting
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.stopping else { return }
            self.startLocked()
        }
    }

    /// A downloaded app carries the quarantine flag on every file. The app itself
    /// was approved when the user opened it, but the speech library that Node.js
    /// loads would still be checked (and refused) one by one, so the flag is
    /// cleared on the bundled Node.js and service before they run.
    private func clearQuarantine(serviceDirectory dir: String) {
        var targets = [dir]
        if let res = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: res + "/node") { targets.append(res + "/node") }
        for target in targets where ServiceManager.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", target], timeout: 5) != nil {
            _ = ServiceManager.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target], timeout: 20)
            DiagnosticsLog.write("service.unquarantine", ["ok": String(ServiceManager.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", target], timeout: 5) == nil)])
        }
    }

    // MARK: finding Node.js

    /// The first supported Node.js: the one inside the app (release builds), the
    /// user's choice, the usual install places, then the login shell's PATH (which
    /// sees nvm/fnm set up in ~/.zshrc).
    func findNode() -> NodeInstall? {
        var tried: [String] = []
        var tooOld: NodeInstall?
        func probe(_ path: String) -> NodeInstall? {
            guard !tried.contains(path), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            tried.append(path)
            guard let version = ServiceManager.run(path, ["--version"], timeout: 5) else { return nil }
            let install = NodeInstall(path: path, version: version.trimmingCharacters(in: .whitespacesAndNewlines))
            if ServiceLocator.isSupported(install.version) { return install }
            if tooOld == nil { tooOld = install }
            return nil
        }
        if let bundled = ServiceLocator.bundledNode(resources: Bundle.main.resourcePath,
                                                    exists: { FileManager.default.isExecutableFile(atPath: $0) }),
           let found = probe(bundled) { return found }
        if let chosen = nodePathOverride, !chosen.isEmpty, let found = probe(chosen) { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        for path in ServiceLocator.nodeCandidates(home: home, list: list) {
            if let found = probe(path) { return found }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let out = ServiceManager.run(shell, ["-lic", "command -v node"], timeout: 8) {
            for line in out.split(separator: "\n").reversed() where line.hasPrefix("/") {
                if let found = probe(String(line)) { return found }
            }
        }
        return tooOld
    }

    /// Run a short command and return its stdout, or nil on failure or timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ServiceLocator.serviceEnvironment(ProcessInfo.processInfo.environment)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
