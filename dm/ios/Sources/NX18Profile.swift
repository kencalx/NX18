// The NX 18 Profile (NX18-X2.0 gate-ui.md §20.5, G13): a name and a picture the games see (DM_NICK, DM_PROFILE_IMAGE: hle_account.c), kept per app and, with the NX 18
// folder, shared by every game app on every device. Plain files, so the Mac's launcher.c reads the same layout with no JSON parser:
//   iOS:  Library/Application Support/Profile/{name.txt, picture.jpg, profile.stamp, appearance.txt}; the per-app switch is nx18.profile in the app's defaults
//   Mac:  ~/Library/Application Support/nxnative/Profile/ (shared by all NX 18 Mac apps); the NX 18 folder's path in nxnative/nx18-folder (one line)
//   seed: <App>.app/NX18ProfileSeed/ with the same files, put there by NX 18 Beam before it signs an iPhone or iPad game (beam/Sources/Model/ProfileSetup.swift): this app's
//   Profile takes it when it has none yet or the seed's stamp is higher (applySeed), so a game Beam installs starts with the player's name and picture. It is not the folder.
//   folder: <NX 18>/Profile/ with the same files. profile.stamp is one line, "<generation> <device id>": an edit writes the picture and the name first and the stamp last,
//   with the highest generation seen + 1. The higher stamp wins, never the newer date (device clocks differ); the device id breaks a tie.
// Reads and writes of the folder are coordinated (NSFileCoordinator) and off the main thread. A look at the folder is cheap first (the stamp's resource values: date, size,
// download status); a coordinated read, which can start a download, happens only when they changed. After a coordinated read, iCloud's conflict versions are resolved: the
// version with the highest stamp stays, the others are removed and marked resolved. Stray copies ("name 2.txt") are never read.
// Privacy: the name and the picture stay on the device and in the player's own iCloud Drive, never in Documents, Share log or the log (only "profile: on" / "off").
import Foundation
import ImageIO
import os   // OSAllocatedUnfairLock
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// GW21: 1-10 characters and at most 32 UTF-8 bytes, trimmed; letters of any script, digits, spaces and - ' . _. Empty means "Player"
enum NX18ProfileName {
    static let maxCharacters = 10
    static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        guard t.count <= maxCharacters, t.utf8.count <= 32 else { return nil }
        for u in t.unicodeScalars {
            if " -'._".unicodeScalars.contains(u) || CharacterSet.decimalDigits.contains(u) || CharacterSet.letters.contains(u) { continue }
            if CharacterSet.nonBaseCharacters.contains(u) { continue }   // a letter's combining mark (é written as e + ´)
            return nil
        }
        return t
    }
    static let refusal = "Letters, digits, spaces and - ' . _ only, up to 10."
}

struct NX18Stamp: Comparable, Equatable {
    var generation: Int
    var device: String
    init(generation: Int, device: String) { self.generation = generation; self.device = device }
    init?(_ line: String) {
        let p = line.split(separator: " ")
        guard p.count >= 2, let g = Int(p[0]) else { return nil }
        generation = g; device = String(p[1])
    }
    var line: String { "\(generation) \(device)" }
    static func < (a: NX18Stamp, b: NX18Stamp) -> Bool { a.generation != b.generation ? a.generation < b.generation : a.device < b.device }
}

@MainActor
final class NX18Profile: ObservableObject {
    static let shared = NX18Profile()
    nonisolated static let switchKey = "nx18.profile"
    nonisolated static let deviceKey = "nx18.device"
    nonisolated static let changed = Notification.Name("nx18.profile.changed")

    @Published private(set) var name = "Player"
    @Published private(set) var hasPicture = false
    @Published private(set) var pictureVersion = 0      // bumps when the picture changes, so the card reloads its 72 pt image
    @Published var folderState: FolderState = .none

    enum FolderState: Equatable { case none, chosen(String), stale, unreachable }

