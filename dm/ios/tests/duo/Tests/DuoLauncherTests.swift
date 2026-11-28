import UIKit
import XCTest
@testable import DuoHarness

// The settings screen's pieces that need no screen (Launcher.swift, LauncherController.swift, LauncherArt.swift) and the in-game menu's Exit and return to Gate
// (GameMenu.swift): the controller's focus moves, the guide found in an app's offline pages in the game language, about.json read leniently, and the skip choice
final class DuoLauncherTests: XCTestCase {
    func testFocusMapMovesByLineAndColumn() {
        let map = LauncherFocusMap(lines: [[.preset(.battery), .preset(.balanced), .preset(.quality)], [.play, .guide, .about], [.row("A")], [.reset]])
        XCTAssertEqual(map.vertical(nil, 1), .preset(.battery), "From nothing: the first item")
        XCTAssertEqual(map.vertical(.preset(.quality), 1), .about, "The column is kept where the next line has it")
        XCTAssertEqual(map.vertical(.about, 1), .row("A"), "A line of one: its item")
        XCTAssertEqual(map.vertical(.reset, 1), .reset, "No wrap at the end")
        XCTAssertEqual(map.vertical(.preset(.battery), -1), .preset(.battery), "No wrap at the top")
        XCTAssertEqual(map.horizontal(.play, 1), .guide)
        XCTAssertNil(map.horizontal(.about, 1), "Past the end of a line")
        XCTAssertNil(map.horizontal(.row("A"), 1), "A row alone on its line: left / right change its value instead")
        XCTAssertEqual(map.vertical(.row("gone"), 1), .preset(.battery), "An item no longer drawn: back to the first")
    }

