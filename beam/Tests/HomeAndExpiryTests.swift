// Beam Home's controller as events (PadEdges, HomePad's routing) with made-up pad values, and the expiry rules: the badges, the day-before reminders (a list
// in place of the Mac's notifications) and Renew All's plan and words
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct PadEdgesTests {
    @Test func edgesOnceAndRepeatTiming() {
        var e = PadEdges()
        #expect(e.update([.right], time: 0) == [.right], "the press")
        #expect(e.update([.right], time: 0.39).isEmpty, "held, before 0.4 s: nothing")
        #expect(e.nextRepeatTime == 0.4, "the timer is set for 0.4 s")
        #expect(e.update([.right], time: 0.4) == [.right], "first repeat at 0.4 s")
        #expect(e.nextRepeatTime == 0.52)
        #expect(e.update([.right], time: 0.5).isEmpty)
        #expect(e.update([.right], time: 0.52) == [.right], "then every 0.12 s")
        #expect(e.update([], time: 0.6).isEmpty && e.nextRepeatTime == nil, "released: no timer")
        #expect(e.update([.right], time: 0.61) == [.right], "pressed again: a new edge")
    }
    @Test func buttonsNeverRepeat() {
        var e = PadEdges()
        #expect(e.update([.a], time: 0) == [.a])
        #expect(e.nextRepeatTime == nil, "a held button needs no timer")
        #expect(e.update([.a], time: 5).isEmpty, "held A: once")
        #expect(e.update([.a, .minus], time: 5.1) == [.minus], "− joins: only it is new")
    }
    @Test func mappingAndDeadzone() {
        typealias R = PadEdges.Reading
        #expect(PadEdges.presses(R(stickX: 0.5)).isEmpty, "half way is not a press")
        #expect(PadEdges.presses(R(stickX: 0.51)) == [.right])
        #expect(PadEdges.presses(R(dpadX: 0.3, stickX: 0.3)) == [.right], "the D-pad and the stick add up")
        #expect(PadEdges.presses(R(dpadY: 1)) == [.up] && PadEdges.presses(R(stickY: -0.9)) == [.down])
        #expect(PadEdges.presses(R(dpadX: -1, dpadY: 1)) == [.left, .up])
        #expect(PadEdges.presses(R(right: true)) == [.a] && PadEdges.presses(R(bottom: true)) == [.b], "by position: right A, bottom B")
        #expect(PadEdges.presses(R(left: true)) == [.y] && PadEdges.presses(R(top: true)) == [.x] && PadEdges.presses(R(minus: true)) == [.minus])
    }
    @MainActor @Test func padOutputsEdgesFromChanges() {
        var t: TimeInterval = 0
        let pad = HomePad(clock: { t })
        var out: [PadEdges.Press] = []
        pad.onPress = { out.append($0) }
        pad.changed([.down]); t = 0.2; pad.changed([.down]); t = 0.45; pad.changed([.down, .a])
        #expect(out == [.down, .down, .a] || out == [.down, .a, .down], "the edge, the repeat after 0.4 s, A's edge")
        pad.changed([]); #expect(pad.edges.nextRepeatTime == nil)
    }
    @Test func routing() {
        #expect(HomePad.route(.a, settingsOpen: false, profileOpen: false) == .home(.a))
        #expect(HomePad.route(.a, settingsOpen: true, profileOpen: false) == .ignore, "a game's settings sheet: Home takes nothing")
        #expect(HomePad.route(.b, settingsOpen: true, profileOpen: false) == .ignore)
        #expect(HomePad.route(.b, settingsOpen: false, profileOpen: true) == .closeProfile)
        #expect(HomePad.route(.minus, settingsOpen: false, profileOpen: true) == .closeProfile)
        #expect(HomePad.route(.right, settingsOpen: false, profileOpen: true) == .ignore)
    }
}

