import Foundation

/// The device a build is for: the NSP script's --device. It sets the app's device family and, when the build makes a pipeline archive (the GPU's own compiled shaders),
/// makes it for this device's GPU alone.
enum TargetDevice: String, Codable, CaseIterable, Identifiable, Sendable {
    case iphone, ipad
    var id: String { rawValue }
    var label: String { self == .iphone ? "iPhone" : "iPad" }
    var model: String { self == .iphone ? "iPhone 18 Pro Max" : "iPad Pro (M4)" }
    var gpu: String { self == .iphone ? "g19p" : "g16g" }   // MTLDevice.architecture: the A20 Pro's, the M4's
    var symbol: String { self == .iphone ? "iphone" : "ipad.landscape" }
}

/// Where the game's files go: into the app, or onto the device beside it (--romfs separate, then push_romfs.sh).
enum GameDataMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case separate, bundle
    var id: String { rawValue }
    var label: String { self == .separate ? "Copied to the device separately (small app, fast reinstalls)" : "Inside the app" }
}

/// How the app reaches the device.
enum InstallMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case xcode, sideload
    var id: String { rawValue }
    var label: String { self == .xcode ? "Sign with my Apple account and install (Xcode)" : "Unsigned IPA for a sideloading tool" }
}

struct Game: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var titleID: String
    var nspFolder: String
    var device: TargetDevice = .iphone
    var gameData: GameDataMode = .separate
    var install: InstallMethod = .xcode
    var bundleID: String = ""
    var language: String = ""
    var useMods: Bool = true
    var precompileGPUShaders: Bool = false
    var showFPS: Bool = false
    // what the last build said
    var lastIPA: String?
    var lastProject: String?
    var lastDerivedData: String?
    var lastBundleID: String?
    var lastGameData: String?
    var lastBuilt: Date?
    var lastBuiltDevice: TargetDevice?

    /// The bundle ID the app has: the one the last build named, else the one set here, else the NSP script's default.
    var effectiveBundleID: String { lastBundleID ?? (bundleID.isEmpty ? "org.nxnative.\(titleID.lowercased())" : bundleID) }
}

struct BuilderSettings: Codable, Sendable {
    var repoPath: String = NSHomeDirectory() + "/Nintanium"
    var repoURL: String = "https://github.com/kencalx/Nintanium.git"
    var branch: String = "main"
    var keysPath: String = NSHomeDirectory() + "/.switch/prod.keys"
    var outputFolder: String = ""            // empty: the IPA goes beside the game's NSPs (the script's default)
    var teamID: String = ""
    var python: String = "python3"
    var autoPull: Bool = true
    var autoPullMinutes: Int = 30
    var paidAccount: Bool = true             // an Apple Developer Program team: both memory entitlements, and devices registered as they are installed on

    init() {}

    /// Missing keys take their defaults, so settings saved by an older version still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BuilderSettings()
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? d.repoPath
        repoURL = try c.decodeIfPresent(String.self, forKey: .repoURL) ?? d.repoURL
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? d.branch
        keysPath = try c.decodeIfPresent(String.self, forKey: .keysPath) ?? d.keysPath
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder) ?? d.outputFolder
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID) ?? d.teamID
        python = try c.decodeIfPresent(String.self, forKey: .python) ?? d.python
        autoPull = try c.decodeIfPresent(Bool.self, forKey: .autoPull) ?? d.autoPull
        autoPullMinutes = try c.decodeIfPresent(Int.self, forKey: .autoPullMinutes) ?? d.autoPullMinutes
        paidAccount = try c.decodeIfPresent(Bool.self, forKey: .paidAccount) ?? d.paidAccount
    }
}

/// The entitlements a build asks for. build_ipa.sh's default is both memory entitlements: Increased Memory Limit and Extended Virtual Addressing (more address space than the
/// 5 to 6 GB iOS gives without it, docs/reference/memory.md). An Apple Developer Program team provisions both; a free Personal Team only the first, so its builds get a file without
/// the second (DM_ENTITLEMENTS).
enum Entitlements {
    /// nil: build_ipa.sh's default (both); else the path of a plist for DM_ENTITLEMENTS.
    static func file(paid: Bool) -> String? {
        if paid { return nil }
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/></dict></plist>\n"
        let url = Paths.support.appendingPathComponent("entitlements-personal-team.plist")
        try? plist.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}

/// A device devicectl sees.
struct Device: Identifiable, Hashable, Sendable {
    var id: String          // devicectl's identifier
    var name: String
    var model: String
    var type: String        // iPhone, iPad
    var udid: String        // the hardware UDID, which xcodebuild's destination takes
    var connected: Bool
}

/// Reads a game's name and title ID from its NSP file names ("Game Name [0100ABCD12340000][v0].nsp").
enum GameFolder {
    static func detect(_ folder: URL) -> (name: String, titleID: String)? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let re = #/\[(01[0-9A-Fa-f]{14})\]/#
        var best: (String, String)?
        for f in files.sorted() where [".nsp", ".nsz", ".xci", ".xcz", ".nup"].contains(where: { f.lowercased().hasSuffix($0) }) {
            guard let m = f.firstMatch(of: re) else { continue }
            let tid = String(m.1).uppercased()
            let name = String(f[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let base = tid.hasSuffix("000")
            if best == nil || (base && !(best!.1.hasSuffix("000"))) { best = (name.isEmpty ? folder.lastPathComponent : name, tid) }
        }
        if let b = best, !b.1.hasSuffix("000") { best = (b.0, String(b.1.dropLast(3)) + "000") }   // an update's title ID: the base game's ends in 000
        return best.map { (name: $0.0, titleID: $0.1) }
    }
}

enum Paths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nintanium Builder", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// A game's own patches and cheats, which every build of it takes (--mods).
    static func mods(_ titleID: String) -> URL { support.appendingPathComponent("Games/\(titleID)/mods", isDirectory: true) }
}
