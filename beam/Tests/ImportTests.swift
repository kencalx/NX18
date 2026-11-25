// "Bring your NX Play library" and the sideloading guides, with a made-up NX Play setup: a temporary preferences suite and games folder (no real NX Play files)
import Foundation
import Testing
@testable import NX_18_Beam

@MainActor @Suite struct ImportTests {
    func setup() throws -> (UserDefaults, String, URL) {
        let suite = "org.nx18.beam.test.nxplay.\(UUID().uuidString.prefix(8).lowercased())"
        let root = FileManager.default.temporaryDirectory.appending(path: "beam-nxplay-\(UUID().uuidString)")
        let fm = FileManager.default
        for (path, data) in [("Zelda/z.nup", "n"), ("Mario/base.nsp", "n"), ("Mario/update.NSP", "n"), ("Dump/base/exefs/main.npdm", "m"),
                             ("NxNative.xcworkspace/contents.xcworkspacedata", "x"), ("Switch Keys/prod.keys", "k"), ("Empty/readme.txt", "r"), ("loose.nsp", "n"),
                             ("Mac/._a.nsp", "x"), ("keys/prod.keys", "k")] {
            let u = root.appending(path: path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data.utf8).write(to: u)
        }
        let d = try #require(UserDefaults(suiteName: suite))
        d.set(root.path, forKey: "gamesRoot")
        d.set(root.appending(path: "keys/prod.keys").path, forKey: "keysPath")
        d.set(["00008150-0000000000000001": ["0400486024DEC000"]], forKey: "deviceGames")
        return (d, suite, root)
    }
    func cleanup(_ suite: String, _ root: URL) {
        ScratchPrefs.clean(suite)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func findsTheGameFolders() throws {
        let (d, suite, root) = try setup(); defer { cleanup(suite, root) }
        let lib = try #require(NXPlayLibrary.find(d))
        #expect(lib.games.map(\.lastPathComponent) == ["Dump", "Mario", "Zelda"], "game folders only: no workspace, keys, empty or AppleDouble-only folder")
        #expect(lib.keys?.lastPathComponent == "prod.keys" && lib.installedTitles == ["0400486024DEC000"])
        #expect(NXPlayLibrary.find(UserDefaults(suiteName: "org.nx18.beam.test.none.\(UUID().uuidString.prefix(6))")) == nil, "no NX Play: nothing offered")
    }

    @Test func importAddsInPlace() async throws {
        let (d, suite, root) = try setup(); defer { cleanup(suite, root) }
        let lib = try #require(NXPlayLibrary.find(d))
        let prefs = "org.nx18.beam.test.lib.\(UUID().uuidString.prefix(8).lowercased())"
        let beamDefaults = try #require(UserDefaults(suiteName: prefs))
        defer { ScratchPrefs.clean(prefs) }
        let settings = BeamSettings(defaults: beamDefaults)
        settings.nx18Folder = root.appending(path: "no-nx18-here")   // identify fails at once: this test is about adding, not reading
        let library = Library(settings: settings, folder: root.appending(path: "beam"))
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let r = await library.importNXPlay(lib)
        #expect(r.added == 3 && r.failed.count == 3 && library.games.count == 3)
        let rootPath = root.resolvingSymlinksInPath().path
        #expect(library.games.allSatisfy { $0.source.resolvingSymlinksInPath().path.hasPrefix(rootPath) }, "added where they are")
        #expect(settings.keys?.lastPathComponent == "prod.keys", "NX Play's keys path taken when Beam has none")
        let after = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "beam" }.sorted()
        #expect(after == before.filter { $0 != "beam" }, "nothing moved or deleted: \(before) → \(after)")
        #expect(await library.importNXPlay(lib).added == 0, "a second import adds nothing")
    }

    @Test func guidesCarryTheRules() {
        for t in SideloadGuide.Tool.allCases {
            let text = SideloadGuide.steps(t).map(\.text).joined(separator: " ")
            #expect(text.contains("Increased Memory Limit") && text.contains("Never delete the game first") && text.contains("Developer Mode"), "\(t.rawValue)")
        }
        #expect(SideloadGuide.steps(.altStore).contains { $0.text.contains("not AltStore PAL") })
    }
}
