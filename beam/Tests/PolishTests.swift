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
    @Test func feedAndTrust() throws {
        let json = #"[{"tag_name": "beam-0.2", "html_url": "h", "draft": false, "prerelease": false, "assets": [{"name": "NX18-Beam-0.2.dmg", "browser_download_url": "file:///x.dmg", "digest": "sha256:ab"}]}, {"tag_name": "beam-0.3", "html_url": "h", "draft": false, "prerelease": false, "assets": [{"name": "NX18-Beam-0.2.dmg", "browser_download_url": "file:///y.dmg"}]}]"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let all = try d.decode([BeamRelease].self, from: Data(json.utf8))
        #expect(all[0].dmg?.digest == "sha256:ab" && all[0].versionString == "0.2", "GitHub's asset list and digest read")
        #expect(all[1].dmg == nil, "a DMG named for another version is not this release's")
        #expect(rel("beam-0.4").dmg == nil, "no assets: link only")
        #expect(BeamUpdate.requirement(team: nil) == nil && BeamUpdate.requirement(team: "AB\" or true") == nil, "no team or an odd one: no install")
        let req = try #require(BeamUpdate.requirement(team: "ABCDE12345"))
        #expect(req.contains("notarized") && req.contains("\"org.nx18.beam\"") && req.contains("anchor apple generic"))
        #expect(BeamUpdate.installTarget(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/A/d/NX 18 Beam.app")) == nil, "translocated: link only")
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

// B5 polish: Home's sounds follow the Mac's interface-sounds switch, and the letter keys stand in for the hints' buttons
@Suite struct HomeTouchTests {
    @Test func soundsFollowTheSystemSwitch() {
        #expect(!HomeSounds.enabled(beam: false, system: nil), "off in Beam: silent")
        #expect(HomeSounds.enabled(beam: true, system: nil), "the system switch never touched: on")
        #expect(HomeSounds.enabled(beam: true, system: NSNumber(value: 1)))
        #expect(!HomeSounds.enabled(beam: true, system: NSNumber(value: 0)), "Play user interface sound effects off: silent")
        #expect(HomeSounds.sound(.left) == "Tink" && HomeSounds.sound(.a) == "Pop" && HomeSounds.sound(.b) == "Bottle")
    }
    @Test func letterKeys() {
        #expect(PadEdges.letter("a") == .a && PadEdges.letter("B") == .b && PadEdges.letter("x") == .x && PadEdges.letter("Y") == .y)
        #expect(PadEdges.letter("-") == .minus && PadEdges.letter("−") == .minus)
        #expect(PadEdges.letter("z") == nil && PadEdges.letter("") == nil)
    }
}
