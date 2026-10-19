import Foundation
import CryptoKit

// Updater.swift - in-app update for this Mac. The repository is private, so the
// release is fetched with the GitHub CLI's own login (`gh release download`), its
// SHA-256 is checked against the release's SHA256SUMS.txt, and the app is re-signed
// with the local "TypeLeast Local Signing" certificate (make-signing-cert.sh) before
// it replaces the installed copy. Same certificate + same bundle id = same designated
// requirement, so macOS keeps the Keychain, microphone and Accessibility permissions.

enum UpdateError: LocalizedError {
    case noGitHubCLI
    case gh(String)
    case checksum
    case badBundle(String)
    case noSigningCertificate
    case sign(String)
    case requirementChanged

    var errorDescription: String? {
        switch self {
        case .noGitHubCLI: return L10n.text("没有找到 GitHub 命令行工具 gh。用 Homebrew 安装（brew install gh）并运行 gh auth login 登录后再试。")
        case .gh(let detail): return L10n.text("从 GitHub 获取更新失败：") + detail + L10n.text("\n如果还没登录，在终端运行 gh auth login。")
        case .checksum: return L10n.text("下载的安装包和发布页记录的 SHA-256 不一致，已放弃更新。")
        case .badBundle(let detail): return L10n.text("下载的安装包不对：") + detail
        case .noSigningCertificate: return L10n.text("这台 Mac 上没有「") + Updater.signingIdentity + L10n.text("」签名证书。在源码目录运行 apps/macos/make-signing-cert.sh 生成后再试。")
        case .sign(let detail): return L10n.text("用本机证书签名失败：") + detail
        case .requirementChanged: return L10n.text("新版本签好名后和当前版本的签名要求不一致，装上会丢失权限，已放弃更新。")
        }
    }
}

enum Updater {
    static let repo = "FlaxXTT/Typeleast"
    static let signingIdentity = "TypeLeast Local Signing"
    static let bundleID = "com.dsh.voice"

    // MARK: pure helpers

    /// "v1.4.0" -> "1.4.0".
    static func version(fromTag tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("v") ? String(t.dropFirst()) : t
    }

    /// Numeric, component by component: 1.10.0 is newer than 1.9.3; 1.3 equals 1.3.0.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The release's zip for this Mac's processor (names made by apps/macos/package.sh).
    static func assetName(version: String, arch: String) -> String {
        "TypeLeast-" + version + "-macOS-" + (arch == "arm64" ? "AppleSilicon" : "Intel") + ".zip"
    }

    /// The hash recorded for `name` in a sha256sum-style file ("<hex>  <name>" or "<hex> *<name>").
    static func checksum(for name: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            var file = String(fields[fields.count - 1])
            if file.hasPrefix("*") { file.removeFirst() }
            if file == name { return fields[0].lowercased() }
        }
        return nil
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static var machineArch: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: steps

    /// The GitHub CLI: an app started from Finder has no shell PATH, so look where Homebrew
    /// and user installs put it, then ask the user's login shell.
    static func findGH(home: String = NSHomeDirectory(),
                       exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                       shellLookup: () -> String? = Updater.ghFromLoginShell) -> String? {
        let known = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home + "/.local/bin/gh", home + "/bin/gh", "/usr/bin/gh"]
        if let found = known.first(where: exists) { return found }
        return shellLookup().flatMap { exists($0) ? $0 : nil }
    }

    static func ghFromLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let path = run(shell, ["-lc", "command -v gh"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// The newest published version, e.g. "1.4.0".
    static func latestVersion() throws -> String {
        guard let gh = findGH() else { throw UpdateError.noGitHubCLI }
        let r = run(gh, ["release", "view", "--repo", repo, "--json", "tagName", "--jq", ".tagName"])
        guard r.status == 0 else { throw UpdateError.gh(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return version(fromTag: r.out)
    }

    /// Download, verify and re-sign `version`; returns the ready app inside a fresh work folder.
    static func prepare(version: String, current: URL = Bundle.main.bundleURL) throws -> (app: URL, work: URL) {
        guard let gh = findGH() else { throw UpdateError.noGitHubCLI }
        guard run("/usr/bin/security", ["find-certificate", "-c", signingIdentity]).status == 0 else {
            throw UpdateError.noSigningCertificate
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TypeLeast-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let asset = assetName(version: version, arch: machineArch)
            let dl = run(gh, ["release", "download", "v" + version, "--repo", repo,
                              "--pattern", asset, "--pattern", "SHA256SUMS.txt", "--dir", work.path])
            guard dl.status == 0 else { throw UpdateError.gh(dl.err.trimmingCharacters(in: .whitespacesAndNewlines)) }

            let zip = work.appendingPathComponent(asset)
            let sums = (try? String(contentsOf: work.appendingPathComponent("SHA256SUMS.txt"), encoding: .utf8)) ?? ""
            guard let expected = checksum(for: asset, in: sums), try sha256Hex(of: zip) == expected else {
                throw UpdateError.checksum
            }

            let unpacked = work.appendingPathComponent("unpacked")
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
                throw UpdateError.badBundle(L10n.text("无法解压"))
            }
            let app = unpacked.appendingPathComponent("TypeLeast.app")
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.badBundle(L10n.text("不是 TypeLeast")) }
            guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateError.badBundle(L10n.text("版本号不是 ") + version) }

            // Not --deep: the bundled Node.js keeps the signature nodejs.org gave it (as in build.sh / package.sh).
            // Keep the release's Hardened Runtime flag and entitlements; the requirement is this Mac's own.
            let sign = run("/usr/bin/codesign", ["--force", "--sign", signingIdentity, "--timestamp=none",
                                                 "--preserve-metadata=entitlements,flags,runtime", app.path])
            guard sign.status == 0 else { throw UpdateError.sign(sign.err) }
            let verify = run("/usr/bin/codesign", ["--verify", "--strict", app.path])
            guard verify.status == 0 else { throw UpdateError.sign(verify.err) }

            // Only when the running copy already uses the local certificate can permissions carry over;
            // then the new copy's requirement must be identical.
            let mine = designatedRequirement(of: current)
            if let mine, mine.contains("certificate leaf"), designatedRequirement(of: app) != mine {
                throw UpdateError.requirementChanged
            }
            return (app, work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    static func designatedRequirement(of app: URL) -> String? {
        let r = run("/usr/bin/codesign", ["-d", "-r-", app.path])
        return (r.out + r.err).split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("designated =>") }.map(String.init)
    }

    /// Swap the installed app for `newApp` once this process (`pid`) has quit, then open it.
    /// If the copy fails, the old app is put back.
    static func replaceAfterExit(pid: Int32, newApp: URL, installed: URL, work: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old" && /usr/bin/ditto "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
        /usr/bin/open "$3"
        rm -rf "$4"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "typeleast-update", String(pid), newApp.path, installed.path, work.path]
        try p.run()
    }
}
