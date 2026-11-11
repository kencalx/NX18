import UIKit
import XCTest
@testable import DuoHarness

// The settings screen's pieces that need no screen (Launcher.swift, LauncherController.swift, LauncherArt.swift) and the in-game menu's Settings screen at start
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
        XCTAssertEqual(a.sourceLine, "From titledb")
        XCTAssertTrue(a.hasText)
        XCTAssertFalse(LauncherAbout(name: "Only a name").hasText, "A name alone gives no About button")
    }

    @MainActor
    func testInGameMenuTurnsTheSkipOff() throws {
        let suite = "DuoLauncherTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = try JSONDecoder().decode(SettingsFile.self, from: Data(#"{"settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "label": "Frame-rate counter", "note": "", "default": "0"}]}"#.utf8))
        let m = LauncherModel(s.settings, defaults: defaults)
        m.skipAtStart = true
        XCTAssertTrue(defaults.bool(forKey: LauncherModel.skipKey))
        let row = try XCTUnwrap(settingsAtStartRow(m) as? UIAction)
        XCTAssertEqual(row.title, "Settings screen at start")
        XCTAssertEqual(row.state, .off, "Skipped: not ticked")
        XCTAssertTrue(LauncherModel.skipsAtStart(defaults: defaults, environment: [:]))
        m.skipAtStart = false   // what the row's action does
        XCTAssertEqual((settingsAtStartRow(m) as? UIAction)?.state, .on)
        XCTAssertNil(defaults.object(forKey: LauncherModel.skipKey), "Off is no key")
        XCTAssertFalse(LauncherModel.skipsAtStart(defaults: defaults, environment: [:]))
    }
}
