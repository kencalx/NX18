import UIKit
import SwiftUI
import XCTest
@testable import DuoHarness

// The in-game menu as NX 18's panel (GameMenuPanel.swift) on the production root view controller: the menu button opens it over the game with the UIMenu's rows, a pick
// takes effect and the panel stays, a choice opens as a page and a pick there comes back, B goes back and closes, the controllers wait meanwhile; how its columns are cut;
// the menu button's cyan-to-coral icon; and DM_GAME_MENU=system keeping the UIMenu
final class DuoGameMenuPanelTests: XCTestCase {
    private static let list = """
    {"schema": 1, "settings": [
     {"env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture", "note": "", "default": "fit", "options": [["fit", "Fit"], ["fill", "Fill"], ["stretch", "Stretch"]]},
     {"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0"}
    ]}
    """

    private func item(_ id: String, _ count: Int) -> [GameMenuItem] { (0..<count).map { GameMenuItem(id: "\(id)\($0)", title: "\(id) \($0)", kind: .toggle(false)) } }

    func testColumnsKeepTheSectionsSideBySide() {
        let game = GameMenuSection(id: "g", heading: "Game", items: item("g", 6))
        let controls = GameMenuSection(id: "c", heading: "Controls", items: item("c", 5))
        let cheats = GameMenuSection(id: "x", heading: "More", items: item("x", 1)), app = GameMenuSection(id: "a", heading: "More", items: item("a", 2))
        let three = GameMenuLayout.columns([game, controls, cheats, app], fit: 3, split: 3)
        XCTAssertEqual(three.map { $0.ids.count }, [6, 5, 3], "One column per section; More's two groups are one column")
        XCTAssertEqual(three.map { $0.blocks.first?.heading }, ["Game", "Controls", "More"])
        let four = GameMenuLayout.columns([game, controls, cheats, app], fit: 4, split: 3)
        XCTAssertEqual(four.map { $0.ids.count }, [3, 3, 5, 3], "A spare column takes half of the tallest section, lowering the panel")
        XCTAssertEqual(four[1].blocks.first?.heading ?? nil, nil, "The section's second column has no heading of its own")
        let one = GameMenuLayout.columns([game, controls, cheats, app], fit: 1, split: 3)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].ids.count, 14, "Portrait on a phone: one column with every row")
        XCTAssertEqual(one[0].blocks.compactMap(\.heading), ["Game", "Controls", "More"])
        let two = GameMenuLayout.columns([game, controls, cheats, app], fit: 2, split: 3)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.flatMap(\.ids), one[0].ids, "Cut in order")
        let options = GameMenuLayout.columns([GameMenuSection(id: "o", items: item("o", 3))], fit: 5, split: 1)
        XCTAssertEqual(options.map { $0.ids.count }, [1, 1, 1], "A page of options spreads its options out")

        // The controller's steps: up and down in a column without wrapping, left and right to the same row of the next column
        XCTAssertEqual(GameMenuLayout.step(nil, 0, 1, in: three), "g0")
        XCTAssertEqual(GameMenuLayout.step("g0", 0, -1, in: three), "g0")
        XCTAssertEqual(GameMenuLayout.step("g5", 0, 1, in: three), "g5")
        XCTAssertEqual(GameMenuLayout.step("g4", 1, 0, in: three), "c4")
        XCTAssertEqual(GameMenuLayout.step("g5", 1, 0, in: three), "c4", "The next column's last row when it is shorter")
        XCTAssertEqual(GameMenuLayout.step("c1", 1, 0, in: three), "a0")
        XCTAssertEqual(GameMenuLayout.step("a1", 1, 0, in: three), "a1", "No column further right")
    }

    @MainActor
    private func productionMenuButton() throws -> (UIViewController, UIButton) {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        func find(_ v: UIView) -> UIButton? {
            if let b = v as? UIButton, b.accessibilityLabel == "Menu" { return b }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return (root, try XCTUnwrap(find(root.view), "the game view's menu button"))
    }

    @MainActor
    private func waitUntil(_ what: String, _ ok: @escaping () -> Bool) {
        let done = expectation(description: what)
        func poll() { if ok() { done.fulfill() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() } } }
        poll()
        wait(for: [done], timeout: 3)
    }

    @MainActor
    func testThePanelOpensOverTheGameWithTheMenusRows() throws {
        let (root, button) = try productionMenuButton()
        let suite = "DuoGameMenuPanelTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(Self.list.utf8))
        let m = LauncherModel(file.settings, defaults: defaults)
        gameMenuModel = m
        let picture = root.value(forKey: "picture")
        defer {
            gameMenuModel = nil
            if dm_game_panel_shown() { dm_game_panel_close() }
            _ = dm_setting_live("DM_PICTURE_FIT", "fit"); unsetenv("DM_PICTURE_FIT"); _ = dm_setting_live("DM_SHOW_FPS", "0"); unsetenv("DM_SHOW_FPS")
            root.setValue(picture, forKey: "picture")
            defaults.removePersistentDomain(forName: suite)
        }

        XCTAssertNil(button.menu, "NX 18's panel, not a UIMenu, by default")
        XCTAssertEqual(button.image(for: .normal)?.renderingMode, .alwaysOriginal, "The icon keeps its own colours")
        button.sendActions(for: .primaryActionTriggered)   // a tap
        XCTAssertTrue(dm_game_panel_shown())
        let host = try XCTUnwrap(root.children.compactMap { $0 as? GameMenuPanelHost }.first, "The panel is a child of the game's view controller")
        XCTAssertTrue(host.view.isDescendant(of: root.view))
        XCTAssertEqual(host.view.frame, root.view.bounds, "Over the whole game: its dim closes it")
        XCTAssertTrue(host.view.accessibilityViewIsModal, "VoiceOver stays in the panel")
        XCTAssertEqual(host.traitCollection.preferredContentSizeCategory, UIApplication.shared.preferredContentSizeCategory, "The system's text size, not the window's fixed one")

        let model = host.model
        let rows = model.root.flatMap(\.items)
        let menu = gameMenuItems().flatMap { ($0 as? UIMenu)?.children ?? [$0] }
        XCTAssertEqual(rows.map(\.title), menu.map(\.title), "The same rows as the UIMenu, in the same order")
        XCTAssertEqual(model.root.compactMap(\.heading), ["Controls", "Game", "More"])
        XCTAssertEqual(rows.last?.title, "Share log")
        XCTAssertEqual(model.focus, "row:DM_PICTURE_FIT", "No presets in this list: the controller's ring starts on the first quick tile")
        XCTAssertEqual(model.home.tiles.map(\.id), ["row:DM_PICTURE_FIT", "row:DM_SHOW_FPS", "layout"], "The first page's quick tiles, in the Gate's order (gate-ui §19.2)")
        XCTAssertEqual(model.home.doors.map(\.id), ["door.more"], "No Customize without other live rows; More holds Exit and return to Gate and Share log")

        // Exit and return to Gate asks first: its page holds the question, the ring starts on Keep Playing, and Keep Playing and B go back without exiting
        let exit = try XCTUnwrap(rows.first { $0.id == GameMenuExit.rowID })
        model.activate(exit)
        XCTAssertEqual(model.page.title, "Exit the game?")
        XCTAssertEqual(model.page.subtitle, "Progress since your last save is lost.")
        XCTAssertEqual(model.focus, GameMenuExit.noID, "Keep Playing has the focus")
        model.activate(try XCTUnwrap(model.page.sections.flatMap(\.items).first { $0.id == GameMenuExit.noID }))   // Keep Playing
        XCTAssertNil(model.page.id, "Back to the rows")
        XCTAssertEqual(model.focus, GameMenuExit.rowID)
        model.activate(exit)
        model.handle(.b)
        XCTAssertNil(model.page.id, "B goes back too")
        XCTAssertTrue(dm_game_panel_shown(), "Nothing exited")

        // A switch: takes effect, and the panel stays
        let fps = try XCTUnwrap(rows.first { $0.id == "row:DM_SHOW_FPS" })
        XCTAssertFalse(fps.isOn)
        model.activate(fps)
        XCTAssertEqual(m.values["DM_SHOW_FPS"], "1")
        XCTAssertTrue(try XCTUnwrap(model.root.flatMap(\.items).first { $0.id == "row:DM_SHOW_FPS" }).isOn)
        XCTAssertTrue(dm_game_panel_shown(), "A switch keeps the panel open")

        // A choice: its page, the ring on the choice made; a pick goes back to the row, which shows it
        let row = try XCTUnwrap(rows.first { $0.id == "row:DM_PICTURE_FIT" })
        XCTAssertEqual(row.currentOption, "Fit")
        model.activate(row)
        XCTAssertTrue(model.page.options)
        XCTAssertEqual(model.page.title, "Picture")
        XCTAssertEqual(model.focus, "row:DM_PICTURE_FIT=fit")
        model.columnsShown = GameMenuLayout.columns(model.page.sections, fit: 3, split: 1)
        model.handle(.right); model.handle(.a)   // the controller: Fill
        XCTAssertEqual(m.values["DM_PICTURE_FIT"], "fill")
        XCTAssertNil(model.page.id, "Back on the first page")
        XCTAssertEqual(model.focus, "row:DM_PICTURE_FIT", "with the ring on the row it came from")
        XCTAssertEqual(model.root.flatMap(\.items).first { $0.id == "row:DM_PICTURE_FIT" }?.currentOption, "Fill")

        // B: back a page, then closed; the menu button's hide timer starts again
        model.activate(try XCTUnwrap(model.root.flatMap(\.items).first { $0.id == "row:DM_PICTURE_FIT" }))
        model.handle(.b)
        XCTAssertNil(model.page.id)
        XCTAssertTrue(dm_game_panel_shown())
        model.handle(.b)
        XCTAssertFalse(dm_game_panel_shown())
        waitUntil("the panel leaves the game's view controller") { host.parent == nil && host.view.superview == nil }

        // A second tap opens it again, a third closes it
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(dm_game_panel_shown())
        let again = try XCTUnwrap(root.children.compactMap { $0 as? GameMenuPanelHost }.first)
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(dm_game_panel_shown())
        XCTAssertFalse(again.view.isUserInteractionEnabled, "Fading out, it takes no touch")
        waitUntil("the panel is gone") { again.parent == nil }
    }

    private static let touchList = """
    {"schema": 1, "settings": [
     {"env": "DM_TOUCH_SIZE", "kind": "choice", "section": "Controls", "label": "Touch control size", "note": "", "default": "1", "options": [["0.7", "Small"], ["0.85", "Medium"], ["1", "Large"]]},
     {"env": "DM_TOUCH_OPACITY", "kind": "choice", "section": "Controls", "label": "Touch control opacity", "note": "", "default": "1", "options": [["0.4", "Faint"], ["0.7", "Light"], ["1", "Normal"], ["1.5", "Strong"]]},
     {"env": "DM_TOUCH_HAPTICS", "kind": "toggle", "section": "Controls", "label": "Touch feedback", "note": "", "default": "1"},
     {"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0"}
    ]}
    """

    // Touch controls: the three touch rows as one row whose subtitle sums them up, opening a page of them; a choice there opens its options, a pick comes back to the page,
    // B goes back to the menu, then closes. An env file's value no option has shows as itself in the summary. DM_GAME_MENU=system: the same page as a submenu
    @MainActor
    func testTheTouchControlsRowOpensAPageOfThem() throws {
        let suite = "DuoGameMenuPanelTests.touch"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(Self.touchList.utf8))
        let m = LauncherModel(file.settings, defaults: defaults)
        gameMenuModel = m
        defer {
            gameMenuModel = nil
            _ = dm_setting_live("DM_TOUCH_SIZE", "1"); unsetenv("DM_TOUCH_SIZE")
            defaults.removePersistentDomain(forName: suite)
        }
        let hidden = dm_setting_why("DM_TOUCH_HAPTICS").map { String(cString: $0) }   // a controller (the Simulator's virtual one) hides the touch controls
        func touchRow() throws -> GameMenuItem { try XCTUnwrap(gameMenuSections().flatMap(\.items).first { $0.id == "touch" }, "One Touch controls row") }

        let ids = gameMenuSections().flatMap(\.items).map(\.id)
        XCTAssertFalse(ids.contains("row:DM_TOUCH_SIZE") || ids.contains("row:DM_TOUCH_OPACITY") || ids.contains("row:DM_TOUCH_HAPTICS"), "Not on the menu's first page: \(ids)")
        XCTAssertEqual(ids.firstIndex(of: "touch"), ids.firstIndex(of: "layout").map { $0 + 1 }, "In Controls, where the first of them was")
        var row = try touchRow()
        XCTAssertTrue(row.summary)
        XCTAssertEqual(row.subtitle, hidden ?? "Large · Normal · Feedback on")
        m.values["DM_TOUCH_SIZE"] = "0.9"   // an env file's value inside the range, no option's
        XCTAssertEqual(try touchRow().subtitle, hidden ?? "0.9 · Normal · Feedback on", "The value itself, not read as a switch")
        m.values["DM_TOUCH_SIZE"] = nil

        let model = GameMenuPanelModel(anchor: nil)
        var closed = false
        model.close = { closed = true }
        model.activate(row)
        XCTAssertEqual(model.page.id, "touch")
        XCTAssertFalse(model.page.options)
        XCTAssertEqual(model.page.title, "Touch controls")
        XCTAssertEqual(model.page.subtitle, row.subtitle)
        XCTAssertEqual(model.page.sections.flatMap(\.items).map(\.id), ["row:DM_TOUCH_SIZE", "row:DM_TOUCH_OPACITY", "row:DM_TOUCH_HAPTICS"])
        XCTAssertEqual(model.focus, "row:DM_TOUCH_SIZE")
        model.activate(try XCTUnwrap(model.page.sections.flatMap(\.items).first))
        XCTAssertTrue(model.page.options, "A choice on the page opens its options")
        XCTAssertEqual(model.page.title, "Touch control size")
        XCTAssertEqual(model.focus, "row:DM_TOUCH_SIZE=1")
        model.activate(try XCTUnwrap(model.page.sections.flatMap(\.items).first { $0.id == "row:DM_TOUCH_SIZE=0.7" }))
        XCTAssertEqual(m.values["DM_TOUCH_SIZE"], "0.7")
        XCTAssertEqual(model.page.id, "touch", "A pick comes back to the Touch controls page")
        XCTAssertEqual(model.focus, "row:DM_TOUCH_SIZE")
        row = try touchRow()
        XCTAssertEqual(row.subtitle, hidden ?? "Small · Normal · Feedback on")
        XCTAssertEqual(model.page.subtitle, row.subtitle, "The page's header follows")

        model.activate(try XCTUnwrap(model.page.sections.flatMap(\.items).first))
        model.columnsShown = GameMenuLayout.columns(model.page.sections, fit: 3, split: 1)
        model.handle(.b)
        XCTAssertEqual(model.page.id, "touch", "B: from the options back to the page")
        model.columnsShown = GameMenuLayout.columns(model.page.sections, fit: 3, split: 1)
        model.handle(.b)
        XCTAssertNil(model.page.id, "then to the menu")
        XCTAssertEqual(model.focus, "touch")
        XCTAssertFalse(closed)
        model.columnsShown = GameMenuLayout.columns(model.page.sections, fit: 3, split: 3)
        model.handle(.b)
        XCTAssertTrue(closed, "then closes")

        let menu = try XCTUnwrap(gameMenuItems().flatMap { ($0 as? UIMenu)?.children ?? [$0] }.first { $0.title == "Touch controls" } as? UIMenu, "DM_GAME_MENU=system: a submenu")
        XCTAssertEqual(menu.subtitle, row.subtitle)
        XCTAssertEqual(menu.children.map(\.title), ["Touch control size", "Touch control opacity", "Touch feedback"])
        XCTAssertEqual((menu.children.first as? UIMenu)?.options.contains(.singleSelection), true, "Each choice its own options")
    }

    @MainActor
    func testTheMenuButtonsIconSweepsFromCyanToCoral() throws {
        let (_, button) = try productionMenuButton()
        let image = try XCTUnwrap(button.image(for: .normal)?.cgImage)
        XCTAssertGreaterThanOrEqual(image.width, Int(button.bounds.width * 0.5 * button.traitCollection.displayScale), "Drawn at the screen's scale")
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var cyan = 0, coral = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 200 {
            let r = Int(px[i]), b = Int(px[i + 2])
            if b > r + 120 { cyan += 1 } else if r > b + 80 { coral += 1 }
        }
        XCTAssertGreaterThan(cyan, 10, "Cyan in the ring")
        XCTAssertGreaterThan(coral, 10, "and coral")
        // each ray is one colour or the other, none a grey blend of the two: the middle of each ray (rays run from 0.72 of the radius to the edge). The most opaque pixel of the
        // 3x3 around that point: on a small icon (the Duo's 53 px) the point can land on a diagonal ray's anti-aliased edge (alpha 193) with the ray's body one pixel inward
        var rays: [String] = []
        for i in 0..<8 {
            let a = Double(i) * .pi / 4, d = 0.84 * Double(w) / 2
            let cx = Int((Double(w) / 2 + d * cos(a)).rounded(.down)), cy = Int((Double(h) / 2 + d * sin(a)).rounded(.down))   // the bitmap's rows run down, as UIKit's y
            var o = (cy * w + cx) * 4
            for y in max(cy - 1, 0)...min(cy + 1, h - 1) {
                for x in max(cx - 1, 0)...min(cx + 1, w - 1) where px[(y * w + x) * 4 + 3] > px[o + 3] { o = (y * w + x) * 4 }
            }
            let r = Int(px[o]), b = Int(px[o + 2])
            XCTAssertGreaterThan(px[o + 3], 200, "ray \(i) is drawn at its middle")
            rays.append(b > r + 120 ? "cyan" : r > b + 80 ? "coral" : "grey (\(r), \(px[o + 1]), \(b))")
        }
        XCTAssertFalse(rays.contains { $0.hasPrefix("grey") }, "No ray is a grey blend: \(rays)")
        XCTAssertEqual(rays.filter { $0 == "cyan" }.count, 4, "Half the rays cyan, half coral: \(rays)")
    }

    @MainActor
    func testTheSystemMenuStaysBehindTheSwitch() {
        setenv("DM_GAME_MENU", "system", 1)
        let pad = dm_gamepad_view(CGRect(x: 0, y: 0, width: 844, height: 390))
        unsetenv("DM_GAME_MENU")
        let button = pad.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Menu" }
        XCTAssertNotNil(button?.menu, "DM_GAME_MENU=system: the UIMenu")
        XCTAssertEqual(button?.showsMenuAsPrimaryAction, true)
        let plain = dm_gamepad_view(CGRect(x: 0, y: 0, width: 844, height: 390)).subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Menu" }
        XCTAssertNil(plain?.menu, "Without it: the panel")
    }

    // The header's save part (gate-ui §19.8): from the game's last commit, in whole minutes, then hours
    @MainActor func testTheHeaderSaysWhenTheGameLastSaved() {
        let ns: UInt64 = 1_000_000_000, t: UInt64 = 10_000 * ns
        XCTAssertEqual(GameMenuHeaderLine.savedText(now: t, last: 0), "Not saved yet this session")
        XCTAssertEqual(GameMenuHeaderLine.savedText(now: t, last: t - 5 * ns), "Saved just now")
        XCTAssertEqual(GameMenuHeaderLine.savedText(now: t, last: t - 59 * ns), "Saved just now")
        XCTAssertEqual(GameMenuHeaderLine.savedText(now: t, last: t - 60 * ns), "Saved 1 min ago")
        XCTAssertEqual(GameMenuHeaderLine.savedText(now: t, last: t - 3599 * ns), "Saved 59 min ago")
        XCTAssertEqual(GameMenuHeaderLine.savedText(now: t, last: t - 7300 * ns), "Saved 2 h ago")
    }
    // The preset chooser in the menu (gate-ui §19.3, presets-first P7 (b)): a chip, L / R, X and Undo move the presets as on the Gate; the rows the game takes live apply at once,
    // the rest wait for the next start and the line says so; the choice is saved for the Gate. Customize holds the live preset rows and ends with Back while Custom
    private static let presetList = """
    {"schema": 1, "presets": ["battery", "balanced", "quality"], "settings": [
     {"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"]], "preset": {"battery": "30"}},
     {"env": "DM_PRESENT_UPSCALE", "kind": "choice", "section": "Game", "label": "Upscaling", "note": "", "default": "off", "options": [["off", "Off"], ["bilinear", "Bilinear"], ["metalfx", "MetalFX"]], "preset": {"quality": "metalfx"}},
     {"env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture", "note": "", "default": "fit", "options": [["fit", "Fit"], ["fill", "Fill"], ["stretch", "Stretch"]]},
     {"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Vitals", "note": "", "default": "0"}
    ]}
    """

    @MainActor
    func testThePresetChooserAppliesTheLivePartNow() throws {
        let (root, button) = try productionMenuButton()
        let suite = "DuoGameMenuPanelTests.presets"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(Self.presetList.utf8))
        unsetenv("DM_PRESET")   // not set at launch: the menu writes it (the model's launch snapshot)
        setenv("DM_FRAMEGEN", "1", 1)   // frame generation on: DM_PRESET's only reader (LauncherModel.framegenOn); without it the menu sets none (below)
        let m = LauncherModel(file.settings, defaults: defaults)
        m.takeList(file)
        gameMenuModel = m
        unsetenv("DM_FPS_TARGET"); unsetenv("DM_PRESENT_UPSCALE")
        defer {
            gameMenuModel = nil
            if dm_game_panel_shown() { dm_game_panel_close() }
            _ = dm_setting_live("DM_PRESENT_UPSCALE", "off"); unsetenv("DM_PRESENT_UPSCALE"); unsetenv("DM_FPS_TARGET"); unsetenv("DM_PRESET"); unsetenv("DM_FRAMEGEN")
            defaults.removePersistentDomain(forName: suite)
        }
        func preset() -> String? { getenv("DM_PRESET").map { String(cString: $0) } }   // what the host's frame generation reads again once a second (front_env_copy)
        button.sendActions(for: .primaryActionTriggered)
        let host = try XCTUnwrap(root.children.compactMap { $0 as? GameMenuPanelHost }.first)
        let model = host.model
        XCTAssertEqual(model.focus, "preset:balanced", "The ring starts on the chosen preset's chip")
        XCTAssertEqual(model.home.doors.map(\.id), ["door.customize", "door.more"])
        guard case .submenu(let groups) = try XCTUnwrap(model.home.doors.first).kind else { return XCTFail("Customize opens a page") }
        XCTAssertEqual(groups.flatMap(\.items).map(\.id), ["row:DM_PRESENT_UPSCALE"], "Customize: the live preset rows (Frame rate is not live: it stays on the Gate)")

        // A chip: Battery Saver. Its frame rate waits for the next start; the choice is saved for the Gate; Undo puts it back
        model.choosePreset(.battery)
        XCTAssertEqual(m.values["DM_FPS_TARGET"], "30")
        XCTAssertEqual(defaults.string(forKey: "launcher.DM_FPS_TARGET"), "30", "Saved at once, as a pick in the menu is")
        XCTAssertEqual(defaults.string(forKey: LauncherModel.presetKey), "battery", "The base is stored: the Gate shows Battery Saver next time")
        XCTAssertNil(getenv("DM_FPS_TARGET"), "Not live: the running game keeps its rate")
        XCTAssertEqual(preset(), "battery", "The preset goes into the environment at once: frame generation steps aside in Battery Saver")
        XCTAssertEqual(model.pending, ["30 fps"], "At next start: 30 fps")
        XCTAssertEqual(model.toast, "Battery Saver · at next start")
        XCTAssertTrue(model.canUndo)
        model.handle(.x)   // X while the toast shows: Undo
        XCTAssertEqual(m.values["DM_FPS_TARGET"], "60")
        XCTAssertEqual(model.pending, [])
        XCTAssertEqual(m.activePreset, .balanced)
        XCTAssertEqual(preset(), "balanced", "Undo puts the preset back in the environment too")
        XCTAssertNil(model.toast)

        // R: the next preset, Quality. Upscaling is live: into the environment and applied now
        model.handle(.r)
        XCTAssertEqual(m.activePreset, .quality)
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "metalfx")
        XCTAssertEqual(getenv("DM_PRESENT_UPSCALE").map { String(cString: $0) }, "metalfx", "A live row applies at once")
        XCTAssertEqual(model.toast, "Quality · Upscaling MetalFX")
        XCTAssertEqual(preset(), "quality")

        // A hand change on Customize: Custom (from Quality); X goes back to the base, and Customize's last row is Back while Custom
        model.activate(try XCTUnwrap(model.home.doors.first))
        XCTAssertEqual(model.page.title, "Customize")
        let row = try XCTUnwrap(model.page.sections.flatMap(\.items).first { $0.id == "row:DM_PRESENT_UPSCALE" })
        model.activate(row)
        model.activate(try XCTUnwrap(model.page.sections.flatMap(\.items).first { $0.id == "row:DM_PRESENT_UPSCALE=bilinear" }))
        XCTAssertTrue(m.isCustom)
        XCTAssertEqual(m.presetLabel, "Custom (from Quality)")
        XCTAssertEqual(preset(), "custom", "A hand change to a preset row: Custom")
        XCTAssertEqual(model.page.sections.last?.items.last?.title, "Back to Quality", "Customize ends with Back while Custom")
        model.handle(.x)
        XCTAssertFalse(m.isCustom)
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "metalfx")
        XCTAssertEqual(preset(), "quality", "Back to the base")

        // The first page's ring: zones side by side, along a line into the next zone, up and down in a zone
        model.back()
        model.homeZones = [[["preset:battery", "preset:balanced"], ["preset:quality"]], [["row:DM_PICTURE_FIT", "row:DM_SHOW_FPS", "layout"], ["door.customize", "door.more"]]]
        model.focus = "preset:balanced"
        model.handle(.right); XCTAssertEqual(model.focus, "row:DM_PICTURE_FIT")
        model.handle(.down); XCTAssertEqual(model.focus, "door.customize")
        model.handle(.left); XCTAssertEqual(model.focus, "preset:quality")
        model.handle(.up); XCTAssertEqual(model.focus, "preset:battery")
        model.handle(.a); XCTAssertEqual(m.activePreset, .battery)
        XCTAssertEqual(preset(), "battery")
        // Frame generation off (no DM_FRAMEGEN): a preset change in game sets no DM_PRESET, as before frame generation
        unsetenv("DM_FRAMEGEN")
        model.choosePreset(.quality)
        XCTAssertEqual(m.activePreset, .quality)
        XCTAssertEqual(preset(), "battery", "Without frame generation the menu leaves DM_PRESET alone")
        model.handle(.b)
        XCTAssertFalse(dm_game_panel_shown(), "B on the first page closes")
    }

    func testTheFirstPagesStepsAcrossZones() {
        let zones = [[["a", "b"], ["c"]], [["t1", "t2", "t3"], ["t4"], ["d1", "d2"]]]
        XCTAssertEqual(GameMenuLayout.homeStep(nil, 0, 0, in: zones), "a")
        XCTAssertEqual(GameMenuLayout.homeStep("b", 1, 0, in: zones), "t1")
        XCTAssertEqual(GameMenuLayout.homeStep("c", 1, 0, in: zones), "t4")
        XCTAssertEqual(GameMenuLayout.homeStep("t1", -1, 0, in: zones), "b", "Back into the chooser at the same line, its last item")
        XCTAssertEqual(GameMenuLayout.homeStep("d2", -1, 0, in: zones), "d1")
        XCTAssertEqual(GameMenuLayout.homeStep("d1", -1, 0, in: zones), "c", "A line past the chooser's last: its last line")
        XCTAssertEqual(GameMenuLayout.homeStep("t3", 0, 1, in: zones), "t4", "Down keeps the column where the next line has it")
        XCTAssertEqual(GameMenuLayout.homeStep("d1", 0, 1, in: zones), "d1", "No wrap")
        XCTAssertEqual(GameMenuLayout.homeStep("t3", 1, 0, in: zones), "t3", "No zone further right")
        XCTAssertEqual(GameMenuLayout.homeStep("c", 0, 0, in: [[["c"]], []]), "c")
    }

    // The menu's dim light set (gate-ui §11a.5): its slab, tiles and chosen chip resolve to the dimmer values in light, the Gate's dark ones in dark
    func testTheMenuTakesTheDimLightSet() {
        func hex(_ c: Color, _ style: UIUserInterfaceStyle) -> UInt32 {
            let ui = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
        }
        XCTAssertEqual(hex(MenuColor.slab, .light), 0xBDBDC3)
        XCTAssertEqual(hex(MenuColor.tile, .light), 0xCACACF)
        XCTAssertEqual(hex(MenuColor.chosen, .light), 0xC29A91)
        XCTAssertEqual(hex(MenuColor.bar, .light), 0x743C35)
        XCTAssertEqual(hex(MenuColor.slab, .dark), 0x2A2A2D)
        XCTAssertEqual(hex(MenuColor.chosen, .dark), 0x9CD1E2)
    }
}
