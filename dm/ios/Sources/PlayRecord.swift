// The play record (gate-ui §18.2, F9): play time, sessions, last played and a battery estimate learned from this device's own play. Library/Application Support/play.json:
// not in Documents (so not in the Files app, Share log or the cloud save), not a launcher.* key (Reset all settings keeps it); Clear play history in About removes it. Nothing
// leaves the device. A session starts at the game's start (front_ios.m startGame) and when the scene comes back to the front, and ends when it goes to the background; it is also
// written every 5 minutes while the game runs (a timer with a minute's leeway, only during play), so a crash loses at most 5 minutes. Sessions under a minute are not counted.
// Battery: the level the power detail line already keeps current (monitoring on), read at the ends of a session and on the level-change notification; no new sampling.
import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct PlaySession: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var minutes: Double
    var batteryMinutes: Double = 0   // minutes on battery (unplugged)
    var batteryUsed: Double = 0      // battery points (percent) used on battery
    var preset: String               // the preset's stored name (battery, balanced, quality, performance, custom)
    var autoScaling = false
    var thermal = 0                  // the highest ProcessInfo thermal state seen
}

struct PlayRecordData: Codable, Equatable, Sendable {
    var sessions: [PlaySession] = []   // the last 30
    var totalMinutes: Double = 0
    var totalSessions = 0
    var lastPlayed: Date? = nil

    static let kept = 30
    mutating func add(_ s: PlaySession) {
        guard s.minutes >= 1 else { return }
        sessions.append(s); if sessions.count > Self.kept { sessions.removeFirst(sessions.count - Self.kept) }
        totalMinutes += s.minutes; totalSessions += 1
        lastPlayed = Swift.max(lastPlayed ?? s.end, s.end)
    }

    // The estimate (§18.2): sessions with ≥ 10 min on battery and ≥ 5 points used, for this preset; once there are 3 of them with 60 min in all, the median rate of the last 10,
    // as minutes from a full charge, rounded to 10 minutes. nil before then: no line
    func batteryEstimate(preset: String) -> Int? {
        let usable = sessions.filter { $0.preset == preset && $0.batteryMinutes >= 10 && $0.batteryUsed >= 5 }
        guard usable.count >= 3, usable.reduce(0, { $0 + $1.batteryMinutes }) >= 60 else { return nil }
        let rates = usable.suffix(10).map { $0.batteryUsed / $0.batteryMinutes }.sorted()   // points per minute
        let n = rates.count, mid = n % 2 == 1 ? rates[n / 2] : (rates[n / 2 - 1] + rates[n / 2]) / 2
        guard mid > 0 else { return nil }
        return Int((100 / mid / 10).rounded()) * 10
    }
}

