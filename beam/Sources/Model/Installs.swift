// Games installed on the player's devices and the free account's slots (beam-design §3.4): at most 3 sideloaded apps active per device, each install good for 7 days,
// Renew offered within 2 days of expiry, and a fourth game swapping out the one played least recently, its save copied off first and put back at its next install
import Foundation

struct InstallRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(deviceID)|\(bundleID)" }
    var deviceID: String
    var deviceName: String
    var gameID: UUID
    var bundleID: String
    var titleID: String
    var installed: Date
    var expires: Date?
    var freeTeam: Bool
    var increasedMemoryLimit: Bool
    var lastPlayed: Date?            // Beam's launch from the device page; else the install date stands in
    var savedCopy: URL?              // a save copied off before Beam removed the app: put back at the next install
    var removed = false              // swapped out by Beam: no longer on the device

    func daysLeft(now: Date = .now) -> Int? {
        expires.map { Int(($0.timeIntervalSince(now) / 86_400).rounded(.down)) }
    }
    func renewDue(now: Date = .now) -> Bool { expires.map { $0.timeIntervalSince(now) <= 2 * 86_400 } ?? false }
    func expired(now: Date = .now) -> Bool { expires.map { $0 <= now } ?? false }
}

enum Slots {
    static let freeLimit = 3
    static let weeklyAppIDs = 10

    /// The sideloaded apps that hold a free account's slots on a device: every development-signed app on it (NX 18's and any other tool's), expired ones too until removed
    static func used(onDevice apps: [DeviceApp]) -> [DeviceApp] { apps.filter(\.byDeveloper) }

    /// What installing `bundleID` needs: nothing (it is there, or a slot is free, or the team is paid), or a swap, naming the game Beam suggests removing
    enum Plan: Equatable { case fits, replaces(bundleID: String) , full }
    static func plan(installing bundleID: String, freeTeam: Bool, onDevice apps: [DeviceApp], records: [InstallRecord]) -> Plan {
        guard freeTeam else { return .fits }
        let used = used(onDevice: apps)
        if used.contains(where: { $0.bundleID == bundleID }) || used.count < freeLimit { return .fits }
        // the NX 18 game played (or installed) least recently; Beam only suggests games it installed, never another tool's app
        let mine = used.compactMap { a in records.first { $0.bundleID == a.bundleID && !$0.removed } }
        guard let victim = mine.min(by: { ($0.lastPlayed ?? $0.installed) < ($1.lastPlayed ?? $1.installed) }) else { return .full }
        return .replaces(bundleID: victim.bundleID)
    }

    /// New App IDs this team registered in the last 7 days, from Beam's own installs (an ID reused across reinstalls counts once)
    static func appIDsThisWeek(_ records: [InstallRecord], now: Date = .now) -> Int {
        Set(records.filter { $0.freeTeam && now.timeIntervalSince($0.installed) < 7 * 86_400 }.map(\.bundleID)).count
    }
}
