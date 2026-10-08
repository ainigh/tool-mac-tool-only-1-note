import AppKit
import Foundation
import NoteCore

/// Keeps the app on the newest commit of the branch it was built from (`main`, unless install.sh
/// was given another): checks at launch and every 6 hours, and installs on request.
///
/// Installing takes GitHub's prebuilt copy when there's a release made from that exact commit.
/// Otherwise it downloads the source and builds it here with Apple's command line tools, which
/// Homebrew already installed. So an update never has to wait for GitHub Actions.
///
/// It talks to GitHub through `gh` when it's installed (signed in: works for private repos too),
/// else directly (public repo).
@MainActor
final class Updater: ObservableObject {
    nonisolated static let repo = "ainigh/tool-mac-tool-only-1-note"
    /// The branch this copy follows (build-app.sh writes it into Info.plist).
    nonisolated static var branch: String {
        let b = Bundle.main.object(forInfoDictionaryKey: "OnlyNoteBranch") as? String ?? ""
        return b.isEmpty ? "main" : b
    }
    nonisolated static let assetName = "OnlyNote.zip"

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The commit this copy was built from (build-app.sh writes it into Info.plist).
    nonisolated static var currentCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "OnlyNoteCommit") as? String
    }

    struct Update: Equatable {
        var commit: Commit
        /// A release made from this commit, if GitHub built one.
        var release: Release?
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Update)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    var hasUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    private var busy: Bool {
        switch state {
        case .checking, .installing: return true
        default: return false
        }
    }

    func start() {
        check(userInitiated: false)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                self?.check(userInitiated: false)
            }
        }
    }

    func check(userInitiated: Bool) {
        if busy { return }
        let before = state
        state = .checking
        Task.detached {
            let outcome: State
            do {
                outcome = try Self.findUpdate().map { .available($0) } ?? .upToDate
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run {
                // A quiet background check that fails shouldn't leave an error in the menu.
                // (And an update it already found stays offered.)
                if case .failed = outcome, !userInitiated {
                    if case .available = before { self.state = before } else { self.state = .idle }
                } else {
                    self.state = outcome
                }
            }
        }
    }

    func install() {
        guard case .available(let update) = state else { return }
        state = .installing("Updating…")
        Task.detached {
            do {
                try Self.install(update) { step in
                    Task { @MainActor in self.state = .installing(step) }
                }
            } catch {
                Self.log("update failed: \(error.localizedDescription)")
                await MainActor.run { self.state = .failed("Update failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - What's new

    nonisolated static func findUpdate() throws -> Update? {
        let head = try Commit.decode(api("repos/\(repo)/commits/\(branch)"))
        // A copy with no commit recorded (an early build, or an empty one: every sha starts with "")
        // updates to whatever main has.
        if let mine = currentCommit, !mine.isEmpty, head.sha.hasPrefix(mine) || mine.hasPrefix(head.sha) { return nil }
        let release = try? Release.decode(api("repos/\(repo)/releases/latest"))
        let prebuilt = release.flatMap { $0.target == head.sha && $0.asset(named: assetName) != nil ? $0 : nil }
        return Update(commit: head, release: prebuilt)
    }

    // MARK: - Installing

    nonisolated static func install(_ update: Update, step: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw Problem("this copy isn't an app bundle (a dev build?)") }
        // On the app's own volume, so the swap at the end is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: work) }

        let newApp: URL
        if let release = update.release {
            step("Downloading \(release.tag)…")
            newApp = try downloadPrebuilt(release, into: work)
        } else {
            newApp = try buildFromSource(update.commit, in: work, step: step)
        }
        let newID = Bundle(url: newApp)?.bundleIdentifier
        guard newID != nil, newID == Bundle.main.bundleIdentifier else {
            throw Problem("the new copy isn't \(app.lastPathComponent)")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        step("Restarting…")
        _ = try fm.replaceItemAt(app, withItemAt: newApp)
        log("updated to \(update.commit.short) (\(update.release == nil ? "built here" : "prebuilt"))")
        // Start the new copy once this one has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    nonisolated static func downloadPrebuilt(_ release: Release, into work: URL) throws -> URL {
        let zip = work.appendingPathComponent(assetName)
        // gh first (the repository may be private); a gh that isn't signed in falls back to a plain download.
        if let gh = ghPath(), (try? run(gh, ["release", "download", release.tag, "--repo", repo, "--pattern", assetName,
                                            "--dir", work.path, "--clobber"])) != nil {
        } else if let asset = release.asset(named: assetName) {
            try download(asset.browserDownloadURL, to: zip)
        } else {
            throw Problem("the release has no \(assetName)")
        }
        let unpacked = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        return unpacked.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    }

    /// Downloads the commit's source and runs scripts/build-app.sh on it (for this Mac only).
    nonisolated static func buildFromSource(_ commit: Commit, in work: URL,
                                            step: (String) -> Void) throws -> URL {
        guard (try? run("/usr/bin/xcode-select", ["-p"])) != nil else {
            throw Problem("building needs Apple's command line tools: run xcode-select --install in Terminal")
        }
        try checkSwift()
        step("Downloading \(commit.short)…")
        let tarball = work.appendingPathComponent("source.tar.gz")
        if let gh = ghPath(), (try? run(gh, ["api", "repos/\(repo)/tarball/\(commit.sha)"], to: tarball)) != nil {
        } else {
            try download(URL(string: "https://codeload.github.com/\(repo)/tar.gz/\(commit.sha)")!, to: tarball)
        }
        let src = work.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xzf", tarball.path, "-C", src.path, "--strip-components", "1"])

        step("Building \(commit.short) (a minute or two)…")
        log("building \(commit.short) in \(src.path)")
        let base = currentVersion.split(separator: "-").first.map(String.init) ?? "0.1"
        try run("/bin/bash", [src.appendingPathComponent("scripts/build-app.sh").path],
                env: ["VERSION": "\(base)-\(commit.short)", "COMMIT": commit.sha, "BRANCH": branch, "UNIVERSAL": "0"],
                in: src, logOutput: true)
        return src.appendingPathComponent("build").appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
    }

    /// Building needs a Swift compiler (the command line tools have one, as does Xcode).
    nonisolated static func checkSwift() throws {
        guard (try? run("/bin/sh", ["-c", "/usr/bin/xcrun swift --version 2>&1"])) != nil else {
            throw Problem("building needs Swift: run xcode-select --install in Terminal, "
                + "or wait a few minutes for GitHub to build this version, then check for updates again")
        }
    }

    /// The error, and when a build failed the end of update.log too, for pasting somewhere.
    nonisolated static func report(_ problem: String) -> String {
        guard problem.contains(logURL.path), let log = try? String(contentsOf: logURL, encoding: .utf8) else { return problem }
        let tail = log.components(separatedBy: "\n").suffix(60).joined(separator: "\n")
        return problem + "\n\n--- the end of \(logURL.path) ---\n" + tail
    }

    // MARK: - GitHub

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// GET https://api.github.com/<path>
    nonisolated static func api(_ path: String) throws -> Data {
        // gh's own error says more ("isn't signed in") than GitHub's 404 for a private repo does.
        var ghError: Error?
        if let gh = ghPath() {
            do { return try run(gh, ["api", path]) } catch { ghError = error }
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/\(path)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try fetch(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404, let ghError { throw ghError }
        if status == 404 { throw Problem("GitHub can't see \(repo): if it's private, sign in with gh auth login") }
        if status == 403 { throw Problem("GitHub's hourly limit: try again later, or sign in with gh auth login") }
        guard status == 200 else { throw Problem("GitHub answered \(status)") }
        return data
    }

    nonisolated static func download(_ url: URL, to file: URL) throws {
        let (data, response) = try fetch(URLRequest(url: url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Problem("download failed (GitHub answered \(status)): \(url)") }
        try data.write(to: file)
    }

    /// gh from Homebrew (apps started from Finder don't get the Terminal's PATH).
    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Helpers

    /// ~/Library/Logs/OnlyNote/update.log: what updates did, and a build's output.
    nonisolated static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OnlyNote/update.log")
    }

    nonisolated static func log(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    /// Runs a program and returns its output (or writes it to `to`). Throws with the last line of
    /// its errors if it fails. `logOutput` also copies everything it prints into update.log.
    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                                in dir: URL? = nil, to file: URL? = nil, logOutput: Bool = false) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GH_PROMPT_DISABLED"] = "1"
        env.merge(extra) { $1 }
        p.environment = env
        let out = Pipe(), err = Pipe()
        var outFile: FileHandle?
        if let file {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            outFile = try FileHandle(forWritingTo: file)
            p.standardOutput = outFile
        } else {
            p.standardOutput = out
        }
        defer { try? outFile?.close() }
        p.standardError = err
        try p.run()
        // Read both while it runs, so a full pipe can't stall it.
        final class Box { var data = Data() }
        let errBox = Box()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errRead.leave()
        }
        let data = file == nil ? out.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        errRead.wait()
        let errData = errBox.data
        let name = (tool as NSString).lastPathComponent
        if logOutput {
            log("\(name) \(args.joined(separator: " "))\n\(String(decoding: data, as: UTF8.self))\(String(decoding: errData, as: UTF8.self))")
        }
        if p.terminationStatus != 0 {
            let lines = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            let msg = logOutput ? (lines.last(where: { $0.contains("error") }) ?? lines.last ?? "") : (lines.last ?? "")
            if name == "gh", msg.contains("auth login") || msg.contains("401") {
                throw Problem("gh isn't signed in: run gh auth login in Terminal")
            }
            let tail = msg.isEmpty ? "\(name) failed (\(p.terminationStatus))" : msg
            throw Problem(logOutput ? "\(tail) (details in \(logURL.path))" : tail)
        }
        return data
    }

    nonisolated static func fetch(_ req: URLRequest) throws -> (Data, URLResponse) {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error> = .failure(Problem("no answer"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let data, let response { result = .success((data, response)) } else { result = .failure(error ?? Problem("no answer")) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }
}
