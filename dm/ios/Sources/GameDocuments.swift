// The documents a game app can show while the game runs (docs/frontends.md, Documents in the game): the game's manual (dm/manual.pdf in the app), the game's guide (its
// offline pages, the .htdocs LauncherContent finds), and the player's own guides and maps from two places:
//   · Documents/Companion in the app's own folder: what Beam's Send My Files copies onto an iPhone or iPad with devicectl (beam LibraryMods.swift sendMyFiles)
//   · the NX 18 folder's <TITLE ID>/Documents: where Beam keeps a game's My files with Keep My files in the NX 18 folder on (beam MyFilesPlace.swift), beside the game's
//     <TITLE ID>/Captures, so every device whose game app has that folder connected sees them
// One model for the iPhone and iPad app (dm/ios: the Sources folder is the app's) and the Mac's game app (dm/host/Makefile MENU_SWIFT), and Beam reads its names (folderName,
// placeholder, isShown) from here. Foundation only: no UIKit or AppKit, so the viewers are each app's own.
// A listing reads folders, and the NX 18 folder is in iCloud Drive: list() blocks and is for a background thread (load() runs it there). A file iCloud has not brought down is a
// placeholder (.<name>.icloud): listed as downloading under the name it will have, and asked for only when the player opens it (fetch, a coordinated read, which makes iCloud
// download it and waits). Reads of the NX 18 folder are coordinated (NSFileCoordinator), as the Profile's are (NX18Profile.swift).
// Shown: PDF, pictures (png, jpg, heic, webp), plain text and Markdown, and HTML pages (shown by the apps with no network, as the guide is). Anything else is left out, since the
// game app has nothing to show it with. Logs give counts only: never a file's name or a folder's path
import Foundation

struct GameDocument: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case manual, guide, pdf, picture, text, web }
    enum Source: String, Sendable { case app, companion, nx18 }   // in the app; sent by Beam; in the NX 18 folder
    let url: URL            // the file (for a placeholder, the name it will have); the guide's index.html
    let title: String       // the name shown: Manual, Game guide, or the file's name without its extension
    let kind: Kind
    let source: Source
    var root: URL? = nil    // the guide's .htdocs: the folder its pages may read
    var downloading = false // an iCloud placeholder: fetch before showing
    var id: String { "\(source.rawValue):\(url.path)" }
}

enum GameDocuments {
    /// The folder in the NX 18 folder's <TITLE ID>/ that holds the player's documents for that game (beside Captures)
    static let folderName = "Documents"
    /// The folder in a phone app's own Documents that Beam's Send My Files fills
    static let companionName = "Companion"

    static let pictures: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    static let texts: Set<String> = ["txt", "text", "md", "markdown"]
    static let pages: Set<String> = ["html", "htm"]

