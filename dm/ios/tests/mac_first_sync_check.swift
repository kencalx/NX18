// The Mac's first-sync wait for iCloud (dm/mac/MacFirstSync.swift), run by test_mac_first_sync.py: compiled with that file alone. A stand-in iCloud over temporary folders
// (placeholders as .<name>.icloud files, the download states from a table) and a clock the test moves: the record (first vs later, the folder changed, the host's own
// state), the paths, the rule, and whole checks (a current file, a placeholder that downloads, nothing listed with the folder busy or settled, a file listed late, a
// download that never ends, offline, a read error, a folder gone, a plain folder, Cancel). Expected values are written by hand from the rules in MacFirstSync.swift.
import Foundation

final class FakeCloud: FirstSyncCloud, @unchecked Sendable {
    var states: [String: FirstSyncItem] = [:]   // by path; a file or folder not in it is .current (in iCloud) or .local
    var inICloud = true, isOnline = true, read: FirstSyncRead = .ok
    var unlistable: Set<String> = []
    var slowReads = false, later: [@Sendable (FirstSyncRead) -> Void] = []   // slowReads: a coordinated read ends only when the test calls later
    var downloads: [String] = [], reads: [String] = []
    func names(in dir: URL) -> [String]? {
        if unlistable.contains(dir.path) { return nil }
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }
    func state(of url: URL) -> FirstSyncItem {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        return states[url.path] ?? (inICloud ? .current : .local)
    }
    func startDownload(_ url: URL) { downloads.append(url.lastPathComponent) }
    func coordinatedRead(_ url: URL, done: @escaping @Sendable (FirstSyncRead) -> Void) { reads.append(url.lastPathComponent); if slowReads { later.append(done) } else { done(read) } }
    func online() -> Bool { isOnline }
    var ends = 0
    func end() { ends += 1 }
}

nonisolated(unsafe) var failed = 0, checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failed += 1; print("FAIL: \(what)") } else { print("ok: \(what)") }
}

