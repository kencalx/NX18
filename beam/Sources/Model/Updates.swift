// Beam's updates (beam-design §4.5 and decision D10). The check is the one network call the player did not start, so it is off until the player turns it on (the
// welcome screen asks; Settings turns it off), and at most once a day. The feed is the NX 18 repository's GitHub releases: a "beam-<version>" release carries
// "NX18-Beam-<version>.dmg" (scripts/release.sh makes it, with a ".sha256" beside it). When the player says Install, Beam downloads the DMG, checks its SHA-256
// (GitHub's asset digest, or the .sha256 asset), opens it read-only, and checks the app inside: Beam's bundle ID, the release's version, a valid signature from the
// same Developer ID team as the running Beam, and notarized. Only then does it put the new app beside the old one, quit, swap them and open the new one.
// A Beam without a Developer ID signature (a local build) cannot check that, so it only shows the release's link. The Library side is in LibraryUpdates.swift.
import CryptoKit
import Foundation
import Security

struct BeamRelease: Decodable, Sendable, Equatable {
    var tagName: String
    var htmlUrl: String
    var name: String?
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]?
    struct Asset: Decodable, Sendable, Equatable {
        var name: String
        var browserDownloadUrl: String
        var digest: String?      // "sha256:<hex>", GitHub's own for each uploaded asset
    }
    var version: [Int]? { BeamUpdate.version(tagName) }
    var versionString: String { String(tagName.dropFirst(5)) }
    var dmg: Asset? { assets?.first { $0.name == BeamUpdate.dmgName(versionString) } }
}

enum BeamUpdate {
    static let releases = URL(string: "https://api.github.com/repos/kencalx/NX18/releases?per_page=30")!
    static let day: TimeInterval = 86_400
    static let bundleID = "org.nx18.beam"
    static func dmgName(_ version: String) -> String { "NX18-Beam-\(version).dmg" }

