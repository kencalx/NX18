// A game's Album (NX18-X2.0 captures-album.md, step 3): its screenshots and recordings, and the player's own documents, in one place on the game's page.
// Three folders feed it, all read in place (Beam copies nothing):
//   · the iCloud NX 18 folder's <title ID>/Captures: what an iPhone or iPad game app files there with This game's captures on NX 18 folder (DmCapture.m)
//   · the Mac app's own ~/Library/Application Support/nxnative/<title ID>/Captures (front_capture.h; DM_ROOT)
//   · Beam's My Files/<title ID> (guides, maps): the documents, or the NX 18 folder's <title ID>/Documents with Keep My files in the NX 18 folder on (MyFilesPlace.swift)
// A file iCloud has not brought down yet is a placeholder (.<name>.icloud): it is listed as downloading, and Beam asks iCloud for it only when the player opens it
// (Album.fetch), so a large Album is not pulled down just by looking at it
import Foundation

struct AlbumItem: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case screenshot, recording, document }
    enum Place: String, Sendable { case iCloud = "iCloud Drive", mac = "This Mac", myFiles = "My files", nx18 = "NX 18 folder" }   // nx18: My files kept in the NX 18 folder (MyFilesPlace.swift)
    let url: URL            // the file (for a placeholder, the name it will have)
    let kind: Kind
    let place: Place
    let date: Date
    var downloading = false
    var id: URL { url }
}

enum Album {
    static let pictures: Set<String> = ["png", "jpg", "jpeg", "heic"]
    static let movies: Set<String> = ["mov", "mp4", "m4v"]

    /// The iCloud NX 18 folder: `chosen` when given, else the one connected on this Mac (nxnative/nx18-folder: Beam's Profile settings and the Mac game apps share it, NX18Profile.folderURL
    /// on the Mac), else the iCloud Drive folder holding an NX 18 Profile, else iCloud Drive › NX 18 when it exists (captures still show with no folder connected)
    static func nx18Folder(chosen: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let chosen { return chosen }
        let line = home.appending(path: "Library/Application Support/nxnative/nx18-folder")
        if let p = (try? String(contentsOf: line, encoding: .utf8))?.split(separator: "\n").first, !p.isEmpty { return URL(fileURLWithPath: String(p), isDirectory: true) }
        // Else the iCloud Drive folder that holds an NX 18 Profile (Profile/profile.stamp, which every game app writes there): the player may have named it anything
        // ("NX saves" on the owner's), so the name "NX 18" is only the first try
        let drive = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        let named = drive.appending(path: "NX 18", directoryHint: .isDirectory)
        let fm = FileManager.default
        let marked = { (u: URL) in fm.fileExists(atPath: u.appending(path: "Profile/profile.stamp").path) }
        if marked(named) { return named }
        let folders = ((try? fm.contentsOfDirectory(at: drive, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
        if let found = folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: marked) { return found }
        return fm.fileExists(atPath: named.path) ? named : nil
    }
    static func capturesFolders(titleID: String, nx18: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(URL, AlbumItem.Place)] {
        let tid = titleID.uppercased()
        var out: [(URL, AlbumItem.Place)] = []
        if let nx18 { out.append((nx18.appending(path: "\(tid)/Captures", directoryHint: .isDirectory), .iCloud)) }
        out.append((home.appending(path: "Library/Application Support/nxnative/\(tid)/Captures", directoryHint: .isDirectory), .mac))
        return out
    }

    /// Everything, newest first: captures from both folders, then nothing hidden, AppleDouble or partly written (.part); placeholders listed, asked for only with download
    static func items(titleID: String, nx18: URL?, myFiles: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser, download: Bool = false) -> [AlbumItem] {
        var out: [AlbumItem] = []
        for (dir, place) in capturesFolders(titleID: titleID, nx18: nx18, home: home) { out += read(dir, place: place, captures: true, download: download) }
        if let myFiles { out += read(myFiles, place: .myFiles, captures: false, download: download) }
        return out.sorted { $0.date > $1.date }
    }

    static func read(_ dir: URL, place: AlbumItem.Place, captures: Bool, download: Bool) -> [AlbumItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
        guard let names = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [AlbumItem] = []
        for u in names {
            var name = u.lastPathComponent, placeholder = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)); placeholder = true }   // iCloud's stand-in for a file not downloaded
            else if name.hasPrefix(".") || name.hasPrefix("._") || name.hasSuffix(".part") { continue }
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let kind: AlbumItem.Kind = pictures.contains(ext) && captures ? .screenshot : movies.contains(ext) && captures ? .recording : .document
            if captures && kind == .document { continue }   // a Captures folder holds only pictures and movies
            let real = dir.appending(path: name)
            if placeholder && download { try? FileManager.default.startDownloadingUbiquitousItem(at: real) }
            out.append(AlbumItem(url: real, kind: kind, place: place, date: v?.creationDate ?? v?.contentModificationDate ?? .distantPast, downloading: placeholder))
        }
        return out
    }
}
