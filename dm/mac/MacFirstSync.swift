// The first sync of a game through a cloud folder on this Mac (the NX 18 folder, or the game's own): iCloud caught up first. Until iCloud Drive on this Mac has listed and
// downloaded the save another device put at <folder>/<title ID>/save.dmsync, the host's first mount (dm/host/save_sync.c mount_once) sees no cloud file there and sends this
// Mac's own older save, which the phone's next start then brings in as "only the cloud changed" (its own save survives only in its backups). So before the first sync (no
// record yet that this Mac synced this game through this folder: FirstSyncRecord), the launcher asks iCloud for the game's folder and file (a coordinated read, a download
// of a file iCloud has only listed) and waits, bounded, until the file is downloaded and current, or until iCloud has listed nothing for a while (no save on any device:
// the Mac's goes up as before). When iCloud cannot be reached, or the wait runs out while the file is still coming, the start is held: the game plays from this Mac's
// save and the host sends nothing this time (DM_SAVE_SYNC_CHOICE=hold, save_sync.c), and the next start checks again. Never longer than FirstSyncLimits.
// Later starts do not wait: the record (FirstSyncRecord.key in the app's preferences, the folder's identity), or the host's own sync state naming this folder's file
// (save_sync_synced), says this Mac has synced the game through it. Another folder is a first sync again.
// Foundation only (no AppKit): the window's line, the alerts and the card's move use it from dm/mac/Launcher.swift (FirstSyncGate); dm/ios/tests/test_mac_first_sync.py runs
// the rules over temporary folders with a stand-in iCloud (FirstSyncCloud). Efficiency: nothing runs once the check has ended; during the bounded wait only, the folder is
// listed again about once a second. The log names no folder.
import Foundation
import Network

/// What iCloud says of one file or folder
enum FirstSyncItem: Equatable, Sendable {
    case absent          // not there
    case local           // there, and not in iCloud (a plain folder): nothing to wait for
    case current         // in iCloud, downloaded and current
    case downloading     // in iCloud, on its way
    case notDownloaded   // in iCloud, only listed (a placeholder, or a dataless file)
    case failed          // iCloud gave a download error (offline, the account signed out)
    case unreadable      // its state cannot be read
}

/// What a folder's own iCloud read said (NSFileCoordinator)
enum FirstSyncRead: Equatable, Sendable { case ok, missing, failed }

/// The iCloud layer the check asks (ICloudLayer on this Mac; a stand-in over temporary folders in the tests)
protocol FirstSyncCloud: AnyObject, Sendable {
    func names(in dir: URL) -> [String]?        // the folder's entries, placeholders (.<name>.icloud) included; [] for a folder not there; nil when it cannot be listed
    func state(of url: URL) -> FirstSyncItem
    func startDownload(_ url: URL)              // the file's own URL, also for a placeholder
    func coordinatedRead(_ url: URL, done: @escaping @Sendable (FirstSyncRead) -> Void)   // asynchronous: a download it starts may take longer than the wait
    func online() -> Bool                       // a network path (only asked for a folder in iCloud)
    func end()                                  // the check has ended: reads still in flight are cancelled, nothing of it runs on
}

/// The bounds of the wait, in seconds: settle (nothing listed, the folder's own iCloud state current: no save anywhere), list (nothing listed at all), download (a file listed)
struct FirstSyncLimits: Equatable, Sendable {
    var settle = 3.0, list = 20.0, download = 30.0, step = 1.0
    static let standard = FirstSyncLimits()
}

/// Where the game's cloud file is, as save_sync.c cloud_path finds it: <folder>/<TITLE ID>/save.dmsync, or <folder>/save.dmsync for a folder that is the game's own
/// (named after the title ID); "icloud" is iCloud Drive/nxnative Saves
struct FirstSyncPaths: Equatable, Sendable {
    let root: URL, gameDir: URL
    var file: URL { gameDir.appendingPathComponent("save.dmsync") }
    var placeholderName: String { ".save.dmsync.icloud" }
    /// The folder a DM_SAVE_SYNC value names ("icloud" resolved, no trailing slash); nil when it says off
    static func folder(_ v: String, home: String?) -> String? {
        var f = v
        if f.isEmpty || f == "0" { return nil }
        if f == "icloud" {
            guard let home, !home.isEmpty else { return nil }
            f = home + "/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves"
        }
        while f.count > 1 && f.hasSuffix("/") { f.removeLast() }
        return f
    }
    init?(folder: String, title: String, home: String? = ProcessInfo.processInfo.environment["HOME"]) {
        guard let f = Self.folder(folder, home: home) else { return nil }
        let id = title.uppercased()
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let r = URL(fileURLWithPath: f, isDirectory: true)
        if r.lastPathComponent.caseInsensitiveCompare(id) == .orderedSame { root = r.deletingLastPathComponent(); gameDir = r }
        else { root = r; gameDir = r.appendingPathComponent(id, isDirectory: true) }
    }
}

