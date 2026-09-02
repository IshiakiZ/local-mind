import Foundation
import AppKit

/// Checking for updates is the ONLY thing in this app that touches the network,
/// and it only happens when the user asks. It sends no conversation data — just
/// a request to GitHub for the latest commit on `main`. The models stay offline.
@MainActor
final class Updater: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(sha: String, short: String, subject: String, when: String)
        case failed(String)
        case updating
    }

    @Published var state: State = .idle

    /// Off by default. Enabling it makes one request on launch — never more.
    @Published var autoCheck = Defaults.bool("autoCheckUpdates", false) {
        didSet { Defaults.set("autoCheckUpdates", autoCheck) }
    }

    var isUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    var canUpdate: Bool {
        !BuildInfo.repo.isEmpty
            && BuildInfo.commit != "unknown"
            && FileManager.default.fileExists(atPath: BuildInfo.sourceDir + "/build.sh")
    }

    /// Why the button is unavailable, in plain words.
    var unavailableReason: String? {
        if BuildInfo.repo.isEmpty { return "This copy wasn't built from a git checkout." }
        if BuildInfo.commit == "unknown" { return "This build has no version stamp." }
        if !FileManager.default.fileExists(atPath: BuildInfo.sourceDir + "/build.sh") {
            return "The source folder this was built from is gone (\(BuildInfo.sourceDir))."
        }
        return nil
    }

    func check() async {
        guard canUpdate else {
            state = .failed(unavailableReason ?? "Can't check for updates.")
            return
        }
        state = .checking
        let url = URL(string: "https://api.github.com/repos/\(BuildInfo.repo)/commits/main")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LocalMind", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                state = .failed(http.statusCode == 404
                    ? "Repository not found, or it's private and this Mac isn't signed in."
                    : "GitHub replied HTTP \(http.statusCode).")
                return
            }
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = o["sha"] as? String else {
                state = .failed("Couldn't read GitHub's reply.")
                return
            }
            if sha == BuildInfo.commit { state = .upToDate; return }

            let commit = o["commit"] as? [String: Any]
            let subject = (commit?["message"] as? String)?
                .split(separator: "\n").first.map(String.init) ?? "New version"
            let when = ((commit?["committer"] as? [String: Any])?["date"] as? String)
                .flatMap(Self.friendlyDate) ?? ""
            state = .available(sha: sha, short: String(sha.prefix(7)),
                               subject: subject, when: when)
        } catch {
            state = .failed("Couldn't reach GitHub: \(error.localizedDescription)")
        }
    }

    /// Hand off to update.sh, detached, so it survives this app being quit —
    /// which it must be, because a running app can't replace itself.
    func applyUpdate() {
        guard canUpdate else { return }
        state = .updating
        let script = BuildInfo.sourceDir + "/update.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            state = .failed("update.sh is missing from \(BuildInfo.sourceDir).")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, BuildInfo.sourceDir]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
        }
    }

    static func friendlyDate(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "d MMM yyyy"
        return out.string(from: d)
    }

    var installedSummary: String {
        let when = Self.friendlyDate(BuildInfo.committedAt).map { " · \($0)" } ?? ""
        return "\(BuildInfo.shortCommit)\(when)"
    }
}
