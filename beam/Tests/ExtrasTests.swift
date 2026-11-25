// Cheats, art and the build's environment (B4 part 2), with temporary folders and fixtures: no network, no Keychain, no real game's files
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct CheatTests {
    let file = """
    {Master code}
    04000000 00000001 00000000

    [Inf HP]
    04000000 00000010 000003E7
    [-- Section label --]
    [Inf HP]
    04000000 00000020 000003E7
    [Moon Jump]
    80000040
    04000000 00000030 00000001
    20000000
    """

    @Test func names() {
        #expect(CheatFile.names(file) == ["Inf HP", "Inf HP #2", "Moon Jump"], "masters and labels left out, a repeat numbered")
        #expect(CheatFile.buildID(of: URL(fileURLWithPath: "/x/e0f3ccfaf50065ae.txt")) == "E0F3CCFAF50065AE")
        #expect(CheatFile.buildID(of: URL(fileURLWithPath: "/x/my cheats.txt")) == nil)
    }

    @Test func addSwitchRemove() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "beam-cheat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = GameCheats(titleID: "0400486024DEC000", build: "E0F3CCFAF50065AE", modsRoot: root.appending(path: "Mods"), macRoot: root.appending(path: "nxnative"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let other = root.appending(path: "1111111111111111.txt"); try file.write(to: other, atomically: true, encoding: .utf8)
        #expect(throws: ModError.self, "another build's file is refused") { try c.add(other, versionShown: "1.1.0") }
        let mine = root.appending(path: "E0F3CCFAF50065AE.txt"); try file.write(to: mine, atomically: true, encoding: .utf8)
        try c.add(mine, versionShown: "1.1.0")
        #expect(c.names.count == 3 && FileManager.default.fileExists(atPath: c.macFile.path), "kept for the iPhone build and copied for the Mac app")
        #expect(c.kept.path.hasSuffix("Mods/0400486024DEC000/cheats/E0F3CCFAF50065AE.txt"))
        try c.setEnabled(["Moon Jump", "Inf HP", "Not a cheat"])
        #expect(try String(contentsOf: c.enabledFile, encoding: .utf8) == "Inf HP\nMoon Jump\n", "the file's order, its names only")
        try c.setAllOff(true); #expect(c.allOff && c.enabled == ["Inf HP", "Moon Jump"], "the master switch keeps the toggles")
        try c.setAllOff(false); #expect(!c.allOff)
        try c.remove()
        #expect(c.names.isEmpty && !FileManager.default.fileExists(atPath: c.enabledFile.path))
    }
}

@Suite struct ArtTests {
    @Test func replies() throws {
        let games = try SteamGrid.decode(Data(#"{"success": true, "data": [{"id": 12, "name": "Game", "types": ["steam"], "verified": true}]}"#.utf8), as: [GridGame].self)
        #expect(games == [GridGame(id: 12, name: "Game")])
        let imgs = try SteamGrid.decode(Data(#"{"success": true, "data": [{"id": 5, "url": "https://cdn/x.png", "thumb": "https://cdn/t.png", "width": 1920, "height": 620, "author": {"name": "Artist", "steam64": "1"}, "style": "alternate"}]}"#.utf8), as: [GridImage].self)
        #expect(imgs.first?.author?.name == "Artist")
        #expect(throws: (any Error).self) { try SteamGrid.decode(Data(#"{"success": false, "errors": ["x"]}"#.utf8), as: [GridGame].self) }
    }
    @Test func imagesOnly() {
        #expect(SteamGrid.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])))
        #expect(SteamGrid.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        #expect(SteamGrid.isImage(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])))
        #expect(!SteamGrid.isImage(Data("<html>".utf8)))
    }
    @Test func buildTakesPicksNeverTheKey() {
        var r = BuildRequest(source: URL(fileURLWithPath: "/g/z.nup"), target: .iPhone, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/w"))
        r.art = URL(fileURLWithPath: "/a/keyArt.png"); r.logo = URL(fileURLWithPath: "/a/logo.png"); r.icon = URL(fileURLWithPath: "/a/icon.png")
        let a = r.arguments(script: URL(fileURLWithPath: "/s.py")).joined(separator: " ")
        #expect(a.contains("--art /a/keyArt.png") && a.contains("--logo /a/logo.png") && a.contains("--icon /a/icon.png"))
        #expect(ScriptRunner.scriptEnvironment(["STEAMGRIDDB_KEY": "secret", "HOME": "/h"]) == ["HOME": "/h"], "the key never reaches the build")
    }
}
