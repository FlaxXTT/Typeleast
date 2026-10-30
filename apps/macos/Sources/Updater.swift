import Foundation
import CryptoKit

// Updater.swift - in-app update for this Mac. The release is fetched from GitHub's public
// release page (no account needed), or from a public mirror when GitHub is slow
// (UpdateSources). Its SHA-256 is checked against the
// release's SHA256SUMS.txt, and the app is re-signed with this Mac's own "TypeLeast Local
// Signing" certificate (made on the first update if there is none) before it replaces the
// installed copy. Same certificate + same bundle id = same designated requirement, so macOS
// keeps the microphone and Accessibility permissions; Keychain items are handed over
// (KeychainHandoff), so an update asks for no password.

enum UpdateError: LocalizedError {
    case unreachable
    case checksum
    case badBundle(String)
    case noSigningCertificate
    case sign(String)
    case requirementChanged

    var errorDescription: String? {
        switch self {
        case .unreachable: return L10n.text("无法获取更新，所有下载线路都失败了。请检查网络。")
        case .checksum: return L10n.text("文件校验失败，更新已取消。")
        case .badBundle(let detail): return L10n.text("更新文件错误：") + detail
        case .noSigningCertificate: return L10n.text("无法在这台 Mac 上生成「") + Updater.signingIdentity + L10n.text("」签名证书。更新已停止。")
        case .sign(let detail): return L10n.text("本机证书签名失败：") + detail
        case .requirementChanged: return L10n.text("新版本签名不同，安装会丢失权限。更新已取消。")
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

    /// The Mac's own processor. An Intel build running under Rosetta on Apple silicon
    /// reports arm64, so it updates to the Apple silicon build.
    static var machineArch: String {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 { return "arm64" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A quiet check offers each new version once, and only while nothing is in the way
    /// (dictating, Prompt Beta open); asking by hand always offers it.
    static func shouldOffer(latest: String, offered: String?, interactive: Bool, busy: Bool) -> Bool {
        interactive || (offered != latest && !busy)
    }

    /// Intel Macs get no new versions after 1.17.1.
    static func intelDiscontinued(arch: String = machineArch) -> Bool { arch != "arm64" }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: steps

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

    // MARK: the public release page

    /// GET over HTTPS, synchronously; nil on any failure (not found, private repository, offline).
    static func fetch(_ url: URL, timeout: TimeInterval = 30) -> Data? {
        guard url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("TypeLeast/" + currentVersion, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    /// The tag of the newest release as GitHub's public API reports it.
    struct Release {
        let version: String
        let summary: String
    }
    static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        return Release(version: version(fromTag: tag), summary: ReleaseSummary.text(json["body"] as? String ?? ""))
    }
    static func latestRelease() throws -> Release {
        guard let data = fetch(URL(string: "https://api.github.com/repos/" + repo + "/releases/latest")!, timeout: 15),
              let release = release(from: data) else { throw UpdateError.unreachable }
        return release
    }

    /// Download a release file from the public release page into `folder`, reporting bytes
    /// received and the total (when the server says it) as it goes.
    static func publicDownload(version: String, name: String, to folder: URL,
                               progress: ((Int64, Int64?) -> Void)? = nil) -> Bool {
        guard let url = URL(string: "https://github.com/" + repo + "/releases/download/v" + version + "/" + name) else { return false }
        return download(url, to: folder.appendingPathComponent(name), timeout: 600, progress: progress)
    }

    /// GET a file over HTTPS straight to disk, synchronously, with progress; false on any failure.
    static func download(_ url: URL, to file: URL, timeout: TimeInterval, progress: ((Int64, Int64?) -> Void)?) -> Bool {
        guard url.scheme == "https" else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("TypeLeast/" + currentVersion, forHTTPHeaderField: "User-Agent")
        let delegate = DownloadDelegate(destination: file, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: request).resume()
        delegate.done.wait()
        session.finishTasksAndInvalidate()
        return delegate.saved
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let destination: URL
        let progress: ((Int64, Int64?) -> Void)?
        let done = DispatchSemaphore(value: 0)
        var saved = false

        init(destination: URL, progress: ((Int64, Int64?) -> Void)?) {
            self.destination = destination
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else { return }
            try? FileManager.default.removeItem(at: destination)
            saved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil { saved = false }
            done.signal()
        }
    }

    // MARK: this Mac's signing certificate

    static func hasSigningIdentity() -> Bool {
        run("/usr/bin/security", ["find-certificate", "-c", signingIdentity]).status == 0
    }

    /// The same certificate make-signing-cert.sh makes: self-signed, code signing only, valid
    /// ten years, private key only in this Mac's login keychain. Made once, on the first update.
    static func ensureSigningIdentity() throws {
        if hasSigningIdentity() { return }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TypeLeast-cert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let config = """
        [req]
        distinguished_name = dn
        x509_extensions = ext
        prompt = no
        [dn]
        CN = \(signingIdentity)
        [ext]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning
        """
        let cfg = work.appendingPathComponent("cfg"), key = work.appendingPathComponent("key.pem")
        let cert = work.appendingPathComponent("cert.pem"), p12 = work.appendingPathComponent("id.p12")
        try config.write(to: cfg, atomically: true, encoding: .utf8)
        guard run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-config", cfg.path,
                                       "-keyout", key.path, "-out", cert.path]).status == 0 else { throw UpdateError.noSigningCertificate }
        let pass = UUID().uuidString
        guard run("/usr/bin/openssl", ["pkcs12", "-export", "-name", signingIdentity, "-inkey", key.path, "-in", cert.path,
                                       "-out", p12.path, "-passout", "pass:" + pass]).status == 0 else { throw UpdateError.noSigningCertificate }
        let keychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        guard run("/usr/bin/security", ["import", p12.path, "-k", keychain, "-P", pass, "-T", "/usr/bin/codesign"]).status == 0,
              hasSigningIdentity() else { throw UpdateError.noSigningCertificate }
    }

    /// Download, verify and re-sign `version`; returns the ready app inside a fresh work folder,
    /// and its code hash as signed (KeychainHandoff hands the Keychain items only to that code).
    static func prepare(version: String, current: URL = Bundle.main.bundleURL,
                        stage: ((UpdateStage) -> Void)? = nil) throws -> (app: URL, work: URL, cdhash: String?) {
        stage?(.preparing)
        try ensureSigningIdentity()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TypeLeast-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let asset = assetName(version: version, arch: machineArch)
            stage?(.downloading(received: 0, total: nil, source: "GitHub"))
            // The checksum list always comes from GitHub; the app may come from a mirror (checked against it).
            var publicCopy = publicDownload(version: version, name: "SHA256SUMS.txt", to: work)
            if publicCopy, let official = URL(string: "https://github.com/" + repo + "/releases/download/v" + version + "/" + asset) {
                let sums = (try? String(contentsOf: work.appendingPathComponent("SHA256SUMS.txt"), encoding: .utf8)) ?? ""
                let expected = checksum(for: asset, in: sums)
                publicCopy = false
                for (url, source) in UpdateSources.list(for: official, mode: Settings.shared.updateSource) {
                    let file = work.appendingPathComponent(asset)
                    guard download(url, to: file, timeout: UpdateSources.stall, progress: { received, total in
                        stage?(.downloading(received: received, total: total, source: source))
                    }) else { continue }
                    if let expected, (try? sha256Hex(of: file)) == expected { publicCopy = true; break }
                }
            }
            guard publicCopy else { throw UpdateError.unreachable }

            stage?(.verifying)
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
            guard info?["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.badBundle(L10n.text("这不是 TypeLeast")) }
            guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateError.badBundle(L10n.text("版本号不是 ") + version) }

            stage?(.signing)
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
            return (app, work, KeychainHandoff.cdhash(of: app))
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
    /// If the copy fails, the old app is put back; if the old app cannot even be moved aside
    /// (no write access to its folder), it is left exactly where it is.
    static func replaceAfterExit(pid: Int32, newApp: URL, installed: URL, work: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old"; then
          if /usr/bin/ditto "$2" "$3"; then rm -rf "$3.old"; else rm -rf "$3"; mv "$3.old" "$3"; fi
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3" >/dev/null 2>&1 || true
        /usr/bin/open "$3"
        rm -rf "$4"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "typeleast-update", String(pid), newApp.path, installed.path, work.path]
        try p.run()
    }
}

/// Where an in-app update is, for the progress window.
enum UpdateStage: Equatable {
    case preparing
    case downloading(received: Int64, total: Int64?, source: String)
    case verifying
    case signing
    case handingOver
    case installing

    var label: String {
        switch self {
        case .preparing: return L10n.text("正在准备…")
        case .downloading(let received, let total, let source):
            let mb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
            if let total { return L10n.text("正在从 {0} 下载：{1} / {2} MB", source, mb(received), mb(total)) }
            return L10n.text("正在从 {0} 下载：{1} MB", source, mb(received))
        case .verifying: return L10n.text("正在校验文件…")
        case .signing: return L10n.text("正在用本机证书签名…")
        case .handingOver: return L10n.text("正在转移钥匙串里的 Key…")
        case .installing: return L10n.text("正在安装，TypeLeast 会重新打开…")
        }
    }

    /// The steps the progress window shows, in order.
    static let steps = ["下载", "校验", "签名", "Key", "安装"]

    /// Which of `steps` this stage is.
    var step: Int {
        switch self {
        case .preparing, .downloading: return 0
        case .verifying: return 1
        case .signing: return 2
        case .handingOver: return 3
        case .installing: return 4
        }
    }

    /// The symbol in the middle of the ring when there is no percentage to show.
    var symbol: String {
        switch self {
        case .preparing, .downloading: return "arrow.down"
        case .verifying: return "checkmark.shield"
        case .signing: return "signature"
        case .handingOver: return "key"
        case .installing: return "sparkles"
        }
    }

    /// Below the percentage while downloading: "12.3 / 50.4 MB".
    var amount: String? {
        guard case .downloading(let received, let total, _) = self else { return nil }
        let mb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        return total.map { mb(received) + " / " + mb($0) + " MB" } ?? mb(received) + " MB"
    }

    /// 0…1 while the size is known; nil shows a moving bar.
    var fraction: Double? {
        guard case .downloading(let received, let total?, _) = self, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
}

/// Where an update is downloaded from. GitHub's release files are slow or cut off from some networks
/// (mainland China), so public GitHub download mirrors are tried too. The checksum list always comes
/// from GitHub itself and the app is checked against it, so a mirror can only make a download faster,
/// never change what is installed.
enum UpdateSources {
    /// Settings values: auto (GitHub, then mirrors), github (GitHub only), mirror (mirrors first).
    static let modes = ["auto", "github", "mirror"]
    /// Public GitHub download mirrors, tried in this order; each takes the full GitHub URL after its address.
    static let mirrors = ["https://ghfast.top/", "https://gh-proxy.com/", "https://gh-proxy.org/", "https://gh.llkk.cc/"]
    /// No new data for this long: give up on this source and try the next.
    static let stall: TimeInterval = 15

    static func list(for official: URL, mode: String) -> [(URL, String)] {
        let prefix = "https://github.com/" + Updater.repo + "/releases/download/"
        guard official.absoluteString.hasPrefix(prefix), mode != "github" else { return [(official, "GitHub")] }
        let viaMirrors = mirrors.compactMap { m -> (URL, String)? in
            guard let url = URL(string: m + official.absoluteString), let host = URL(string: m)?.host else { return nil }
            return (url, host)
        }
        return mode == "mirror" ? viaMirrors + [(official, "GitHub")] : [(official, "GitHub")] + viaMirrors
    }
}