    /// "beam-1.2" / "beam-1.2.3" → [1, 2, 3]; nil for any other tag (NX 18's own X2.0 and so on)
    static func version(_ tag: String) -> [Int]? {
        guard tag.hasPrefix("beam-") else { return nil }
        let parts = tag.dropFirst(5).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }
    static func newer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) { let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0; if x != y { return x > y } }
        return false
    }
    /// The newest published Beam release above `current` (no drafts or pre-releases)
    static func newest(_ all: [BeamRelease], current: String) -> BeamRelease? {
        let cur = current.split(separator: ".").compactMap { Int($0) }
        return all.filter { !$0.draft && !$0.prerelease }.compactMap { r in r.version.map { (r, $0) } }
            .filter { newer($0.1, than: cur) }.max { newer($1.1, than: $0.1) }?.0
    }

    /// `feed`: GitHub's releases list; a test passes a file:// or local http:// one of the same shape (release.sh --unsigned writes one)
    static func check(current: String, feed: URL = releases) async throws -> BeamRelease? {
        let data = try await fetch(feed, accept: "application/vnd.github+json")
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return newest(try d.decode([BeamRelease].self, from: data), current: current)
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    // MARK: install

    enum Failure: Error, Equatable, CustomStringConvertible {
        case noDMG, noChecksum, checksum, download, open, noApp, wrongApp, signature
        var description: String {
            switch self {
            case .noDMG: "This release has no Beam disk image."
            case .noChecksum: "This release has no checksum, so Beam cannot check its download."
            case .checksum: "The download does not match the release's checksum."
            case .download: "The download did not finish."
            case .open: "The disk image did not open."
            case .noApp: "The disk image has no NX 18 Beam app."
            case .wrongApp: "The app in the disk image is not this release of Beam."
            case .signature: "The new Beam is not signed and notarized by NX 18."
            }
        }
    }

    /// The code requirement a new Beam must meet: Apple-issued certificate, Beam's bundle ID, the same team as this Beam, notarized.
    /// nil when this Beam has no team (a local or ad hoc build): it cannot check an update, so it only shows the link.
    static func requirement(team: String?) -> String? {
        guard let team, !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\" and notarized"
    }
    /// This Beam's Developer ID team, read from its own signature (never shown or logged)
    static func ownTeam() -> String? {
        var code: SecCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var s: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &s) == errSecSuccess, let s,
              SecCodeCopySigningInformation(s, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    /// Where the new app goes: this Beam's own place, when Beam can write there and macOS is not running it from a read-only copy (App Translocation, the DMG);
    /// never a development build's DerivedData
    static func installTarget(_ app: URL = Bundle.main.bundleURL) -> URL? {
        let dir = app.deletingLastPathComponent()
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/"), !app.path.contains("/DerivedData/"), FileManager.default.isWritableFile(atPath: dir.path),
              (try? dir.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true else { return nil }
        return app
    }

    /// Downloads the release's DMG into `folder` and checks its SHA-256 against the release
    static func download(_ r: BeamRelease, into folder: URL) async throws -> URL {
        guard let asset = r.dmg, let url = URL(string: asset.browserDownloadUrl) else { throw Failure.noDMG }
        let want: String
        if let d = asset.digest, d.hasPrefix("sha256:") { want = String(d.dropFirst(7)) }
        else if let side = r.assets?.first(where: { $0.name == asset.name + ".sha256" }), let su = URL(string: side.browserDownloadUrl),
                let text = String(data: try await fetch(su), encoding: .utf8), let first = text.split(whereSeparator: \.isWhitespace).first { want = String(first) }
        else { throw Failure.noChecksum }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: asset.name)
        try? FileManager.default.removeItem(at: dest)
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(ModFetch.userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { try? FileManager.default.removeItem(at: tmp); throw Failure.download }
        try FileManager.default.moveItem(at: tmp, to: dest)
        guard try sha256(dest) == want.lowercased() else { try? FileManager.default.removeItem(at: dest); throw Failure.checksum }
        return dest
    }

    static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        var hash = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Opens the DMG read-only, checks the app inside and copies it beside `target` as a hidden ".NX 18 Beam.update.app", checking the copy again.
    /// Returns the copy. The DMG is closed again whatever happens.
    static func stage(dmg: URL, version: String, beside target: URL, requirement: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appending(path: "beam-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { tool("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]); try? FileManager.default.removeItem(at: mount) }
        guard tool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, "-quiet"]) == 0 else { throw Failure.open }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw Failure.noApp }
        try verify(app: app, version: version, requirement: requirement)
        let staged = target.deletingLastPathComponent().appending(path: ".\(target.deletingPathExtension().lastPathComponent).update.app")
        try? FileManager.default.removeItem(at: staged)
        guard tool("/usr/bin/ditto", [app.path, staged.path]) == 0 else { throw Failure.open }
        do { try verify(app: staged, version: version, requirement: requirement) } catch { try? FileManager.default.removeItem(at: staged); throw error }
        return staged
    }

    /// The app is Beam, this release's version, and meets the signing requirement (all its code, strictly)
    static func verify(app: URL, version: String, requirement: String) throws {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID, info["CFBundleShortVersionString"] as? String == version else { throw Failure.wrongApp }
        guard meets(app, requirement) else { throw Failure.signature }
    }
    /// The app's signature is valid, all its code strictly, and meets `requirement`
    static func meets(_ app: URL, _ requirement: String) -> Bool {
        var code: SecStaticCode?, req: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// The swap, run by /bin/sh after Beam quits: $1 Beam's process ID, $2 the staged new app, $3 Beam's app, $4 1 to open the new one.
    /// The old app is moved aside first and put back if the new one cannot take its place; it is removed only once the new one is in.
    static let swapScript = """
        pid=$1 new=$2 dst=$3 relaunch=$4
        i=0; while kill -0 "$pid" 2>/dev/null; do i=$((i+1)); [ $i -le 600 ] || { rm -rf "$new"; exit 1; }; sleep 0.1; done
        old="$(dirname "$dst")/.$(basename "$dst" .app).old.app"
        rm -rf "$old"
        mv "$dst" "$old" || { rm -rf "$new"; exit 1; }
        if mv "$new" "$dst"; then rm -rf "$old"; else mv "$old" "$dst"; rm -rf "$new"; [ "$relaunch" = 1 ] && /usr/bin/open "$dst"; exit 1; fi
        [ "$relaunch" = 1 ] && /usr/bin/open "$dst"
        exit 0
        """
    /// Starts the swap, which waits up to a minute for `pid` (Beam) to quit. It outlives Beam; the caller quits Beam right after.
    @discardableResult
    static func startSwap(staged: URL, target: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier, relaunch: Bool = true) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swapScript, "beam-update", String(pid), staged.path, target.path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    // MARK: helpers

    static func fetch(_ url: URL, accept: String? = nil) async throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(ModFetch.userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { r.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.download }
        return data
    }
    @discardableResult
    static func tool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
