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

/// What the library and Home say about a game's installs that run out soon: the most urgent one, within 2 days of its expiry or past it
struct ExpiryBadge: Equatable, Sendable {
    var text: String
    var expired: Bool

    static func make(_ records: [InstallRecord], now: Date = .now, calendar: Calendar = .current) -> ExpiryBadge? {
        guard let r = records.filter({ !$0.removed && $0.renewDue(now: now) }).min(by: { $0.expires! < $1.expires! }), let end = r.expires else { return nil }
        if r.expired(now: now) { return ExpiryBadge(text: "Expired on \(r.deviceName): renew", expired: true) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day ?? 0
        let when = days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
        return ExpiryBadge(text: "Expires \(when) on \(r.deviceName)", expired: false)
    }
}

/// The one reminder each install gets: the day before it expires, at 10:00. Scheduled when an install is recorded or renewed, replaced or withdrawn when it changes
/// or goes; never polled. Through a scheduler, so tests post nothing
enum ExpiryReminders {
    struct Reminder: Equatable, Sendable { var id: String; var fireDate: Date; var title: String; var body: String }
    static let hour = 10

    static func id(_ r: InstallRecord) -> String { "beam.expiry.\(r.id)" }

    /// nil: nothing to remind of (no expiry, removed, or the day before has passed: the badges say it then)
    static func reminder(for r: InstallRecord, title: String, now: Date = .now, calendar: Calendar = .current) -> Reminder? {
        guard !r.removed, let end = r.expires,
              let dayBefore = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: end)),
              let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayBefore), fire > now else { return nil }
        return Reminder(id: id(r), fireDate: fire, title: "\(title) expires tomorrow on \(r.deviceName)",
                        body: "Connect \(r.deviceName) to this Mac and renew it in Beam. Its save stays on the device.")
    }

    /// From one list of installs to the next: the reminders to withdraw, and the ones to schedule (each replaces any with its ID)
    static func changes(old: [InstallRecord], new: [InstallRecord], title: (UUID) -> String, now: Date = .now, calendar: Calendar = .current)
        -> (cancel: [String], schedule: [Reminder]) {
        var cancel: [String] = [], schedule: [Reminder] = []
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for r in new {
            if let o = before[r.id], o.expires == r.expires, o.removed == r.removed, o.deviceName == r.deviceName { continue }   // a launch, a save copy: no new date
            if let m = reminder(for: r, title: title(r.gameID), now: now, calendar: calendar) { schedule.append(m) } else if before[r.id] != nil { cancel.append(id(r)) }
        }
        let kept = Set(new.map(\.id))
        cancel += old.filter { !kept.contains($0.id) }.map(id)
        return (cancel, schedule)
    }
}

/// Renew All: every install within 2 days of its expiry (or past it) whose device is connected, one at a time; the devices not connected named
enum RenewAll {
    static func plan(installs: [InstallRecord], devices: [DeviceInfo], now: Date = .now) -> (renew: [InstallRecord], notConnected: [String]) {
        let due = installs.filter { !$0.removed && $0.renewDue(now: now) }.sorted { ($0.expires ?? now) < ($1.expires ?? now) }
        let connected = Set(devices.filter(\.connected).map(\.id))
        var away: [String] = []
        for r in due where !connected.contains(r.deviceID) && !away.contains(r.deviceName) { away.append(r.deviceName) }
        return (due.filter { connected.contains($0.deviceID) }, away)
    }

    /// The end in plain words
    static func summary(renewed: Int, failed: Int, notConnected: [String]) -> String {
        var parts: [String] = []
        if renewed > 0 { parts.append("Renewed \(renewed) \(renewed == 1 ? "game" : "games").") }
        if failed > 0 { parts.append("\(failed) could not be renewed: \(failed == 1 ? "its page says" : "their pages say") why.") }
        if !notConnected.isEmpty {
            let one = notConnected.count == 1
            parts.append("Not connected: \(joined(notConnected)). Connect \(one ? "it" : "them") by cable or on the same Wi-Fi, then choose Renew All again.")
        }
        return parts.isEmpty ? "Nothing needs renewing." : parts.joined(separator: " ")
    }
    static func joined(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
