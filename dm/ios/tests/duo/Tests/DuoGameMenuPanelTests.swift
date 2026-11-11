import UIKit
import XCTest
@testable import DuoHarness

// The in-game menu as NX 18's panel (GameMenuPanel.swift) on the production root view controller: the menu button opens it over the game with the UIMenu's rows, a pick
// takes effect and the panel stays, a choice opens as a page and a pick there comes back, B goes back and closes, the controllers wait meanwhile; how its columns are cut;
// the menu button's cyan-to-coral icon; and DM_GAME_MENU=system keeping the UIMenu
final class DuoGameMenuPanelTests: XCTestCase {
    private static let list = """
    {"schema": 1, "settings": [
     {"env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture", "note": "", "default": "fit", "options": [["fit", "Fit"], ["fill", "Fill"], ["stretch", "Stretch"]]},
     {"env": "DM_SHOW_FPS", "kind": "toggle", "section": "Game", "label": "Frame-rate counter", "note": "", "default": "0"}
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
        XCTAssertEqual(model.focus, "layout", "The controller's ring starts on the first row")

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
}