/// The record that this Mac has synced a game through a folder: FirstSyncRecord.key in the app's preferences holds the folder's identity (its path with links resolved)
enum FirstSyncRecord {
    static let key = "cloudSaves.firstSync"
    static func identity(_ folder: String, home: String? = ProcessInfo.processInfo.environment["HOME"]) -> String? {
        guard let f = FirstSyncPaths.folder(folder, home: home) else { return nil }   // the folder as the paths take it ("icloud" resolved)
        return URL(fileURLWithPath: f, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// Whether this start is the first sync through `folder`: no record of it, and the host's sync state names another file (or none)
    static func needed(folder: String, recorded: String?, hostSynced: Bool, home: String? = ProcessInfo.processInfo.environment["HOME"]) -> Bool {
        guard let id = identity(folder, home: home) else { return false }   // sync off
        return !hostSynced && recorded != id
    }
}

/// Why a start is held (the game plays from this Mac's save, nothing is sent)
enum FirstSyncHold: Equatable, Sendable {
    case unreachable        // iCloud cannot be reached (offline, a read error, the folder cannot be listed)
    case stillDownloading   // the wait ran out while the file was still coming
    case playAnyway         // the player did not wait
    var log: String {
        switch self {
        case .unreachable: return "iCloud cannot be reached"
        case .stillDownloading: return "this game's save is still downloading"
        case .playAnyway: return "the player did not wait"
        }
    }
}

enum FirstSyncOutcome: Equatable, Sendable {
    case ready          // iCloud's file is here, downloaded and current: the host compares it as ever
    case nothingThere   // no save of this game in iCloud (or a folder not in iCloud): this Mac's goes there as ever
    case held(FirstSyncHold)
    case cancelled      // the check was stopped (Cancel): no start
    var synced: Bool { self == .ready || self == .nothingThere }   // the record is written
}

/// One look at the folder, and the rule that decides from it
struct FirstSyncLook: Equatable, Sendable {
    var reachable = true    // the folder can be listed, iCloud gave no error, a network path for a folder in iCloud
    var inICloud = true     // the folder is in iCloud Drive
    var file: FirstSyncItem = .absent
    var placeholder = false // .save.dmsync.icloud listed
    var folderBusy = false  // the folder's (or the game folder's) own iCloud state: downloading, or not current
}

enum FirstSyncStep: Equatable, Sendable { case done(FirstSyncOutcome), wait(download: Bool) }

enum FirstSyncRule {
    static func step(_ l: FirstSyncLook, elapsed: Double, limits: FirstSyncLimits = .standard) -> FirstSyncStep {
        if !l.reachable { return .done(.held(.unreachable)) }
        if !l.inICloud { return .done(l.file == .absent && !l.placeholder ? .nothingThere : .ready) }   // a plain folder: what is there is all there is
        switch l.file {
        case .current, .local: return .done(.ready)
        case .failed, .unreadable: return .done(.held(.unreachable))
        case .downloading, .notDownloaded: return elapsed >= limits.download ? .done(.held(.stillDownloading)) : .wait(download: true)
        case .absent:
            if l.placeholder { return elapsed >= limits.download ? .done(.held(.stillDownloading)) : .wait(download: true) }
            if elapsed >= limits.list || (elapsed >= limits.settle && !l.folderBusy) { return .done(.nothingThere) }
            return .wait(download: false)
        }
    }
}

/// The check itself: run() blocks until it ends (FirstSyncLimits at most), so call it off the main thread; cancel() ends it at once (.cancelled)
final class FirstSyncCheck: @unchecked Sendable {
    let paths: FirstSyncPaths
    private let cloud: FirstSyncCloud, limits: FirstSyncLimits
    private let lock = NSLock(), wake = DispatchSemaphore(value: 0)
    private var stopped = false, readFailed = false, rootRead = false   // rootRead: iCloud's coordinated read of the folder has ended (it lists the folder first)

    init(paths: FirstSyncPaths, cloud: FirstSyncCloud, limits: FirstSyncLimits = .standard) { self.paths = paths; self.cloud = cloud; self.limits = limits }

    func cancel() { lock.lock(); stopped = true; lock.unlock(); wake.signal() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func read(_ url: URL) {
        let root = url == paths.root
        cloud.coordinatedRead(url) { [weak self] r in
            guard let self else { return }
            self.lock.lock()
            if r == .failed { self.readFailed = true } else if root { self.rootRead = true }
            self.lock.unlock()
            if r == .failed { self.wake.signal() }   // the wait ends at once: held
        }
    }

    /// What iCloud shows of the folder now
    func look() -> FirstSyncLook {
        var l = FirstSyncLook()
        lock.lock(); let failed = readFailed, rootDone = rootRead; lock.unlock()
        guard !failed, let top = cloud.names(in: paths.root) else { l.reachable = false; return l }
        let rootState = cloud.state(of: paths.root)
        if rootState == .absent || rootState == .failed || rootState == .unreadable { l.reachable = false; return l }
        l.inICloud = rootState != .local
        if l.inICloud && !cloud.online() { l.reachable = false; return l }
        let busy: (FirstSyncItem) -> Bool = { $0 == .downloading || $0 == .notDownloaded }
        // Still busy while iCloud's own read of the folder has not ended: a folder can say it is current while iCloud has not yet fetched what the other devices put
        // in it, so nothing listed ends early (the settle) only after that read, else at the list limit
        l.folderBusy = busy(rootState) || !rootDone
        let game = paths.gameDir.lastPathComponent
        if top.contains(game) || top.contains("." + game + ".icloud") {
            guard let names = cloud.names(in: paths.gameDir) else { l.reachable = false; return l }
            let gameState = top.contains(game) ? cloud.state(of: paths.gameDir) : .notDownloaded
            if gameState == .failed { l.reachable = false; return l }
            l.folderBusy = l.folderBusy || busy(gameState) || !top.contains(game)
            l.placeholder = names.contains(paths.placeholderName)
            l.file = names.contains("save.dmsync") ? cloud.state(of: paths.file) : .absent
        }
        return l
    }

    func run() -> FirstSyncOutcome {
        run(now: { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }, pause: { [wake] s in _ = wake.wait(timeout: .now() + s) })   // cancel() and a failed read end a pause early
    }
    /// With the test's clock: `pause` stands for the bounded wait's step
    func run(now: () -> Double, pause: (Double) -> Void) -> FirstSyncOutcome {
        defer { cloud.end() }   // however it ends (ready, nothing there, held, cancelled): iCloud's reads still waiting are cancelled
        let start = now()
        read(paths.root)   // iCloud lists the folder (and downloads what a read asks for)
        var asked = false
        while true {
            if isStopped { return .cancelled }
            let step = FirstSyncRule.step(look(), elapsed: now() - start, limits: limits)
            switch step {
            case .done(let o): return o
            case .wait(let download):
                if download && !asked {   // the file iCloud has listed: download it now
                    asked = true
                    cloud.startDownload(paths.file); read(paths.gameDir); read(paths.file)
                }
            }
            pause(limits.step)   // the bounded wait's only re-listing, about once a second
        }
    }
}

/// iCloud Drive on this Mac: resource values, NSFileCoordinator, startDownloadingUbiquitousItem and the network path (NWPathMonitor, asked once and kept while the check runs)
final class ICloudLayer: FirstSyncCloud, @unchecked Sendable {
    private let lock = NSLock(), queue = DispatchQueue(label: "nx18.firstsync")
    private var monitor: NWPathMonitor?, path: Bool?
    private let coordinators = OperationQueue()
    private var held: [NSFileCoordinator] = []   // kept until the check's end (end()): a coordinated read in flight keeps its coordinator

    deinit { monitor?.cancel() }

    /// The check's end: every coordinated read still waiting on iCloud is cancelled (its accessor gets a cancel error, which the check, ended, no longer reads) and the
    /// network watch stops, so nothing of the check runs on into the game
    func end() {
        lock.lock(); let readers = held, m = monitor; held = []; monitor = nil; lock.unlock()
        for fc in readers { fc.cancel() }
        m?.cancel()
    }

    func names(in dir: URL) -> [String]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return nil }
        return try? FileManager.default.contentsOfDirectory(atPath: dir.path)
    }
    func state(of url: URL) -> FirstSyncItem {
        let u = URL(fileURLWithPath: url.path)   // a URL of its own: resource values are cached per URL object
        guard FileManager.default.fileExists(atPath: u.path) else { return .absent }
        guard let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey])
        else { return .unreadable }
        if v.isUbiquitousItem != true { return .local }
        if v.ubiquitousItemDownloadingError != nil { return .failed }
        if v.ubiquitousItemDownloadingStatus == .current { return .current }
        return v.ubiquitousItemIsDownloading == true ? .downloading : .notDownloaded
    }
    func startDownload(_ url: URL) { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
    func coordinatedRead(_ url: URL, done: @escaping @Sendable (FirstSyncRead) -> Void) {
        let fc = NSFileCoordinator(filePresenter: nil)
        lock.lock(); held.append(fc); lock.unlock()
        fc.coordinate(with: [.readingIntent(with: url, options: [])], queue: coordinators) { error in
            guard let e = error as NSError? else { done(.ok); return }
            if e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError) { done(.missing); return }
            // an iCloud error (NSUbiquitousFileUnavailableError and its range) says it cannot be reached; another (a folder iCloud does not manage) says nothing of iCloud
            done(e.domain == NSCocoaErrorDomain && (NSUbiquitousFileErrorMinimum...NSUbiquitousFileErrorMaximum).contains(e.code) ? .failed : .ok)
        }
    }
    func online() -> Bool {
        lock.lock()
        if monitor == nil {
            let m = NWPathMonitor(), first = DispatchSemaphore(value: 0)
            m.pathUpdateHandler = { [weak self] p in
                guard let self else { return }
                self.lock.lock(); let was = self.path; self.path = p.status == .satisfied; self.lock.unlock()
                if was == nil { first.signal() }
            }
            monitor = m; lock.unlock()
            m.start(queue: queue)
            _ = first.wait(timeout: .now() + 1)   // its first answer comes at once
            lock.lock()
        }
        let on = path ?? true   // no answer: not taken as offline (the reads still say)
        lock.unlock()
        return on
    }
}
