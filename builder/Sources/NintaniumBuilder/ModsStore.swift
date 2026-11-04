import Foundation

/// One entry of a game's mods folder: a mod (a folder of code patches and / or replacement game files) or a cheat file.
struct ModEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case mod, cheat }
    var url: URL
    var kind: Kind
    var enabled: Bool
    var name: String
    var detail: String
    var toggle: String?   // the launcher toggle the build makes of it: High frame rate, Ultrawide
    var id: String { url.path }
}

/// A game's mods folder (Paths.mods): mods as folders in yuzu's layout (<mod>/exefs/*.pchtxt or *.ips, <mod>/romfs/...), cheats in cheats/. The NSP script reads it with
/// --mods (dm/tools/game_mods.py): a name starting with - is off, which is how a mod or cheat file is turned off here.
enum ModsStore {
    static let patchExtensions = ["ips", "ips32", "pchtxt"]

    static func list(_ root: URL) -> [ModEntry] {
        let fm = FileManager.default
        var out: [ModEntry] = []
        let top = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        for u in top where !u.lastPathComponent.hasPrefix(".") {
            let bare = displayName(u.lastPathComponent)
            if bare.lowercased() == "cheats", isDir(u) {
                let files = ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for f in files where f.pathExtension.lowercased() == "txt" && !f.lastPathComponent.hasPrefix(".") {
                    let n = cheatNames(f)
                    out.append(ModEntry(url: f, kind: .cheat, enabled: !f.lastPathComponent.hasPrefix("-"), name: displayName(f.deletingPathExtension().lastPathComponent),
                                        detail: n.isEmpty ? "cheat file" : "\(n.count) cheat\(n.count == 1 ? "" : "s"): " + n.prefix(4).joined(separator: ", ") + (n.count > 4 ? ", …" : "")))
                }
                continue
            }
            guard isDir(u) else { continue }
            out.append(ModEntry(url: u, kind: .mod, enabled: !u.lastPathComponent.hasPrefix("-"), name: bare, detail: describe(u), toggle: toggle(for: bare)))
        }
        return out
    }

    /// The launcher toggle a mod of this name becomes (game_mods.py role_of: the same name rules).
    static func toggle(for name: String) -> String? {
        let n = name.lowercased()
        if n.contains(#/ultra\s*-?\s*wide|\b\d{2}\s*[.:x]\s*(9|10)\b/#) { return "Ultrawide" }
        if n.contains(#/\d+\s*-?\s*fps|fps\s*-?\s*\d+|\bfps\b|frame\s*rate/#) { return "High frame rate" }
        return nil
    }

    static func setEnabled(_ e: ModEntry, _ on: Bool) throws {
        let name = e.url.lastPathComponent
        let new = on ? String(name.drop(while: { $0 == "-" })) : "-" + name
        guard new != name else { return }
        try FileManager.default.moveItem(at: e.url, to: e.url.deletingLastPathComponent().appendingPathComponent(new))
    }

    static func remove(_ e: ModEntry) throws { try FileManager.default.trashItem(at: e.url, resultingItemURL: nil) }

    /// Adds what the player chose: a cheat file (.txt), a patch file (.ips / .ips32 / .pchtxt, as a mod named modName), a mod folder, or a .zip of mods.
    /// Returns what was added, for the message.
    static func add(_ src: URL, to root: URL, modName: String? = nil) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let ext = src.pathExtension.lowercased()
        if ext == "txt" {
            let dir = root.appendingPathComponent("cheats", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try replace(src, dir.appendingPathComponent(src.lastPathComponent))
            return ["cheats: \(src.lastPathComponent)"]
        }
        if patchExtensions.contains(ext) {
            let name = clean(modName ?? src.deletingPathExtension().lastPathComponent)
            let dir = root.appendingPathComponent(name).appendingPathComponent("exefs", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try replace(src, dir.appendingPathComponent(src.lastPathComponent))
            return [name]
        }
        if ext == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent("nintanium-mod-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: tmp) }
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", src.path, tmp.path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw BuilderError("cannot unpack \(src.lastPathComponent)") }
            try? fm.removeItem(at: tmp.appendingPathComponent("__MACOSX"))
            return try addTree(tmp, name: src.deletingPathExtension().lastPathComponent, to: root)
        }
        if isDir(src) { return try addTree(src, name: src.lastPathComponent, to: root) }
        throw BuilderError("\(src.lastPathComponent): add a .pchtxt, .ips or .ips32 patch, a .txt cheat file, a mod folder or a .zip of them")
    }

    // A folder of mods: a mod itself (it has exefs/, romfs/, cheats/ or patch files), a single folder holding one, or a pack whose folders are mods.
    private static func addTree(_ dir: URL, name: String, to root: URL) throws -> [String] {
        let kids = visible(dir)
        if kids.count == 1, isDir(kids[0]), !isModPart(kids[0]) { return try addTree(kids[0], name: kids[0].lastPathComponent, to: root) }
        if kids.contains(where: isModPart) || kids.contains(where: { patchExtensions.contains($0.pathExtension.lowercased()) }) {
            let n = clean(name)
            try replace(dir, root.appendingPathComponent(n))
            return [n]
        }
        let mods = kids.filter { isDir($0) && visible($0).contains(where: isModPart) }
        guard !mods.isEmpty else { throw BuilderError("\(name): no mod in it (a mod folder holds exefs/ with .pchtxt or .ips patches, or romfs/)") }
        var added: [String] = []
        for m in mods { let n = clean(m.lastPathComponent); try replace(m, root.appendingPathComponent(n)); added.append(n) }
        return added
    }

    private static func isModPart(_ u: URL) -> Bool {
        ["exefs", "romfs", "cheats", "atmosphere", "contents", "exefs_patches"].contains(u.lastPathComponent.lowercased()) && isDir(u)
    }
    private static func visible(_ d: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
    }
    private static func replace(_ src: URL, _ dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.trashItem(at: dst, resultingItemURL: nil) }
        try fm.copyItem(at: src, to: dst)
    }
    private static func clean(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: ".").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Mod" : t
    }
    static func displayName(_ s: String) -> String { String(s.drop(while: { $0 == "-" })) }
    static func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }

    private static func describe(_ dir: URL) -> String {
        var patches = 0, files = 0, cheats = 0
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let u = en?.nextObject() as? URL {
            if isDir(u) { continue }
            let low = u.path.lowercased()
            if patchExtensions.contains(u.pathExtension.lowercased()) { patches += 1 }
            else if low.contains("/romfs/") { files += 1 }
            else if low.contains("/cheats/") && u.pathExtension.lowercased() == "txt" { cheats += 1 }
        }
        var parts: [String] = []
        if patches > 0 { parts.append("\(patches) patch file\(patches == 1 ? "" : "s")") }
        if files > 0 { parts.append("\(files) game file\(files == 1 ? "" : "s")") }
        if cheats > 0 { parts.append("\(cheats) cheat file\(cheats == 1 ? "" : "s")") }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }

    /// The names of a cheat file's cheats ([Name] and {Name} lines).
    static func cheatNames(_ f: URL) -> [String] {
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.count > 2, let a = t.first, let b = t.last, (a == "[" && b == "]") || (a == "{" && b == "}") else { return nil }
            return String(t.dropFirst().dropLast())
        }
    }

    /// The cheat files that are on, for copying to the device.
    static func enabledCheatFiles(_ root: URL) -> [URL] { list(root).filter { $0.kind == .cheat && $0.enabled }.map(\.url) }

    static func hasAnything(_ root: URL) -> Bool { !list(root).filter(\.enabled).isEmpty }
}

struct BuilderError: LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
