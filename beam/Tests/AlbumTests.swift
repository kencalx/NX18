// The Album's folders, with a made-up home (a temporary folder): the captures of the iCloud NX 18 folder and the Mac app's, My files, iCloud placeholders, files left out
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct AlbumTests {
    func file(_ u: URL, _ date: Date) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: u.path)
    }

    @Test func gathersNewestFirst() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "beam-album-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: home) }
        let tid = "0100abc0000a0000", nx = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs/NX 18"), mine = home.appending(path: "My Files/0100ABC0000A0000")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try file(nx.appending(path: "0100ABC0000A0000/Captures/2026-11-25 21.04.17.png"), t)
        try file(nx.appending(path: "0100ABC0000A0000/Captures/.2026-11-25 21.05.00.png.icloud"), t + 60)   // not downloaded yet
        try file(nx.appending(path: "0100ABC0000A0000/Captures/2026-11-25 21.06.00.png.part"), t + 70)      // still being written
        try file(nx.appending(path: "0100ABC0000A0000/Captures/notes.txt"), t + 80)                         // not a capture
        try file(home.appending(path: "Library/Application Support/nxnative/0100ABC0000A0000/Captures/2026-11-26 09.00.00.mov"), t + 3600)
        try file(mine.appending(path: "map.pdf"), t - 3600)
        try file(mine.appending(path: ".DS_Store"), t)

        #expect(Album.nx18Folder(chosen: nil, home: home)?.lastPathComponent == "NX 18", "iCloud Drive › NX 18 found without a choice")
        let items = Album.items(titleID: tid, nx18: Album.nx18Folder(chosen: nil, home: home), myFiles: mine, home: home, download: false)
        #expect(items.map(\.url.lastPathComponent) == ["2026-11-26 09.00.00.mov", "2026-11-25 21.05.00.png", "2026-11-25 21.04.17.png", "map.pdf"])
        #expect(items.map(\.kind) == [.recording, .screenshot, .screenshot, .document])
        #expect(items.map(\.place) == [.mac, .iCloud, .iCloud, .myFiles])
        #expect(items[1].downloading && !items[2].downloading, "the placeholder is listed as downloading, under the name it will have")
    }

    @Test func folderFoundByItsProfile() throws {   // a folder of any name, found by the Profile the game apps keep in it
        let home = FileManager.default.temporaryDirectory.appending(path: "beam-album-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: home) }
        let drive = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        try FileManager.default.createDirectory(at: drive.appending(path: "Documents"), withIntermediateDirectories: true)
        try file(drive.appending(path: "NX saves/Profile/profile.stamp"), .now)
        #expect(Album.nx18Folder(chosen: nil, home: home)?.lastPathComponent == "NX saves")
    }

    @Test func folderTheMacAppsUse() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "beam-album-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: home) }
        let line = home.appending(path: "Library/Application Support/nxnative/nx18-folder")
        try FileManager.default.createDirectory(at: line.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Games NX\n".write(to: line, atomically: true, encoding: .utf8)
        #expect(Album.nx18Folder(chosen: nil, home: home)?.lastPathComponent == "Games NX")
        #expect(Album.nx18Folder(chosen: URL(fileURLWithPath: "/tmp/mine"), home: home)?.path == "/tmp/mine", "Beam's own choice wins")
    }
}
