import Foundation
import Observation

/// A commit on the remote branch that the checkout does not have yet.
struct Commit: Identifiable, Hashable, Sendable {
    var hash: String
    var author: String
    var when: String
    var subject: String
    var id: String { hash }
}

/// The Nintanium checkout the builds run from: cloned once, then kept up to date with the remote branch (fast-forward only, so nothing of the player's is ever overwritten).
@MainActor @Observable
final class Repository {
    var exists = false
    var head = ""            // short hash and subject
    var incoming: [Commit] = []
    var localChanges = false
    var busy = false
    var writing = false      // a pull or a clone changes the checkout's files: no build or copy starts from it meanwhile (a fetch, busy alone, leaves them)
    var lastChecked: Date?
    var message = ""
    /// Lines of the pulled commits that a front end has to act on (docs/frontends.md, Following main).
    var notes: [String] = []

    private var path = ""
    private var branch = "main"

    func configure(path: String, branch: String) { self.path = path; self.branch = branch }

    private var url: URL { URL(fileURLWithPath: path) }

    private func git(_ args: [String]) async -> CommandResult { await Shell.run("git", ["-C", path] + args) }

    func refresh() async {
        exists = FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/build_ipa_from_nsp.py").path)
        guard exists else { head = ""; incoming = []; return }
        let h = await git(["log", "-1", "--format=%h  %s"])
        head = h.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        localChanges = !(await git(["status", "--porcelain", "--untracked-files=no"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let log = await git(["log", "--format=%h%x09%an%x09%ar%x09%s", "HEAD..origin/\(branch)"])
        incoming = log.stdout.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3).map(String.init)
            return f.count == 4 ? Commit(hash: f[0], author: f[1], when: f[2], subject: f[3]) : nil
        }
    }

    /// Fetches the remote branch and lists what it has that the checkout does not.
    func check() async {
        guard exists, !busy else { return }
        busy = true; defer { busy = false }
        let r = await git(["fetch", "--quiet", "origin", branch])
        message = r.ok ? "" : "Could not check for updates: \(r.reason)"
        lastChecked = Date()
        await refresh()
    }

    /// Pulls the new commits (fast-forward only). Returns whether the checkout moved.
    @discardableResult
    func pull() async -> Bool {
        guard exists, !busy else { return false }
        busy = true; writing = true; defer { busy = false; writing = false }
        let before = (await git(["rev-parse", "HEAD"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = await git(["pull", "--ff-only", "--quiet", "origin", branch])
        guard r.ok else {
            message = "Could not update: \(r.reason)" + (localChanges ? " (the checkout has changes of its own: commit or discard them, then update again)" : "")
            await refresh(); return false
        }
        let after = (await git(["rev-parse", "HEAD"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if before != after {
            let n = (await git(["rev-list", "--count", "\(before)..\(after)"])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let fe = await git(["log", "--format=%b", "\(before)..\(after)"])
            notes = fe.stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Front-ends:") }
            message = "Updated: \(n) new commit\(n == "1" ? "" : "s")."
        } else { message = "Already up to date." }
        lastChecked = Date()
        await refresh()
        return before != after
    }

    func clone(from remote: String) async {
        guard !busy else { return }
        busy = true; writing = true; defer { busy = false; writing = false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        message = "Cloning \(remote)…"
        let r = await Shell.run("git", ["clone", "--branch", branch, remote, path])
        message = r.ok ? "Cloned into \(path)." : "Could not clone: \(r.reason)"
        await refresh()
    }
}
