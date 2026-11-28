// Where a game's My files live (Settings › Profile › Keep My files in the NX 18 folder; docs/beam.md, My files in the NX 18 folder):
//   · off, or no NX 18 folder connected: Beam's own folder, <Beam library>/My Files/<TITLE ID> (never packed into an IPA)
//   · on, with an NX 18 folder connected: <NX 18 folder>/<TITLE ID>/Documents (GameDocuments.folderName), beside the game's Captures, so the game apps on every device that
//     connected the folder list them in the game (GameDocuments.swift), and so does Beam on another Mac
// settle() brings the files to where the switch says, for every game or one, and is safe to run again at any time:
//   · on: every file in Beam's folder for a game moves into the NX 18 folder's, and Beam notes its name (the ledger: My Files/.in-nx18-folder.json, per title ID)
//   · off: only the files the ledger names move back. The rest of <TITLE ID>/Documents is not Beam's to take: another Mac's Beam put it there, or the player did in the Files app,
//     and other devices still use it; it stays, and the game page says where to find it. A file still in iCloud (a placeholder) is asked for and waits for the next settle
// Moves are coordinated (NSFileCoordinator, for moving and replacing) and never overwrite: a name already taken gets " 2" ("map.pdf" → "map 2.pdf", then " 3" and so on).
// Nothing is ever deleted. A file the ledger names that is gone from the folder (removed or renamed on another device) is dropped from the ledger. Logs give counts only
import Foundation

enum MyFilesPlace {
    struct Report: Equatable, Sendable {
        var moved = 0      // files moved this time
        var waiting = 0    // still in iCloud: asked for, moved at a later settle
        var failed = 0
    }