@Suite struct ExpiryTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 15))! }
    func rec(_ device: String = "D1", name: String = "Phone", game: UUID = UUID(), bundle: String = "org.nxnative.T.0100", expires: TimeInterval?, removed: Bool = false) -> InstallRecord {
        var r = InstallRecord(deviceID: device, deviceName: name, gameID: game, bundleID: bundle, titleID: "0100", installed: now.addingTimeInterval(-86_400),
                              expires: expires.map { now.addingTimeInterval($0) }, freeTeam: true, increasedMemoryLimit: true)
        r.removed = removed
        return r
    }

    @Test func badges() {
        #expect(ExpiryBadge.make([rec(expires: 3 * 86_400)], now: now, calendar: cal) == nil, "3 days: no badge")
        #expect(ExpiryBadge.make([rec(expires: nil)], now: now, calendar: cal) == nil, "no expiry known")
        #expect(ExpiryBadge.make([rec(expires: 86_400)], now: now, calendar: cal) == ExpiryBadge(text: "Expires tomorrow on Phone", expired: false))
        #expect(ExpiryBadge.make([rec(expires: 3600)], now: now, calendar: cal)?.text == "Expires today on Phone")
        #expect(ExpiryBadge.make([rec(expires: 2 * 86_400)], now: now, calendar: cal)?.text == "Expires in 2 days on Phone")
        #expect(ExpiryBadge.make([rec(expires: -60)], now: now, calendar: cal) == ExpiryBadge(text: "Expired on Phone: renew", expired: true))
        #expect(ExpiryBadge.make([rec(expires: -60, removed: true)], now: now, calendar: cal) == nil, "swapped out: not on the device")
        let two = [rec(name: "iPad", expires: 86_400), rec("D2", name: "Phone", expires: -10)]
        #expect(ExpiryBadge.make(two, now: now, calendar: cal)?.text == "Expired on Phone: renew", "the most urgent device")
    }

    @Test func reminderTheDayBefore() throws {
        let r = rec(expires: 7 * 86_400)   // 4 December 15:00
        let m = try #require(ExpiryReminders.reminder(for: r, title: "Ocarina", now: now, calendar: cal))
        #expect(m.fireDate == cal.date(from: DateComponents(year: 2026, month: 12, day: 3, hour: 10)), "the day before, at 10:00")
        #expect(m.title == "Ocarina expires tomorrow on Phone" && m.id == "beam.expiry.D1|org.nxnative.T.0100")
        #expect(ExpiryReminders.reminder(for: rec(expires: 12 * 3600), title: "O", now: now, calendar: cal) == nil, "the day before has passed: none")
        #expect(ExpiryReminders.reminder(for: rec(expires: nil), title: "O", now: now, calendar: cal) == nil)
        #expect(ExpiryReminders.reminder(for: rec(expires: 7 * 86_400, removed: true), title: "O", now: now, calendar: cal) == nil)
    }

    @Test func reminderChanges() {
        let a = rec(expires: 7 * 86_400)
        var c = ExpiryReminders.changes(old: [], new: [a], title: { _ in "G" }, now: now, calendar: cal)
        #expect(c.cancel.isEmpty && c.schedule.map(\.id) == [ExpiryReminders.id(a)], "recorded: scheduled")
        var played = a; played.lastPlayed = now
        c = ExpiryReminders.changes(old: [a], new: [played], title: { _ in "G" }, now: now, calendar: cal)
        #expect(c.cancel.isEmpty && c.schedule.isEmpty, "played: no change")
        var renewed = a; renewed.expires = now.addingTimeInterval(14 * 86_400)
        c = ExpiryReminders.changes(old: [a], new: [renewed], title: { _ in "G" }, now: now, calendar: cal)
        #expect(c.cancel.isEmpty && c.schedule.count == 1 && c.schedule[0].fireDate > now.addingTimeInterval(12 * 86_400), "renewed: replaced, same ID")
        var gone = a; gone.removed = true
        c = ExpiryReminders.changes(old: [a], new: [gone], title: { _ in "G" }, now: now, calendar: cal)
        #expect(c.cancel == [ExpiryReminders.id(a)] && c.schedule.isEmpty, "swapped out: withdrawn")
        c = ExpiryReminders.changes(old: [a], new: [], title: { _ in "G" }, now: now, calendar: cal)
        #expect(c.cancel == [ExpiryReminders.id(a)], "forgotten: withdrawn")
    }

    @Test func renewPlanAndWords() {
        let dev = [DeviceInfo(id: "D1", name: "Phone", model: "iPhone 18 Pro Max", platform: "iOS", paired: true, connected: true, physical: true),
                   DeviceInfo(id: "D2", name: "iPad", model: "iPad Pro", platform: "iOS", paired: true, connected: false, physical: true)]
        let due1 = rec("D1", expires: 86_400), late = rec("D1", bundle: "b2", expires: -5), away = rec("D2", name: "iPad", expires: 3600),
            fine = rec("D1", bundle: "b3", expires: 5 * 86_400), gone = rec("D1", bundle: "b4", expires: 100, removed: true), unknown = rec("D3", name: "Old Phone", expires: 10)
        let p = RenewAll.plan(installs: [fine, due1, away, late, gone, unknown], devices: dev, now: now)
        #expect(p.renew == [late, due1], "due on a connected device, most urgent first")
        #expect(p.notConnected == ["Old Phone", "iPad"])
        #expect(RenewAll.summary(renewed: 2, failed: 0, notConnected: []) == "Renewed 2 games.")
        #expect(RenewAll.summary(renewed: 1, failed: 1, notConnected: ["iPad"]) ==
                "Renewed 1 game. 1 could not be renewed: its page says why. Not connected: iPad. Connect it by cable or on the same Wi-Fi, then choose Renew All again.")
        #expect(RenewAll.joined(["A", "B", "C"]) == "A, B and C")
        #expect(RenewAll.summary(renewed: 0, failed: 0, notConnected: []) == "Nothing needs renewing.")
    }
}

