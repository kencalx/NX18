// Where a Mac game's cloud saves go, as Beam reads it (NX18CloudSaves in dm/ios/Sources/NX18Profile.swift; the same rule as dm/mac/launcher.c dm_mac_cloud_place, whose
// own test is dm/tools/tests/test_nsp_mac_app.py test_cloud_saves_place): the NX 18 card's choice, the NX 18 folder by default when one is connected and the game has no own
// folder, its own folder, off. Beam's Cloud saves door says "NX 18 folder" from it (GameSettingsView) and the game page says where the save lives. A scratch preferences
// domain and temporary folders stand in for the game app's preferences, Application Support/nxnative and iCloud Drive: nothing real is read or written
import Foundation
import Testing
@testable import NX_18_Beam

@Suite(.serialized) struct CloudSavesPlaceTests {
    typealias P = NX18CloudSaves.Place

    @Test func theRule() {
        let d = NX18CloudSaves.decide
        #expect(d(nil, nil, nil, true) == P.off)
        #expect(d("/own", nil, nil, true) == P.own("/own"))
        #expect(d(nil, nil, "/nx", true) == P.nx18("/nx"), "connected and no own folder: the NX 18 folder, chosen or not")
        #expect(d("", nil, "/nx", true) == P.off, "an own folder turned off (\"\"): this Mac keeps its own save, the default never syncs it")
        #expect(d("", "shared", "/nx", true) == P.nx18("/nx"), "the card's NX 18 folder still wins")
        #expect(d("/own", nil, "/nx", true) == P.own("/own"), "an own folder and no choice: it stays")
        #expect(d("/own", "shared", "/nx", true) == P.nx18("/nx"))
        #expect(d(nil, "own", "/nx", true) == P.off, "Own folder with none chosen: off")
        #expect(d("/own", "shared", "/nx", false) == P.nx18("/nx"), "the card's NX 18 folder holds with the switch off, as on the iPhone: the switch's Off moves the save first")
        #expect(d(nil, nil, "/nx", false) == P.off, "the default needs the switch on")
        #expect(d("/own", "shared", nil, true) == P.own("/own"), "no NX 18 folder there: its own")
        #expect(d(nil, "something else", "/nx", true) == P.nx18("/nx"), "an unknown value is no choice")
        #expect(P.nx18("/nx").inNX18 && !P.own("/o").inNX18 && P.off.folder == nil)
    }

    @Test func aGameAppsPreferencesAndTheConnectedFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "beam-cloud-place-\(UUID().uuidString)")
        let suite = "org.nxnative.beamtest.\(UUID().uuidString.lowercased())"
        defer { try? fm.removeItem(at: root); ScratchPrefs.clean(suite) }
        let app = root.appending(path: "Game.app"), sup = root.appending(path: "nxnative"), nx = root.appending(path: "iCloud/NX 18"), own = root.appending(path: "iCloud/Mine")
        for u in [app.appending(path: "Contents"), sup, nx, own] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": suite, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let prefs = try #require(UserDefaults(suiteName: suite))

        #expect(NX18CloudSaves.place(app: app, support: sup) == P.off)
        try (nx.path + "\n").write(to: sup.appending(path: "nx18-folder"), atomically: true, encoding: .utf8)
        let shared = try #require(NX18CloudSaves.place(app: app, support: sup))
        #expect(shared == P.nx18(nx.path) && shared.inNX18, "the door says NX 18 folder")
        #expect(shared.plainWords == "In your NX 18 folder, with your other devices")
        prefs.set(own.path, forKey: NX18CloudSaves.folderKey)
        #expect(NX18CloudSaves.place(app: app, support: sup) == P.own(own.path))
        #expect(NX18CloudSaves.place(app: app, support: sup)?.plainWords == "In this game's own folder, Mine")
        prefs.set("shared", forKey: NX18CloudSaves.choiceKey)
        #expect(NX18CloudSaves.place(app: app, support: sup) == P.nx18(nx.path))
        try fm.removeItem(at: nx)
        #expect(NX18CloudSaves.place(app: app, support: sup) == P.own(own.path), "the NX 18 folder no longer there: its own folder")
    }
}
