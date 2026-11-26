// F10 (NX18-X2.0 gate-ui.md §20-§21): the Profile's name rule (GW21), its storage and the stamp rules with the NX 18 folder (a temporary folder standing in for iCloud
// Drive: the owner's real one is never touched), what the games are given (DM_NICK, DM_PROFILE_IMAGE), the picture the host accepts (256 x 256 baseline JPEG), the card
// with its Profile rows, and the welcome's rule and its place before the Gate
import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import DuoHarness

@MainActor final class DuoProfileTests: XCTestCase {
    private func temp(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("duo-profile-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    private func name(at root: URL) -> String? { (try? String(contentsOf: root.appendingPathComponent("name.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testNameRule() {
        for good in ["Player 1", "Zoë", "あきら", "O'Neil", "a.b_c-d", "  Link  "] { XCTAssertEqual(NX18ProfileName.clean(good), good.trimmingCharacters(in: .whitespaces), good) }
        XCTAssertEqual(NX18ProfileName.clean("   "), "", "empty means Player")
        for bad in ["ElevenChars", "Link🎮", "a/b", "x<y>"] { XCTAssertNil(NX18ProfileName.clean(bad), bad) }
    }

    func testStampOrder() {
        XCTAssertLessThan(NX18Stamp(generation: 3, device: "b"), NX18Stamp(generation: 4, device: "a"), "the generation first")
        XCTAssertLessThan(NX18Stamp(generation: 4, device: "a"), NX18Stamp(generation: 4, device: "b"), "the device id breaks a tie")
        XCTAssertEqual(NX18Stamp("7 abc")?.generation, 7)
        XCTAssertNil(NX18Stamp("garbage"))
    }

    // Two devices through one folder: an edit goes there; the other device's look brings it in; a lower stamp never overwrites a higher one
    func testFolderStampRules() throws {
        let a = try temp("a"), b = try temp("b"), folder = try temp("folder")
        NX18Profile.writeLocal(at: a, name: "Kiki", picture: nil, appearance: "light")
        NX18ProfileSync.lastSeen = nil
        NX18ProfileSync.push(local: a, folder: folder)
        XCTAssertEqual(name(at: folder.appendingPathComponent("Profile")), "Kiki")
        NX18ProfileSync.lastSeen = nil
        XCTAssertTrue(NX18ProfileSync.pull(local: b, folder: folder), "a device with no Profile takes the folder's")
        XCTAssertEqual(name(at: b), "Kiki")
        XCTAssertEqual((try? String(contentsOf: b.appendingPathComponent("appearance.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "light")
        NX18ProfileSync.lastSeen = nil
        XCTAssertFalse(NX18ProfileSync.pull(local: b, folder: folder), "the same stamp: nothing to bring in")
        // b edits (its stamp goes higher) and writes the folder; a's older stamp neither pulls back over it nor pushes over it
        NX18Profile.writeLocal(at: b, name: "Tombo", picture: nil, appearance: nil)
        NX18ProfileSync.push(local: b, folder: folder)
        NX18ProfileSync.push(local: a, folder: folder)
        XCTAssertEqual(name(at: folder.appendingPathComponent("Profile")), "Tombo", "a lower stamp never overwrites a higher one")
        NX18ProfileSync.lastSeen = nil
        XCTAssertTrue(NX18ProfileSync.pull(local: a, folder: folder))
        XCTAssertEqual(name(at: a), "Tombo")
    }

    // Appearance with the Profile (§20.5b): with the switch on and a folder, a change writes appearance.txt and a higher stamp there; off, or with no folder, it stays per app
    func testAppearanceGoesWithTheProfile() throws {
        let root = try temp("look"), folder = try temp("look-folder"), d = try XCTUnwrap(UserDefaults(suiteName: "duo-look-\(UUID().uuidString)"))
        NX18Profile.writeLocal(at: root, name: "Kiki", picture: nil, appearance: nil)
        let before = try XCTUnwrap(NX18ProfileSync.readStamp(root.appendingPathComponent("profile.stamp")))
        XCTAssertFalse(NX18Profile.shareAppearance(.light, root: root, defaults: d, folder: nil, wait: true), "no folder: this app only")
        XCTAssertTrue(NX18Profile.shareAppearance(.light, root: root, defaults: d, folder: folder, wait: true))
        let dir = folder.appendingPathComponent("Profile")
        XCTAssertEqual((try? String(contentsOf: dir.appendingPathComponent("appearance.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "light")
        XCTAssertGreaterThan(try XCTUnwrap(NX18ProfileSync.readStamp(dir.appendingPathComponent("profile.stamp"))), before, "the stamp goes up, last")
        d.set(false, forKey: NX18Profile.switchKey)
        XCTAssertFalse(NX18Profile.shareAppearance(.dark, root: root, defaults: d, folder: folder, wait: true), "the Profile off: this app only")
        XCTAssertEqual((try? String(contentsOf: dir.appendingPathComponent("appearance.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines), "light")
    }

    // The careful read (§21.3): a folder read in full and empty is "no profile"; one with a Profile names it
    func testCarefulRead() throws {
        let folder = try temp("careful")
        XCTAssertEqual(NX18ProfileSync.careful(folder: folder, timeout: 5), NX18ProfileSync.Found.none)
        let p = folder.appendingPathComponent("Profile"); try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "Jiji\n".write(to: p.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(NX18ProfileSync.careful(folder: folder, timeout: 5), .profile("Jiji"))
    }

    // What the games get: the name and the picture's path with the switch on; neither with it off; an env.txt value wins
    func testEnvForTheGames() throws {
        let root = try temp("env"), d = try XCTUnwrap(UserDefaults(suiteName: "duo-profile-env-\(UUID().uuidString)"))
        NX18Profile.writeLocal(at: root, name: "Kiki", picture: Data([0xFF, 0xD8, 0xFF, 0xD9]), appearance: nil)
        unsetenv("DM_NICK"); unsetenv("DM_PROFILE_IMAGE"); NX18Profile.ownEnv = []
        defer { unsetenv("DM_NICK"); unsetenv("DM_PROFILE_IMAGE"); unsetenv("DM_ENV_FILE_KEYS"); NX18Profile.ownEnv = [] }
        NX18Profile.applyEnv(root: root, defaults: d)
        XCTAssertEqual(getenv("DM_NICK").map { String(cString: $0) }, "Kiki")
        XCTAssertEqual(getenv("DM_PROFILE_IMAGE").map { String(cString: $0) }, root.appendingPathComponent("picture.jpg").path)
        d.set(false, forKey: NX18Profile.switchKey)
        NX18Profile.applyEnv(root: root, defaults: d)
        XCTAssertNil(getenv("DM_NICK"), "off: the games see Player")
        XCTAssertNil(getenv("DM_PROFILE_IMAGE"))
        d.set(true, forKey: NX18Profile.switchKey)
        setenv("DM_NICK", "FromFile", 1); setenv("DM_ENV_FILE_KEYS", "DM_NICK", 1)
        NX18Profile.applyEnv(root: root, defaults: d)
        XCTAssertEqual(getenv("DM_NICK").map { String(cString: $0) }, "FromFile", "an env.txt value wins")
    }

    // The picture the host accepts (hle_account.c): 256 x 256, baseline, at most 128 KiB
    func testPictureIsWhatTheHostTakes() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<60 { ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)); ctx.fill(CGRect(x: i * 20, y: (i * 37) % 900, width: 30, height: 200)) }
        let jpeg = try XCTUnwrap(NX18ProfilePicture.jpeg(from: try XCTUnwrap(ctx.makeImage())))
        XCTAssertLessThanOrEqual(jpeg.count, 128 * 1024)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8]); XCTAssertEqual(Array(jpeg.suffix(2)), [0xFF, 0xD9])
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 256); XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 256)
        XCTAssertNotEqual((props[kCGImagePropertyJFIFDictionary] as? [CFString: Any])?[kCGImagePropertyJFIFIsProgressive] as? Bool, true, "baseline, not progressive")
        // the SOF0 marker (baseline) is there, no SOF2 (progressive)
        let bytes = [UInt8](jpeg)
        XCTAssertTrue(zip(bytes, bytes.dropFirst()).contains { $0 == 0xFF && $1 == 0xC0 })
        XCTAssertFalse(zip(bytes, bytes.dropFirst()).contains { $0 == 0xFF && $1 == 0xC2 })
    }

    // The card with its Profile rows: taller than before, and in iPhone landscape it fits under the mark by scrolling its body (§20.1)
    func testCardWithProfileRows() {
        let rows = NX18CardProfile(note: "Moved and checked.", shared: true, choosePicture: {}, editName: {}, toggle: {}, chooseFolder: {}, saves: {})
        let host = UIHostingController(rootView: NX18Card(gameVersion: "1.4.1", focused: .picture, glyphs: nil, close: {}, profileRows: rows).frame(width: 320))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 2000))
        XCTAssertGreaterThan(size.height, 330, "header, version, Appearance, the Profile label, picture and name, the switch")
        let scrolling = UIHostingController(rootView: NX18Card(gameVersion: "1.4.1", focused: .picture, glyphs: nil, close: {}, profileRows: rows, scrolls: true).frame(width: 320).frame(maxHeight: 359))
        XCTAssertLessThanOrEqual(scrolling.sizeThatFits(in: CGSize(width: 320, height: 359)).height, 359.5, "iPhone landscape: the body scrolls under the header")
    }

    // This game's captures (the card's row; DmCapture.m reads it): own folder by default, the choice kept, and a flip on the flow stores it
    func testCapturesChoice() {
        let was = UserDefaults.standard.object(forKey: "nx18.captures"); defer { UserDefaults.standard.set(was, forKey: "nx18.captures") }
        UserDefaults.standard.removeObject(forKey: "nx18.captures")
        XCTAssertFalse(dm_nx18_captures_shared(), "own folder until chosen")
        dm_set_nx18_captures_shared(true); XCTAssertTrue(dm_nx18_captures_shared())
        let flow = NX18ProfileFlow()
        XCTAssertTrue(flow.capturesShared)
        flow.capturesTapped(); XCTAssertFalse(flow.capturesShared); XCTAssertFalse(dm_nx18_captures_shared(), "the flip is stored")
    }

    // The welcome (§21.1): once per app, DM_WELCOME=0 skips it and 1 forces it; any choice records it
    func testWelcomeRule() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "duo-welcome-\(UUID().uuidString)"))
        XCTAssertTrue(NX18WelcomeGate.due(environment: [:], defaults: d))
        XCTAssertFalse(NX18WelcomeGate.due(environment: ["DM_WELCOME": "0"], defaults: d))
        NX18WelcomeGate.record("not now", defaults: d)
        XCTAssertFalse(NX18WelcomeGate.due(environment: [:], defaults: d))
        XCTAssertTrue(NX18WelcomeGate.due(environment: ["DM_WELCOME": "1"], defaults: d))
    }

    // The welcome comes before the Gate, and Not now goes on to it
    func testWelcomeThenTheGate() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let dir = try temp("welcome-gate")
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        setenv("DM_APP_DM", dir.path, 1); setenv("DM_WELCOME", "1", 1); unsetenv("DM_LAUNCHER")
        defer {
            unsetenv("DM_APP_DM"); setenv("DM_WELCOME", "0", 1)
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = nil
        }
        waitUntil("nothing over the game") { root.presentedViewController == nil }
        XCTAssertTrue(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), {}))
        let welcome = try XCTUnwrap(root.presentedViewController as? DmHostingController<NX18WelcomeView>)
        welcome.rootView.finished()
        waitUntil("the Gate shows after the welcome") { root.presentedViewController is DmHostingController<LauncherView> }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(cond(), what)
    }
}
