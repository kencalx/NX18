// Beam's Profile setup (ProfileSetup.swift): connecting the NX 18 folder (the folder's newer Profile comes here, else this Mac's goes there), the seed every iPhone or iPad
// install carries and the rules the app applies it by (NX18Profile.applySeed), the name rule in Beam's edits, the one NX 18 folder, and the folder Beam proposes. Temporary
// folders stand in for Application Support/nxnative and iCloud Drive: the player's real Profile and iCloud Drive are never touched
import Foundation
import Testing
@testable import NX_18_Beam

@Suite(.serialized) struct ProfileSetupTests {
    init() { UserDefaults.standard.register(defaults: [NX18Profile.deviceKey: "testmac"]) }   // the stamps' device id, in memory: no preferences written
    func temp(_ n: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "beam-profile-setup-\(n)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func write(_ u: URL, _ s: String) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }
    func read(_ u: URL) -> String? { (try? String(contentsOf: u, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    func eventually(_ cond: @Sendable () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return cond()
    }

    @Test func connectTakesTheFoldersNewerProfile() throws {
        let sup = try temp("sup"), folder = try temp("folder"); defer { [sup, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        try write(folder.appending(path: "Profile/name.txt"), "Kiki\n"); try write(folder.appending(path: "Profile/profile.stamp"), "4 phone\n")
        try write(sup.appending(path: "Profile/name.txt"), "Old\n"); try write(sup.appending(path: "Profile/profile.stamp"), "2 mac\n")
        #expect(ProfileSetup.connect(folder, support: sup) == .tookFolders)
        #expect(read(sup.appending(path: "Profile/name.txt")) == "Kiki")
        #expect(ProfileSetup.connectedFolder(support: sup)?.path == folder.path, "the Mac games' nx18-folder line")
        ProfileSetup.disconnect(support: sup)
        #expect(ProfileSetup.connectedFolder(support: sup) == nil)
        #expect(read(folder.appending(path: "Profile/name.txt")) == "Kiki", "disconnecting leaves the folder's files")
    }

    @Test func connectSendsThisMacsToAnEmptyFolder() throws {
        let sup = try temp("sup"), folder = try temp("folder"), sup2 = try temp("sup2"), folder2 = try temp("folder2")
        defer { [sup, folder, sup2, folder2].forEach { try? FileManager.default.removeItem(at: $0) } }
        NX18Profile.writeLocal(at: sup.appending(path: "Profile"), name: "MacName", picture: nil, appearance: nil)
        #expect(ProfileSetup.connect(folder, support: sup) == .sentMine)
        #expect(read(folder.appending(path: "Profile/name.txt")) == "MacName")
        #expect(ProfileSetup.connect(folder2, support: sup2) == .nothingYet, "neither has a Profile")
    }

    @Test func seedForAnInstall() throws {
        let sup = try temp("seed"), out = try temp("out"), folder = try temp("folder"); defer { [sup, out, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        let root = sup.appending(path: "Profile"), dir = out.appending(path: NX18Profile.seedFolder)
        #expect(!ProfileSetup.writeSeed(from: root, to: dir), "no Profile: no seed")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        NX18Profile.writeLocal(at: root, name: "Kiki", picture: Data([0xFF, 0xD8, 0xFF, 0xD9]), appearance: "dark")
        #expect(ProfileSetup.writeSeed(from: root, to: dir))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["name.txt", "picture.jpg", "appearance.txt", "profile.stamp"])
        // with the NX 18 folder connected, its newer Profile is brought here first
        try write(folder.appending(path: "Profile/name.txt"), "Tombo\n"); try write(folder.appending(path: "Profile/profile.stamp"), "9 phone\n")
        try write(sup.appending(path: "nx18-folder"), folder.path + "\n")
        NX18ProfileSync.lastSeen = nil
        let s = try #require(ProfileSetup.seedNow(support: sup, budget: 5))
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent()) }
        #expect(read(s.appending(path: "name.txt")) == "Tombo" && read(s.appending(path: "profile.stamp")) == "9 phone")
        #expect(!s.path.contains(" "), "no spaces: it goes on the xcodebuild line")
        let empty = try temp("empty"); defer { try? FileManager.default.removeItem(at: empty) }
        #expect(ProfileSetup.seedNow(support: empty, budget: 1) == nil, "no Profile: no seed")
    }

    // The app's rules for the seed (dm/ios/Sources/NX18Profile.swift; DuoProfileTests has them on iOS)
    @Test func seedRulesInTheApp() throws {
        let seed = try temp("seed"), local = try temp("local"); defer { [seed, local].forEach { try? FileManager.default.removeItem(at: $0) } }
        let root = local.appending(path: "Profile")
        try write(seed.appending(path: "name.txt"), "Kiki\n"); try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: seed.appending(path: "picture.jpg"))
        try write(seed.appending(path: "profile.stamp"), "5 beammac\n")
        #expect(NX18Profile.applySeed(seed, to: root), "a fresh install takes it")
        #expect(read(root.appending(path: "name.txt")) == "Kiki" && read(root.appending(path: "profile.stamp")) == "5 beammac")
        #expect(!NX18Profile.applySeed(seed, to: root), "the same seed again: nothing")
        try write(seed.appending(path: "name.txt"), "Tombo\n"); try FileManager.default.removeItem(at: seed.appending(path: "picture.jpg"))
        try write(seed.appending(path: "profile.stamp"), "6 beammac\n")
        #expect(NX18Profile.applySeed(seed, to: root) && read(root.appending(path: "name.txt")) == "Tombo", "a newer seed replaces")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "picture.jpg").path))
        try write(seed.appending(path: "name.txt"), "Old\n"); try write(seed.appending(path: "profile.stamp"), "4 beammac\n")
        #expect(!NX18Profile.applySeed(seed, to: root) && read(root.appending(path: "name.txt")) == "Tombo", "an older seed is ignored")
        NX18Profile.writeLocal(at: root, name: "Jiji", picture: nil, appearance: nil)
        try write(seed.appending(path: "name.txt"), "Tombo\n"); try write(seed.appending(path: "profile.stamp"), "6 beammac\n")
        #expect(!NX18Profile.applySeed(seed, to: root) && read(root.appending(path: "name.txt")) == "Jiji", "the phone's edit wins")
    }

    @MainActor @Test func editsFollowTheNameRuleAndReachTheFolder() async throws {
        let sup = try temp("model"), folder = try temp("folder"); defer { [sup, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        try write(sup.appending(path: "nx18-folder"), folder.path + "\n")
        let m = ProfileModel(support: sup)
        #expect(!m.exists && m.name == "Player")
        #expect(!m.setName("ElevenChars"), "the name rule refuses it")
        #expect(m.setName("Kiki") && m.name == "Kiki" && m.exists)
        let pushed = await eventually { (try? String(contentsOf: folder.appending(path: "Profile/name.txt"), encoding: .utf8)) == "Kiki\n" }
        #expect(pushed, "the edit goes to the connected folder")
    }

    @MainActor @Test func oneNX18Folder() async throws {
        let suite = "org.nx18.beam.test.profile-\(UUID().uuidString)"; defer { ScratchPrefs.clean(suite) }
        let d = try #require(UserDefaults(suiteName: suite))
        let sup = try temp("unify"), chosen = try temp("chosen"), sup2 = try temp("unify2"), mine = try temp("mine")
        defer { [sup, chosen, sup2, mine].forEach { try? FileManager.default.removeItem(at: $0) } }
        let s = BeamSettings(defaults: d); s.icloudNX18Folder = chosen
        ProfileSetup.unify(s, support: sup)
        #expect(s.icloudNX18Folder == nil, "Beam's own Album choice is dropped")
        let connected = await eventually { ProfileSetup.connectedFolder(support: sup)?.path == chosen.path }
        #expect(connected, "and becomes the Mac's connected folder")
        try write(sup2.appending(path: "nx18-folder"), mine.path + "\n")
        s.icloudNX18Folder = chosen
        ProfileSetup.unify(s, support: sup2)
        #expect(s.icloudNX18Folder == nil && ProfileSetup.connectedFolder(support: sup2)?.path == mine.path, "the Mac games' folder stays the choice")
    }

    @Test func proposedFolder() throws {
        let home = try temp("home"), home2 = try temp("home2"), psup = try temp("psup"); defer { [home, home2, psup].forEach { try? FileManager.default.removeItem(at: $0) } }
        try write(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/NX saves/Profile/profile.stamp"), "1 phone\n")
        #expect(ProfileSetup.proposedFolder(home: home, support: psup)?.lastPathComponent == "NX saves", "iCloud Drive's folder holding a Profile")
        #expect(ProfileSetup.proposedFolder(home: home2, support: psup) == nil)
    }
}
