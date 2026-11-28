// The game apps' documents (dm/ios/Sources/GameDocuments.swift), run by test_game_documents.py in a temporary folder it names: the manual and guide first, then the player's
// documents from Documents/Companion (what Beam sent) and the NX 18 folder's <TITLE ID>/Documents, by name; a name in both shown once; iCloud placeholders listed as downloading;
// only the kinds the apps can show; the Mac's connected folder read from its nx18-folder line. Nothing here leaves the temporary folder
import Foundation

@main struct DocumentsCheck {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 else { print("usage: game_documents_check <empty folder>"); exit(2) }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        func write(_ rel: String) { let u = root.appendingPathComponent(rel); try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try? Data("x".utf8).write(to: u) }

        let tid = "0100abc0000a0000"
        for f in ["app/dm/manual.pdf", "app/html/index.html",
                  "docs/Companion/Area map.png", "docs/Companion/route.pdf", "docs/Companion/notes.txt", "docs/Companion/save.zip", "docs/Companion/.DS_Store", "docs/Companion/half.pdf.part",
                  "NX 18/0100ABC0000A0000/Documents/route.pdf", "NX 18/0100ABC0000A0000/Documents/.notes.txt.icloud", "NX 18/0100ABC0000A0000/Documents/.boss guide.pdf.icloud",
                  "NX 18/0100ABC0000A0000/Documents/Walkthrough.md", "NX 18/0100ABC0000A0000/Documents/page.html", "NX 18/0100ABC0000A0000/Documents/photo.HEIC",
                  "NX 18/0100ABC0000A0000/Captures/shot.png"] { write(f) }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("NX 18/0100ABC0000A0000/Documents/folder.pdf"), withIntermediateDirectories: true)   // a folder: left out

        let companion = GameDocuments.companionFolder(documents: root.appendingPathComponent("docs"))
        expect(companion?.lastPathComponent == "Companion", "the companion folder is Documents/Companion")
        expect(GameDocuments.nx18Folder(titleID: tid, nx18: root.appendingPathComponent("NX 18")).path.hasSuffix("NX 18/0100ABC0000A0000/Documents"), "the NX 18 folder's <TITLE ID>/Documents, upper case")
        let docs = await GameDocuments.load(manual: root.appendingPathComponent("app/dm/manual.pdf"), guide: root.appendingPathComponent("app/html/index.html"),
                                            guideRoot: root.appendingPathComponent("app/html"), companion: companion, nx18: root.appendingPathComponent("NX 18"), titleID: tid)
        let shown = docs.map { "\($0.title)|\($0.kind.rawValue)|\($0.source.rawValue)|\($0.downloading ? "cloud" : "here")" }
        print(shown.joined(separator: "\n"))
        expect(shown == ["Manual|manual|app|here", "Game guide|guide|app|here",
                         "Area map|picture|companion|here", "boss guide|pdf|nx18|cloud", "notes|text|companion|here", "page|web|nx18|here", "photo|picture|nx18|here",
                         "route|pdf|nx18|here", "Walkthrough|text|nx18|here"],
               "manual, guide, then the player's by name: the NX 18 folder's copy of a name unless it is still in iCloud and Beam's copy is here; no zip, hidden, partly written or folder")
        expect(docs[1].root?.lastPathComponent == "html", "the guide carries the folder its pages may read")
        expect(docs.first { $0.title == "boss guide" }?.url.lastPathComponent == "boss guide.pdf", "a placeholder is listed under the name it will have")
        expect(Set(docs.map(\.id)).count == docs.count, "ids are unique")
        let none = GameDocuments.list(manual: nil, guide: nil, guideRoot: nil, companion: root.appendingPathComponent("missing"), nx18: nil, titleID: tid)
        expect(none.isEmpty, "no manual, guide or folders: nothing")

        let route = docs.first { $0.title == "route" }!
        let fetched = await GameDocuments.fetch(route)
        expect(fetched == route.url, "a file in the folder is ready as it is (a coordinated read)")
        let gone = GameDocument(url: root.appendingPathComponent("NX 18/0100ABC0000A0000/Documents/gone.pdf"), title: "gone", kind: .pdf, source: .nx18)
        expect(await GameDocuments.fetch(gone) == nil, "a file gone from the folder cannot be fetched")

        expect(GameDocuments.kind(of: "A.PDF") == .pdf && GameDocuments.kind(of: "b.webp") == .picture && GameDocuments.kind(of: "c.markdown") == .text && GameDocuments.kind(of: "d.htm") == .web, "kinds by extension, any case")
        expect(GameDocuments.kind(of: "e.zip") == nil && GameDocuments.kind(of: "noext") == nil, "nothing the apps cannot show")
        expect(GameDocuments.placeholder(".x.pdf.icloud").map { "\($0.name) \($0.placeholder)" } == "x.pdf true" && GameDocuments.placeholder("._x.pdf") == nil, "placeholders and hidden names")
        let summary = GameDocuments.summary(docs)
        expect(summary == "documents: 2 from the app, 2 sent by Beam, 5 in the NX 18 folder (1 in iCloud)", "the log line counts: \(summary)")
        expect(!summary.contains("route") && !summary.contains(root.path), "the log line has no names or paths")

        // Manual & documents in the in-game menu: offered when there is anything to read, its note, each row's note and symbol, ZL / ZR round the list
        expect(GameDocuments.offered(docs) && !GameDocuments.offered(none), "the row shows with a manual, a guide or a document, and not without")
        let manualOnly = Array(docs.prefix(1)), mineOnly = docs.filter { $0.source != .app }
        expect(GameDocuments.offered(manualOnly) && GameDocuments.offered(mineOnly), "a manual alone, or the player's documents alone, are enough")
        expect(GameDocuments.menuNote(docs) == "Manual, guide, 7 of yours", "the row's note: \(GameDocuments.menuNote(docs))")
        expect(GameDocuments.menuNote(manualOnly) == "Manual" && GameDocuments.menuNote(Array(docs[1...1])) == "Guide" && GameDocuments.menuNote(Array(mineOnly.prefix(1))) == "1 of yours", "the note's parts")
        let notes = docs.map(GameDocuments.note)
        print(notes.joined(separator: "\n"))
        expect(notes == ["The game's manual", "The game's own guide", "Picture · sent by Beam", "PDF · in iCloud, downloads when opened", "Text · sent by Beam", "Web page · NX 18 folder",
                         "Picture · NX 18 folder", "PDF · NX 18 folder", "Text · NX 18 folder"], "each row's note: what it is and where it is kept")
        expect(docs.map(GameDocuments.symbol) == ["book.closed", "map", "photo", "doc.richtext", "doc.plaintext", "globe", "photo", "doc.richtext", "doc.plaintext"], "each row's symbol")
        expect(GameDocuments.step(from: docs[0].id, by: -1, in: docs)?.title == "Walkthrough" && GameDocuments.step(from: docs.last!.id, by: 1, in: docs)?.title == "Manual", "ZL / ZR go round the list")
        expect(GameDocuments.step(from: docs[2].id, by: 1, in: docs)?.id == docs[3].id && GameDocuments.step(from: docs[0].id, by: 1, in: manualOnly) == nil, "the next one; none with one document")
        expect(!notes.joined().contains(root.path), "no paths in the notes")

        #if os(macOS)
        let support = root.appendingPathComponent("support")
        expect(GameDocuments.macNX18Folder(support: support) == nil, "the Mac: no folder connected")
        write("support/nxnative/nx18-folder")
        try? (root.appendingPathComponent("NX 18").path + "\n").write(to: support.appendingPathComponent("nxnative/nx18-folder"), atomically: true, encoding: .utf8)
        expect(GameDocuments.macNX18Folder(support: support)?.lastPathComponent == "NX 18", "the Mac: the connected folder from the nx18-folder line")
        #endif
        print("game documents: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
