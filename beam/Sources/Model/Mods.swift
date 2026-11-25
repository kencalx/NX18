// Mods in Beam (beam-design §3.6, §5): only frame-rate and Ultrawide code patches, from sources the player adds (a JSON list a mod author runs, docs/beam-sources.md)
// or a file the player got themselves. Beam ships no sources and reads one only when the player asks. Every mod is checked before it is kept: the exact build,
// the kind, the SHA-256 its source gives, and patch files only (.ips, .ips32, .pchtxt; a readme or license beside them). Kept per game in Beam's own folder,
// in folders the packer knows by name ("60 FPS - <author>", "Ultrawide - <author>"), with a beam-mod.json crediting the author; passed to builds with --mods
import CryptoKit
import Foundation

/// A source as its maintainer publishes it (docs/beam-sources.md, version 1)
struct ModSource: Codable, Sendable, Equatable {
    var beamSource: Int
    var name: String
    var maintainer: String?
    var homepage: String?
    var mods: [Entry]
    struct Entry: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var titleId: String
        var buildIds: [String]
        var kind: String           // "framerate" or "ultrawide"; anything else is not shown
        var variant: String?
        var version: String?
        var author: String
        var license: String?
        var homepage: String?
        var download: String
        var sha256: String
        var size: Int?
        var notes: String?
        var role: ModKind? { ModKind(rawValue: kind) }
    }
    static func decode(_ data: Data) throws -> ModSource {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let s = try d.decode(ModSource.self, from: data)
        guard s.beamSource == 1 else { throw ModError.refused("This source is in a newer format (\(s.beamSource)) than this Beam reads. Update Beam.") }
        return s
    }
    /// The mods this source lists for a game: its kinds only
    func mods(for titleID: String) -> [Entry] { mods.filter { $0.titleId.uppercased() == titleID.uppercased() && $0.role != nil } }
}

enum ModKind: String, Codable, Sendable, CaseIterable {
    case framerate, ultrawide
    var label: String { self == .framerate ? "Frame rate" : "Ultrawide" }
    /// The folder name the packer reads the kind from (dm/tools/game_mods.py role_of)
    func folderName(variant: String?, author: String) -> String {
        let base = self == .framerate ? (variant.flatMap { $0.range(of: #"\d+"#, options: .regularExpression).map { "\(variant![$0]) FPS" } } ?? "60 FPS") : "Ultrawide"
        return "\(base) - \(ModStore.safe(author))"
    }
}

/// beam-mod.json beside each kept mod: where it came from and whose it is (beam-design §5, Provenance)
struct ModCredit: Codable, Sendable, Equatable {
    var kind: ModKind
    var variant: String?
    var author: String
    var license: String?           // nil: "License not stated"
    var homepage: String?
    var version: String?
    var source: String?            // the source's URL; nil for a file the player added ("Added by you")
    var sha256: String
    var buildIds: [String]
    var added: Date
}

enum ModError: LocalizedError, Equatable {
    case refused(String)
    var errorDescription: String? { if case .refused(let m) = self { m } else { nil } }
}

/// What a mod's files hold, after the checks
struct ModContents: Sendable, Equatable {
    var patches: [URL]             // the patch files, flattened into the mod's folder when kept
    var texts: [URL]               // readme / license
    var buildIds: Set<String>      // the 16-digit build IDs the patches name
}

enum ModCheck {
    static let patchSuffixes: Set<String> = ["ips", "ips32", "pchtxt"]
    static let textSuffixes: Set<String> = ["txt", "md"]
    static let maxPatch = 1_000_000, maxTotal = 8_000_000

    /// Checks an unpacked mod folder: patch files only (and a readme or license), no links, nothing outside, nothing large; no RomFS or whole code modules
    static func contents(of dir: URL) throws -> ModContents {
        let fm = FileManager.default
        var patches: [URL] = [], texts: [URL] = [], total = 0, ids = Set<String>()
        let root = dir.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: []) else { throw ModError.refused("The mod could not be read.") }
        while let u = e.nextObject() as? URL {
            let name = u.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX" { if name == "__MACOSX" { e.skipDescendants() }; continue }
            let v = try u.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if v.isSymbolicLink == true { throw ModError.refused("The mod holds a link (\(name)). Beam takes patch files only.") }
            guard u.resolvingSymlinksInPath().path.hasPrefix(root) else { throw ModError.refused("The mod has a file outside its folder.") }
            if name.lowercased() == "romfs" { throw ModError.refused("The mod changes the game's files (romfs). Beam takes only frame-rate and Ultrawide code patches.") }
            guard v.isRegularFile == true else { continue }
            let ext = u.pathExtension.lowercased(), size = v.fileSize ?? 0
            total += size
            if patchSuffixes.contains(ext) {
                guard size <= maxPatch else { throw ModError.refused("\(name) is too large for a patch file.") }
                patches.append(u)
                if let id = buildID(of: u) { ids.insert(id) }
            } else if textSuffixes.contains(ext) && size <= 200_000 {
                texts.append(u)
            } else {
                throw ModError.refused("The mod holds \(name), which is not a patch file. Beam takes only .ips, .ips32 and .pchtxt patches (with a readme or license).")
            }
        }
        guard total <= maxTotal else { throw ModError.refused("The mod is larger than a code patch should be.") }
        guard !patches.isEmpty else { throw ModError.refused("The mod has no patch files (.ips, .ips32 or .pchtxt).") }
        return ModContents(patches: patches, texts: texts, buildIds: ids)
    }

    /// The build a patch file is for: an IPS file is named after the module's build ID; a .pchtxt says it in its @nsobid line. The first 16 hex digits, upper case
    static func buildID(of file: URL) -> String? {
        if file.pathExtension.lowercased() == "pchtxt", let text = try? String(contentsOf: file, encoding: .utf8),
           let r = text.range(of: #"@nsobid-([0-9A-Fa-f]{16,64})"#, options: .regularExpression) {
            return String(text[r].dropFirst("@nsobid-".count).prefix(16)).uppercased()
        }
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.count >= 16, stem.allSatisfy(\.isHexDigit) else { return nil }
        return String(stem.prefix(16)).uppercased()
    }
}

/// Beam's mods, per game: ~/Library/Application Support/NX 18 Beam/Mods/<title ID>/<kind - author>/
enum ModStore {
    static func folder(titleID: String, root: URL = Library.defaultFolder.appending(path: "Mods")) -> URL { root.appending(path: titleID.uppercased(), directoryHint: .isDirectory) }

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Unknown" : String(t.prefix(60))
    }

    struct Kept: Identifiable, Sendable, Equatable { var id: URL { folder }; var folder: URL; var credit: ModCredit? }
    static func kept(titleID: String, root: URL? = nil) -> [Kept] {
        let f = root.map { folder(titleID: titleID, root: $0) } ?? folder(titleID: titleID)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil).filter(\.hasDirectoryPath)) ?? []
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { dir in
            Kept(folder: dir, credit: (try? Data(contentsOf: dir.appending(path: "beam-mod.json"))).flatMap { try? d.decode(ModCredit.self, from: $0) })
        }
    }

    /// Keeps a checked mod: its patch files (flattened) and texts in a new folder named for its kind and author, replacing one of the same name, with its credit
    @discardableResult
    static func keep(_ c: ModContents, credit: ModCredit, titleID: String, root: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let base = root.map { folder(titleID: titleID, root: $0) } ?? folder(titleID: titleID)
        let dst = base.appending(path: credit.kind.folderName(variant: credit.variant, author: credit.author), directoryHint: .isDirectory)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let tmp = base.appending(path: ".adding-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for u in c.patches + c.texts {
            let to = tmp.appending(path: u.lastPathComponent)
            guard !fm.fileExists(atPath: to.path) else { try? fm.removeItem(at: tmp); throw ModError.refused("The mod has two files named \(u.lastPathComponent).") }
            try fm.copyItem(at: u, to: to)
        }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try e.encode(credit).write(to: tmp.appending(path: "beam-mod.json"))
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }

    static func remove(_ k: Kept) throws { try FileManager.default.removeItem(at: k.folder) }
}

