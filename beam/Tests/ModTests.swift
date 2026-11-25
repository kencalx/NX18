// Mods (B4) without the network: the source format, the content checks, build IDs, keeping a mod, and the build's --mods / --manual
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct ModTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "beam-modtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func sourceFormat() throws {
        let json = #"""
        {"beam_source": 1, "name": "Example Patches", "maintainer": "A", "homepage": "https://example.org",
         "mods": [
          {"id": "a", "title_id": "0100000000010000", "build_ids": ["0123456789ABCDEF"], "kind": "framerate", "variant": "60 fps", "author": "A", "download": "https://example.org/a.zip", "sha256": "00"},
          {"id": "b", "title_id": "0100000000010000", "build_ids": ["0123456789ABCDEF"], "kind": "texture", "author": "A", "download": "https://example.org/b.zip", "sha256": "00"},
          {"id": "c", "title_id": "0100000000020000", "build_ids": [], "kind": "ultrawide", "author": "A", "download": "https://example.org/c.zip", "sha256": "00"}
         ], "later_field": true}
        """#
        let s = try ModSource.decode(Data(json.utf8))
        #expect(s.mods(for: "0100000000010000").map(\.id) == ["a"], "only frame-rate and Ultrawide, only this game")
        #expect(throws: ModError.self) { try ModSource.decode(Data(#"{"beam_source": 2, "name": "x", "mods": []}"#.utf8)) }
    }

    @Test func folderNamesThePackerReads() {
        #expect(ModKind.framerate.folderName(variant: "60 fps", author: "A/B") == "60 FPS - A B")
        #expect(ModKind.framerate.folderName(variant: nil, author: "A") == "60 FPS - A")
        #expect(ModKind.ultrawide.folderName(variant: nil, author: "A") == "Ultrawide - A")
    }

    @Test func buildIDs() throws {
        let d = try tempDir()
        let ips = d.appending(path: "0123456789abcdef0123456789abcdef.ips"); try Data([0x50]).write(to: ips)
        let pch = d.appending(path: "x.pchtxt"); try "@nsobid-FEDCBA9876543210FEDCBA9876543210\n@flag offset_shift 0x100\n".write(to: pch, atomically: true, encoding: .utf8)
        #expect(ModCheck.buildID(of: ips) == "0123456789ABCDEF" && ModCheck.buildID(of: pch) == "FEDCBA9876543210")
    }

    @Test func contentChecks() throws {
        let ok = try tempDir()
        try FileManager.default.createDirectory(at: ok.appending(path: "exefs_patches/60fps"), withIntermediateDirectories: true)
        try Data([1]).write(to: ok.appending(path: "exefs_patches/60fps/0123456789ABCDEF00000000.ips"))
        try "readme".write(to: ok.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let c = try ModCheck.contents(of: ok)
        #expect(c.patches.count == 1 && c.texts.count == 1 && c.buildIds == ["0123456789ABCDEF"])

        for bad in ["romfs/Data/a.bin", "exefs/main", "run.sh", "big.ips"] {
            let d = try tempDir()
            let f = d.appending(path: bad)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bad == "big.ips" ? 2_000_000 : 4).write(to: f)
            #expect(throws: ModError.self, "refused: \(bad)") { try ModCheck.contents(of: d) }
        }
        let link = try tempDir()
        try FileManager.default.createSymbolicLink(at: link.appending(path: "a.ips"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: ModError.self, "a link is refused") { try ModCheck.contents(of: link) }
        #expect(throws: ModError.self, "no patches") { try ModCheck.contents(of: try tempDir()) }
    }

    @Test func zipUnpackedAndKept() async throws {
        let src = try tempDir(), root = try tempDir()
        try Data([1, 2]).write(to: src.appending(path: "0123456789ABCDEF.ips"))
        let zip = root.appending(path: "m.zip")
        let r = try await Tool.run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path]); #expect(r.code == 0)
        let c = try await ModFetch.unpack(try Data(contentsOf: zip), name: "m.zip", into: root.appending(path: "work"))
        let credit = ModCredit(kind: .framerate, variant: "60 fps", author: "A", license: nil, homepage: nil, version: nil, source: nil, sha256: "x", buildIds: ["0123456789ABCDEF"], added: .now)
        let kept = try ModStore.keep(c, credit: credit, titleID: "0100000000010000", root: root.appending(path: "Mods"))
        #expect(kept.lastPathComponent == "60 FPS - A")
        #expect(FileManager.default.fileExists(atPath: kept.appending(path: "0123456789ABCDEF.ips").path) && FileManager.default.fileExists(atPath: kept.appending(path: "beam-mod.json").path))
        let list = ModStore.kept(titleID: "0100000000010000", root: root.appending(path: "Mods"))
        #expect(list.count == 1 && list[0].credit?.license == nil && list[0].credit?.kind == .framerate)
        await #expect(throws: ModError.self, "a single non-patch file is refused") { try await ModFetch.unpack(Data([1]), name: "x.exe", into: root.appending(path: "w2")) }
    }

    @Test func httpsOnly() async {
        await #expect(throws: ModError.self) { try await ModFetch.get(URL(string: "http://example.org/s.json")!) }
    }

    @Test func buildArgs() {
        var r = BuildRequest(source: URL(fileURLWithPath: "/g/Z/z.nup"), target: .mac, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/w"))
        r.mods = URL(fileURLWithPath: "/beam/Mods/X"); r.manual = URL(fileURLWithPath: "/m.pdf")
        let a = r.arguments(script: URL(fileURLWithPath: "/s.py")).joined(separator: " ")
        #expect(a.contains("--mods /beam/Mods/X") && a.contains("--manual /m.pdf"))
        r.noMods = true
        #expect(!r.arguments(script: URL(fileURLWithPath: "/s.py")).contains("--mods"))
    }
}

/// The mods folder beside a game's files (the build script's default): read for builds and the list, brought into Beam's folder before Beam's first own mod
@Suite struct GameFolderModTests {
    @Test func namesAsThePackerReadsThem() {   // dm/tools/game_mods.py role_of
        #expect(GameFolderMods.kind(of: "[21.9 Ultrawide v1.4.0]") == .ultrawide)
        #expect(GameFolderMods.kind(of: "60 FPS - Author") == .framerate && GameFolderMods.kind(of: "Frame rate unlock") == .framerate)
        #expect(GameFolderMods.kind(of: "[Disable Dynamic Resolution v1.4.0]") == nil && GameFolderMods.kind(of: "[Improved Level of Detail v1.4.0]") == nil)
    }
    @Test func readAndBringIn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "beam-gfm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "Game"), mods = game.appending(path: "mods")
        for (p, d) in [("game.nsp", "n"), ("mods/[21.9 Ultrawide v1.4.0]/exefs/1.4.0.pchtxt", "@nsobid-0123456789ABCDEF\n"),
                       ("mods/[Improved Level of Detail]/exefs/1.4.0.pchtxt", "x"), ("mods/-Off mod/exefs/a.ips", "x"),
                       ("mods/cheats/0123456789ABCDEF.txt", "[Inf]\n04000000 0 0\n"), ("mods/[21.9 Ultrawide v1.4.0]/readme.md", "r"),
                       ("mods/[21.9 Ultrawide v1.4.0]/romfs/ui/layout.bin", "texture")] {
            let u = game.appending(path: p); try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(d.utf8).write(to: u)
        }
        let own = try #require(GameFolderMods.read(game))
        #expect(own.mods.map(\.name) == ["[21.9 Ultrawide v1.4.0]", "[Improved Level of Detail]"] && own.cheatFiles == 1, "a turned-off (-) folder is skipped")
        #expect(own.mods.first?.kind == .ultrawide && own.mods.last?.kind == nil)
        let beam = root.appending(path: "Beam")
        let n = try own.bringIn(to: beam)
        #expect(n == 4, "patches, the cheat file and the readme; never the romfs file")
        #expect(!FileManager.default.fileExists(atPath: beam.appending(path: "[21.9 Ultrawide v1.4.0]/romfs/ui/layout.bin").path))
        #expect(FileManager.default.fileExists(atPath: mods.appending(path: "[21.9 Ultrawide v1.4.0]/exefs/1.4.0.pchtxt").path), "the game's folder is left as it was")
        #expect(GameFolderMods.read(root.appending(path: "none")) == nil)
    }
}