let title = "0100ABCDEF012000"
func make(_ p: String) { try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
func put(_ p: String) { FileManager.default.createFile(atPath: p, contents: Data("x".utf8)) }

/// One check over `folder` with the clock at 0: `script` runs after each pause with the time it moved to; returns the outcome and the time it ended at
func runCheck(_ folder: String, _ cloud: FakeCloud, limits: FirstSyncLimits = .standard, cancelAt: Double? = nil, _ script: (Double) -> Void = { _ in }) -> (FirstSyncOutcome, Double) {
    guard let paths = FirstSyncPaths(folder: folder, title: title) else { return (.cancelled, -1) }
    let c = FirstSyncCheck(paths: paths, cloud: cloud, limits: limits)
    var t = 0.0
    let o = c.run(now: { t }, pause: { step in t += step; script(t); if let at = cancelAt, t >= at { c.cancel() } })
    return (o, t)
}

@main struct Main {
    static func main() {
        let root = NSTemporaryDirectory() + "mac_first_sync.\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: root) }
        make(root)
        let home = root + "/home"

        // The record: first vs later, the folder changed, the host's state, sync off
        let nx = root + "/iCloud/NX 18", other = root + "/iCloud/NX 18 B"
        make(nx); make(other)
        let id = FirstSyncRecord.identity(nx, home: home)
        check(id != nil && FirstSyncRecord.identity(nx + "/", home: home) == id, "the folder's identity ignores a trailing slash")
        try? FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/iCloud")
        check(FirstSyncRecord.identity(root + "/link/NX 18", home: home) == id, "and a link to it is the same folder")
        check(FirstSyncRecord.needed(folder: nx, recorded: nil, hostSynced: false, home: home), "no record: a first sync")
        check(!FirstSyncRecord.needed(folder: nx, recorded: id, hostSynced: false, home: home), "the record names this folder: a later start, no wait")
        check(FirstSyncRecord.needed(folder: other, recorded: id, hostSynced: false, home: home), "another NX 18 folder: a first sync again")
        check(!FirstSyncRecord.needed(folder: other, recorded: id, hostSynced: true, home: home), "the host's sync state names this folder's file: no wait")
        check(!FirstSyncRecord.needed(folder: "0", recorded: nil, hostSynced: false, home: home) && !FirstSyncRecord.needed(folder: "", recorded: nil, hostSynced: false, home: home), "sync off: nothing to check")
        check(FirstSyncOutcome.ready.synced && FirstSyncOutcome.nothingThere.synced, "iCloud caught up (a file, or none): the record is written")
        check(!FirstSyncOutcome.held(.stillDownloading).synced && !FirstSyncOutcome.held(.unreachable).synced && !FirstSyncOutcome.held(.playAnyway).synced && !FirstSyncOutcome.cancelled.synced,
              "a held start or Cancel writes no record: the next start checks again")

        // The paths, as save_sync.c cloud_path
        let p = FirstSyncPaths(folder: nx, title: "0100abcdef012000", home: home)
        check(p?.file.path == nx + "/" + title + "/save.dmsync", "the file is <folder>/<TITLE ID>/save.dmsync")
        let own = FirstSyncPaths(folder: root + "/iCloud/0100abcdef012000/", title: title, home: home)
        check(own?.file.path == root + "/iCloud/0100abcdef012000/save.dmsync" && own?.root.path == root + "/iCloud", "a folder named after the game is the game's own: no second title ID")
        check(FirstSyncPaths(folder: "icloud", title: title, home: home)?.root.path == home + "/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves", "icloud is iCloud Drive/nxnative Saves")
        check(FirstSyncPaths(folder: "0", title: title, home: home) == nil, "0 is off")

        // The rule
        var l = FirstSyncLook()
        check(FirstSyncRule.step(l, elapsed: 0) == .wait(download: false), "nothing listed at first: wait")
        check(FirstSyncRule.step(l, elapsed: 3) == .done(.nothingThere), "nothing listed, the folder settled after 3 s: no save there")
        l.folderBusy = true
        check(FirstSyncRule.step(l, elapsed: 19.9) == .wait(download: false) && FirstSyncRule.step(l, elapsed: 20) == .done(.nothingThere), "nothing listed with the folder busy: up to 20 s")
        l.placeholder = true
        check(FirstSyncRule.step(l, elapsed: 0) == .wait(download: true) && FirstSyncRule.step(l, elapsed: 30) == .done(.held(.stillDownloading)), "a placeholder: download, held at 30 s")
        l = FirstSyncLook(); l.file = .downloading
        check(FirstSyncRule.step(l, elapsed: 29) == .wait(download: true), "a file downloading: wait")
        l.file = .current
        check(FirstSyncRule.step(l, elapsed: 0) == .done(.ready), "a current file: ready")
        l.file = .failed
        check(FirstSyncRule.step(l, elapsed: 0) == .done(.held(.unreachable)), "a download error: held")
        l = FirstSyncLook(); l.reachable = false; l.file = .current
        check(FirstSyncRule.step(l, elapsed: 0) == .done(.held(.unreachable)), "unreachable: held, whatever is listed")
        l = FirstSyncLook(); l.inICloud = false
        check(FirstSyncRule.step(l, elapsed: 0) == .done(.nothingThere), "a plain folder with no file: no wait")

        // Whole checks over the folders
        let game = nx + "/" + title, file = game + "/save.dmsync", ph = game + "/.save.dmsync.icloud"
        func reset() { try? FileManager.default.removeItem(atPath: game) }
        var c = FakeCloud()
        reset(); make(game); put(file)
        var (o, t) = runCheck(nx, c)
        check(o == .ready && t == 0, "the phone's save is here and current: ready at once")
        check(c.reads.contains("NX 18"), "the folder was read through the coordinator")

        c = FakeCloud(); reset(); make(game); put(ph)
        (o, t) = runCheck(nx, c) { now in
            if now >= 4, FileManager.default.fileExists(atPath: ph) { try? FileManager.default.removeItem(atPath: ph); put(file) }   // iCloud brings it at 4 s
        }
        check(o == .ready && t == 4, "a placeholder: downloaded at 4 s, then ready (\(t))")
        check(c.downloads == ["save.dmsync"] && c.reads.contains("save.dmsync"), "the download was asked for once, for the file itself")

        c = FakeCloud(); reset(); make(game); put(file); c.states[file] = .notDownloaded
        (o, t) = runCheck(nx, c) { now in if now >= 2 { c.states[file] = .downloading }; if now >= 5 { c.states[file] = .current } }
        check(o == .ready && t == 5, "a dataless file: downloading, current at 5 s")

        c = FakeCloud(); reset(); c.states[nx] = .downloading
        (o, t) = runCheck(nx, c)
        check(o == .nothingThere && t == 20, "nothing listed, the folder busy all along: no save there after 20 s (\(t))")

        c = FakeCloud(); reset()
        (o, t) = runCheck(nx, c)
        check(o == .nothingThere && t == 3, "nothing listed, the folder current: no save there after 3 s (\(t))")

        c = FakeCloud(); reset(); c.slowReads = true
        (o, t) = runCheck(nx, c)
        check(o == .nothingThere && t == 20, "nothing listed, the folder current, but iCloud's read of it has not ended: no early end, no save there after 20 s (\(t))")
        c = FakeCloud(); reset(); c.slowReads = true
        (o, t) = runCheck(nx, c) { now in if now >= 5 { for d in c.later { d(.ok) }; c.later = [] } }
        check(o == .nothingThere && t == 5, "and once that read ends (5 s), past the 3 s: no save there then (\(t))")

        c = FakeCloud(); reset(); c.states[nx] = .downloading
        (o, t) = runCheck(nx, c) { now in if now >= 2 && !FileManager.default.fileExists(atPath: ph) && !FileManager.default.fileExists(atPath: file) { make(game); put(ph) }; if now >= 6 { try? FileManager.default.removeItem(atPath: ph); put(file) } }
        check(o == .ready && t == 6, "iCloud lists the phone's save at 2 s and brings it at 6 s: ready (\(t))")

        c = FakeCloud(); reset(); make(game); put(ph)
        (o, t) = runCheck(nx, c)
        check(o == .held(.stillDownloading) && t == 30, "a download that never ends: held at 30 s (\(t))")

        c = FakeCloud(); reset(); make(game); put(file); c.isOnline = false
        (o, t) = runCheck(nx, c)
        check(o == .held(.unreachable) && t == 0, "offline: held at once, even with a file listed")

        c = FakeCloud(); reset(); c.read = .failed
        (o, _) = runCheck(nx, c)
        check(o == .held(.unreachable), "iCloud's read failed: held")

        c = FakeCloud(); reset(); make(game); c.unlistable = [game]
        (o, _) = runCheck(nx, c)
        check(o == .held(.unreachable), "the game's folder cannot be listed: held")

        c = FakeCloud()
        (o, _) = runCheck(root + "/iCloud/gone", c)
        check(o == .held(.unreachable), "the folder is gone: held")

        c = FakeCloud(); c.inICloud = false; reset()
        (o, t) = runCheck(nx, c)
        check(o == .nothingThere && t == 0, "a folder not in iCloud with no file: no wait")
        make(game); put(file)
        (o, t) = runCheck(nx, c)
        check(o == .ready && t == 0, "and with one: ready at once")

        c = FakeCloud(); reset(); c.states[nx] = .downloading
        (o, t) = runCheck(nx, c, cancelAt: 2)
        check(o == .cancelled && t == 2, "Cancel ends the wait at once")
        check(c.ends == 1, "and ends the layer's reads once")
        c = FakeCloud(); reset(); c.slowReads = true; make(game); put(file)
        (o, _) = runCheck(nx, c)
        check(o == .ready && c.ends == 1 && !c.later.isEmpty, "a check that ends with a read still in flight ends the layer (its reads cancelled)")

        print("mac first sync: \(checks) checks, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
