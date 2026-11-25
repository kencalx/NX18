// Beam's update check (beam-design §4.5, Network): the one network call the player did not start, so it is off until the player turns it on (the welcome screen
// asks; Settings turns it off), and at most once a day. It reads the NX 18 repository's releases and looks for a newer "beam-<version>" tag; Beam then shows a
// link to that release. Nothing is downloaded or installed by itself (the notarized DMG's own install step comes with the release work, D10)
import Foundation

struct BeamRelease: Decodable, Sendable, Equatable {
    var tagName: String
    var htmlUrl: String
    var name: String?
    var draft: Bool
    var prerelease: Bool
    var version: [Int]? { BeamUpdate.version(tagName) }
}

enum BeamUpdate {
    static let releases = URL(string: "https://api.github.com/repos/kencalx/NX18/releases?per_page=30")!
    static let day: TimeInterval = 86_400

    /// "beam-1.2" / "beam-1.2.3" → [1, 2, 3]; nil for any other tag (NX 18's own X2.0 and so on)
    static func version(_ tag: String) -> [Int]? {
        guard tag.hasPrefix("beam-") else { return nil }
        let parts = tag.dropFirst(5).split(separator: ".").map { Int($0) }
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

    static func check(current: String) async throws -> BeamRelease? {
        var r = URLRequest(url: releases, timeoutInterval: 20)
        r.setValue(ModFetch.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        return newest(try d.decode([BeamRelease].self, from: data), current: current)
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}

extension Library {
    /// The daily check, when the player turned it on and a day has passed since the last one
    func checkForUpdateIfDue(now: Date = .now) async {
        guard settings.updateChecks else { return }
        if let last = settings.lastUpdateCheck, now.timeIntervalSince(last) < BeamUpdate.day { return }
        settings.lastUpdateCheck = now
        updateAvailable = try? await BeamUpdate.check(current: BeamUpdate.currentVersion)
    }
}
