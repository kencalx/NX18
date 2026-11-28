// Cheats, art and the build's environment (B4 part 2), with temporary folders and fixtures: no network, no Keychain, no real game's files
import Foundation
import Testing
import AppKit
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

@Suite struct ArtFilterTests {
    @Test func keptToWhatTheBuildTakes() {
        func img(_ u: String) -> GridImage { GridImage(id: 1, url: u, thumb: u, width: nil, height: nil, author: nil) }
        #expect(SteamGrid.usable(img("https://cdn/a.png"), .icon) && SteamGrid.usable(img("https://cdn/a.jpg"), .keyArt))
        #expect(!SteamGrid.usable(img("https://cdn/a.ico"), .icon) && !SteamGrid.usable(img("https://cdn/a.webp"), .keyArt))
        #expect(SteamGrid.usable(img("https://cdn/a.webp"), .logo) && !SteamGrid.usable(img("https://cdn/a.jpg"), .logo))
    }
}

@Suite struct NXPlayPictureTests {
    @Test func keepsACopyForWhenTheCacheIsCleared() throws {
        let t = FileManager.default.temporaryDirectory.appending(path: "nxplay-picture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: t) }
        let cache = t.appending(path: "Banners"), art = t.appending(path: "Art")
        try FileManager.default.createDirectory(at: cache.appending(path: "icons"), withIntermediateDirectories: true)
        let png = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let tiff = try #require(png.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:]))
        try data.write(to: cache.appending(path: "icons/0100ABCD00001000.jpg"))
        #expect(NXPlayPicture.image(.icon, titleID: "0100abcd00001000", cache: cache, art: art) != nil)   // from NX Play's cache, with a copy kept
        #expect(FileManager.default.fileExists(atPath: art.appending(path: "0100ABCD00001000/nxplay-icon.jpg").path))
        try FileManager.default.removeItem(at: cache)   // the cache cleared
        #expect(NXPlayPicture.image(.icon, titleID: "0100ABCD00001000", cache: cache, art: art) != nil)   // Beam's copy
        #expect(NXPlayPicture.image(.banner, titleID: "0100ABCD00001000", cache: cache, art: art) == nil)   // never had one
    }
}

/// Adjust Framing (ArtFocus.swift): the library keeps the framing, a build gets it as --art-focus (only from an NX 18 that knows the option), a new key art drops it,
/// and a Mac app's own preferences get it. Temporary folders and a scratch preferences domain only
@MainActor @Suite struct ArtFramingTests {
    @Test func libraryKeepsItAndTheBuildGetsIt() throws {
        let suite = "org.nx18.beam.test.frame.\(UUID().uuidString.prefix(8).lowercased())"
        defer { ScratchPrefs.clean(suite) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "beam-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let lib = Library(settings: BeamSettings(defaults: try #require(UserDefaults(suiteName: suite))), folder: folder)
        var g = LibraryGame(source: URL(fileURLWithPath: "/g/Wonder"))
        g.identity = IdentifyEvent(titleId: "010015100B514000", name: "Wonder", platform: "switch1", kind: "nsp", versions: [], packs: nil, dlc: [], programs: [], profile: nil, alias: nil)
        lib.games = [g]; lib.save()
        lib.setArtFocus(ArtFocus(x: 0.25, y: 0.5, zoom: 1.5), for: g.id)
        #expect(Library(settings: lib.settings, folder: folder).games.first?.artFocus == ArtFocus(x: 0.25, y: 0.5, zoom: 1.5), "kept in library.json")
        var req = BuildRequest(source: g.source, target: .iPhone, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/w"))
        lib.dress(&req, lib.games[0], g.identity!)
        let args = req.arguments(script: URL(fileURLWithPath: "/s.py"))
        #expect(args.firstIndex(of: "--art-focus").map { args[$0 + 1] } == "0.25,0.5,1.5", "--art-focus x,y,zoom")
        lib.setArtFocus(.centre, for: g.id); #expect(lib.games[0].artFocus == nil, "the centre: nothing kept")
        lib.setArtFocus(ArtFocus(x: 0.1), for: g.id)
        lib.setArt(URL(fileURLWithPath: "/a/keyArt.png"), .keyArt, for: g.id); #expect(lib.games[0].artFocus == nil, "another key art: framed afresh")
        #expect(lib.games[0].artFocusStale == true, "the Mac app's framing is for the old picture until its next Mac build")
        lib.setArtFocus(ArtFocus(x: 0.1), for: g.id)
        lib.setArt(URL(fileURLWithPath: "/a/logo.png"), .logo, for: g.id); #expect(lib.games[0].artFocus == ArtFocus(x: 0.1), "a logo keeps the framing")
        var none = BuildRequest(source: g.source, target: .mac, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/w")); none.artFocus = nil
        #expect(!none.arguments(script: URL(fileURLWithPath: "/s.py")).contains("--art-focus"))
    }

    @Test func olderLibraryFilesRead() throws {
        let old = #"[{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "source": "file:///g/Old", "added": 0}]"#
        let games = try JSONDecoder().decode([LibraryGame].self, from: Data(old.utf8))
        #expect(games.first?.artFocus == nil, "a library from before the framing")
        let bad = #"[{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "source": "file:///g/Old", "added": 0, "artFocus": {"x": 7, "zoom": "big"}}]"#
        #expect(try JSONDecoder().decode([LibraryGame].self, from: Data(bad.utf8)).first?.artFocus == ArtFocus(x: 1), "out of range: kept in range; another type: the default")
    }

    @Test func checkoutKnowsTheOption() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "beam-knows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let c = NX18Checkout(folder: root)
        #expect(!c.knows("--art-focus"), "no script")
        try FileManager.default.createDirectory(at: c.script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ap.add_argument('--art', help='x')\n".write(to: c.script, atomically: true, encoding: .utf8)
        #expect(!c.knows("--art-focus"), "an NX 18 from before the option")
        try "ap.add_argument('--art-focus', metavar='X,Y[,ZOOM]')\n".write(to: c.script, atomically: true, encoding: .utf8)
        #expect(c.knows("--art-focus"))
    }

    @Test func macAppPreferences() throws {
        let id = "org.nx18.beam.test.frameapp.\(UUID().uuidString.prefix(8).lowercased())"
        defer { ScratchPrefs.clean(id) }
        let app = FileManager.default.temporaryDirectory.appending(path: "beam-frameapp-\(UUID().uuidString)/Game.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        #expect(MacArtFocus.read(app: app) == nil)
        MacArtFocus.write(ArtFocus(x: 0.3, y: 0.6, zoom: 2), app: app)
        #expect(UserDefaults(suiteName: id)?.string(forKey: "launcher.artFocus") == "0.3,0.6,2", "the key the game's window reads")
        #expect(MacArtFocus.read(app: app) == ArtFocus(x: 0.3, y: 0.6, zoom: 2))
        MacArtFocus.forget(app: app); #expect(MacArtFocus.read(app: app) == nil, "a new key art built: the old framing gone")
    }
}
