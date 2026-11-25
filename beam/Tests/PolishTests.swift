// B5: the update check's rules (no network: off, or already checked today, never calls), and What's new once per version
import Foundation
import Testing
@testable import NX_18_Beam

@MainActor @Suite struct UpdateTests {
    func rel(_ tag: String, draft: Bool = false, pre: Bool = false) -> BeamRelease {
        BeamRelease(tagName: tag, htmlUrl: "https://github.com/kencalx/NX18/releases/tag/\(tag)", name: nil, draft: draft, prerelease: pre)
    }
    @Test func versions() {
        #expect(BeamUpdate.version("beam-1.2.3") == [1, 2, 3] && BeamUpdate.version("X2.0") == nil && BeamUpdate.version("beam-1.x") == nil)
        #expect(BeamUpdate.newer([1, 10], than: [1, 9]) && !BeamUpdate.newer([1, 0], than: [1]) && BeamUpdate.newer([1, 0, 1], than: [1]))
        let all = [rel("X2.0"), rel("beam-0.1"), rel("beam-0.3", draft: true), rel("beam-0.2.1"), rel("beam-0.4", pre: true), rel("beam-0.2")]
        #expect(BeamUpdate.newest(all, current: "0.1")?.tagName == "beam-0.2.1", "drafts, pre-releases and NX 18's own tags left out")
        #expect(BeamUpdate.newest(all, current: "0.2.1") == nil)
    }
    @Test func checkOnlyWhenOnAndDue() async throws {
        let suite = "org.nx18.beam.test.upd.\(UUID().uuidString.prefix(8).lowercased())"
        defer { ScratchPrefs.clean(suite) }
        let s = BeamSettings(defaults: try #require(UserDefaults(suiteName: suite)))
        let lib = Library(settings: s, folder: FileManager.default.temporaryDirectory.appending(path: "beam-upd-\(UUID().uuidString)"))
        #expect(!s.updateChecks, "off until the player turns it on")
        await lib.checkForUpdateIfDue()
        #expect(s.lastUpdateCheck == nil, "off: no call")
        s.updateChecks = true; s.lastUpdateCheck = .now.addingTimeInterval(-3600)
        let before = s.lastUpdateCheck
        await lib.checkForUpdateIfDue()
        #expect(s.lastUpdateCheck == before, "checked within the day: no call")
    }
}

@MainActor @Suite struct RenameTests {
    @Test func renameAndBuild() throws {
        let suite = "org.nx18.beam.test.ren.\(UUID().uuidString.prefix(8).lowercased())"
        defer { ScratchPrefs.clean(suite) }
        let lib = Library(settings: BeamSettings(defaults: try #require(UserDefaults(suiteName: suite))),
                          folder: FileManager.default.temporaryDirectory.appending(path: "beam-ren-\(UUID().uuidString)"))
        var g = LibraryGame(source: URL(fileURLWithPath: "/g/LM3"))
        g.identity = IdentifyEvent(titleId: "0100DCA0064A6000", name: "Luigi's Mansion 3", platform: "switch1", kind: "nsp", versions: [], packs: nil, dlc: [], programs: [], profile: nil, alias: nil)
        lib.games = [g]
        lib.rename(g.id, to: "  LM3  ")
        #expect(lib.games[0].title == "LM3" && lib.games[0].customName == "LM3")
        var req = BuildRequest(source: g.source, target: .iPhone, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/w"))
        lib.dress(&req, lib.games[0], g.identity!)
        #expect(req.arguments(script: URL(fileURLWithPath: "/s.py")).joined(separator: " ").contains("--app-name LM3"))
        lib.rename(g.id, to: "Luigi's Mansion 3"); #expect(lib.games[0].customName == nil, "its own name: no custom name")
        lib.rename(g.id, to: "LM3"); lib.rename(g.id, to: ""); #expect(lib.games[0].title == "Luigi's Mansion 3", "empty: the game's own name again")
        lib.rename(g.id, to: String(repeating: "x", count: 100)); #expect(lib.games[0].customName?.count == 60)
    }
}

/// The setup: the real script Beam carries, run read-only (--check) on an empty folder: every line is an event Beam reads, and NX 18's clone is offered
@MainActor @Suite struct SetupTests {
    @Test func checkAnEmptyFolder() async throws {
        #expect(SetupModel.script != nil, "Beam carries nx18-setup.sh")
        let folder = FileManager.default.temporaryDirectory.appending(path: "beam-setup-\(UUID().uuidString)/NX18")
        let s = SetupModel()
        await s.check(folder: folder)
        #expect(s.checked && !s.items.isEmpty && s.stopped == nil)
        #expect(s.fixes.map(\.id).contains("clone"), "an empty folder: the clone is offered")
        #expect(!s.ready)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "--check changes nothing")
    }
    @Test func events() {
        #expect(SetupEvent.parse(#"{"ev":"fixable","id":"venv","question":"Make a virtualenv?"}"#)?.id == "venv")
        #expect(SetupEvent.parse("plain text") == nil)
    }
}
