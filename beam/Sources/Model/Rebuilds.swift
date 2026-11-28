// "Rebuild only what changed": when the NX 18 checkout Beam builds with moves on, which of the player's built games carry an older NX 18 (an idea from Cartouche; Beam's own code).
// Each build records the checkout it was built from (BuiltFrom: git commit, a digest of uncommitted changes, the shader chain). A game needs a rebuild when:
//   - the shader chain differs (dm/gfx/nvn/dmsh_chain.h DMSH_CHAIN): every game, its shader libraries are another chain's;
//   - else a file changed since its build that goes into its app: its own profile (dm/games/<its title, profile or program ID>/), or anything else in the checkout
//     (the host, graphics, iOS and Mac app code, the build scripts and tools, dm/games' shared files), which goes into every app.
//   Only what never goes into an app is left out: docs/, beam/, .github/, .githooks/, test folders, scripts/release/ and the root's text files (README and the like).
//   When git cannot say (no git, a commit the checkout does not have), the game is marked: an unneeded rebuild costs minutes, a missed one a stale app.
// Checked when Beam comes to the front and after a build: no polling. Rebuild Updated Games builds them three at a time, the Mac kept awake while it runs.
import Foundation
import CryptoKit

/// The NX 18 checkout a build was made from
struct BuiltFrom: Codable, Sendable, Equatable {
    var commit: String?          // HEAD; nil without git
    var changes: String?         // a digest of the uncommitted changes to tracked files (git diff HEAD), nil when there are none
    var chain: String?           // DMSH_CHAIN
    var guessed: Bool?           // a build from before Beam recorded this: the commit HEAD was at the build's time (the checkout's reflog)
}

enum NX18Git {
    static let chainHeader = "dm/gfx/nvn/dmsh_chain.h"

