import Metal
import UIKit
import XCTest
@testable import DuoHarness

// Whether the settings screen (the Gate: dmShowLauncher, Launcher.swift presentLauncher) gives its memory back once Play is pressed. The real screen is shown over the harness's
// root view controller as front_ios.m shows it, with placeholder art made here (a 2732x2048 gradient JPEG, about 21 MB decoded), a placeholder logo and About text, then Play
// goes through the screen's own start() (the Game shortcut on the screen: the path the Play button, A on Play and + take), with the About sheet up in the second test. Once
// the dismissal's completion has called done (a no-op that counts) and 5 s have passed, weak references and the heap's live instances say what is gone: the hosting controller,
// the art and logo images, the controller poll (LauncherGamepad, owned by the view's task), the sheet scroller and the flowing rails. The screen's model stays by design: dmShowLauncher
// hands it to the in-game menu (gameMenuModel, Launcher.swift), so the test checks that nothing else holds it. The physical footprint before the screen, while it is up and 5 s after
// Play goes to the log (lines starting "duo-gate-memory:") and to the test's attachments. The CG Image regions are measured by their virtual size (every page mapped, resident or
// compressed), and the art must be seen there while the Gate is up (at least 20 MB more than before it), or a region given back after Play would prove nothing. A third test takes
// the Gate away without Play (dismissed from the root, as anything over the game could be): the play closure holds the hosting controller only weakly, so that frees it all too.
// DUO_GATE_LEAKS_HOLD=<seconds> (TEST_RUNNER_DUO_GATE_LEAKS_HOLD for xcodebuild) keeps the first test waiting that long before the Gate and after its checks, for `footprint -p <pid>`,
// `vmmap -summary <pid>` or `leaks <pid>` from the Mac (the pid is in the log)
private nonisolated(unsafe) var duoGatePlays = 0   // dmShowLauncher's done: the game would start here

final class DuoGateMemoryTests: XCTestCase {
    @MainActor
    private func waitUntil(_ what: String, _ timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(cond(), what)
    }
    @MainActor
    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    private static func delta(_ a: UInt64, _ b: UInt64) -> String { String(format: "%+.1f MB", (Double(b) - Double(a)) / 1_048_576) }

