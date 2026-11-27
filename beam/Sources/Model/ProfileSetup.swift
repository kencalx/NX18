// Beam's side of the NX 18 Profile (NX18-X2.0 gate-ui.md §20.5; the layout and the stamp rules in dm/ios/Sources/NX18Profile.swift, which Beam compiles): the name and picture the
// games show. Beam edits the Mac's copy in ~/Library/Application Support/nxnative/Profile/, the one every NX 18 Mac game app reads (dm/mac/launcher.c profile_env, so a Mac
// game Beam builds or plays has it with nothing passed), and connects the NX 18 folder the way a Mac game's card does (nxnative/nx18-folder, one line; MacProfileFlow in
// dm/mac/Launcher.swift): the folder's Profile comes here when it is newer, else this Mac's goes there. Every iPhone or iPad game Beam installs gets a copy of the Profile in
// <App>.app/NX18ProfileSeed before it is signed (seed); the app takes it on its first start, or when it is newer than the app's own (NX18Profile.applySeed).
// The NX 18 folder is one choice: the Album reads its captures from the same folder (Album.nx18Folder). Privacy: the name and the picture are never logged.
import AppKit
import Foundation
import Observation

enum ProfileSetup {
    /// What a Profile and the NX 18 folder are: the same words on the welcome page and in Settings
    static let explanation = "Your profile is the name and picture your games show. Beam keeps it on this Mac for the games you play here, and puts it in every game it installs on your iPhone or iPad. Connect the same NX 18 folder in iCloud Drive here and in your games on iPhone or iPad to share your profile, cloud saves and captures: change your profile on one, and the others pick it up."

    /// nxnative/ in Application Support: Profile/ and the nx18-folder line, shared with every NX 18 Mac game app
    static var macSupport: URL { NX18Profile.localRoot().deletingLastPathComponent() }

    /// The NX 18 folder this Mac's games use (the nx18-folder line), nil when none is connected
    static func connectedFolder(support: URL = macSupport) -> URL? {
        guard let line = (try? String(contentsOf: support.appending(path: "nx18-folder"), encoding: .utf8))?.split(separator: "\n").first, !line.isEmpty else { return nil }
        return URL(fileURLWithPath: String(line), isDirectory: true)
    }

    /// The folder Beam proposes to connect: iCloud Drive's folder holding an NX 18 Profile, else iCloud Drive › NX 18 when it exists (Album.nx18Folder without a connected one)
    static func proposedFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser, support: URL = macSupport) -> URL? {
        connectedFolder(support: support) ?? Album.nx18Folder(chosen: nil, home: home)
    }

    enum Connected: Equatable, Sendable {
        case tookFolders    // the folder's Profile is on this Mac now
        case sentMine       // the folder had none (or an older one): this Mac's is there now
        case nothingYet     // neither has a Profile yet
        case failed
        var message: String {
            switch self {
            case .tookFolders: "Connected. Your profile from the NX 18 folder is on this Mac."
            case .sentMine: "Connected. This Mac's profile is in the NX 18 folder now."
            case .nothingYet: "Connected. Create a profile and it goes to the NX 18 folder too."
            case .failed: "The NX 18 folder could not be connected. Check that iCloud Drive is on, then try again."
            }
        }
    }

    /// Makes `folder` this Mac's NX 18 folder, then brings its Profile here when it is newer, else sends this Mac's there (MacProfileFlow.chooseFolder). Coordinated reads and
    /// writes: call it off the main thread
    static func connect(_ folder: URL, support: URL = macSupport) -> Connected {
        let line = support.appending(path: "nx18-folder")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard (try? (folder.path + "\n").write(to: line, atomically: true, encoding: .utf8)) != nil else { return .failed }
        fputs("beam: NX 18 folder connected\n", stderr)   // never its path
        let local = support.appending(path: "Profile", directoryHint: .isDirectory)
        NX18ProfileSync.lastSeen = nil   // a look at another folder may be cached
        if NX18ProfileSync.pull(local: local, folder: folder) { return .tookFolders }
        guard NX18ProfileSync.readStamp(local.appending(path: "profile.stamp")) != nil else { return .nothingYet }
        NX18ProfileSync.push(local: local, folder: folder)
        return .sentMine
    }

    /// Stops this Mac's games and Beam using the folder for the Profile (the folder and its files stay as they are)
    static func disconnect(support: URL = macSupport) {
        try? FileManager.default.removeItem(at: support.appending(path: "nx18-folder"))
        fputs("beam: NX 18 folder disconnected\n", stderr)
    }

    /// One NX 18 folder: Beam's own choice for the Album (settings.icloudNX18Folder, before the Profile came to Beam) becomes the Mac's connected folder when the Mac has none,
    /// and is dropped. When the Mac games already use one, theirs stays the choice: the Profile and the cloud saves live there
    @MainActor static func unify(_ settings: BeamSettings, support: URL = macSupport) {
        guard let chosen = settings.icloudNX18Folder else { return }
        settings.icloudNX18Folder = nil
        guard connectedFolder(support: support) == nil else { fputs("beam: the Album uses the NX 18 folder this Mac's games use\n", stderr); return }
        Task.detached(priority: .utility) { _ = connect(chosen, support: support) }
    }

    /// A picture file as the games take it: its centre square, 256 x 256 JPEG (NX18ProfilePicture; as MacProfileFlow.choosePicture)
    static func pictureJPEG(from url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let img = NX18ProfilePicture.thumbnail(of: url) else { return nil }
        let side = min(img.width, img.height)
        guard let square = img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)) else { return nil }
        return NX18ProfilePicture.jpeg(from: square)
    }

    // ---- the seed in the games Beam installs ----

    /// The Profile's files into `dir` (NX18ProfileSeed): the picture and the name first, the stamp last. false, and no folder, when `root` holds no Profile (no stamp).
    /// The stamp is read before the files and written as read: an edit or a pull landing during the copy (each writes its stamp last) can make the files newer than the
    /// seed's stamp, never older, so a phone never takes old files under a newer stamp
    @discardableResult static func writeSeed(from root: URL, to dir: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        guard let stamp = NX18ProfileSync.readStamp(root.appending(path: "profile.stamp")) else { return false }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in NX18ProfileSync.files where fm.fileExists(atPath: root.appending(path: f).path) { try fm.copyItem(at: root.appending(path: f), to: dir.appending(path: f)) }
            try (stamp.line + "\n").write(to: dir.appending(path: "profile.stamp"), atomically: true, encoding: .utf8)
            return true
        } catch {
            try? fm.removeItem(at: dir)
            return false
        }
    }

    /// The current Profile as a seed for an install: the NX 18 folder's newer copy brought to this Mac first (within `budget`; a slow iCloud keeps this Mac's copy), then the Mac's
    /// copy written to a new temporary folder (no spaces in its path, for the xcodebuild line). nil when there is no Profile. The caller removes the folder's parent after signing
    static func seed(support: URL = macSupport, budget: TimeInterval = 2) async -> URL? {
        await Task.detached(priority: .userInitiated) { seedNow(support: support, budget: budget) }.value
    }
    static func seedNow(support: URL, budget: TimeInterval) -> URL? {
        let local = support.appending(path: "Profile", directoryHint: .isDirectory)
        if let folder = connectedFolder(support: support) {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async { NX18ProfileSync.pull(local: local, folder: folder); done.signal() }
            if done.wait(timeout: .now() + budget) == .timedOut { fputs("beam: the NX 18 folder did not answer; the profile on this Mac goes in\n", stderr) }
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "beam-seed-\(UUID().uuidString)/\(NX18Profile.seedFolder)", directoryHint: .isDirectory)
        let ok = writeSeed(from: local, to: dir)
        fputs("beam: profile in the install: \(ok ? "on" : "off")\n", stderr)   // never the name
        return ok ? dir : nil
    }
}

