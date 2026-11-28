// The NX 18 folder Beam builds with, the Python that runs its script, and the script's command lines (beam-design §4.2).
import Foundation

struct NX18Checkout: Sendable, Equatable {
    var folder: URL
    var script: URL { folder.appending(path: "scripts/build_ipa_from_nsp.py") }
    var isValid: Bool { FileManager.default.isExecutableFile(atPath: script.path) || FileManager.default.fileExists(atPath: script.path) }

    static let defaultFolder = URL.homeDirectory.appending(path: "NX18")

    /// The Python to run the script with: the checkout's .venv (scripts/release/nx18-setup.sh makes it), else the first arm64 Python 3.12+ in nx18-setup.sh's order that has
    /// the build's modules, else the first of them that exists (identify needs none of the modules). Never macOS's own /usr/bin/python3, which is too old
    func python(checkModules: Bool = true) -> URL? {
        let fm = FileManager.default
        var candidates = [folder.appending(path: ".venv/bin/python3").path]
        candidates += ["/opt/homebrew/bin/python3"] + (12...16).reversed().map { "/opt/homebrew/bin/python3.\($0)" }
        candidates += ["/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/local/bin/python3"]
        let existing = candidates.filter { fm.isExecutableFile(atPath: $0) }
        if checkModules, let good = existing.first(where: Self.hasModules) { return URL(fileURLWithPath: good) }
        return existing.first.map { URL(fileURLWithPath: $0) }
    }

    private static func hasModules(_ python: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import sys; assert sys.version_info >= (3, 12); import lz4.block, capstone, fontTools"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// What to build and how: the options Beam passes (beam-design §4.2). Never --allow-other-metal, --env-file or the SteamGridDB key.
struct BuildRequest: Sendable, Equatable {
    enum Target: String, Sendable, CaseIterable, Codable { case iPhone, mac }
    var source: URL              // the game: a folder of NSPs or a dump, a .nup or a .nx
    var target: Target
    var keys: URL?               // prod.keys, for NSPs (IdentifyEvent.needsKeys)
    var package: String?         // -p v<N>: another version than the newest
    var titleId: String?         // --title-id: one game of an archive that holds several
    var workDir: URL             // the build folder (never an NX Play <title ID>_build folder)
    var noMods = false
    var output: URL?             // -o: the IPA or Mac app to write (nil: the script's default, beside the build folder)
    var mods: URL?               // --mods: Beam's mods folder for the game (never the player's own mods folder beside the game files)
    var manual: URL?             // --manual: the game's manual (PDF)
    var art: URL?, logo: URL?, icon: URL?   // --art, --logo, --icon: the player's picks
    var appName: String?         // --app-name: the player's name for the game (Rename)
    var profileSeed: URL?        // --profile-seed: the player's Profile (ProfileSetup.seed) in the IPA for other tools (Route B); the Xcode route takes it at xcodebuild, a Mac app reads the Mac's own
    var xcode: XcodePrep?        // --prepare-xcode: an Xcode project to sign with the player's account (iPhone install, beam-design §3.4 Route A)
    struct XcodePrep: Sendable, Equatable { var bundleID: String; var teamID: String; var workspace: URL }

    /// The game's own folder: a folder given as the game, or the folder a .nup / .nx file is in
    static func gameFolder(of source: URL) -> URL {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: source.path, isDirectory: &dir) && dir.boolValue ? source : source.deletingLastPathComponent()
    }
    /// Beam's build folder for a game: `<game folder>/build` (beam-design §4.2), or `<build space>/<title ID>` when the player chose a build space
    static func defaultWorkDir(source: URL, titleId: String, buildSpace: URL?) -> URL {
        if let buildSpace { return buildSpace.appending(path: titleId, directoryHint: .isDirectory) }
        return gameFolder(of: source).appending(path: "build", directoryHint: .isDirectory)
    }

    func arguments(script: URL) -> [String] {
        var a = [script.path, source.path, "--progress", "json", "--work-dir", workDir.path]
        if let keys { a += ["-k", keys.path] }
        if target == .mac { a += ["--platform", "mac-app"] }
        if let package { a += ["--package", package] }
        if let titleId { a += ["--title-id", titleId] }
        if noMods { a.append("--no-mods") } else if let mods { a += ["--mods", mods.path] }
        if let manual { a += ["--manual", manual.path] }
        if let art { a += ["--art", art.path] }
        if let logo { a += ["--logo", logo.path] }
        if let icon { a += ["--icon", icon.path] }
        if let appName { a += ["--app-name", appName] }
        if let output { a += ["-o", output.path] }
        if let profileSeed, target == .iPhone, xcode == nil { a += ["--profile-seed", profileSeed.path] }
        if let x = xcode {   // the workspace in the build folder, never NxNative.xcworkspace beside the player's game folder
            a += ["--prepare-xcode", "--keep-extracted", "--bundle-id", x.bundleID, "--team-id", x.teamID, "--xcode-workspace", x.workspace.path]
        }
        return a
    }
}

enum Identify {
    static func arguments(script: URL, source: URL, keys: URL?) -> [String] {
        var a = [script.path, source.path, "--identify", "--progress", "json"]
        if let keys { a += ["-k", keys.path] }
        return a
    }
}