    func testGuideIsFoundInTheGameLanguageAndLegalPagesAreSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duo-guide-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func page(_ rel: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: u)
        }
        try page("html0/html-document/ipnotices.htdocs/html/index.html")   // legal notices only: not a guide
        try page("html1/html-document/htmlcontents.htdocs/html/USen/index.html")
        try page("html1/html-document/htmlcontents.htdocs/html/EUfr/index.html")
        try page("html1/html-document/htmlcontents.htdocs/html/JPja/index.html")
        let fr = try XCTUnwrap(LauncherContent.findGuide(in: root, lang: "fr"))
        XCTAssertEqual(fr.index.deletingLastPathComponent().lastPathComponent, "EUfr")
        XCTAssertEqual(fr.root.lastPathComponent, "htmlcontents.htdocs", "Read access to the guide's htdocs")
        XCTAssertEqual(LauncherContent.findGuide(in: root, lang: "en-GB")?.index.deletingLastPathComponent().lastPathComponent, "USen", "No EUen: USen")
        XCTAssertEqual(LauncherContent.findGuide(in: root, lang: "ja")?.index.deletingLastPathComponent().lastPathComponent, "JPja")
        XCTAssertEqual(LauncherContent.guideLanguages("es-419"), ["USes", "USen", "EUen"])
        XCTAssertEqual(LauncherContent.guideLanguages(nil), ["USen", "EUen"])
        XCTAssertNil(LauncherContent.findGuide(in: root.appendingPathComponent("html0"), lang: "en-US"), "Legal notices alone are no guide")
    }

    // A slim build (DM_COPY_ROMFS=NO): the game files are Documents/romfs.img, with no html beside them, and build_ipa.sh packed the guide into the app's html. The guide is the app's;
    // html beside the game files, when there is one, still comes first, and DM_HTML before both
    func testGuideOfASlimBuildIsTheAppsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duo-slim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("DmIOS.app"), docs = root.appendingPathComponent("Documents")
        func page(_ rel: String) throws {
            let u = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: u)
        }
        try page("DmIOS.app/html/html1/html-document/htmlcontents.htdocs/html/USen/index.html")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let bundle = try XCTUnwrap(Bundle(path: app.path))
        let slim = ["DM_ROMFS": docs.appendingPathComponent("romfs.img").path]
        XCTAssertEqual(LauncherContent.guideFolder(environment: slim, bundle: bundle)?.standardizedFileURL, app.appendingPathComponent("html").standardizedFileURL, "No html beside the game files: the app's")
        let found = LauncherContent.find(dir: root.appendingPathComponent("dm"), lang: "en-US", environment: slim, bundle: bundle)
        XCTAssertTrue(found.hasGuide, "The Guide shortcut and the Game guide button have the guide build_ipa.sh advertised")
        XCTAssertEqual(found.guide?.deletingLastPathComponent().lastPathComponent, "USen")
        try page("Documents/html/html-document/guide.htdocs/index.html")
        XCTAssertEqual(LauncherContent.guideFolder(environment: slim, bundle: bundle)?.standardizedFileURL, docs.appendingPathComponent("html").standardizedFileURL, "html beside the game files first")
        XCTAssertEqual(LauncherContent.guideFolder(environment: slim.merging(["DM_HTML": "/elsewhere"]) { $1 }, bundle: bundle)?.path, "/elsewhere", "DM_HTML before both")
    }

    @MainActor
    func testGuideFilesAreServedFromTheGuideOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duo-guidefiles-\(UUID().uuidString)/htmlcontents.htdocs")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let index = root.appendingPathComponent("html/USen/index.html")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: index)
        let files = LauncherGuideFiles(root: root)
        let u = try XCTUnwrap(files.url(for: index))
        XCTAssertEqual(u.absoluteString, "nx18guide://guide/html/USen/index.html")
        XCTAssertEqual(files.file(for: u)?.standardizedFileURL.resolvingSymlinksInPath().path, index.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertNil(files.url(for: root.deletingLastPathComponent().appendingPathComponent("other.html")), "A file beside the guide has no URL")
        XCTAssertNil(files.file(for: try XCTUnwrap(URL(string: "nx18guide://guide/html/../../../secret.txt"))), "No climbing out of the guide")
        XCTAssertEqual(LauncherGuideFiles.mime("CSS"), "text/css")
        XCTAssertTrue(LauncherGuideFiles.policy.hasPrefix("default-src nx18guide:"), "Every response keeps the page to its own scheme")
    }

    func testAboutIsReadLeniently() throws {
        let json = #"{"name": " Game ", "intro": "", "description": "Text", "publisher": 3, "releaseDate": "2020-02-29", "source": "titledb", "extra": [1]}"#
        let a = try JSONDecoder().decode(LauncherAbout.self, from: Data(json.utf8))
        XCTAssertEqual(a.name, "Game")
        XCTAssertNil(a.intro, "Empty is none")
        XCTAssertNil(a.publisher, "A number where text belongs is none, not a failure")
        XCTAssertNotNil(a.released)
        XCTAssertEqual(a.sourceLine, "From the game's eShop page", "The title database is not named on screen")
        XCTAssertTrue(a.hasText)
        XCTAssertFalse(LauncherAbout(name: "Only a name").hasText, "A name alone gives no About button")
    }

    func testAcknowledgementsAreBundledAndSplitIntoEntries() throws {   // the settings screen's Acknowledgements (GuideViewer.swift LauncherNoticesSheet)
        let url = try XCTUnwrap(LauncherNotices.url, "The notices are in the app")
        XCTAssertTrue(LauncherNotices.available)
        let blocks = LauncherNotices.blocks(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(blocks.first?.kind, .title)
        let headings = blocks.filter { $0.kind == .heading }.map(\.text)
        XCTAssertGreaterThanOrEqual(headings.count, 15)
        XCTAssertEqual(headings.first, "1. nxnative")
        XCTAssertTrue(headings.contains { $0.hasSuffix("Switch Button Icons and Controls") })
        XCTAssertTrue(blocks.contains { $0.kind == .license && $0.text.contains("Copyright (c) 2026 jhaizhou") }, "The license texts are drawn as license text")
        XCTAssertTrue(blocks.contains { $0.kind == .prose && $0.text.hasPrefix("Decodes the games' AV1 movies") }, "What NX 18 uses it for is prose")
        XCTAssertFalse(blocks.contains { $0.text.hasPrefix("====") || $0.text.hasSuffix("----") }, "The rule lines are not drawn")
        XCTAssertEqual(Set(blocks.map(\.id)).count, blocks.count)
    }

    @MainActor
    func testInGameMenuExitAsksFirst() throws {
        let s = try JSONDecoder().decode(SettingsFile.self, from: Data(#"{"settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "label": "Vitals", "note": "", "default": "0"}]}"#.utf8))
        let m = LauncherModel(s.settings, defaults: try XCTUnwrap(UserDefaults(suiteName: "DuoLauncherTests")))
        let row = settingsAtStartRow(m)
        XCTAssertEqual(row.id, GameMenuExit.rowID)
        XCTAssertEqual(row.title, "Exit and return to Gate", "The row's name (the owner, 2026-11-27; it was Gate at start)")
        XCTAssertEqual(row.subtitle, "Ends the game; unsaved progress is lost")
        guard case .submenu(let page) = row.kind else { return XCTFail("The row opens its confirmation, it does not exit") }
        let items = page.flatMap(\.items)
        XCTAssertEqual(items.map(\.title), ["Exit to Gate", "Keep Playing"])
        XCTAssertEqual(items.map(\.id), [GameMenuExit.yesID, GameMenuExit.noID])
        XCTAssertTrue(items[0].closesMenu, "Exit to Gate closes the panel first")
        XCTAssertNil(items[1].perform, "Keep Playing does nothing but go back")
        let menu = try XCTUnwrap(uiMenuElement(row) as? UIMenu)   // as the UIMenu shows it (DM_GAME_MENU=system): a submenu of the two
        XCTAssertEqual(menu.children.map(\.title), ["Exit to Gate", "Keep Playing"])
    }

    // The cloud-save report's pull=<0|1> (save_sync.h): with a download of the cloud's save left unfinished nothing is asked, even beside conflict=1, and a line
    // without the key (a host before the journal) reads as 0
    func testSaveSyncReportPendingPullAsksNothing() throws {
        let base = "sync=1 cloud=1 local=aa saved=10 files=1 size=3 chash=bb csaved=20 cfiles=1 csize=16 cdevice=Mac16,5 sametitle=1"
        let old = try XCTUnwrap(SaveSyncReport(line: base + " conflict=1"))
        XCTAssertFalse(old.pullPending)
        XCTAssertEqual(SaveSyncReport.step(old), .choose)
        let none = try XCTUnwrap(SaveSyncReport(line: base + " conflict=1 pull=0"))
        XCTAssertFalse(none.pullPending)
        XCTAssertEqual(SaveSyncReport.step(none), .choose)
        let pending = try XCTUnwrap(SaveSyncReport(line: base + " conflict=0 pull=1"))
        XCTAssertTrue(pending.pullPending)
        XCTAssertEqual(SaveSyncReport.step(pending), .play("ask"), "the start's mount puts this device's save back, then compares")
        XCTAssertEqual(SaveSyncReport.step(try XCTUnwrap(SaveSyncReport(line: base + " conflict=1 pull=1"))), .play("ask"), "no question while a pull is pending")
        XCTAssertEqual(SaveSyncReport.step(try XCTUnwrap(SaveSyncReport(line: "sync=1 cloud=-1 local=aa conflict=0 pull=1"))), .unreadable, "a cloud not read is still said")
    }

    // The Gate panel (LauncherPanel.swift): the strip's notes stay one line of at most 60 characters, and Customize repeats no row of the main page or the Touch page
    @MainActor
    func testGatePanelBriefsAndPages() throws {
        XCTAssertEqual(GateText.brief("Short note. Second sentence that is long."), "Short note.")
        let long = String(repeating: "word ", count: 30)
        XCTAssertLessThanOrEqual(GateText.brief(long).count, 60)
        XCTAssertTrue(GateText.brief(long).hasSuffix("…"))
        let json = #"{"settings": [{"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "options": [["1", "Docked"], ["0", "Handheld"]]},"#
            + #"{"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"]], "preset": {"battery": "30"}},"#
            + #"{"env": "DM_TOUCH_SIZE", "kind": "choice", "section": "Controls", "label": "Touch control size", "note": "", "default": "1", "options": [["0.7", "Small"], ["1", "Large"]]},"#
            + #"{"env": "DM_PSO_PREBUILD", "kind": "toggle", "section": "Performance", "label": "Pipeline prebuild", "note": "", "default": "1"}]}"#
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(json.utf8))
        let m = LauncherModel(file.settings, defaults: UserDefaults(suiteName: "duo-gate-\(UUID().uuidString)")!)
        XCTAssertEqual(m.gateFirstTiles, ["DM_OPMODE"])
        XCTAssertEqual(m.gateSecondTiles, ["touch"], "Touch controls is a door to its page")
        XCTAssertEqual(m.gateCustomizeGroups.map(\.title), ["Picture and performance"], "Troubleshooting only while one of its rows differs (presets-first P6)")
        m.values["DM_PSO_PREBUILD"] = "0"
        let groups = m.gateCustomizeGroups
        XCTAssertEqual(groups.map(\.title), ["Picture and performance", "Troubleshooting"])
        XCTAssertEqual(groups.flatMap(\.rows).map(\.env), ["DM_FPS_TARGET", "DM_PSO_PREBUILD"])
        XCTAssertEqual(LauncherPreset.battery.gateName, "Battery Saver")
    }

    // The presets on the Gate (presets-first §4, §7, W9, W12; gate-ui O4): the drawn chips from the list, Custom from the base with Back to it, a toast's Undo, the notes built
    // from the rows a preset moves, and the status line holding only the console and the preset state
    @MainActor
    func testGatePresetsCustomBackAndStatus() throws {
        let json = #"{"presets": ["battery", "balanced", "quality"], "moves": {"battery": ["DM_FPS_TARGET", "DM_RENDER_SCALE"], "quality": ["DM_PRESENT_UPSCALE"]}, "settings": ["#
            + #"{"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"]], "preset": {"battery": "30", "quality": "60", "performance": "60"}},"#
            + #"{"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05, "preset": {"battery": "0.75", "quality": "1.0", "performance": "1.0"}},"#
            + #"{"env": "DM_PRESENT_UPSCALE", "kind": "choice", "section": "Game", "label": "Upscaling", "note": "", "default": "off", "options": [["off", "Standard"], ["metalfx", "MetalFX"]], "inactive": [{"option": "metalfx", "when": ["mfx:none"], "why": "This device has no MetalFX scaler"}], "preset": {"battery": "off", "quality": "metalfx", "performance": "off"}},"#
            + #"{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0", "level": "basic"}]}"#
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(json.utf8))
        let m = LauncherModel(file.settings, defaults: UserDefaults(suiteName: "duo-presets-\(UUID().uuidString)")!)
        m.takeList(file)
        XCTAssertEqual(m.offeredPresets, [.battery, .balanced, .quality], "the list's drawn chips, Performance waiting for A9b")
        XCTAssertEqual(GateText.presetNote(m, .battery), "30 fps, lower resolution: less power and heat.")
        XCTAssertTrue(GateText.presetNote(m, .quality).hasPrefix("MetalFX upscaling"))
        m.applyPreset(.battery)
        m.values["DM_RENDER_SCALE"] = "0.90"
        XCTAssertEqual(m.presetLabel, "Custom (from Battery Saver)")
        m.backToBase()
        XCTAssertEqual(m.activePreset, .battery); XCTAssertEqual(m.values["DM_RENDER_SCALE"], "0.75")
        m.applyPreset(.quality)
        m.undo()
        XCTAssertEqual(m.activePreset, .battery, "Undo")
        var st = LauncherStatus(); st.console = .switch1; st.preset = m.presetLabel
        XCTAssertEqual(st.parts().map(\.text), ["Switch 1", "Battery Saver"], "the Gate's line: the console and the preset state only")
        XCTAssertEqual(m.gateRow("DM_SHOW_FPS")?.label, "Vitals")
        m.facts.metalFX = false
        m.applyPreset(.quality)
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "off", "a greyed option falls back"); XCTAssertEqual(m.activePreset, .quality, "the preset still lights")
    }

}