    let local: URL
    nonisolated static func localRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return base.appendingPathComponent("nxnative/Profile", isDirectory: true)
        #else
        return base.appendingPathComponent("Profile", isDirectory: true)
        #endif
    }
    init(root: URL = NX18Profile.localRoot()) {
        local = root
        if root == Self.localRoot(), Self.bundledSeed,   // the Profile Beam put in this app (before the first read)
           let a = (try? String(contentsOf: root.appendingPathComponent("appearance.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
           let look = NX18Appearance(rawValue: a), look != NX18Appearance.current {
            NX18Appearance.store(look, fromFolder: true)   // as a pull from the folder brings it: nothing is written back
        }
        reload()
        if root == Self.localRoot() { NX18Appearance.share = { Self.shareAppearance($0, root: root) } }
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.switchKey) as? Bool ?? true }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: Self.switchKey); fputs("profile: \(newValue ? "on" : "off")\n", stderr); NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    var pictureURL: URL { local.appendingPathComponent("picture.jpg") }
    var isSet: Bool { name != "Player" || hasPicture }

    nonisolated static var deviceID: String {
        if let d = UserDefaults.standard.string(forKey: deviceKey), !d.isEmpty { return d }
        let d = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        UserDefaults.standard.set(d, forKey: deviceKey)
        return d
    }

    func reload() {
        let n = (try? String(contentsOf: local.appendingPathComponent("name.txt"), encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        name = NX18ProfileName.clean(n).flatMap { $0.isEmpty ? nil : $0 } ?? "Player"
        hasPicture = FileManager.default.fileExists(atPath: pictureURL.path)
    }

    // ---- edits (local first, then the folder) ----
    func setName(_ raw: String) -> Bool {
        guard let n = NX18ProfileName.clean(raw) else { return false }
        Self.writeLocal(at: local, name: n.isEmpty ? "Player" : n, picture: nil, appearance: nil)
        reload(); afterEdit()
        return true
    }
    func setPicture(jpeg: Data) {
        Self.writeLocal(at: local, name: nil, picture: jpeg, appearance: nil)
        reload(); pictureVersion += 1; afterEdit()
    }
    func clearPicture() { try? FileManager.default.removeItem(at: pictureURL); Self.bumpLocal(at: local); reload(); pictureVersion += 1; afterEdit() }
    // The look goes with the Profile when it uses the NX 18 folder (§20.5b): appearance.txt and a new stamp here, then the folder (off the main thread). Otherwise per app only
    nonisolated static func shareAppearance(_ value: NX18Appearance, root: URL, defaults: UserDefaults = .standard, folder: URL? = folderURL(), wait: Bool = false) -> Bool {
        guard defaults.object(forKey: switchKey) as? Bool ?? true, let folder else { return false }
        writeLocal(at: root, name: nil, picture: nil, appearance: value.rawValue)
        if wait { NX18ProfileSync.push(local: root, folder: folder) } else { DispatchQueue.global(qos: .utility).async { NX18ProfileSync.push(local: root, folder: folder) } }
        return true
    }

    private func afterEdit() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
        guard let folder = Self.folderURL() else { return }
        let local = self.local
        DispatchQueue.global(qos: .utility).async { NX18ProfileSync.push(local: local, folder: folder) }
    }

    nonisolated static func bumpLocal(at root: URL) {
        let s = NX18ProfileSync.readStamp(root.appendingPathComponent("profile.stamp")) ?? NX18Stamp(generation: 0, device: deviceID)
        try? (NX18Stamp(generation: s.generation + 1, device: deviceID).line + "\n").write(to: root.appendingPathComponent("profile.stamp"), atomically: true, encoding: .utf8)
    }
    nonisolated static func writeLocal(at root: URL, name: String?, picture: Data?, appearance: String?) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let p = picture { try? p.write(to: root.appendingPathComponent("picture.jpg"), options: .atomic) }
        if let n = name { try? (n + "\n").write(to: root.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8) }
        if let a = appearance { try? (a + "\n").write(to: root.appendingPathComponent("appearance.txt"), atomically: true, encoding: .utf8) }
        bumpLocal(at: root)   // the stamp last
    }

    // ---- the seed from Beam ----
    nonisolated static let seedFolder = "NX18ProfileSeed"
    // Once per run, before the first read (init) or the games' env (applyEnv), whichever comes first: true when the app's bundled seed went into this app's Profile
    nonisolated static let bundledSeed: Bool = {
        #if os(iOS)
        return applySeed(Bundle.main.bundleURL.appendingPathComponent(seedFolder, isDirectory: true), to: localRoot())
        #else
        return false   // the Mac game apps share the Mac's Profile, which Beam edits in place
        #endif
    }()
    // A seed's Profile into `root` when `root` has no stamp yet (never set on this install) or the seed's stamp is higher (a reinstall from Beam after a newer edit). An edit made
    // here since (a higher stamp) is never overwritten by an older seed. The picture and the name first, the stamp last, as writeLocal; the folder is not touched
    @discardableResult nonisolated static func applySeed(_ seed: URL, to root: URL) -> Bool {
        guard let theirs = NX18ProfileSync.readStamp(seed.appendingPathComponent("profile.stamp")) else { return false }
        if let mine = NX18ProfileSync.readStamp(root.appendingPathComponent("profile.stamp")), mine >= theirs { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        for f in NX18ProfileSync.files {
            let src = seed.appendingPathComponent(f), dst = root.appendingPathComponent(f)
            if fm.fileExists(atPath: src.path) { try? fm.removeItem(at: dst); try? fm.copyItem(at: src, to: dst) }
            else if f == "picture.jpg" { try? fm.removeItem(at: dst) }   // the seed is the whole Profile: no picture there, none here
        }
        guard (try? (theirs.line + "\n").write(to: root.appendingPathComponent("profile.stamp"), atomically: true, encoding: .utf8)) != nil else { return false }
        fputs("profile: the profile from Beam is in this app\n", stderr)   // never the name
        return true
    }

    // ---- the NX 18 folder ----
    nonisolated static func folderURL() -> URL? {
        #if os(iOS)
        guard let p = dm_nx18_folder_path(nil) else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
        #else
        let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("nxnative/nx18-folder")
        guard let line = (try? String(contentsOf: f, encoding: .utf8))?.split(separator: "\n").first, !line.isEmpty else { return nil }
        return URL(fileURLWithPath: String(line), isDirectory: true)
        #endif
    }
    func refreshFolderState() {
        #if os(iOS)
        var stale: ObjCBool = false
        if let p = dm_nx18_folder_path(&stale) { folderState = .chosen((p as NSString).lastPathComponent) }
        else { folderState = stale.boolValue ? .stale : .none }
        #else
        folderState = Self.folderURL().map { .chosen($0.lastPathComponent) } ?? .none
        #endif
    }

    // One look per start (DM_PROFILE_LOOK_ONCE, on by default; =0 looks again at startGame and lets a second read start while one is still running, as before): the Gate's Play
    // looks (envForPlay) and startGame, moments later, takes the name and picture it left without looking again (two folder bookmark resolves and up to the budget again on the
    // main thread before the first frame); a start that skipped the Gate, or one more than 5 minutes after Play looked (a question answered late), still looks there. And while
    // a read that outlived its wait is still running, a look uses the local copy instead of starting another (they would race on lastSeen)
    nonisolated static let lookOnce: Bool = { guard let e = getenv("DM_PROFILE_LOOK_ONCE") else { return true }; return atoi(e) != 0 }()
    nonisolated(unsafe) static var lookedForPlayAt: CFAbsoluteTime = 0   // main thread: when the Gate's Play looked for this start (0: it did not)
    nonisolated static let pullInFlight = OSAllocatedUnfairLock(initialState: false)
    // The Gate's Play (Launcher.swift start): the look and the env, and startGame's dm_profile_env then skips the look
    func envForPlay() {
        lookAtFolder(); NX18Profile.applyEnv()
        Self.lookedForPlayAt = Self.lookOnce ? CFAbsoluteTimeGetCurrent() : 0
    }

    // At Gate open and at a start that skips it: a cheap look at the folder within the budget, never blocking past it; a timeout keeps the local copy
    func lookAtFolder(budget: TimeInterval = 1.0) {
        refreshFolderState()
        guard enabled, let folder = Self.folderURL() else { return }
        let local = self.local
        let once = Self.lookOnce
        if once, !Self.pullInFlight.withLock({ busy in if busy { return false }; busy = true; return true }) {
            fputs("profile: the last look at the NX 18 folder is still reading; the copy on this device is used\n", stderr); return
        }
        let done = DispatchSemaphore(value: 0)
        let pulled = OSAllocatedUnfairLock(initialState: false)   // written by the read, which may finish after a timeout: a lock, not a captured var (Swift 6)
        DispatchQueue.global(qos: .userInitiated).async {
            let c = NX18ProfileSync.pull(local: local, folder: folder); pulled.withLock { $0 = c }
            if once { NX18Profile.pullInFlight.withLock { $0 = false } }
            done.signal()
        }
        if done.wait(timeout: .now() + budget) == .timedOut { fputs("profile: the NX 18 folder did not answer within \(budget) s; the copy on this device is used\n", stderr); return }
        if pulled.withLock({ $0 }) {
            reload(); pictureVersion += 1
            if let a = (try? String(contentsOf: local.appendingPathComponent("appearance.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
               let look = NX18Appearance(rawValue: a), look != NX18Appearance.current {
                NX18Appearance.store(look, fromFolder: true)   // the latest change on any device wins; nothing is written back
            }
        }
    }

    // The name and picture the games see (gate-ui §20.5 "To the games"), beside dm_cloud_saves_env. An env.txt or launch value wins; with the switch off neither is set
    nonisolated static func applyEnv(root: URL = localRoot(), defaults: UserDefaults = .standard) {
        if root == localRoot() { _ = bundledSeed }   // a start that skips the Gate off the main thread: the seed before the name is read
        let fromFile = Set((getenv("DM_ENV_FILE_KEYS").map { String(cString: $0) } ?? "").split(separator: " ").map(String.init))   // getenv: main.m sets it after ProcessInfo's snapshot
        let on = defaults.object(forKey: switchKey) as? Bool ?? true
        let raw = (try? String(contentsOf: root.appendingPathComponent("name.txt"), encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        let nick = NX18ProfileName.clean(raw).flatMap { $0.isEmpty || $0 == "Player" ? nil : $0 }
        let pic = root.appendingPathComponent("picture.jpg").path
        for (k, v) in [("DM_NICK", nick), ("DM_PROFILE_IMAGE", FileManager.default.fileExists(atPath: pic) ? pic : nil)] {
            if fromFile.contains(k) || (getenv(k) != nil && !ownEnv.contains(k)) { continue }   // an env.txt or launch value wins
            if on, let v { setenv(k, v, 1); ownEnv.insert(k) } else if ownEnv.contains(k) { unsetenv(k); ownEnv.remove(k) }
        }
        fputs("profile: \(on ? "on" : "off")\n", stderr)   // never the name or the picture's path
    }
    nonisolated(unsafe) static var ownEnv = Set<String>()
}

// The folder side, off the main thread: the cheap look, the coordinated read with conflict resolution, and the write back
enum NX18ProfileSync {
    static let files = ["picture.jpg", "name.txt", "appearance.txt"]   // copied before the stamp, which goes last
    nonisolated(unsafe) static var lastSeen: (Date?, Int?)? = nil       // the folder stamp's resource values at the last look

    static func readStamp(_ url: URL) -> NX18Stamp? { (try? String(contentsOf: url, encoding: .utf8)).flatMap { NX18Stamp($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }

    // Folder → this device when the folder's stamp is higher. true when local files changed
    @discardableResult static func pull(local: URL, folder: URL) -> Bool {
        let dir = folder.appendingPathComponent("Profile", isDirectory: true), stampURL = dir.appendingPathComponent("profile.stamp")
        let v = try? stampURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let seen = (v?.contentModificationDate, v?.fileSize)
        if let last = lastSeen, last.0 == seen.0, last.1 == seen.1 { return false }   // the cheap look: nothing changed since
        var changed = false
        coordinated(read: dir) { d in
            resolveConflicts(d.appendingPathComponent("profile.stamp"))
            guard let theirs = readStamp(d.appendingPathComponent("profile.stamp")) else { return }
            let mine = readStamp(local.appendingPathComponent("profile.stamp"))
            if let mine, mine >= theirs { return }
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for f in files {
                let src = d.appendingPathComponent(f), dst = local.appendingPathComponent(f)
                resolveConflicts(src)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: src, to: dst)
                    if let date = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dst.path)   // the source's date: the next look finds nothing to write back
                    }
                } else if f == "picture.jpg" { try? FileManager.default.removeItem(at: dst) }
            }
            try? (theirs.line + "\n").write(to: local.appendingPathComponent("profile.stamp"), atomically: true, encoding: .utf8)
            changed = true
        }
        lastSeen = seen
        return changed
    }

    // This device → folder when its stamp is higher (after an edit, or a folder that has no Profile yet)
    static func push(local: URL, folder: URL) {
        let dir = folder.appendingPathComponent("Profile", isDirectory: true)
        guard let mine = readStamp(local.appendingPathComponent("profile.stamp")) else { return }
        coordinated(write: dir) { d in
            if let theirs = readStamp(d.appendingPathComponent("profile.stamp")), theirs >= mine { return }   // a newer edit elsewhere: the next look brings it here
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for f in files {
                let src = local.appendingPathComponent(f), dst = d.appendingPathComponent(f)
                guard FileManager.default.fileExists(atPath: src.path) else { if f == "picture.jpg" { try? FileManager.default.removeItem(at: dst) }; continue }
                try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: src, to: dst)
            }
            try? (mine.line + "\n").write(to: d.appendingPathComponent("profile.stamp"), atomically: true, encoding: .utf8)   // last
        }
        lastSeen = nil
    }

    // A folder's Profile, read carefully (Connect, a new folder on the card): nil when the read did not finish in time; .none when read in full and empty
    enum Found: Equatable { case profile(String), none }
    static func careful(folder: URL, timeout: TimeInterval = 10) -> Found? {
        let dir = folder.appendingPathComponent("Profile", isDirectory: true)
        let done = DispatchSemaphore(value: 0); let result = OSAllocatedUnfairLock<Found?>(initialState: nil)   // as lookAtFolder: the read may outlive the wait
        DispatchQueue.global(qos: .userInitiated).async {
            var found: Found? = nil
            coordinated(read: dir) { d in
                let fm = FileManager.default
                let any = ["name.txt", "picture.jpg", "profile.stamp"].contains { fm.fileExists(atPath: d.appendingPathComponent($0).path) }
                let n = (try? String(contentsOf: d.appendingPathComponent("name.txt"), encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? "Player"
                found = any ? .profile(n) : Found.none
            }
            if found == nil, !FileManager.default.fileExists(atPath: dir.path) { found = Found.none }
            let f = found; result.withLock { $0 = f }; done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .timedOut ? nil : result.withLock { $0 }
    }

    static func coordinated(read url: URL, _ body: (URL) -> Void) {
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { body($0) }
        if let err { fputs("profile: the NX 18 folder could not be read (\(err.code))\n", stderr) }
    }
    static func coordinated(write url: URL, _ body: (URL) -> Void) {
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &err) { body($0) }
        if let err { fputs("profile: the NX 18 folder could not be written (\(err.code))\n", stderr) }
    }

    // iCloud keeps conflict versions after two offline edits: the version holding the highest stamp stays (for the stamp file itself; other files follow the stamp's
    // winner as written), the others are removed and marked resolved
    static func resolveConflicts(_ url: URL) {
        guard let others = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !others.isEmpty else { return }
        if url.lastPathComponent == "profile.stamp", let cur = readStamp(url) {
            let best = others.compactMap { v -> (NSFileVersion, NX18Stamp)? in readStamp(v.url).map { (v, $0) } }.max { $0.1 < $1.1 }
            if let best, best.1 > cur { _ = try? best.0.replaceItem(at: url) }
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        for v in others { v.isResolved = true }
    }
}

// The picture as the games take it (GW22, hle_account.c): 256 x 256, a baseline JPEG of at most 128 KiB, the photo's orientation applied
enum NX18ProfilePicture {
    static let side = 256
    static func jpeg(from image: CGImage) -> Data? {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let ctx else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let square = ctx.makeImage() else { return nil }
        for q in [0.85, 0.7, 0.55, 0.4] {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, square, [kCGImageDestinationLossyCompressionQuality: q, kCGImagePropertyJFIFIsProgressive: false] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            if out.length <= 128 * 1024 { return out as Data }
        }
        return nil
    }
    // A photo file, read with a 2048 px limit and its orientation applied (never the whole photo decoded)
    static func thumbnail(of url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
}

// The C entry for front_ios.m's start that skips the Gate (the look within its budget, then the env), and the Gate's Play
@_cdecl("dm_profile_env")
public func dm_profile_env() {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            let at = NX18Profile.lookedForPlayAt; NX18Profile.lookedForPlayAt = 0
            if at > 0, CFAbsoluteTimeGetCurrent() - at < 300 { fputs("profile: the Gate's Play looked at the NX 18 folder for this start\n", stderr) }   // DM_PROFILE_LOOK_ONCE
            else { NX18Profile.shared.lookAtFolder() }
        }
    }
    NX18Profile.applyEnv()
}

// Where a Mac game's cloud saves go (dm/mac/launcher.c dm_mac_cloud_place, the same rule; docs/frontends.md, The cloud saves folder): the NX 18 folder when the NX 18 card's
// This game's saves says so (nx18.cloud = "shared"), or with no choice yet when the game has no own folder (cloudSaves.folder); else its own folder; else off. The NX 18
// folder only when one is connected and there; the default only with the Profile and NX 18 folder switch on. NX 18 Beam reads a game's preferences with it (its Cloud saves door and game page)
nonisolated enum NX18CloudSaves {
    static let choiceKey = "nx18.cloud", folderKey = "cloudSaves.folder"
    enum Place: Equatable, Sendable {
        case off, own(String), nx18(String)
        var folder: String? { switch self { case .off: nil; case .own(let f), .nx18(let f): f } }
        var inNX18: Bool { if case .nx18 = self { true } else { false } }
    }
    /// own: the game's own folder (nil: never chosen; "": turned off, which the default respects); choice: nx18.cloud; nx18: the connected NX 18 folder when it is there.
    /// The card's "shared" holds whatever the Profile switch says (as on the iPhone: the switch's Off moves the save first); the default needs the switch on
    static func decide(own: String?, choice: String?, nx18: String?, profileOn: Bool) -> Place {
        let shared = choice == "shared", dflt = !shared && choice != "own" && own == nil && profileOn
        if let nx = nx18, !nx.isEmpty, shared || dflt { return .nx18(nx) }
        return own.flatMap { $0.isEmpty ? nil : $0 }.map(Place.own) ?? .off
    }
    /// A game's preferences (its own UserDefaults, or another app's suite in Beam) and the Mac's connected NX 18 folder (nxnative/nx18-folder), checked to be there
    static func place(_ d: UserDefaults, nx18: URL?) -> Place {
        var dir: ObjCBool = false
        let nx = nx18.flatMap { FileManager.default.fileExists(atPath: $0.path, isDirectory: &dir) && dir.boolValue ? $0.path : nil }
        return decide(own: d.string(forKey: folderKey), choice: d.string(forKey: choiceKey), nx18: nx, profileOn: d.object(forKey: NX18Profile.switchKey) as? Bool ?? true)
    }
}