enum PlayRecordText {
    // "12 h 40 min", "35 min", "Under a minute"
    static func duration(minutes m: Double) -> String {
        let t = Int(m.rounded(.down))
        if t < 1 { return "Under a minute" }
        let h = t / 60, r = t % 60
        return h == 0 ? "\(r) min" : r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
    static func sessions(_ n: Int) -> String { n == 1 ? "1 session" : "\(n) sessions" }
    static func battery(minutes: Int, preset: String) -> String { "About \(duration(minutes: Double(minutes))) from a full charge with \(preset)" }
    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

@MainActor
final class PlayRecord {
    static let shared = PlayRecord()
    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("play.json")
    }
    var url = PlayRecord.defaultURL
    private(set) var current: PlaySession?
    private var lastLevel: Double?, lastAt: Date?, unplugged = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    nonisolated static func read(_ url: URL = defaultURL) -> PlayRecordData {
        guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder.play.decode(PlayRecordData.self, from: d) else { return PlayRecordData() }
        return r
    }
    private func write(_ r: PlayRecordData) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder.play.encode(r) { try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
    // Clear play history: the file goes; a session under way counts from now, so the cleared time does not come back with its next write
    func clear(now: Date = Date()) {
        if var s = current { s.start = now; s.end = now; s.batteryMinutes = 0; s.batteryUsed = 0; current = s }
        try? FileManager.default.removeItem(at: url)
    }

    // The game's start (and each return to the front): a new session
    func begin(preset: String, autoScaling: Bool, now: Date = Date()) {
        if current != nil { return }
        current = PlaySession(start: now, end: now, minutes: 0, preset: preset, autoScaling: autoScaling, thermal: ProcessInfo.processInfo.thermalState.rawValue)
        sampleBattery(now)
        #if canImport(UIKit)
        if observers.isEmpty {
            let c = NotificationCenter.default
            observers.append(c.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { PlayRecord.shared.sampleBattery(Date()) } })
            observers.append(c.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { PlayRecord.shared.sampleBattery(Date()) } })
            observers.append(c.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if var s = PlayRecord.shared.current { s.thermal = Swift.max(s.thermal, ProcessInfo.processInfo.thermalState.rawValue); PlayRecord.shared.current = s } }
            })
        }
        #endif
        let t = Timer(timeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { PlayRecord.shared.checkpoint() } }
        t.tolerance = 60; RunLoop.main.add(t, forMode: .common); timer = t
    }
    // To the background, or the app's end: the session ends and is written
    func end(now: Date = Date()) {
        guard current != nil else { return }
        sampleBattery(now)
        timer?.invalidate(); timer = nil
        guard var s = current else { return }
        current = nil
        s.end = now; s.minutes = now.timeIntervalSince(s.start) / 60
        var r = Self.read(url)
        if s.minutes >= 1 { r.add(s); write(r) }
    }
    // Every 5 minutes: the session so far is written as the record's last one, replaced on the next checkpoint
    func checkpoint(now: Date = Date()) {
        guard current != nil else { return }
        sampleBattery(now)
        guard var s = current else { return }
        s.end = now; s.minutes = now.timeIntervalSince(s.start) / 60
        var r = Self.read(url)
        if let last = r.sessions.last, last.start == s.start {   // the previous checkpoint of this session
            r.sessions.removeLast(); r.totalMinutes -= last.minutes; r.totalSessions -= 1
        }
        if s.minutes >= 1 { r.add(s); write(r) }
    }
    private func sampleBattery(_ now: Date) {
        #if canImport(UIKit)
        let dev = UIDevice.current
        guard dev.isBatteryMonitoringEnabled, dev.batteryLevel >= 0 else { lastLevel = nil; return }
        let level = Double(dev.batteryLevel) * 100, onBattery = dev.batteryState == .unplugged
        if var s = current, let l0 = lastLevel, let t0 = lastAt, unplugged {
            s.batteryMinutes += now.timeIntervalSince(t0) / 60
            s.batteryUsed += Swift.max(0, l0 - level)
            current = s
        }
        lastLevel = level; lastAt = now; unplugged = onBattery
        #endif
    }
}

extension JSONEncoder { static var play: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e } }
extension JSONDecoder { static var play: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d } }

// The game's start and the scene's trips (front_ios.m startGame and front_ios_focus_event): the preset the launcher stored (launcher.preset; "custom" while the values match
// none, DM_PLAY_PRESET from Play) and Auto scaling from the env the game reads
@_cdecl("dm_play_record_event")
public func dm_play_record_event(_ ev: Int32) {
    MainActor.assumeIsolated {
        if ev == 1 {
            let env = ProcessInfo.processInfo.environment
            let preset = env["DM_PLAY_PRESET"] ?? UserDefaults.standard.string(forKey: "launcher.preset") ?? "balanced"
            let auto = (env["DM_DYNAMIC_RESOLUTION"].map { $0 != "0" && $0 != "off" }) ?? false
            PlayRecord.shared.begin(preset: preset, autoScaling: auto)
        } else { PlayRecord.shared.end() }
    }
}