/// The library's installs drive the reminders: a list in place of the Mac's notification centre
@MainActor final class ListScheduler: ExpiryScheduler {
    var scheduled: [ExpiryReminders.Reminder] = []
    var cancelled: [String] = []
    func schedule(_ r: ExpiryReminders.Reminder) { scheduled.append(r) }
    func cancel(_ ids: [String]) { cancelled += ids }
}

@MainActor @Suite struct ReminderWiringTests {
    @Test func installsScheduleAndWithdraw() throws {
        let suite = "org.nx18.beam.test.exp.\(UUID().uuidString.prefix(8).lowercased())"
        defer { ScratchPrefs.clean(suite) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "beam-exp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let list = ListScheduler()
        let lib = Library(settings: BeamSettings(defaults: try #require(UserDefaults(suiteName: suite))), folder: folder, reminders: list)
        var g = LibraryGame(source: URL(fileURLWithPath: "/g/Ocarina")); g.customName = "Ocarina"
        lib.games = [g]
        let r = InstallRecord(deviceID: "D1", deviceName: "Phone", gameID: g.id, bundleID: "b", titleID: "0100", installed: .now,
                              expires: .now.addingTimeInterval(7 * 86_400), freeTeam: true, increasedMemoryLimit: true)
        lib.installs.append(r)
        #expect(list.scheduled.map(\.title) == ["Ocarina expires tomorrow on Phone"])
        lib.installs[0].lastPlayed = .now
        #expect(list.scheduled.count == 1 && list.cancelled.isEmpty, "a launch: nothing new")
        lib.installs[0].removed = true
        #expect(list.cancelled == [ExpiryReminders.id(r)])
        #expect(lib.expiryBadge(g.id) == nil && !lib.renewDue())
    }
}
