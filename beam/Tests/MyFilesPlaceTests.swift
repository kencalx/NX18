// Keep My files in the NX 18 folder (MyFilesPlace.swift), with a made-up Beam library and NX 18 folder (temporary folders): turning it on moves Beam's files into
// <TITLE ID>/Documents without overwriting, turning it off brings back only what Beam put there, placeholders wait, and nothing is ever deleted
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct MyFilesPlaceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "beam-myfiles-\(UUID().uuidString)")
    var library: URL { root.appending(path: "Beam") }
    var nx18: URL { root.appending(path: "NX 18") }
    let tid = "0100ABC0000A0000"

    func write(_ u: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }
    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    @Test func onMovesInWithoutOverwritingAndOffBringsBackBeamsOnly() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid), docs = GameDocuments.nx18Folder(titleID: tid, nx18: nx18)
        #expect(docs.path.hasSuffix("NX 18/\(tid)/Documents"))
        try write(mine.appending(path: "map.pdf"), "beam map")
        try write(mine.appending(path: "notes.txt"), "beam notes")
        try write(docs.appending(path: "map.pdf"), "other device's map")   // already in the folder: kept as it is
        try write(docs.appending(path: "tips.md"), "player's own")         // put there by the player in Files: not Beam's

        #expect(MyFilesPlace.current(library: library, titleID: tid, keepInNX18: true, nx18: nx18) == docs)
        #expect(MyFilesPlace.current(library: library, titleID: tid, keepInNX18: true, nx18: nil) == mine, "no folder connected: Beam's folder")
        let on = MyFilesPlace.settle(library: library, keepInNX18: true, nx18: nx18)
        #expect(on == .init(moved: 2))
        #expect(names(mine).isEmpty)
        #expect(names(docs) == ["map 2.pdf", "map.pdf", "notes.txt", "tips.md"])
        #expect(text(docs.appending(path: "map.pdf")) == "other device's map" && text(docs.appending(path: "map 2.pdf")) == "beam map")
        #expect(MyFilesPlace.ledger(library: library, folder: nx18)[tid]?.sorted() == ["map 2.pdf", "notes.txt"])
        #expect(MyFilesPlace.settle(library: library, keepInNX18: true, nx18: nx18) == .init(), "again: nothing to do")

        // added with the switch on: written into the folder under a free name, and Beam's to bring back
        let added = root.appending(path: "picked/notes.txt"); try write(added, "added")
        let name = try #require(MyFilesPlace.add(added, into: docs))
        #expect(name == "notes 2.txt")
        MyFilesPlace.noteAdded(name, titleID: tid, library: library, nx18: nx18)

        let off = MyFilesPlace.settle(library: library, keepInNX18: false, nx18: nx18)
        #expect(off == .init(moved: 3))
        #expect(names(mine) == ["map 2.pdf", "notes 2.txt", "notes.txt"])
        #expect(names(docs) == ["map.pdf", "tips.md"], "what Beam did not put there stays for the other devices")
        #expect(!FileManager.default.fileExists(atPath: MyFilesPlace.ledgerURL(library: library).path))
        #expect(FileManager.default.fileExists(atPath: added.path), "an added file is copied, never moved")
    }

    @Test func placeholdersWaitAndGoneFilesLeaveTheLedger() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid), docs = GameDocuments.nx18Folder(titleID: tid, nx18: nx18)
        try write(docs.appending(path: ".big.pdf.icloud"), "placeholder")   // still in iCloud
        MyFilesPlace.noteAdded("big.pdf", titleID: tid, library: library, nx18: nx18)
        MyFilesPlace.noteAdded("gone.pdf", titleID: tid, library: library, nx18: nx18)   // removed on another device
        let r = MyFilesPlace.settle(library: library, keepInNX18: false, nx18: nx18)
        #expect(r == .init(waiting: 1))
        #expect(MyFilesPlace.ledger(library: library, folder: nx18)[tid] == ["big.pdf"])
        #expect(names(mine).isEmpty)
        #expect(MyFilesPlace.settle(library: library, keepInNX18: false, nx18: nil) == .init(), "no folder connected: nothing moves")
        #expect(MyFilesPlace.ledger(library: library, folder: nx18)[tid] == ["big.pdf"], "kept for when a folder is connected")
    }

    @Test func aFolderGoneSinceItWasConnectedIsNotMadeAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid), gone = root.appending(path: "Renamed NX 18")
        try write(mine.appending(path: "map.pdf"), "beam map")
        #expect(MyFilesPlace.current(library: library, titleID: tid, keepInNX18: true, nx18: gone) == mine, "a gone folder: Beam's own")
        #expect(MyFilesPlace.settle(library: library, keepInNX18: true, nx18: gone) == .init())
        #expect(names(mine) == ["map.pdf"])
        #expect(!FileManager.default.fileExists(atPath: gone.path), "never made again, where no device would look")
    }

    @Test func aNameNotedWhileASettleRunsIsKept() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid)
        try FileManager.default.createDirectory(at: nx18, withIntermediateDirectories: true)
        for i in 0..<150 { try write(mine.appending(path: "page \(i).txt"), "\(i)") }
        let (library, nx18) = (library, nx18)
        let settle = Task.detached { MyFilesPlace.settle(library: library, keepInNX18: true, nx18: nx18) }
        for i in 0..<150 { MyFilesPlace.noteAdded("added \(i).pdf", titleID: tid, library: library, nx18: nx18) }   // Add Files, meanwhile
        #expect(await settle.value.moved == 150)
        let l = Set(MyFilesPlace.ledger(library: library, folder: nx18)[tid] ?? [])
        #expect(l.count == 300, "every name moved and every name added")
    }

    @Test func anotherFolderConnectedWhileOnStillGivesTheFirstFoldersFilesBack() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid), other = root.appending(path: "Other NX 18")
        let first = GameDocuments.nx18Folder(titleID: tid, nx18: nx18), second = GameDocuments.nx18Folder(titleID: tid, nx18: other)
        try write(mine.appending(path: "map.pdf"), "beam map")
        for f in [nx18, other] { try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }
        #expect(MyFilesPlace.settle(library: library, keepInNX18: true, nx18: nx18) == .init(moved: 1))
        // the player connects another folder, switch still on: Add Files writes there
        try write(mine.appending(path: "notes.txt"), "beam notes")
        #expect(MyFilesPlace.settle(library: library, keepInNX18: true, nx18: other) == .init(moved: 1))
        try write(second.appending(path: "tips.md"), "player's own")
        #expect(MyFilesPlace.ledger(library: library, folder: nx18)[tid] == ["map.pdf"])
        #expect(MyFilesPlace.ledger(library: library, folder: other)[tid] == ["notes.txt"])
        // off with the second folder connected: both folders' files come back, the player's own stays
        #expect(MyFilesPlace.settle(library: library, keepInNX18: false, nx18: other) == .init(moved: 2))
        #expect(names(mine) == ["map.pdf", "notes.txt"])
        #expect(names(first).isEmpty && names(second) == ["tips.md"])
        #expect(!FileManager.default.fileExists(atPath: MyFilesPlace.ledgerURL(library: library).path))
    }

    @Test func aGoneEarlierFolderKeepsItsEntries() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid), other = root.appending(path: "Other NX 18")
        try write(mine.appending(path: "map.pdf"), "beam map")
        try FileManager.default.createDirectory(at: nx18, withIntermediateDirectories: true)
        #expect(MyFilesPlace.settle(library: library, keepInNX18: true, nx18: nx18) == .init(moved: 1))
        let moved = root.appending(path: "Parked NX 18")
        try FileManager.default.moveItem(at: nx18, to: moved)   // the first folder renamed away (signed out, say)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(MyFilesPlace.settle(library: library, keepInNX18: false, nx18: other) == .init(), "the first folder is gone: nothing to bring back yet")
        try FileManager.default.moveItem(at: moved, to: nx18)
        #expect(MyFilesPlace.ledger(library: library, folder: nx18)[tid] == ["map.pdf"], "kept, never dropped as removed")
        #expect(MyFilesPlace.settle(library: library, keepInNX18: false, nx18: other) == .init(moved: 1), "back: its file comes home")
        #expect(names(mine) == ["map.pdf"])
    }

    @Test func anOldLedgerIsReadAsTheConnectedFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = MyFilesPlace.local(library: library, titleID: tid), docs = GameDocuments.nx18Folder(titleID: tid, nx18: nx18)
        try write(docs.appending(path: "map.pdf"), "beam map")
        try write(docs.appending(path: "tips.md"), "player's own")
        try write(MyFilesPlace.legacyLedgerURL(library: library), #"{ "\#(tid)" : [ "map.pdf" ] }"#)
        #expect(MyFilesPlace.ledger(library: library, folder: nx18)[tid] == ["map.pdf"])
        #expect(MyFilesPlace.settle(library: library, keepInNX18: false, nx18: nx18) == .init(moved: 1))
        #expect(names(mine) == ["map.pdf"] && names(docs) == ["tips.md"])
        #expect(!FileManager.default.fileExists(atPath: MyFilesPlace.legacyLedgerURL(library: library).path), "folded into the new ledger")
    }

    @Test func sendListsFilesAndCountsWhatIsInICloud() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = GameDocuments.nx18Folder(titleID: tid, nx18: nx18)
        try write(docs.appending(path: "map.pdf"), "x"); try write(docs.appending(path: "a.txt"), "x")
        try write(docs.appending(path: ".big.pdf.icloud"), "placeholder"); try write(docs.appending(path: ".DS_Store"), "x")
        try write(docs.appending(path: "half.pdf.part"), "x"); try write(docs.appending(path: "folder/x"), "x")
        let (files, inICloud) = MyFilesPlace.toSend(docs)
        #expect(files.map(\.lastPathComponent) == ["a.txt", "map.pdf"])
        #expect(inICloud == 1)
        #expect(MyFilesPlace.toSend(root.appending(path: "none")).files.isEmpty)
        #expect(MyFilesPlace.sendNote(sent: 2, inICloud: 0, device: "iPhone") == nil)
        #expect(MyFilesPlace.sendNote(sent: 2, inICloud: 1, device: "iPhone") == "2 files sent to iPhone. 1 file wasn't sent because it's still in iCloud. Beam asked iCloud for it: send again once it has downloaded.")
        #expect(MyFilesPlace.sendNote(sent: 0, inICloud: 3, device: "iPhone") == "3 files weren't sent because they're still in iCloud. Beam asked iCloud for them: send again once they have downloaded.")
    }

    @Test func freeNames() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appending(path: "a.pdf"), "x"); try write(root.appending(path: "a 2.pdf"), "x"); try write(root.appending(path: ".a 3.pdf.icloud"), "x")
        try write(root.appending(path: "folder/x"), "x")
        #expect(MyFilesPlace.freeName("a.pdf", in: root) == "a 4.pdf")
        #expect(MyFilesPlace.freeName("b.pdf", in: root) == "b.pdf")
        #expect(MyFilesPlace.freeName("folder", in: root) == "folder 2")
    }
}
