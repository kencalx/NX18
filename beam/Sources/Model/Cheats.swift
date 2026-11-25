// Cheats in Beam (beam-design §3.7, docs/frontends.md "Cheats"): the player's own Atmosphère cheat files, never downloaded. A file is named after the build it is
// for (<build ID>.txt, the first 16 hex digits of main's build ID); one for another build is refused with both versions named. Beam keeps each in the game's
// mods folder (cheats/), so an iPhone build packs it; for a Mac app it writes the host's files before a start: <DM_ROOT>/cheats/<build ID>.txt, the cheats that
// are on (<build ID>.enabled) and the master switch (.cheats-off-<title ID>). Never while the game runs: the host reads them only at a start or on Reload Cheats
import Foundation

enum CheatFile {
    /// The cheats a file lists, by name, as the host names them: [Name] entries in order, a repeated name's later ones "Name #2", "Name #3"; {Master} entries
    /// (always on) and labels without code are left out
    static func names(_ text: String) -> [String] {
        var out: [String] = [], count: [String: Int] = [:]
        var current: String?, hasCode = false
        func close() {
            guard let c = current, hasCode else { return }
            count[c, default: 0] += 1
            out.append(count[c]! == 1 ? c : "\(c) #\(count[c]!)")
        }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") && line.count >= 2 {
                close(); current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces); hasCode = false
            } else if line.hasPrefix("{") && line.hasSuffix("}") {
                close(); current = nil; hasCode = false   // a master: always on, not listed
            } else if current != nil, !line.isEmpty, line.first?.isHexDigit == true {
                hasCode = true
            }
        }
        close()
        return out
    }

    /// The build a cheat file is for, from its name (cheat sites name the file after the build ID)
    static func buildID(of file: URL) -> String? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.count >= 16, stem.prefix(16).allSatisfy(\.isHexDigit) else { return nil }
        return String(stem.prefix(16)).uppercased()
    }
}

/// One game's cheats: the file Beam keeps, and the Mac app's copy with its switches
struct GameCheats {
    let titleID: String
    let build: String
    var modsRoot: URL = Library.defaultFolder.appending(path: "Mods")
    var macRoot: URL = URL.applicationSupportDirectory.appending(path: "nxnative")

    var kept: URL { ModStore.folder(titleID: titleID, root: modsRoot).appending(path: "cheats/\(build).txt") }
    var macFolder: URL { macRoot.appending(path: "\(titleID.uppercased())/cheats", directoryHint: .isDirectory) }
    var macFile: URL { macFolder.appending(path: "\(build).txt") }
    var enabledFile: URL { macFolder.appending(path: "\(build).enabled") }
    var offFile: URL { macFolder.appending(path: ".cheats-off-\(titleID.uppercased())") }

    var names: [String] { (try? String(contentsOf: kept, encoding: .utf8)).map(CheatFile.names) ?? [] }
    var enabled: Set<String> {
        Set(((try? String(contentsOf: enabledFile, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init))
    }
    var allOff: Bool { FileManager.default.fileExists(atPath: offFile.path) }

    /// Keeps the player's file for this build (refusing one for another build), and puts it in the Mac app's folder too
    func add(_ file: URL, versionShown: String) throws {
        guard let id = CheatFile.buildID(of: file) else {
            throw ModError.refused("Name the cheat file after the game's build ID (\(build).txt): cheat files are made for one build.")
        }
        guard id == build else {
            throw ModError.refused("This cheat file is for build \(id); your game is \(versionShown) (build \(build)). Cheats made for another build would write to the wrong places.")
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard !CheatFile.names(text).isEmpty else { throw ModError.refused("That file has no cheats in the Atmosphère format ([Name] followed by code lines).") }
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: kept, options: .atomic)
        try syncToMac()
    }

    /// The kept file into the Mac app's cheats folder (the host reads it at the next start)
    func syncToMac() throws {
        guard FileManager.default.fileExists(atPath: kept.path) else { return }
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
        try Data(contentsOf: kept).write(to: macFile, options: .atomic)
    }

    /// The cheats that are on, written as the host writes them: one name per line, a temporary file renamed over the old one
    func setEnabled(_ on: Set<String>) throws {
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
        let ordered = names.filter(on.contains)
        try Data((ordered.joined(separator: "\n") + (ordered.isEmpty ? "" : "\n")).utf8).write(to: enabledFile, options: .atomic)
    }
    /// The master switch: the .cheats-off file while every cheat is off (the toggles are kept)
    func setAllOff(_ off: Bool) throws {
        try FileManager.default.createDirectory(at: macFolder, withIntermediateDirectories: true)
        if off { try Data().write(to: offFile) } else { try? FileManager.default.removeItem(at: offFile) }
    }
    /// Removes Beam's file and the Mac app's copy (its .enabled and .values with it); other builds' files stay
    func remove() throws {
        for u in [kept, macFile, enabledFile, macFolder.appending(path: "\(build).values")] { try? FileManager.default.removeItem(at: u) }
    }
}
