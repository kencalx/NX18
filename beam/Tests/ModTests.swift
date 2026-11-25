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