    /// What kind of document a file of this name is, nil for one the game apps cannot show
    static func kind(of name: String) -> GameDocument.Kind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if pictures.contains(ext) { return .picture }
        if texts.contains(ext) { return .text }
        if pages.contains(ext) { return .web }
        return nil
    }

    /// <NX 18 folder>/<TITLE ID>/Documents
    static func nx18Folder(titleID: String, nx18: URL) -> URL {
        nx18.appendingPathComponent(titleID.uppercased(), isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }
    /// The app's Documents/Companion
    static func companionFolder(documents: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) -> URL? {
        documents?.appendingPathComponent(companionName, isDirectory: true)
    }

    /// The name a directory entry stands for, and whether it is an iCloud placeholder; nil for one never shown (hidden, AppleDouble, partly written)
    static func placeholder(_ entry: String) -> (name: String, placeholder: Bool)? {
        if entry.hasPrefix("."), entry.hasSuffix(".icloud"), entry.count > 8 { return (String(entry.dropFirst().dropLast(7)), true) }
        if entry.hasPrefix(".") || entry.hasSuffix(".part") { return nil }
        return (entry, false)
    }

    #if os(macOS)
    /// The NX 18 folder this Mac's games use (Application Support/nxnative/nx18-folder, one line: NX18Profile.folderURL, which the in-game menu's module does not have)
    static func macNX18Folder(support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first) -> URL? {
        guard let f = support?.appendingPathComponent("nxnative/nx18-folder"),
              let line = (try? String(contentsOf: f, encoding: .utf8))?.split(separator: "\n").first, !line.isEmpty else { return nil }
        return URL(fileURLWithPath: String(line), isDirectory: true)
    }
    #endif

    /// Everything the game app can show, in order: the manual, the guide, then the player's documents by name. A name in both of the player's folders shows once: the NX 18 folder's,
    /// unless that one is still in iCloud and the copy Beam sent is here. Blocks on the folders (the NX 18 folder's read is coordinated): call off the main thread
    static func list(manual: URL?, guide: URL?, guideRoot: URL?, companion: URL?, nx18: URL?, titleID: String?) -> [GameDocument] {
        var out: [GameDocument] = []
        if let manual { out.append(GameDocument(url: manual, title: "Manual", kind: .manual, source: .app)) }
        if let guide { out.append(GameDocument(url: guide, title: "Game guide", kind: .guide, source: .app, root: guideRoot)) }
        var mine: [String: GameDocument] = [:]
        if let companion { for d in read(companion, source: .companion) { mine[d.url.lastPathComponent.lowercased()] = d } }
        if let nx18, let titleID, !titleID.isEmpty {
            var found: [GameDocument] = []
            let dir = nx18Folder(titleID: titleID, nx18: nx18)
            if FileManager.default.fileExists(atPath: dir.path) { coordinated(read: dir) { found = read($0, source: .nx18, as: dir) } }
            for d in found {
                let key = d.url.lastPathComponent.lowercased()
                if d.downloading, let here = mine[key], !here.downloading { continue }
                mine[key] = d
            }
        }
        out += mine.values.sorted { a, b in
            let c = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            return c == .orderedSame ? a.source.rawValue < b.source.rawValue : c == .orderedAscending
        }
        return out
    }

    /// list() on a background thread
    static func load(manual: URL?, guide: URL?, guideRoot: URL?, companion: URL?, nx18: URL?, titleID: String?) async -> [GameDocument] {
        await Task.detached(priority: .userInitiated) { list(manual: manual, guide: guide, guideRoot: guideRoot, companion: companion, nx18: nx18, titleID: titleID) }.value
    }

    /// A folder's documents (the ones shown), placeholders as downloading. `as` names the folder in the URLs (a coordinated read may hand back another URL for it)
    static func read(_ dir: URL, source: GameDocument.Source, as named: URL? = nil) -> [GameDocument] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let base = named ?? dir
        var out: [GameDocument] = []
        for e in entries {
            guard let p = placeholder(e.lastPathComponent), let k = kind(of: p.name) else { continue }
            if !p.placeholder, (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(GameDocument(url: base.appendingPathComponent(p.name), title: (p.name as NSString).deletingPathExtension, kind: k, source: source, downloading: p.placeholder))
        }
        return out
    }

    /// A document ready to show: a placeholder is brought down by a coordinated read (iCloud downloads the file for it and the read waits), on a background thread. nil when it
    /// could not be read (no connection, the file gone). The game keeps running meanwhile: the apps show the row as downloading until this returns
    static func fetch(_ doc: GameDocument) async -> URL? {
        let url = doc.url, cloud = doc.source == .nx18
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            if !cloud { return FileManager.default.isReadableFile(atPath: url.path) ? url : nil }
            var ok = false
            if doc.downloading { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            coordinated(read: url) { ok = FileManager.default.isReadableFile(atPath: $0.path) }
            return ok ? url : nil
        }.value
    }

    static func coordinated(read url: URL, _ body: (URL) -> Void) {
        var err: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { body($0) }
        if let err { fputs("documents: the NX 18 folder could not be read (\(err.code))\n", stderr) }
    }

    /// A line for the log: counts only
    static func summary(_ docs: [GameDocument]) -> String {
        let mine = docs.filter { $0.source != .app }
        return "documents: \(docs.count - mine.count) from the app, \(mine.filter { $0.source == .companion }.count) sent by Beam, \(mine.filter { $0.source == .nx18 }.count) in the NX 18 folder (\(mine.filter(\.downloading).count) in iCloud)"
    }

    // MARK: What the game apps' Manual & documents shows (GameDocumentsViewer.swift; the Gate's My files): the words and symbols, kept here so they are tested without a window

    /// Whether the in-game menu offers Manual & documents: a manual, a guide or one document of the player's
    static func offered(_ docs: [GameDocument]) -> Bool { !docs.isEmpty }

    /// The row's note: "Manual, guide, 3 of yours"
    static func menuNote(_ docs: [GameDocument]) -> String {
        var parts: [String] = []
        if docs.contains(where: { $0.kind == .manual }) { parts.append("Manual") }
        if docs.contains(where: { $0.kind == .guide }) { parts.append(parts.isEmpty ? "Guide" : "guide") }
        let mine = docs.filter { $0.source != .app }.count
        if mine > 0 { parts.append(mine == 1 ? "1 of yours" : "\(mine) of yours") }
        return parts.joined(separator: ", ")
    }

    /// A document's note: what it is and where it is kept ("PDF · NX 18 folder", "Picture · in iCloud, downloads when opened")
    static func note(_ d: GameDocument) -> String {
        let what: String
        switch d.kind {
        case .manual: return "The game's manual"
        case .guide: return "The game's own guide"
        case .pdf: what = "PDF"
        case .picture: what = "Picture"
        case .text: what = "Text"
        case .web: what = "Web page"
        }
        if d.downloading { return "\(what) · in iCloud, downloads when opened" }
        return what + (d.source == .nx18 ? " · NX 18 folder" : " · sent by Beam")
    }

    /// Its SF Symbol
    static func symbol(_ d: GameDocument) -> String {
        switch d.kind {
        case .manual: return "book.closed"
        case .guide: return "map"
        case .pdf: return "doc.richtext"
        case .picture: return "photo"
        case .text: return "doc.plaintext"
        case .web: return "globe"
        }
    }

    /// The document before (step -1) or after (1) the one with this id, round the list (ZL / ZR in the viewer); nil with fewer than two
    static func step(from id: String, by step: Int, in docs: [GameDocument]) -> GameDocument? {
        guard docs.count > 1 else { return nil }
        let i = docs.firstIndex { $0.id == id } ?? 0
        return docs[((i + step) % docs.count + docs.count) % docs.count]
    }
}