    // The placeholder files: no game's art, logo or text
    private static func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("duo-gate-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"schema": 1, "settings": [{"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0", "on": "1", "off": "0"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("launcher.json"))
        try Data(#"{"name": "Placeholder", "description": "Placeholder text for the memory test.", "publisher": "Nobody"}"#.utf8).write(to: dir.appendingPathComponent("about.json"))
        try autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true
            let size = CGSize(width: 2732, height: 2048)
            let art = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { c in
                let colors = [UIColor(red: 0.05, green: 0.75, blue: 0.85, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.42, blue: 0.38, alpha: 1).cgColor] as CFArray
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
                c.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            try art.write(to: dir.appendingPathComponent("art.jpg"))
            let logoFormat = UIGraphicsImageRendererFormat()
            logoFormat.scale = 1; logoFormat.opaque = false
            let logo = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400), format: logoFormat).pngData { _ in
                UIColor.white.setFill()
                UIBezierPath(roundedRect: CGRect(x: 80, y: 120, width: 1040, height: 160), cornerRadius: 40).fill()
            }
            try logo.write(to: dir.appendingPathComponent("logo.png"))
        }
        return dir
    }

    // Weak references to what one shown screen holds: its hosting controller and the images of its LauncherArtwork (read from the hosting controller's root view)
    private struct Shown {
        weak var host: UIViewController?
        weak var art: UIImage?
        weak var logo: UIImage?
        weak var model: LauncherModel?
        let hostClass: AnyClass
        let artPixels: CGSize
    }
    @MainActor
    private func shown(_ root: UIViewController) throws -> Shown {
        let host = try XCTUnwrap(root.presentedViewController, "The settings screen")
        let typed = try XCTUnwrap(host as? DmHostingController<LauncherView>, "presented as presentLauncher presents it")
        let artwork = typed.rootView.artwork
        let art = try XCTUnwrap(artwork.art, "The placeholder art decoded")
        XCTAssertNotNil(artwork.logo, "The placeholder logo decoded")
        return Shown(host: host, art: art, logo: artwork.logo, model: gameMenuModel, hostClass: type(of: host),
                     artPixels: CGSize(width: art.size.width * art.scale, height: art.size.height * art.scale))
    }

    private struct Census: CustomStringConvertible {
        var hosts = 0, pads = 0, scrollers = 0, rails = 0, models = 0
        var description: String { "hosting controllers \(hosts), LauncherGamepad \(pads), LauncherScroller \(scrollers), NX18RailsFlowView \(rails), LauncherModel \(models)" }
    }
    private static func census(_ hostClass: AnyClass) -> Census {
        Census(hosts: Int(duo_live_instances(hostClass)), pads: Int(duo_live_instances(LauncherGamepad.self)), scrollers: Int(duo_live_instances(LauncherScroller.self)),
               rails: Int(duo_live_instances(NX18RailsFlowView.self)), models: Int(duo_live_instances(LauncherModel.self)))
    }

    private enum Leave { case play, playOverAbout, dismiss }   // how the Gate goes: Play, Play with About this game up, or dismissed without Play (done not called)

    @MainActor
    func testGateFreesItsMemoryAfterPlay() throws { try gate(.play) }

    @MainActor
    func testGateFreesItsMemoryAfterPlayOverAbout() throws { try gate(.playOverAbout) }

    @MainActor
    func testGateFreesItsMemoryDismissedWithoutPlay() throws { try gate(.dismiss) }

    private static let mib: UInt64 = 1_048_576

    @MainActor
    private func gate(_ leave: Leave) throws {
        let about = leave == .playOverAbout, play = leave != .dismiss
        let name = about ? "Play over About" : play ? "Play" : "Dismissed without Play"
        let gone = play ? "Play" : "the dismissal"   // in the log: 5 s after it
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        waitUntil("Nothing over the game (a settings screen another test showed is gone)") { root.presentedViewController == nil }
        let dir = try Self.makeFolder()
        let skip = UserDefaults.standard.object(forKey: LauncherModel.skipKey)
        UserDefaults.standard.removeObject(forKey: LauncherModel.skipKey)
        let active = LauncherShortcuts.appActive
        LauncherShortcuts.appActive = { true }   // the Simulator app may not be in front: the start must not wait for it (LauncherView.startHeld)
        let menuModel = gameMenuModel
        gameMenuModel = nil
        setenv("DM_APP_DM", dir.path, 1); unsetenv("DM_LAUNCHER"); unsetenv("DM_SAVE")
        defer {
            unsetenv("DM_APP_DM"); unsetenv("DM_SAVE_SYNC_CHOICE")
            if let skip { UserDefaults.standard.set(skip, forKey: LauncherModel.skipKey) }
            LauncherShortcuts.appActive = active
            root.presentedViewController?.presentedViewController?.dismiss(animated: false)
            if root.presentedViewController != nil { root.dismiss(animated: false) }
            LauncherShortcuts.screenUp = false; LauncherShortcuts.started = true; LauncherShortcuts.pending = nil
            gameMenuModel = menuModel
            try? FileManager.default.removeItem(at: dir)
        }
        LauncherShortcuts.pending = nil
        _ = MTLCreateSystemDefaultDevice()   // made before the measure: Play's completion makes it for the facts (metalDeviceMade), and in the app the game's own device is that one
        settle(1)

        let hold = leave != .play ? 0 : ProcessInfo.processInfo.environment["DUO_GATE_LEAKS_HOLD"].flatMap(Double.init) ?? 0
        if hold > 0 {   // the same wait before the Gate, for a footprint or vmmap of the process to compare with the one after
            let l = "duo-gate-memory: holding \(Int(hold)) s before the Gate: pid \(getpid())"
            print(l); fputs(l + "\n", stderr)
            settle(hold)
        }
        let cgTag = UInt32(VM_MEMORY_CGIMAGE)
        let before = duo_phys_footprint(), cgBefore = duo_vm_tag_virtual(cgTag), cgBeforeResident = duo_vm_tag_resident(cgTag)
        duoGatePlays = 0
        // Each call from here goes in a pool of its own, as in the app, where UIKit calls front_ios.m (dm_show_launcher) and a shortcut in a run loop turn whose pool drains after
        // it: called straight from the test method, what they autorelease (preparingForDisplay's image contents, which hold the decoded art) waits for the test's own pool, which
        // drains only when the test ends, and kept the 21 MB decode mapped after Play
        XCTAssertTrue(autoreleasepool { dmShowLauncher(Unmanaged.passUnretained(root).toOpaque(), { duoGatePlays += 1 }) }, "The screen shows")
        let s = try autoreleasepool { try shown(root) }
        XCTAssertEqual(s.artPixels, CGSize(width: 2732, height: 2048), "The art decoded at full size")
        XCTAssertNotNil(s.model, "dmShowLauncher's model")
        settle(2)   // drawn; the controller poll and the status line's tasks running
        let base = Self.census(s.hostClass)   // with the screen up; what is left of earlier tests' screens is in it too
        let up = duo_phys_footprint(), cgUp = duo_vm_tag_virtual(cgTag), cgUpResident = duo_vm_tag_resident(cgTag)
        // The art's decode (2732x2048, about 21 MB) is in the regions measured, or their size after Play would say nothing about it
        XCTAssertGreaterThanOrEqual(cgUp, cgBefore + 20 * Self.mib, "The decoded art is mapped in the CG Image regions while the Gate is up")
        if about {
            XCTAssertTrue(autoreleasepool { dmShortcutPerform("dm.shortcut.guide") }, "Guide: this app has no guide or manual, so About this game opens")
            waitUntil("About this game opened over the screen") { s.host?.presentedViewController != nil }
            settle(1)
        }
        let atPlay = duo_phys_footprint()

        if play {
            // Play: the screen's start() (Play, A on Play, + and the Game shortcut all go there), no cloud save to check (no DM_SAVE), so it plays at once
            XCTAssertTrue(autoreleasepool { dmShortcutPerform("dm.shortcut.game") })
            waitUntil("Play dismissed the screen and called done") { duoGatePlays == 1 && root.presentedViewController == nil }
            XCTAssertFalse(LauncherShortcuts.screenUp)
        } else {
            // Taken away without Play: dismissed from the root, as anything that dismissed what is over the game would; the play closure is never called
            autoreleasepool { root.dismiss(animated: false) }
            waitUntil("The screen dismissed") { root.presentedViewController == nil }
        }
        settle(5)
        let after = duo_phys_footprint(), cgAfter = duo_vm_tag_virtual(cgTag), cgAfterResident = duo_vm_tag_resident(cgTag)
        let left = Self.census(s.hostClass)
        let modelHeld = s.model != nil && s.model === gameMenuModel
        gameMenuModel = nil   // the in-game menu's hold on the model let go: nothing else may keep it
        settle(0.5)
        let modelFreed = s.model == nil
        let withoutModel = duo_phys_footprint()

        let lines = [
            "duo-gate-memory: \(name): footprint before the Gate \(Self.mb(before)), Gate shown \(Self.mb(up)) (\(Self.delta(before, up)))"
                + (about ? ", About up \(Self.mb(atPlay)) (\(Self.delta(before, atPlay)))" : "")
                + ", 5 s after \(gone) \(Self.mb(after)) (\(Self.delta(before, after)) against before, \(Self.delta(atPlay, after)) against the Gate)"
                + ", model let go too \(Self.mb(withoutModel)) (\(Self.delta(before, withoutModel)))",
            "duo-gate-memory: \(name): CG Image regions (decoded images), virtual (resident): before \(Self.mb(cgBefore)) (\(Self.mb(cgBeforeResident))), Gate shown \(Self.mb(cgUp)) (\(Self.mb(cgUpResident)))"
                + ", 5 s after \(gone) \(Self.mb(cgAfter)) (\(Self.mb(cgAfterResident)))",
            "duo-gate-memory: \(name): live with the Gate up: \(base)",
            "duo-gate-memory: \(name): live 5 s after \(gone): \(left)",
            "duo-gate-memory: \(name): weak refs after \(gone): hosting controller \(s.host == nil ? "freed" : "ALIVE"), art \(s.art == nil ? "freed" : "ALIVE"), logo \(s.logo == nil ? "freed" : "ALIVE"), model \(modelHeld ? "alive, held by gameMenuModel" : "?"), then \(modelFreed ? "freed" : "ALIVE") once gameMenuModel let it go",
        ]
        for l in lines { print(l); fputs(l + "\n", stderr) }
        add(XCTAttachment(string: lines.joined(separator: "\n")))

        XCTAssertEqual(duoGatePlays, play ? 1 : 0, play ? "done called once" : "done not called without Play")
        let how = play ? "after Play" : "dismissed without Play"
        XCTAssertNil(s.host, "The DmHostingController is freed \(how)")
        XCTAssertNil(s.art, "The decoded art (LauncherArtwork.art) is freed \(how)")
        XCTAssertNil(s.logo, "The decoded logo (LauncherArtwork.logo) is freed \(how)")
        XCTAssertEqual(left.hosts, base.hosts - 1, "This screen's hosting controller is gone from the heap")
        XCTAssertEqual(left.pads, base.pads - 1, "Its controller poll (LauncherGamepad, owned by the view's .task) is gone")
        XCTAssertLessThan(left.scrollers, base.scrollers, "Its LauncherScroller is gone")
        XCTAssertLessThan(left.rails, base.rails, "Its flowing rails are gone")
        // The model is kept for the in-game menu (Launcher.swift: gameMenuModel = model); nothing else may hold it
        XCTAssertTrue(modelHeld, "The model lives on as the in-game menu's (gameMenuModel)")
        XCTAssertTrue(modelFreed, "Nothing but gameMenuModel holds the screen's LauncherModel")
        // The art's decode (about 21 MB, a CG Image region, seen mapped while the Gate was up) is unmapped: the regions are back to their size before the Gate
        XCTAssertLessThan(cgAfter, cgBefore + Self.mib, "The decoded art's memory is given back \(how)")
        // A decoded image still mapped: who holds it (after the measures: the scan reads memory the footprint would then count)
        var lo: UInt = 0, hi: UInt = 0
        if cgAfter >= cgBefore + Self.mib, duo_vm_tag_largest(cgTag, &lo, &hi) {
            let tree = "duo-gate-memory: \(name): what holds the CG Image region 5 s after \(gone): " + duo_referrer_tree(lo, hi, 6)
            print(tree); fputs(tree + "\n", stderr)
            add(XCTAttachment(string: tree))
        }

        if hold > 0 {
            let l = "duo-gate-memory: holding \(Int(hold)) s after Play, for leaks: pid \(getpid())"
            print(l); fputs(l + "\n", stderr)
            let end = Date().addingTimeInterval(hold)
            while Date() < end {
                settle(5)
                let t = "duo-gate-memory: hold: footprint \(Self.mb(duo_phys_footprint())) (\(Self.delta(before, duo_phys_footprint())) against before)"
                print(t); fputs(t + "\n", stderr)
            }
        }
    }
}