    /// git in `folder`, read only (no index refresh); nil when git fails
    static func run(_ folder: URL, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path, "--no-optional-locks", "-c", "core.quotepath=off"] + args
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
    static func line(_ d: Data?) -> String? {
        d.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func chain(text: String) -> String? {
        guard let r = text.range(of: #"#define DMSH_CHAIN "([^"]*)""#, options: .regularExpression) else { return nil }
        return text[r].split(separator: "\"").dropFirst().first.map(String.init)
    }
    static func chain(of folder: URL) -> String? {
        (try? String(contentsOf: folder.appending(path: chainHeader), encoding: .utf8)).flatMap { chain(text: $0) }
    }

    /// The checkout as it is now
    static func stamp(of folder: URL) -> BuiltFrom {
        let commit = line(run(folder, ["rev-parse", "--verify", "-q", "HEAD"]))
        var changes: String?
        if commit != nil, let diff = run(folder, ["diff", "HEAD", "--binary", "--no-color", "--no-ext-diff"]), !diff.isEmpty {
            changes = SHA256.hash(data: diff).map { String(format: "%02x", $0) }.joined()
        }
        return BuiltFrom(commit: commit, changes: changes, chain: chain(of: folder))
    }

    /// The files that differ between `commit` and the checkout's files now (commits since, and uncommitted changes); nil when git cannot say
    static func changedPaths(_ folder: URL, since commit: String) -> [String]? {
        guard run(folder, ["cat-file", "-e", "\(commit)^{commit}"]) != nil, let d = run(folder, ["diff", "--name-only", "-z", "--no-renames", commit, "--"]) else { return nil }
        return d.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A build from before Beam recorded its checkout: the commit HEAD was at `date` (the reflog) and that commit's chain. nil when the reflog does not reach back so far
    static func stamp(at date: Date, of folder: URL) -> BuiltFrom? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let oldest = line(run(folder, ["log", "-g", "--format=%ct", "HEAD"]))?.split(separator: "\n").last.flatMap({ Double($0) }),
              oldest <= date.timeIntervalSince1970,
              let commit = line(run(folder, ["rev-parse", "--verify", "-q", "HEAD@{\(f.string(from: date))}"])) else { return nil }
        let chain = line(run(folder, ["show", "\(commit):\(chainHeader)"])).flatMap { chain(text: $0) }
        return BuiltFrom(commit: commit, changes: nil, chain: chain, guessed: true)
    }
}

enum RebuildRule {
    enum Reason: String, Codable, Sendable { case shaders, nx18, unknown
        /// The game page's line under its last build
        var text: String {
            switch self {
            case .shaders: "NX 18's shaders changed since this build. Rebuild to get the update."
            case .nx18: "NX 18 changed since this build. Rebuild to get the update."
            case .unknown: "Beam cannot tell which NX 18 this was built with. Rebuild to be sure it has the latest."
            }
        }
    }

    /// Whether a changed file (a path in the checkout) goes into the app of a game whose profile folders are `titles` (upper-case title IDs: the game's, its profile's,
    /// its programs'). Unsure: yes
    static func affects(_ path: String, titles: Set<String>) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let top = parts.first else { return false }
        if ["docs", "beam", ".github", ".githooks"].contains(top) { return false }
        if parts.count == 1 { return !(top.hasPrefix(".") || top.hasSuffix(".md") || top == "LICENSE") }   // the root's own files: README, AGENTS.md, .gitignore; pyproject.toml counts
        if top == "scripts" && parts[1] == "release" { return false }   // setup and release packaging
        if parts.dropLast().contains(where: { $0 == "tests" || $0 == "test" }) { return false }
        if parts.count >= 4, parts[0] == "dm", parts[1] == "games", parts[2].count == 16, parts[2].allSatisfy(\.isHexDigit) {
            return titles.contains(parts[2].uppercased())   // a game's profile: that game's app only
        }
        return true
    }

    /// Why a game built with `built` needs a rebuild against the checkout `now` (nil: it is current). `changed`: git's changed files since built.commit (nil: git could not say)
    static func reason(built: BuiltFrom?, now: BuiltFrom, changed: [String]?, titles: Set<String>) -> Reason? {
        guard let built else { return .unknown }
        if let a = built.chain, let b = now.chain, a != b { return .shaders }
        if built.commit == nil && now.commit == nil { return built.chain == nil || now.chain == nil ? .unknown : nil }   // no git either time: the chain is all Beam can compare
        guard built.commit != nil, now.commit != nil else { return .unknown }
        if built.commit == now.commit && built.changes == now.changes { return nil }
        guard let changed else { return .unknown }
        return changed.contains { affects($0, titles: titles) } ? .nx18 : nil
    }

    /// The profile folders a game's app is made from: its title ID, its profile's ID (a regional release builds with another's), its programs'
    static func titles(of i: IdentifyEvent?) -> Set<String> {
        guard let i else { return [] }
        return Set(([i.titleId] + [i.profile].compactMap { $0 } + i.programs).map { $0.uppercased() })
    }

    /// A built game as the check sees it
    struct Built: Sendable { var id: UUID; var from: BuiltFrom?; var titles: Set<String> }

    /// Every built game's reason against the checkout in `folder`, one git diff per distinct build commit. Runs git: off the main thread
    static func check(_ builds: [Built], folder: URL) -> [UUID: Reason] {
        let now = NX18Git.stamp(of: folder)
        var diffs: [String: [String]] = [:], unknown: Set<String> = []
        var out: [UUID: Reason] = [:]
        for b in builds {
            var changed: [String]?
            if let c = b.from?.commit, now.commit != nil, c != now.commit || b.from?.changes != now.changes, !unknown.contains(c) {
                if diffs[c] == nil { if let d = NX18Git.changedPaths(folder, since: c) { diffs[c] = d } else { unknown.insert(c) } }
                changed = diffs[c]
            }
            if let r = reason(built: b.from, now: now, changed: changed, titles: b.titles) { out[b.id] = r }
        }
        return out
    }

    /// Groups of three, in library order: the owner builds three at a time, testing one group while the next builds
    static func groups<T>(_ items: [T], size: Int = 3) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// The next 1 AM after `now`: Rebuild Updated Games Tonight
    static func tonight(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: 1, minute: 0, second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }
}
