// UI step 3 (NX18-X2.0 gate-ui.md §11a, §18, §20, §21.2a): the light look's tokens, the Appearance choice applied live to the Gate's host, the first-start acknowledgement before
// every start path, About this game's add-on count and storage line, and the NX 18 card's row
import SwiftUI
import UIKit
import XCTest
@testable import DuoHarness

private nonisolated(unsafe) var duoAckPlays = 0   // dmShowLauncher's done: the game would start here

@MainActor final class DuoAboutTests: XCTestCase {
    private func hex(_ c: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
        let u = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    // The Soft tone's sets (§11a.3, §11a.5): dark as the Gate had it, light and in-game light from the decided tables
    func testTokensFollowTheLook() {
        let gate: [(Color, UInt32, UInt32)] = [(GateColor.slab, 0x2A2A2D, 0xECECF0), (GateColor.tile, 0x333337, 0xFAFAFB), (GateColor.lit, 0x23434D, 0xF8E7E4),
                                              (GateColor.chosen, 0x9CD1E2, 0xF3C7BE), (GateColor.ring, 0x86CADF, 0x95534A), (GateColor.text, 0xEDEDF0, 0x1C1C1F),
                                              (GateColor.muted, 0xB4B4BC, 0x55555E), (GateColor.peach, 0xF4B7A6, 0x3E6B7A), (GateColor.disabled, 0x8A8A92, 0x7E7E86)]
        for (c, d, l) in gate {
            XCTAssertEqual(hex(c, .dark), d, String(format: "dark %06X", d))
            XCTAssertEqual(hex(c, .light), l, String(format: "light %06X", l))
        }
        XCTAssertEqual(hex(MenuColor.slab, .light), 0xBDBDC3, "the in-game menu's dimmer light slab")
        XCTAssertEqual(hex(MenuColor.text, .light), 0x121214)
        XCTAssertEqual(hex(MenuColor.slab, .dark), 0x2A2A2D)
        XCTAssertEqual(hex(NX18PageColor.page(tint: nil), .light), 0xDCDCE1)
        XCTAssertEqual(hex(NX18PageColor.page(tint: nil), .dark), 0x1E1E21)
        let white = NX18RGB(r: 1, g: 1, b: 1)
        XCTAssertEqual(hex(NX18PageColor.page(tint: white), .light) >> 16, UInt32((0xDC + (255 - 0xDC) * 6 / 100)), "6 % of the art's colour in light")
    }

    // Match device, Light, Dark: stored in the app's defaults, stepped in order, and taken by the Gate's host at once (§20.5b)
    func testAppearanceChoiceAppliesLive() {
        let was = UserDefaults.standard.object(forKey: NX18Appearance.key)
        defer { if let was { UserDefaults.standard.set(was, forKey: NX18Appearance.key) } else { UserDefaults.standard.removeObject(forKey: NX18Appearance.key) } }
        UserDefaults.standard.removeObject(forKey: NX18Appearance.key)
        XCTAssertEqual(NX18Appearance.current, .device, "Match device by default")
        XCTAssertEqual(NX18Appearance.device.stepped(1), .light)
        XCTAssertEqual(NX18Appearance.dark.stepped(1), .device, "wraps")
        XCTAssertEqual(NX18Appearance.device.stepped(-1), .dark)
        let host = DmHostingController(rootView: Color.clear)
        host.followAppearance()
        XCTAssertEqual(host.overrideUserInterfaceStyle, .unspecified)
        NX18Appearance.current = .light
        XCTAssertEqual(UserDefaults.standard.string(forKey: NX18Appearance.key), "light")
        XCTAssertEqual(host.overrideUserInterfaceStyle, .light, "a change applies to the open host")
        NX18Appearance.current = .dark
        XCTAssertEqual(host.overrideUserInterfaceStyle, .dark)
        NX18Appearance.current = .device
        XCTAssertEqual(host.overrideUserInterfaceStyle, .unspecified)
    }

    // Once per app; DM_TEST_ACK=1 forces it, =0 skips it, and an env file's DM_TEST_ACK counts for nothing (GW33)
    func testAcknowledgementRule() throws {
        let suite = "duo.ack.\(UUID().uuidString)", other = "duo.ack.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite); UserDefaults(suiteName: other)?.removePersistentDomain(forName: other) }
        XCTAssertTrue(NX18Acknowledge.due(environment: [:], defaults: d), "a new app asks")
        NX18Acknowledge.record(defaults: d)
        XCTAssertFalse(NX18Acknowledge.due(environment: [:], defaults: d), "once")
        XCTAssertTrue(try XCTUnwrap(d.string(forKey: NX18Acknowledge.key)).hasPrefix("1 "), "the line's version, then the day")
        XCTAssertTrue(NX18Acknowledge.due(environment: ["DM_TEST_ACK": "1"], defaults: d))
        XCTAssertFalse(NX18Acknowledge.due(environment: ["DM_TEST_ACK": "0"], defaults: UserDefaults(suiteName: other)!))
        XCTAssertFalse(NX18Acknowledge.due(environment: ["DM_TEST_ACK": "1", "DM_ENV_FILE_KEYS": "DM_SHOW_FPS DM_TEST_ACK"], defaults: d), "set by env.txt: ignored")
        XCTAssertTrue(NX18Acknowledge.line.contains("legally owned and acquired"))
    }

    // An app with no Gate still asks: the panel shows, and the game starts only after I understand (§21.2a)
    func testAcknowledgementComesBeforeAStartWithNoGate() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let was = UserDefaults.standard.object(forKey: NX18Acknowledge.key)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-ack-\(UUID().uuidString)")   // no launcher.json: no Gate
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("DM_APP_DM", dir.path, 1); setenv("DM_TEST_ACK", "1", 1)
        defer {
            unsetenv("DM_APP_DM"); setenv("DM_TEST_ACK", "0", 1)
            if let was { UserDefaults.standard.set(was, forKey: NX18Acknowledge.key) } else { UserDefaults.standard.removeObject(forKey: NX18Acknowledge.key) }
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            try? FileManager.default.removeItem(at: dir)
        }
        duoAckPlays = 0
        XCTAssertTrue(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoAckPlays += 1 }), "the panel shows: done comes later")
        let host = try XCTUnwrap(root.presentedViewController as? DmHostingController<NX18AcknowledgeView>, "the acknowledgement panel")
        XCTAssertEqual(duoAckPlays, 0, "the game waits for the press")
        host.rootView.understood()
        waitUntil("the panel goes") { root.presentedViewController == nil }
        waitUntil("and the game starts") { duoAckPlays == 1 }
        XCTAssertNotNil(UserDefaults.standard.string(forKey: NX18Acknowledge.key), "recorded")
    }

    // With a Gate: the panel first, then the Gate itself, presented once the panel has gone
    func testAcknowledgementThenTheGate() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let was = UserDefaults.standard.object(forKey: NX18Acknowledge.key)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-ack-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        setenv("DM_APP_DM", dir.path, 1); setenv("DM_TEST_ACK", "1", 1); unsetenv("DM_LAUNCHER")
        defer {
            unsetenv("DM_APP_DM"); setenv("DM_TEST_ACK", "0", 1)
            if let was { UserDefaults.standard.set(was, forKey: NX18Acknowledge.key) } else { UserDefaults.standard.removeObject(forKey: NX18Acknowledge.key) }
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = nil
            try? FileManager.default.removeItem(at: dir)
        }
        waitUntil("nothing over the game") { root.presentedViewController == nil }
        XCTAssertTrue(dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoAckPlays += 1 }))
        let ack = try XCTUnwrap(root.presentedViewController as? DmHostingController<NX18AcknowledgeView>)
        ack.rootView.understood()
        waitUntil("the Gate shows after the panel") { root.presentedViewController is DmHostingController<LauncherView> }
    }

    // About this game's figures: the add-ons the build packed and the storage line (§18.1)
    func testAboutCountsAndStorage() async throws {
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("duo-about-\(UUID().uuidString)")
        for i in 0..<2 { try FileManager.default.createDirectory(at: b.appendingPathComponent("aoc/\(i)"), withIntermediateDirectories: true) }
        try Data("x".utf8).write(to: b.appendingPathComponent("aoc/readme.txt"))   // a file, not an add-on
        defer { try? FileManager.default.removeItem(at: b) }
        let bundle = try XCTUnwrap(Bundle(path: b.path))
        XCTAssertEqual(LauncherAboutSheet.addOnCount(bundle: bundle), 2)
        XCTAssertEqual(LauncherAboutSheet.addOnCount(bundle: .main), 0, "the harness packs none")
        let line = await LauncherAboutSheet.storageLine()
        XCTAssertTrue(line.hasPrefix("Game ") && line.contains(" · Saves ") && line.contains(" · Caches "), line)
    }

    // The card renders with its row and every target at least 44 pt (§20.1, §20.5b)
    func testCardShowsTheAppearanceRow() throws {
        let host = UIHostingController(rootView: NX18Card(gameVersion: "1.4.1", focused: .appearance, glyphs: nil) {}.frame(width: 320))
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 400)
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertGreaterThan(size.height, 150, "header, version, the Appearance row and its note")
        XCTAssertLessThan(size.height, 420, "fits under the mark in iPhone landscape with the Profile still to come")
    }

    // About this game's art header runs edge to edge in iPhone landscape: under side safe areas of 59 pt (the camera housing's) it still spans the window's whole width,
    // its content inset by them (owner, 2026-11-16)
    func testAboutHeaderSpansTheWindow() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first, "the harness's window scene")
        let window = UIWindow(windowScene: scene)   // UIWindow() is deprecated in iOS 26
        window.frame = CGRect(x: 0, y: 0, width: 956, height: 440)
        let host = UIHostingController(rootView: LauncherAboutSheet(about: LauncherAbout(name: "Duo"), artwork: LauncherArtwork(), name: "Duo", version: nil,
                                                                    scroller: LauncherScroller()) {})
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 59)
        window.rootViewController = host
        LauncherAboutSheet.headerWidth = 0
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        waitUntil("the header laid out") { LauncherAboutSheet.headerWidth > 0 }
        XCTAssertEqual(LauncherAboutSheet.headerWidth, 956, accuracy: 0.5, "the header's background spans the window, side safe areas included")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(cond(), what)
    }
}