    static func local(library: URL, titleID: String) -> URL {
        library.appending(path: "My Files/\(titleID.uppercased())", directoryHint: .isDirectory)
    }
    /// Where Add Files writes and the game page reads, for the switch and the connected folder
    static func current(library: URL, titleID: String, keepInNX18: Bool, nx18: URL?) -> URL {
        if keepInNX18, let nx18, reachable(nx18) { return GameDocuments.nx18Folder(titleID: titleID, nx18: nx18) }
        return local(library: library, titleID: titleID)
    }
    /// The connected NX 18 folder is there (not renamed, removed or signed out of iCloud since it was connected): a gone one is never made again just to put My files in, where
    /// no device would look for them
    static func reachable(_ nx18: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: nx18.path, isDirectory: &dir) && dir.boolValue
    }

    // ---- the ledger: the names Beam put in the NX 18 folder, per title ID ----
    static func ledgerURL(library: URL) -> URL { library.appending(path: "My Files/.in-nx18-folder.json") }
    /// Every read-change-write of the ledger holds this: a settle (a background task) and Add Files (another) both change it
    private static let ledgerLock = NSLock()
    static func ledger(library: URL) -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: ledgerURL(library: library)))) ?? [:]
    }
    static func saveLedger(_ l: [String: [String]], library: URL) {
        let u = ledgerURL(library: library)
        let kept = l.filter { !$0.value.isEmpty }
        if kept.isEmpty { try? FileManager.default.removeItem(at: u); return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(kept).write(to: u, options: .atomic)
    }

    /// The files to settle in a folder: every entry but hidden ones and iCloud placeholders (GameDocuments.placeholder)
    static func entries(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { GameDocuments.placeholder($0.lastPathComponent)?.placeholder == false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A free name in dir for name: name itself, else "name 2.ext", "name 3.ext"… (a name iCloud holds as a placeholder counts as taken)
    static func freeName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        func taken(_ n: String) -> Bool { fm.fileExists(atPath: dir.appending(path: n).path) || fm.fileExists(atPath: dir.appending(path: ".\(n).icloud").path) }
        if !taken(name) { return name }
        let ext = (name as NSString).pathExtension, stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let n = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !taken(n) { return n }
            i += 1
        }
    }

    /// Moves src into dir under a free name, coordinated; the name it got, nil when it could not be moved (src stays as it was)
    @discardableResult static func move(_ src: URL, into dir: URL) -> String? {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        for _ in 0..<3 {   // a name taken between the look and the move: the move refuses (it never overwrites) and the next free name is tried
            let name = freeName(src.lastPathComponent, in: dir), dst = dir.appending(path: name)
            var done = false, err: NSError?
            let c = NSFileCoordinator(filePresenter: nil)
            c.coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &err) { s, d in
                // no item(at:didMoveTo:): Foundation logs the file's path for each (a sandbox extension for presenters), Beam presents none of these files, and iCloud Drive follows
                // the move itself
                guard !fm.fileExists(atPath: d.path) else { return }
                done = (try? fm.moveItem(at: s, to: d)) != nil
            }
            if done { return name }
            if err != nil || !fm.fileExists(atPath: src.path) { return nil }
        }
        return nil
    }

    /// Copies a file the player added into dir under a free name (coordinated, as the NX 18 folder is in iCloud Drive); the name it got
    @discardableResult static func add(_ src: URL, into dir: URL) -> String? {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let name = freeName(src.lastPathComponent, in: dir), dst = dir.appending(path: name)
        var done = false, err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { d in
            guard !fm.fileExists(atPath: d.path) else { return }
            done = (try? fm.copyItem(at: src, to: d)) != nil
        }
        return done ? name : nil
    }
    /// Notes a name Beam put in a game's NX 18 Documents (Add Files with the switch on), so turning the switch off brings it back
    static func noteAdded(_ name: String, titleID: String, library: URL) {
        changeLedger(library: library) { l in
            let tid = titleID.uppercased()
            if !(l[tid] ?? []).contains(name) { l[tid, default: []].append(name) }
        }
    }
    /// Reads, changes and writes the ledger under its lock, so a change made meanwhile by another task is never written over
    static func changeLedger(library: URL, _ change: (inout [String: [String]]) -> Void) {
        ledgerLock.lock(); defer { ledgerLock.unlock() }
        var l = ledger(library: library)
        change(&l)
        saveLedger(l, library: library)
    }

    /// Brings the files to where the switch says (see the top of this file); titleIDs nil: every game Beam has My files or ledger entries for. Blocks: run it off the main thread
    static func settle(library: URL, keepInNX18: Bool, nx18: URL?, titleIDs: [String]? = nil) -> Report {
        var report = Report()
        // no folder connected, or the connected one is gone: nothing moves either way (the files stay where they are until one is there)
        guard let nx18, reachable(nx18) else { return report }
        let l = ledger(library: library)
        var added: [String: [String]] = [:], done: [String: Set<String>] = [:]   // what this settle changes, written over the ledger as it is then (Add Files may have noted a name)
        let fm = FileManager.default
        if keepInNX18 {
            let all = ((try? fm.contentsOfDirectory(atPath: library.appending(path: "My Files").path)) ?? []).filter { !$0.hasPrefix(".") }
            let wanted = titleIDs.map { Set($0.map { $0.uppercased() }) }
            for tid in all.map({ $0.uppercased() }) where wanted?.contains(tid) ?? true {
                let from = local(library: library, titleID: tid), to = GameDocuments.nx18Folder(titleID: tid, nx18: nx18)
                for f in entries(from) {
                    if let name = move(f, into: to) { added[tid, default: []].append(name); report.moved += 1 } else { report.failed += 1 }
                }
            }
        } else {
            for (tid, names) in l where titleIDs.map({ $0.map { $0.uppercased() }.contains(tid) }) ?? true {
                let from = GameDocuments.nx18Folder(titleID: tid, nx18: nx18), to = local(library: library, titleID: tid)
                for name in names {
                    let f = from.appending(path: name)
                    if fm.fileExists(atPath: from.appending(path: ".\(name).icloud").path) {   // still in iCloud: asked for, moved next time
                        try? fm.startDownloadingUbiquitousItem(at: f); report.waiting += 1; continue
                    }
                    guard fm.fileExists(atPath: f.path) else { done[tid, default: []].insert(name); continue }   // removed or renamed elsewhere: no longer Beam's to bring back
                    if move(f, into: to) != nil { done[tid, default: []].insert(name); report.moved += 1 } else { report.failed += 1 }
                }
            }
        }
        if !added.isEmpty || !done.isEmpty {
            changeLedger(library: library) { l in
                for (tid, names) in added { for n in names where !(l[tid] ?? []).contains(n) { l[tid, default: []].append(n) } }
                for (tid, names) in done { l[tid] = l[tid]?.filter { !names.contains($0) } }
            }
        }
        if report != Report() { fputs("beam: My files: \(report.moved) moved \(keepInNX18 ? "to" : "from") the NX 18 folder, \(report.waiting) waiting on iCloud, \(report.failed) not moved\n", stderr) }
        return report
    }
}