enum ModFetch {
    /// A generic client name, nothing that identifies the player or this Mac (beam-design §4.5, Network)
    static let userAgent = "NX18-Beam"

    static func get(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw ModError.refused("Beam reads sources and mods over HTTPS only.") }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw ModError.refused("The server answered \((resp as? HTTPURLResponse)?.statusCode ?? 0) for \(url.host() ?? "the address").") }
        return data
    }
    static func source(_ url: URL) async throws -> ModSource { try ModSource.decode(try await get(url)) }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// Downloads a source's mod from its author's location, checks its SHA-256, unpacks it (a .zip) or takes it as one patch file, and checks its contents.
    /// Returns the contents and the folder they are in (the caller keeps them, then removes the folder)
    static func download(_ m: ModSource.Entry, into work: URL) async throws -> ModContents {
        guard let url = URL(string: m.download) else { throw ModError.refused("The source gives no valid download address for \(m.id).") }
        let data = try await get(url)
        guard sha256(data) == m.sha256.lowercased() else { throw ModError.refused("The download does not match the checksum its source gives, so Beam did not keep it.") }
        return try await unpack(data, name: url.lastPathComponent, into: work)
    }

    /// A zip or a single patch file into `work`, then checked
    static func unpack(_ data: Data, name: String, into work: URL) async throws -> ModContents {
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "zip" {
            let z = work.appending(path: "mod.zip"); try data.write(to: z)
            let out = work.appending(path: "x")
            let r = try await Tool.run("/usr/bin/ditto", ["-x", "-k", z.path, out.path])
            guard r.code == 0 else { throw ModError.refused("The mod's archive could not be unpacked.") }
            return try ModCheck.contents(of: out)
        }
        guard ModCheck.patchSuffixes.contains(ext) else { throw ModError.refused("Beam takes a .zip of patch files, or one .ips, .ips32 or .pchtxt file.") }
        let out = work.appending(path: "x"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try data.write(to: out.appending(path: name))
        return try ModCheck.contents(of: out)
    }
}
