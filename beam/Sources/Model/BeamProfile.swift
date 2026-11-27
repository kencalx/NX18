// The player's NX 18 Profile for Beam Home's top bar: the name and picture the games see (dm/ios/Sources/NX18Profile.swift has the layout). Read-only here: Beam's Welcome and Settings edit it (ProfileSetup.swift), and Home reads it again on NX18Profile.changed.
// Two places hold it: the Mac game apps' ~/Library/Application Support/nxnative/Profile/ and, with an NX 18 folder in iCloud Drive, <NX 18>/Profile/. Each has
// name.txt, picture.jpg and profile.stamp ("<generation> <device id>"); the higher stamp wins, never the newer date, as the game apps decide it. A folder copy iCloud
// has not downloaded yet reads as missing, so the Mac's copy shows until it arrives. Never logged.
import Foundation
import ImageIO

struct BeamProfile: Equatable, Sendable {
    var name: String           // "Player" when none was set
    var picture: CGImage?      // already shrunk for the bar; nil draws the default picture

    static func == (a: BeamProfile, b: BeamProfile) -> Bool { a.name == b.name && a.picture === b.picture }

    struct Stamp: Comparable {
        var generation: Int, device: String
        static func < (a: Stamp, b: Stamp) -> Bool { (a.generation, a.device) < (b.generation, b.device) }
        static func read(_ url: URL) -> Stamp? {
            guard let s = try? String(contentsOf: url, encoding: .utf8), let line = s.split(separator: "\n").first else { return nil }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let g = Int(parts.first ?? "") else { return nil }
            return Stamp(generation: g, device: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// The Profile folder to show: the one with the higher stamp; a folder without a stamp counts only when the other has none either (the Mac's comes first then)
    static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser, nx18: URL?) -> URL? {
        let fm = FileManager.default
        let mac = home.appending(path: "Library/Application Support/nxnative/Profile", directoryHint: .isDirectory)
        var places = [mac]
        if let nx18 { places.append(nx18.appending(path: "Profile", directoryHint: .isDirectory)) }
        let present = places.filter { d in ["name.txt", "picture.jpg", "profile.stamp"].contains { fm.fileExists(atPath: d.appending(path: $0).path) } }
        return present.max { (Stamp.read($0.appending(path: "profile.stamp")) ?? Stamp(generation: -1, device: "")) < (Stamp.read($1.appending(path: "profile.stamp")) ?? Stamp(generation: -1, device: "")) } ?? present.first
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, nx18: URL?, pixels: Int = 96) -> BeamProfile {
        guard let dir = folder(home: home, nx18: nx18) else { return BeamProfile(name: "Player", picture: nil) }
        let raw = (try? String(contentsOf: dir.appending(path: "name.txt"), encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        let name = raw.trimmingCharacters(in: .whitespaces)
        var picture: CGImage?
        if let src = CGImageSourceCreateWithURL(dir.appending(path: "picture.jpg") as CFURL, nil) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true]
            picture = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        return BeamProfile(name: name.isEmpty ? "Player" : name, picture: picture)
    }
}
