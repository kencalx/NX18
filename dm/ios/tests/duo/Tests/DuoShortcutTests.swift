import GameController
import UIKit
import XCTest
@testable import DuoHarness

// The home screen shortcuts (LauncherShortcuts.swift): the start each gives against the program record, DM_LAUNCHER and the player's skip; a cold start's shortcut handed over before the
// launcher decides, then the real settings screen (dmShowLauncher, over the harness's root view controller) opened with the guide, a shortcut while it is up (Launcher closes the guide,
// Guide opens it, Game plays), one while the game runs (Game carries on, Launcher and Guide open the in-game menu), and the menu opening for it. With cloud saves on, the starts that
// skip the screen (Skip this screen next time, the Game shortcut) show it for the cloud-save check, the game starting by itself when there is nothing to ask
private nonisolated(unsafe) var duoPlays = 0   // dmShowLauncher's done: the game would start

final class DuoShortcutTests: XCTestCase {
    func testTypesAndTheStartOrder() {
        XCTAssertEqual(LauncherShortcut(type: "dm.shortcut.guide"), .guide)
        XCTAssertNil(LauncherShortcut(type: "dm.shortcut.other"))
        XCTAssertNil(LauncherShortcut(type: "com.example.game"))
        XCTAssertEqual(LauncherShortcut.allCases.map(\.type), ["dm.shortcut.game", "dm.shortcut.launcher", "dm.shortcut.guide"])
        let none: [String: String] = [:]
        // A shortcut wins over the player's skip, each this time only
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .game, environment: none, skipChosen: false, cloudSaves: false).start, .skip("shortcut Game: the game starts at once with the saved choices (this time only)"))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .launcher, environment: none, skipChosen: true, cloudSaves: false).start, .show(guide: false))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .guide, environment: none, skipChosen: true, cloudSaves: false).start, .show(guide: true))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: nil, environment: none, skipChosen: true, cloudSaves: false).start, .playerSkip, "Without one, the player's skip")
        XCTAssertEqual(LauncherShortcuts.start(shortcut: nil, environment: none, skipChosen: false, cloudSaves: false).start, .show(guide: false))
        // DM_LAUNCHER from an env file or the launch wins over a shortcut, and says so when it overrules it
        let envOff = ["DM_LAUNCHER": "0", "DM_ENV_FILE_KEYS": "DM_LAUNCHER", "DM_ENV_LAUNCH_KEYS": ""]
        let off = LauncherShortcuts.start(shortcut: .launcher, environment: envOff, skipChosen: false, cloudSaves: false)
        XCTAssertEqual(off.start, .skip("off (DM_LAUNCHER=0)"))
        XCTAssertEqual(off.notes, ["launcher: shortcut Launcher ignored: DM_LAUNCHER=0 from an env file or the launch decides"])
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .game, environment: envOff, skipChosen: false, cloudSaves: false).notes, [], "Game agrees with DM_LAUNCHER=0: nothing to say")
        let envOn = ["DM_LAUNCHER": "1", "DM_ENV_FILE_KEYS": "", "DM_ENV_LAUNCH_KEYS": "DM_LAUNCHER"]
        let on = LauncherShortcuts.start(shortcut: .game, environment: envOn, skipChosen: true, cloudSaves: false)
        XCTAssertEqual(on.start, .show(guide: false))
        XCTAssertEqual(on.notes, ["launcher: shortcut Game ignored: DM_LAUNCHER=1 from an env file or the launch decides"])
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .guide, environment: envOn, skipChosen: false, cloudSaves: false).start, .show(guide: true), "The screen DM_LAUNCHER shows still opens the guide")
        // main.m's program record (DM_LAUNCHER=0 that neither list names) wins over everything
        let record = ["DM_LAUNCHER": "0", "DM_ENV_FILE_KEYS": "", "DM_ENV_LAUNCH_KEYS": ""]
        for s in LauncherShortcut.allCases {
            let r = LauncherShortcuts.start(shortcut: s, environment: record, skipChosen: false, cloudSaves: false)
            XCTAssertEqual(r.start, .skip("off (DM_LAUNCHER=0)"))
            XCTAssertEqual(r.notes.count, 1)
            XCTAssertTrue(r.notes.first?.contains("program record") ?? false, "\(s): \(r.notes)")
        }
    }

    @MainActor
    private func waitUntil(_ what: String, _ timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(cond(), what)
    }

    @MainActor
    func testColdAndWarmShortcutsOnTheSettingsScreenAndInTheRunningGame() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-shortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { c in c.beginPage(); UIColor.gray.setFill(); c.fill(CGRect(x: 20, y: 20, width: 80, height: 80)) }
        try pdf.write(to: dir.appendingPathComponent("manual.pdf"))   // a placeholder manual: the Guide shortcut opens it, as the app has no game guide
        let skip = UserDefaults.standard.object(forKey: LauncherModel.skipKey)
        UserDefaults.standard.set(true, forKey: LauncherModel.skipKey)   // the player's skip is on: the shortcut wins over it, and leaves it on
        setenv("DM_APP_DM", dir.path, 1); unsetenv("DM_LAUNCHER")
        let opener = LauncherShortcuts.openMenu
        var menus = 0
        LauncherShortcuts.openMenu = { menus += 1 }
        defer {
            LauncherShortcuts.openMenu = opener
            unsetenv("DM_APP_DM")
            if let skip { UserDefaults.standard.set(skip, forKey: LauncherModel.skipKey) } else { UserDefaults.standard.removeObject(forKey: LauncherModel.skipKey) }
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = nil
            try? FileManager.default.removeItem(at: dir)
        }

        // Cold: the scene connects with the Guide shortcut before the launcher decides; the screen shows, with the manual open
        LauncherShortcuts.started = false
        dmShortcutCold("dm.shortcut.guide")
        XCTAssertEqual(LauncherShortcuts.pending, .guide, "Kept for the launcher")
        duoPlays = 0
        XCTAssertTrue(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoPlays += 1 }), "The screen shows although Skip this screen next time is on")
        XCTAssertNil(LauncherShortcuts.pending, "Taken")
        let host = try XCTUnwrap(root.presentedViewController, "The settings screen")
        XCTAssertTrue(LauncherShortcuts.screenUp)
        waitUntil("The Guide shortcut opened the manual over the settings screen") { host.presentedViewController != nil }
        XCTAssertTrue(UserDefaults.standard.bool(forKey: LauncherModel.skipKey), "Skip this screen next time is still on")

        // Warm, the screen up: Launcher closes the guide and stays, Guide opens it again, Game plays from there
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.launcher"))
        waitUntil("Launcher closed the guide") { host.presentedViewController == nil }
        XCTAssertTrue(root.presentedViewController === host, "and the settings screen stays")
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.guide"))
        waitUntil("Guide opened it") { host.presentedViewController != nil }
        XCTAssertEqual(duoPlays, 0)
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.game"))
        waitUntil("Game played: the screen and the guide over it are gone") { root.presentedViewController == nil }
        waitUntil("and the game started") { duoPlays == 1 }
        XCTAssertFalse(LauncherShortcuts.screenUp)

        // The game runs: Game carries on, Launcher and Guide open the in-game menu
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.game"))
        XCTAssertEqual(menus, 0)
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.launcher"))
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.guide"))
        XCTAssertEqual(menus, 2)
        XCTAssertNil(root.presentedViewController, "No settings screen over the running game")
        XCTAssertEqual(duoPlays, 1, "Nothing starts the game twice")
        XCTAssertFalse(dmShortcutPerform("com.example.other"), "Not one of the app's")

        // Before the launcher has decided (the player's skip waiting for a held controller button), a shortcut is kept for it
        LauncherShortcuts.started = false
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.launcher"))
        XCTAssertEqual(LauncherShortcuts.take(), .launcher)
    }

    // What LauncherShortcuts.openMenu does in the app: the menu button shows and its menu opens over the game, as a tap would (DmGamepad.m menuOpenNow)
    @MainActor
    func testInGameMenuOpensForAShortcut() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let pad = try XCTUnwrap(root.value(forKey: "pad") as? UIView, "The game's touch controls")
        let button = try XCTUnwrap(pad.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Menu" })
        waitUntil("Nothing over the game (a settings screen another test showed is gone)") { root.presentedViewController == nil }
        button.alpha = 0; button.isHidden = true   // faded out, as 5 s after the last touch
        XCTAssertEqual(pad.value(forKey: "menuOpen") as? Bool, false)
        _ = pad.perform(NSSelectorFromString("menuOpenNow"))   // what dm_gamepad_menu_open asks of the app's one pad (here other tests make pads of their own, and the last one made is the one it asks)
        waitUntil("The in-game menu opened") { pad.value(forKey: "menuOpen") as? Bool == true }
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(button.alpha, 1)
        button.contextMenuInteraction?.dismissMenu()   // closed again for the tests after this one; a dismissal from code need not reach the button's willEnd, so the pad hears it here
        _ = pad.perform(NSSelectorFromString("menuClosed"))
        XCTAssertEqual(pad.value(forKey: "menuOpen") as? Bool, false)
    }

    // One press on a hidden virtual controller, which the settings screen polls (LauncherGamepad): a Switch button (the pad is not a Nintendo one, so A is its right button) or a D-pad direction
    @MainActor
    private func press(_ pad: GCVirtualController, button: String? = nil, dpad: CGPoint = .zero) {
        if let button { pad.setValue(1, forButtonElement: button) } else { pad.setPosition(dpad, forDirectionPadElement: GCInputDirectionPad) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        if let button { pad.setValue(0, forButtonElement: button) } else { pad.setPosition(.zero, forDirectionPadElement: GCInputDirectionPad) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    // Guide while About this game or the folder picker is up: what is up closes, and the guide (here the manual) opens once it has gone, not lost to a presentation still under way
    @MainActor
    func testGuideShortcutOverAboutAndTheFolderPicker() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-shortcut-over-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        try Data(#"{"name": "Placeholder", "description": "Placeholder text for the test."}"#.utf8).write(to: dir.appendingPathComponent("about.json"))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { c in c.beginPage(); UIColor.gray.setFill(); c.fill(CGRect(x: 20, y: 20, width: 80, height: 80)) }
        try pdf.write(to: dir.appendingPathComponent("manual.pdf"))
        let skip = UserDefaults.standard.object(forKey: LauncherModel.skipKey)
        UserDefaults.standard.removeObject(forKey: LauncherModel.skipKey)
        setenv("DM_APP_DM", dir.path, 1); unsetenv("DM_LAUNCHER")
        defer {
            unsetenv("DM_APP_DM")
            if let skip { UserDefaults.standard.set(skip, forKey: LauncherModel.skipKey) }
            root.presentedViewController?.presentedViewController?.dismiss(animated: false)
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = nil
            try? FileManager.default.removeItem(at: dir)
        }
        waitUntil("Nothing over the game (a settings screen another test showed is gone)") { root.presentedViewController == nil }
        let config = GCVirtualController.Configuration()
        config.isHidden = true
        config.elements = [GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputDirectionPad, GCInputLeftThumbstick]
        let pad = GCVirtualController(configuration: config)
        var connected: Bool?
        pad.connect { connected = $0 == nil }
        defer { pad.disconnect() }
        waitUntil("The virtual controller answered", 10) { connected != nil }
        guard connected == true else { throw XCTSkip("Simulator has no virtual controller") }
        waitUntil("GameController lists it") { GCController.controllers().contains { $0.extendedGamepad != nil } }
        LauncherShortcuts.started = false
        XCTAssertTrue(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), {}))
        let host = try XCTUnwrap(root.presentedViewController, "The settings screen")
        func guideUp() -> Bool { host.presentedViewController.map { [.fullScreen, .overFullScreen].contains($0.modalPresentationStyle) && !$0.isBeingDismissed } ?? false }   // the guide's cover, not a sheet
        RunLoop.main.run(until: Date().addingTimeInterval(1))   // the screen's controller poll starts and lets go of what was held as it appeared

        // About this game up, then Guide
        // Play, Game guide, About this game on the first line (no presets): right, right, A
        press(pad, dpad: CGPoint(x: 1, y: 0)); press(pad, dpad: CGPoint(x: 1, y: 0)); press(pad, button: GCInputButtonB)
        waitUntil("About this game opened") { host.presentedViewController != nil && !guideUp() }
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.guide"))
        waitUntil("Guide closed About and opened the manual") { guideUp() }
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.launcher"))
        waitUntil("Launcher closed it") { host.presentedViewController == nil }

        // The folder picker up, then Guide
        // Reset, Cloud saves, Skip are the last three lines: down to the end, up one, A
        for _ in 0..<8 { press(pad, dpad: CGPoint(x: 0, y: -1)) }
        press(pad, dpad: CGPoint(x: 0, y: 1)); press(pad, button: GCInputButtonB)
        waitUntil("The folder picker opened", 10) { host.presentedViewController != nil && !guideUp() }
        XCTAssertTrue(dmShortcutPerform("dm.shortcut.guide"))
        waitUntil("Guide closed the picker and opened the manual", 10) { guideUp() }
    }

    @MainActor
    func testGameShortcutStartsWithoutTheScreen() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-shortcut-game-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        let skip = UserDefaults.standard.object(forKey: LauncherModel.skipKey)
        UserDefaults.standard.removeObject(forKey: LauncherModel.skipKey)   // the screen would show
        setenv("DM_APP_DM", dir.path, 1); unsetenv("DM_LAUNCHER"); unsetenv("DM_SAVE_SYNC")   // cloud saves off (no folder picked in the harness): no check, no screen
        defer {
            unsetenv("DM_APP_DM")
            if let skip { UserDefaults.standard.set(skip, forKey: LauncherModel.skipKey) }
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = nil
            try? FileManager.default.removeItem(at: dir)
        }
        LauncherShortcuts.started = false
        dmShortcutCold("dm.shortcut.game")
        duoPlays = 0
        XCTAssertFalse(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoPlays += 1 }), "No screen: front_ios.m starts the game at once")
        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(LauncherShortcuts.started)
        XCTAssertNil(UserDefaults.standard.object(forKey: LauncherModel.skipKey), "Skip this screen next time is not turned on")
        // The next start without a shortcut shows the screen again
        LauncherShortcuts.started = false
        XCTAssertTrue(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoPlays += 1 }))
        XCTAssertNotNil(root.presentedViewController)
    }

    // The cloud-save check of a start that skips the screen (LauncherShortcuts.start, afterWait, cloudSavesOn): the pure decisions
    func testCloudSaveCheckDecisions() {
        let none: [String: String] = [:]
        // Cloud saves on: the Game shortcut shows the screen for the check; Launcher, Guide and no shortcut start as without them (the player's skip waits for afterWait)
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .game, environment: none, skipChosen: false, cloudSaves: true).start, .check("shortcut Game, this time only"))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .game, environment: none, skipChosen: true, cloudSaves: true).start, .check("shortcut Game, this time only"))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .launcher, environment: none, skipChosen: true, cloudSaves: true).start, .show(guide: false))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: .guide, environment: none, skipChosen: false, cloudSaves: true).start, .show(guide: true))
        XCTAssertEqual(LauncherShortcuts.start(shortcut: nil, environment: none, skipChosen: true, cloudSaves: true).start, .playerSkip)
        XCTAssertEqual(LauncherShortcuts.start(shortcut: nil, environment: none, skipChosen: false, cloudSaves: true).start, .show(guide: false))
        // DM_LAUNCHER=0 from an env file or the launch: still no screen, and one line says the cloud save was not checked; none with cloud saves off
        let envOff = ["DM_LAUNCHER": "0", "DM_ENV_FILE_KEYS": "DM_LAUNCHER", "DM_ENV_LAUNCH_KEYS": ""]
        for s in [nil] + LauncherShortcut.allCases.map(Optional.some) {
            let r = LauncherShortcuts.start(shortcut: s, environment: envOff, skipChosen: true, cloudSaves: true)
            XCTAssertEqual(r.start, .skip("off (DM_LAUNCHER=0)"))
            XCTAssertEqual(r.notes.filter { $0 == LauncherShortcuts.notChecked }.count, 1, "\(String(describing: s)): \(r.notes)")
            XCTAssertFalse(LauncherShortcuts.start(shortcut: s, environment: envOff, skipChosen: true, cloudSaves: false).notes.contains(LauncherShortcuts.notChecked))
        }
        XCTAssertTrue(LauncherShortcuts.notChecked.contains("cloud save was not checked"))
        // DM_LAUNCHER=1 shows the screen: Play checks there, nothing to say
        let envOn = ["DM_LAUNCHER": "1", "DM_ENV_FILE_KEYS": "", "DM_ENV_LAUNCH_KEYS": "DM_LAUNCHER"]
        XCTAssertFalse(LauncherShortcuts.start(shortcut: nil, environment: envOn, skipChosen: true, cloudSaves: true).notes.contains(LauncherShortcuts.notChecked))
        // main.m's program record: unchanged, no check and no line about it
        let record = ["DM_LAUNCHER": "0", "DM_ENV_FILE_KEYS": "", "DM_ENV_LAUNCH_KEYS": ""]
        for s in [nil] + LauncherShortcut.allCases.map(Optional.some) {
            let r = LauncherShortcuts.start(shortcut: s, environment: record, skipChosen: true, cloudSaves: true)
            XCTAssertEqual(r.start, .skip("off (DM_LAUNCHER=0)"))
            XCTAssertFalse(r.notes.contains(LauncherShortcuts.notChecked))
        }
        // After the player's skip has watched for a held controller button: a held button, a late Launcher or Guide show the screen as before, cloud saves or not
        for cloud in [false, true] {
            XCTAssertEqual(LauncherShortcuts.afterWait(held: true, late: nil, cloudSaves: cloud).start, .show(guide: false))
            XCTAssertEqual(LauncherShortcuts.afterWait(held: true, late: nil, cloudSaves: cloud).note, "launcher: shown although skipped (a controller button held at start)")
            XCTAssertEqual(LauncherShortcuts.afterWait(held: false, late: .launcher, cloudSaves: cloud).start, .show(guide: false))
            XCTAssertEqual(LauncherShortcuts.afterWait(held: false, late: .guide, cloudSaves: cloud).start, .show(guide: true))
            XCTAssertEqual(LauncherShortcuts.afterWait(held: true, late: .guide, cloudSaves: cloud).start, .show(guide: true))
        }
        // else the check with cloud saves on (a late Game too), and no screen without them
        XCTAssertEqual(LauncherShortcuts.afterWait(held: false, late: nil, cloudSaves: true).start, .check("Skip this screen next time is on"))
        XCTAssertNil(LauncherShortcuts.afterWait(held: false, late: nil, cloudSaves: true).note)
        XCTAssertEqual(LauncherShortcuts.afterWait(held: false, late: .game, cloudSaves: true).start, .check("Skip this screen next time is on; shortcut Game"))
        guard case .skip = LauncherShortcuts.afterWait(held: false, late: nil, cloudSaves: false).start else { return XCTFail("no screen without cloud saves") }
        guard case .skip = LauncherShortcuts.afterWait(held: false, late: .game, cloudSaves: false).start else { return XCTFail("a late Game without cloud saves: no screen") }
        // Cloud saves on: DM_SAVE_SYNC names a folder (the picked one, or an env file's); unset, empty, 0 and the Mac's icloud are off
        XCTAssertTrue(LauncherShortcuts.cloudSavesOn(saveSync: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Saves"))
        for off in [nil, "", "0", "icloud"] { XCTAssertFalse(LauncherShortcuts.cloudSavesOn(saveSync: off), "\(String(describing: off))") }
    }

    // The settings screen as a skipped start shows it for the cloud-save check, against the host's real comparison (save_sync.c) on a save and a cloud folder made here: with
    // nothing to ask the game starts by itself (DM_SAVE_SYNC_CHOICE=ask, no input); with both saves changed the question shows and the game waits for it; with cloud saves off
    // the player's skip shows no screen. Skip this screen next time and a cold Game shortcut
    @MainActor
    func testSkippedStartsRunTheCloudSaveCheck() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-cloud-check-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        func save(_ name: String, _ text: String) throws -> URL {   // a committed save folder with one file, as DM_SAVE names it
            let s = dir.appendingPathComponent(name)
            try fm.createDirectory(at: s, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: s.appendingPathComponent("progress.bin"))
            return s
        }
        let cloud = dir.appendingPathComponent("cloud")
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let mine = try save("save", "this device's progress")
        let keep = ["DM_SAVE", "DM_SAVE_SYNC", "DM_SAVE_SYNC_CHOICE"].map { (k: String) in (k, getenv(k).map { String(cString: $0) }) }
        let skip = UserDefaults.standard.object(forKey: LauncherModel.skipKey)
        let bookmark = UserDefaults.standard.object(forKey: "cloudSavesBookmark")   // CloudSaves.m: a folder picked in the harness would turn cloud saves on below
        UserDefaults.standard.removeObject(forKey: "cloudSavesBookmark")
        setenv("DM_APP_DM", dir.path, 1); unsetenv("DM_LAUNCHER"); setenv("DM_SAVE", mine.path, 1)
        defer {
            unsetenv("DM_APP_DM")
            for (k, v) in keep { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
            if let skip { UserDefaults.standard.set(skip, forKey: LauncherModel.skipKey) } else { UserDefaults.standard.removeObject(forKey: LauncherModel.skipKey) }
            if let bookmark { UserDefaults.standard.set(bookmark, forKey: "cloudSavesBookmark") }
            root.presentedViewController?.presentedViewController?.dismiss(animated: false)
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = nil
            try? fm.removeItem(at: dir)
        }
        waitUntil("Nothing over the game (a settings screen another test showed is gone)") { root.presentedViewController == nil }
        func choice() -> String? { getenv("DM_SAVE_SYNC_CHOICE").map { String(cString: $0) } }
        // One start: dmShowLauncher, then the run loop watched closely until the game starts (done) or the time is up; whether the screen was seen, and what it asked
        func run(shortcut: LauncherShortcut?, expectStart: Bool, _ timeout: TimeInterval = 10) -> (shown: Bool, returned: Bool) {
            unsetenv("DM_SAVE_SYNC_CHOICE")
            LauncherShortcuts.started = false
            if let s = shortcut { dmShortcutCold(s.type) }
            duoPlays = 0
            var shown = false
            let returned = dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoPlays += 1 })
            let end = Date().addingTimeInterval(timeout)
            while Date() < end && !(expectStart && duoPlays > 0) {
                if root.presentedViewController != nil { shown = true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            return (shown, returned)
        }

        // Skip this screen next time, cloud saves off: no screen, the game starts after the short wait for a held button, nothing checked
        UserDefaults.standard.set(true, forKey: LauncherModel.skipKey)
        unsetenv("DM_SAVE_SYNC")
        var r = run(shortcut: nil, expectStart: true)
        XCTAssertTrue(r.returned, "The skip waits a moment for a held controller button")
        XCTAssertEqual(duoPlays, 1, "The game started")
        XCTAssertFalse(r.shown, "No screen with cloud saves off")
        XCTAssertNil(choice(), "Nothing compared")

        // Skip this screen next time, cloud saves on (a folder in DM_SAVE_SYNC, as an env file's), nothing in the cloud yet: the screen shows for the check, and the game starts by itself
        setenv("DM_SAVE_SYNC", cloud.path, 1)
        r = run(shortcut: nil, expectStart: true)
        XCTAssertTrue(r.returned)
        XCTAssertTrue(r.shown, "The settings screen showed for the check")
        XCTAssertEqual(duoPlays, 1, "The game started with no input")
        XCTAssertEqual(choice(), "ask", "The check ran: nothing to choose")
        waitUntil("The screen is gone") { root.presentedViewController == nil }
        XCTAssertTrue(UserDefaults.standard.bool(forKey: LauncherModel.skipKey), "Skip this screen next time stays on")

        // The Game shortcut at a cold start, cloud saves on, the player's skip off: the same
        UserDefaults.standard.removeObject(forKey: LauncherModel.skipKey)
        r = run(shortcut: .game, expectStart: true)
        XCTAssertTrue(r.returned, "The screen shows: front_ios.m waits for done")
        XCTAssertTrue(r.shown)
        XCTAssertEqual(duoPlays, 1)
        XCTAssertEqual(choice(), "ask")
        waitUntil("The screen is gone") { root.presentedViewController == nil }
        XCTAssertNil(UserDefaults.standard.object(forKey: LauncherModel.skipKey), "Skip this screen next time is not turned on")

        // Both changed: another device's save in the cloud (packed by the host's own sender) and a save here that was never synced. The Game shortcut's check asks, and the game waits
        let theirs = try save("their-save", "another device's progress")
        XCTAssertEqual(save_sync_after_exit(theirs.path, dm_save_title()), 1, "The other device's save is in the cloud folder")
        r = run(shortcut: .game, expectStart: false, 3)
        XCTAssertTrue(r.returned)
        XCTAssertEqual(duoPlays, 0, "The game waits for the player's answer")
        XCTAssertNil(choice())
        let host = try XCTUnwrap(root.presentedViewController, "The settings screen stays")
        waitUntil("Which save do you want to play? shows") { (host.presentedViewController as? UIAlertController)?.title == SaveSyncReport.chooseTitle }
    }
}