/// The Mac's Profile as Beam's Welcome and Settings show and edit it. Edits are the Mac's copy first (NX18Profile.writeLocal: the stamp last), then the NX 18 folder off the
/// main thread; each posts NX18Profile.changed, which Beam Home's chip reads again on
@MainActor @Observable final class ProfileModel {
    static let shared = ProfileModel()
    let support: URL
    private(set) var name = "Player"
    private(set) var hasPicture = false
    private(set) var exists = false          // a Profile was made on this Mac (a stamp): Beam's own or a Mac game's
    private(set) var pictureVersion = 0
    private(set) var folder: URL?
    private(set) var connecting = false
    var note: String?

    init(support: URL = ProfileSetup.macSupport) { self.support = support; reload() }
    var root: URL { support.appending(path: "Profile", directoryHint: .isDirectory) }
    var pictureURL: URL { root.appending(path: "picture.jpg") }

    func reload() {
        let raw = (try? String(contentsOf: root.appending(path: "name.txt"), encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        name = NX18ProfileName.clean(raw).flatMap { $0.isEmpty ? nil : $0 } ?? "Player"
        let had = hasPicture
        hasPicture = FileManager.default.fileExists(atPath: pictureURL.path)
        if had != hasPicture { pictureVersion += 1 }
        exists = NX18ProfileSync.readStamp(root.appending(path: "profile.stamp")) != nil
        folder = ProfileSetup.connectedFolder(support: support)
    }

    /// false (nothing written) when the name breaks the rule (NX18ProfileName.refusal says it)
    @discardableResult func setName(_ raw: String) -> Bool {
        guard let n = NX18ProfileName.clean(raw) else { return false }
        NX18Profile.writeLocal(at: root, name: n.isEmpty ? "Player" : n, picture: nil, appearance: nil)
        edited()
        return true
    }
    @discardableResult func setPicture(from url: URL) -> Bool {
        guard let jpeg = ProfileSetup.pictureJPEG(from: url) else { note = "That picture could not be read."; return false }
        NX18Profile.writeLocal(at: root, name: nil, picture: jpeg, appearance: nil)
        pictureVersion += 1; edited()
        return true
    }
    func clearPicture() {
        try? FileManager.default.removeItem(at: pictureURL)
        NX18Profile.bumpLocal(at: root)
        pictureVersion += 1; edited()
    }

    func connect(_ folder: URL) async {
        connecting = true; note = nil
        let support = self.support
        let r = await Task.detached(priority: .userInitiated) { ProfileSetup.connect(folder, support: support) }.value
        connecting = false; note = r.message
        pictureVersion += 1; reload()
        NotificationCenter.default.post(name: NX18Profile.changed, object: nil)
    }
    func disconnect() {
        ProfileSetup.disconnect(support: support); note = nil; reload()
        NotificationCenter.default.post(name: NX18Profile.changed, object: nil)
    }

    private func edited() {
        note = nil; reload()
        NotificationCenter.default.post(name: NX18Profile.changed, object: nil)
        guard let folder else { return }
        let local = root
        Task.detached(priority: .utility) { NX18ProfileSync.push(local: local, folder: folder) }
    }
}
