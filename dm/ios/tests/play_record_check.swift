// The play record (dm/ios/Sources/PlayRecord.swift): a session of 5 minutes or more is stored once, not once by its checkpoint and again at its end; time in the background is not
// counted as battery minutes. test_play_record.py compiles it with PlayRecord.swift and runs it; the record is a file in a temporary folder, the battery a stand-in
import Foundation

@main struct PlayRecordCheck {
    nonisolated(unsafe) static var failed = 0
    static func expect(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }
    static func near(_ a: Double, _ b: Double, _ what: String) { expect(abs(a - b) < 0.001, "\(what): \(a) is not \(b)") }

    @MainActor static func main() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("play_record_check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

        // one 7-minute session with a checkpoint at 5: one session of 7 minutes
        var p = PlayRecord(); p.url = dir.appendingPathComponent("a.json")
        p.begin(preset: "balanced", autoScaling: false, now: at(0))
        p.checkpoint(now: at(5))
        var r = PlayRecord.read(p.url)
        expect(r.sessions.count == 1 && r.totalSessions == 1, "the checkpoint is in the record"); near(r.totalMinutes, 5, "checkpoint minutes")
        p.checkpoint(now: at(10))
        p.end(now: at(12))
        r = PlayRecord.read(p.url)
        expect(r.sessions.count == 1, "one session stored, not \(r.sessions.count)")
        expect(r.totalSessions == 1, "one session counted, not \(r.totalSessions)")
        near(r.totalMinutes, 12, "total minutes"); near(r.sessions.last?.minutes ?? 0, 12, "the session's minutes")
        // a second session after it: the first is kept as it was
        p.begin(preset: "balanced", autoScaling: false, now: at(60))
        p.checkpoint(now: at(65))
        p.end(now: at(66))
        r = PlayRecord.read(p.url)
        expect(r.sessions.count == 2 && r.totalSessions == 2, "two sessions, not \(r.sessions.count)/\(r.totalSessions)"); near(r.totalMinutes, 18, "both sessions' minutes")
        // a short session with no checkpoint is still stored at its end
        p.begin(preset: "balanced", autoScaling: false, now: at(100)); p.end(now: at(103))
        r = PlayRecord.read(p.url); expect(r.totalSessions == 3, "a session without a checkpoint is stored"); near(r.totalMinutes, 21, "with its minutes")

        // battery: 10 minutes on battery, an hour in the background, 10 more minutes; each session has its own 10 minutes, not the hour away
        p = PlayRecord(); p.url = dir.appendingPathComponent("b.json")
        var level = 80.0
        p.batteryReading = { (level, true) }
        p.begin(preset: "battery", autoScaling: false, now: at(0))
        level = 76; p.end(now: at(10))
        level = 70   // the battery drains while the game is away
        p.begin(preset: "battery", autoScaling: false, now: at(70))
        level = 66; p.end(now: at(80))
        r = PlayRecord.read(p.url)
        expect(r.sessions.count == 2, "two battery sessions")
        if r.sessions.count == 2 {
            near(r.sessions[0].batteryMinutes, 10, "first session's battery minutes"); near(r.sessions[0].batteryUsed, 4, "first session's points")
            near(r.sessions[1].batteryMinutes, 10, "second session's battery minutes, without the time away"); near(r.sessions[1].batteryUsed, 4, "second session's points, without the drain away")
        }
        // plugged in at the end of the last session, unplugged at the next start: no carried-over state either way
        p.batteryReading = { (level, false) }; p.begin(preset: "battery", autoScaling: false, now: at(100)); p.end(now: at(110))
        r = PlayRecord.read(p.url); near(r.sessions.last?.batteryMinutes ?? -1, 0, "plugged in: no battery minutes")

        print("play record: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
