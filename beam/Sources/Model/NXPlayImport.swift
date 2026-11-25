// "Bring your NX Play library" (beam-design §3.1): Beam reads NX Play's own settings (its games folder and keys path), adds each game folder in place, and
// leaves everything where it is: nothing is moved, copied or deleted, and NX Play keeps working. An NX Play install on a device keeps its bundle ID when Beam
// reinstalls the game (XcodeSigning.bundleID takes the one an app for the same title already has), so the reinstall replaces the app and keeps its save
import Foundation

struct NXPlayLibrary: Sendable, Equatable {
    var gamesRoot: URL
    var keys: URL?
    var games: [URL]                 // its game folders
    var installedTitles: [String]    // title IDs NX Play installed on the player's devices (deviceGames)

    static let domain = "com.varyform.nxplay"

    /// NX Play's library on this Mac, from its preferences; nil when NX Play has none
    static func find(_ defaults: UserDefaults? = UserDefaults(suiteName: domain)) -> NXPlayLibrary? {
        guard let d = defaults, let root = d.string(forKey: "gamesRoot"), !root.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return nil }
        let keys = d.string(forKey: "keysPath").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let titles = (d.dictionary(forKey: "deviceGames") ?? [:]).values.compactMap { $0 as? [String] }.flatMap { $0 }
        return NXPlayLibrary(gamesRoot: rootURL, keys: keys, games: gameFolders(in: rootURL), installedTitles: Array(Set(titles.map { $0.uppercased() })).sorted())
    }

    static let gameSuffixes: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup", "nx"]

    /// The folders of a games folder that hold a game: NSPs, XCIs, NSZs, a .nup or a .nx, or a dump (base/exefs/main.npdm). Xcode workspaces, key folders and
    /// loose files are passed over
    static func gameFolders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { d in
            guard (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !["xcworkspace", "xcodeproj", "app"].contains(d.pathExtension.lowercased()) else { return false }
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if files.contains(where: { gameSuffixes.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("._") }) { return true }
            return fm.fileExists(atPath: d.appending(path: "base/exefs/main.npdm").path)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

extension Library {
    /// Adds NX Play's games that Beam does not have yet, takes its keys path if Beam has none, then asks NX 18 about each, one game at a time.
    /// Returns (added, read, not read)
    @discardableResult
    func importNXPlay(_ lib: NXPlayLibrary) async -> (added: Int, read: Int, failed: [String]) {
        if settings.keys == nil, let k = lib.keys { settings.keys = k }
        var added: [UUID] = []
        for f in lib.games where !games.contains(where: { $0.source.standardizedFileURL == f.standardizedFileURL }) {
            let g = LibraryGame(source: f)
            games.append(g); added.append(g.id)
        }
        save()
        settings.welcomed = true
        var failed: [String] = [], read = 0
        for id in added {
            if await identifyNow(id, quiet: true) == nil { read += 1 }
            else { failed.append(games.first { $0.id == id }?.title ?? "?") }
        }
        return (added.count, read, failed)
    }
}
