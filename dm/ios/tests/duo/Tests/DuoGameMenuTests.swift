import UIKit
import XCTest
@testable import DuoHarness

// The in-game menu's rows as GameMenu.swift builds them from a launcher model, on the production root view controller: a row the front end holds is greyed with its reason, an
// option a launcher rule greys cannot be picked (MetalFX as soon as Picture is set to Stretch in the menu, and back with Fit), and the running game's note (front_ios.m
// dm_setting_why, fed here by the harness's present stub) is the row's subtitle, before a launcher hint, which the game's word that the choice works (dm_setting_working) leaves out
final class DuoGameMenuTests: XCTestCase {
    private static let list = """
    {"schema": 1, "settings": [
     {"env": "DM_PRESENT_UPSCALE", "kind": "choice", "section": "Game", "label": "Upscaling", "note": "", "default": "off",
      "options": [["off", "Standard"], ["metalfx", "MetalFX"]],
      "inactive": [{"option": "metalfx", "when": ["mfx:none"], "why": "This device has no MetalFX scaler"},
                   {"option": "metalfx", "when": ["DM_PICTURE_FIT=stretch", "tv:none", "window>=1.7956"], "why": "Not with Stretch: pick Fit or Fill"}],
      "hint": [{"option": "metalfx", "when": ["DM_MOD_ULTRAWIDE=1", "screen>=1.85", "tv:none"], "why": "With Ultrawide, only when the game draws a smaller picture"}]},
     {"env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture", "note": "", "default": "fit",
      "options": [["fit", "Fit"], ["fill", "Fill"], ["stretch", "Stretch"]],
      "inactive": [{"when": ["DM_MOD_ULTRAWIDE=1", "screen>=1.85"], "why": "Ultrawide always stretches the picture"}],
      "shows": [{"option": "stretch", "when": ["DM_MOD_ULTRAWIDE=1", "screen>=1.85"]}]},
     {"env": "DM_MOD_ULTRAWIDE", "kind": "toggle", "section": "Game", "label": "Ultrawide", "note": "", "default": "0"}
    ]}
    """

    // A row or option of the menu as GameMenu.swift builds it, by its id, for its pick (the panel's and the UIMenu's perform)
    @MainActor private func item(_ id: String, in sections: [GameMenuSection]) -> GameMenuItem? {
        for s in sections { for i in s.items {
            if i.id == id { return i }
            if case .choice(let o) = i.kind, let f = o.first(where: { $0.id == id }) { return f }
            if case .submenu(let inner) = i.kind, let f = item(id, in: inner) { return f }
        } }
        return nil
    }

    private func row(_ title: String, in elements: [UIMenuElement]) -> UIMenu? {
        for e in elements {
            guard let m = e as? UIMenu else { continue }
            if m.title == title { return m }
            if let found = row(title, in: m.children) { return found }
        }
        return nil
    }

    @MainActor
    func testInGameMenuRowsShowWhyTheyDoNothing() throws {
        let root = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController)
        let suite = "DuoGameMenuTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(Self.list.utf8))
        let m = LauncherModel(file.settings, defaults: defaults)
        gameMenuModel = m
        defer {
            gameMenuModel = nil
            root.setValue(false, forKey: "ultrawideStretch")
            _ = dm_setting_live("DM_PICTURE_FIT", "fit"); unsetenv("DM_PICTURE_FIT"); unsetenv("DM_PRESENT_UPSCALE")   // the picks below went into the environment and the layout
            duo_harness_set_present_why(0, 0, 0)
            defaults.removePersistentDomain(forName: suite)
        }

        // Ultrawide holds Stretch: Picture is shown, greyed, with the reason, and ticks the Stretch the game has; the saved choice is not touched
        m.values["DM_PICTURE_FIT"] = "fill"
        root.setValue(true, forKey: "ultrawideStretch")
        let picture = try XCTUnwrap(row("Picture", in: gameMenuItems()), "The Picture row is shown while Ultrawide holds Stretch")
        XCTAssertEqual(picture.subtitle, "Ultrawide always stretches the picture")
        let options = picture.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(options.count, 3)
        XCTAssertTrue(options.allSatisfy { $0.attributes.contains(.disabled) }, "No option can be picked")
        XCTAssertEqual(options.filter { $0.state == .on }.map(\.title), ["Stretch"], "The value the game is held at is the one ticked, not the saved Fill")
        XCTAssertEqual(m.values["DM_PICTURE_FIT"], "fill", "The saved choice stays")
        XCTAssertEqual(String(cString: try XCTUnwrap(dm_setting_held_value("DM_PICTURE_FIT"))), "stretch")
        XCTAssertNil(dm_setting_held_value("DM_OPMODE"), "Only Picture is held")
        XCTAssertNil(row("Ultrawide", in: gameMenuItems()), "Ultrawide needs the next start: not in the menu")
        root.setValue(false, forKey: "ultrawideStretch")
        let free = try XCTUnwrap(row("Picture", in: gameMenuItems()))
        XCTAssertNil(free.subtitle)
        XCTAssertFalse(free.children.compactMap { $0 as? UIAction }.contains { $0.attributes.contains(.disabled) })
        XCTAssertEqual(free.children.compactMap { $0 as? UIAction }.first { $0.state == .on }?.title, "Fill", "Ultrawide gone: the saved choice is ticked again")
        XCTAssertNil(dm_setting_held_value("DM_PICTURE_FIT"))
        // The launcher's own rule (the list's shows) gives the same where the front end holds nothing, as the settings screen draws it: greyed, Stretch ticked, Fill saved
        m.values["DM_MOD_ULTRAWIDE"] = "1"; m.facts = DeviceFacts(kind: .iphone, screen: 2.17)
        let ruled = try XCTUnwrap(row("Picture", in: gameMenuItems()))
        XCTAssertEqual(ruled.subtitle, "Ultrawide always stretches the picture")
        XCTAssertEqual(ruled.children.compactMap { $0 as? UIAction }.filter { $0.state == .on }.map(\.title), ["Stretch"])
        XCTAssertTrue(ruled.children.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) })
        let pictureRow = try XCTUnwrap(m.settings.first { $0.env == "DM_PICTURE_FIT" })
        XCTAssertEqual(m.shown(pictureRow), "stretch")
        XCTAssertFalse(m.choose(pictureRow, "fit"), "A greyed row refuses a pick")
        XCTAssertEqual(m.values["DM_PICTURE_FIT"], "fill")
        m.values["DM_MOD_ULTRAWIDE"] = "0"; m.facts = DeviceFacts()

        // MetalFX under Stretch on an iPhone (its window 2.17:1, the picture 16:9): Picture set to Stretch in the menu greys MetalFX at once, before any present, with the reason
        // under it; Standard stays selectable, and with Standard chosen the row has nothing to say. Fit gives MetalFX back
        let notStretch = "Not with Stretch: pick Fit or Fill"
        m.facts = DeviceFacts(kind: .iphone, screen: 2.17, window: 2.17, tv: false, metalFX: true)
        m.values["DM_PICTURE_FIT"] = "fit"
        duo_harness_set_present_why(Int32(DM_FX_UPSCALED), 0, 0)   // the last present, in Fit, upscaled
        func upscalingOptions() throws -> (row: UIMenu, metalfx: UIAction, standard: UIAction) {
            let r = try XCTUnwrap(row("Upscaling", in: gameMenuItems()))
            let a = r.children.compactMap { $0 as? UIAction }
            return (r, try XCTUnwrap(a.first { $0.title == "MetalFX" }), try XCTUnwrap(a.first { $0.title == "Standard" }))
        }
        XCTAssertFalse(try upscalingOptions().metalfx.attributes.contains(.disabled), "Fit: MetalFX can be picked")
        try XCTUnwrap(item("row:DM_PICTURE_FIT=stretch", in: gameMenuSections())?.perform)(nil)   // the menu's pick: saved, into the environment, the layout told
        XCTAssertEqual(m.values["DM_PICTURE_FIT"], "stretch")
        var u = try upscalingOptions()
        XCTAssertTrue(u.metalfx.attributes.contains(.disabled), "Stretch picked: MetalFX greyed at once")
        XCTAssertEqual(u.metalfx.subtitle, notStretch)
        XCTAssertFalse(u.standard.attributes.contains(.disabled), "Standard can still be picked")
        XCTAssertNil(u.row.subtitle, "Standard chosen: nothing to say about the row")
        XCTAssertFalse(m.choose(try XCTUnwrap(m.settings.first { $0.env == "DM_PRESENT_UPSCALE" }), "metalfx"), "the model refuses MetalFX under Stretch")
        try XCTUnwrap(item("row:DM_PICTURE_FIT=fit", in: gameMenuSections())?.perform)(nil)
        u = try upscalingOptions()
        XCTAssertFalse(u.metalfx.attributes.contains(.disabled), "Fit picked: MetalFX back")
        XCTAssertNil(u.metalfx.subtitle)

        // MetalFX saved, then Stretch picked: the option chosen is shown ticked and greyed, and the row says why at once, before the next present has told (it still says it
        // upscaled, in Fit), and after it too, in place of the game's own note. The saved choice stays, and comes back with Fit
        m.values["DM_PRESENT_UPSCALE"] = "metalfx"
        try XCTUnwrap(item("row:DM_PICTURE_FIT=stretch", in: gameMenuSections())?.perform)(nil)
        u = try upscalingOptions()
        XCTAssertEqual(u.row.subtitle, notStretch, "the rule's reason, though the last present upscaled")
        XCTAssertEqual(u.metalfx.state, .on, "MetalFX is the choice shown")
        XCTAssertTrue(u.metalfx.attributes.contains(.disabled), "and greyed")
        XCTAssertFalse(u.standard.attributes.contains(.disabled))
        duo_harness_set_present_why(Int32(DM_FX_STRETCHED), 0, 0)
        XCTAssertEqual(try upscalingOptions().row.subtitle, notStretch, "the next present's note says the same, in the settings screen's words")
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "metalfx", "A note changes no choice")
        m.facts.tv = true
        duo_harness_set_present_why(Int32(DM_FX_UPSCALED), 0, 0)
        u = try upscalingOptions()
        XCTAssertFalse(u.metalfx.attributes.contains(.disabled), "a TV shows the picture whole: MetalFX works under Stretch")
        XCTAssertNil(u.row.subtitle)
        m.facts.tv = false
        try XCTUnwrap(item("row:DM_PICTURE_FIT=fit", in: gameMenuSections())?.perform)(nil)
        u = try upscalingOptions()
        XCTAssertFalse(u.metalfx.attributes.contains(.disabled)); XCTAssertNil(u.row.subtitle)
        XCTAssertEqual(u.metalfx.state, .on, "Fit: the saved MetalFX in force again")

        // Ultrawide (Picture saved as Fit): a hint, not a greying. The running game's note comes first, and the row stays selectable
        m.values["DM_MOD_ULTRAWIDE"] = "1"
        duo_harness_set_present_why(Int32(DM_FX_STRETCHED), 0, 0)
        u = try upscalingOptions()
        XCTAssertEqual(u.row.subtitle, "Not upscaling: picture is stretched")
        XCTAssertFalse(u.standard.attributes.contains(.disabled) || u.metalfx.attributes.contains(.disabled), "a hint greys nothing")
        // Without a note from the game (before the first present), the launcher's hint for the choice made
        duo_harness_set_present_why(0, 0, 0)
        XCTAssertEqual(row("Upscaling", in: gameMenuItems())?.subtitle, "With Ultrawide, only when the game draws a smaller picture")
        // MetalFX upscaled at the last present (a crop smaller than its texture): the hint, which says it may not, is left out
        duo_harness_set_present_why(Int32(DM_FX_UPSCALED), 0, 0)
        XCTAssertNil(row("Upscaling", in: gameMenuItems())?.subtitle, "MetalFX working: no note")
        m.values["DM_MOD_ULTRAWIDE"] = "0"; m.facts = DeviceFacts()

        // A launcher rule greys one option: MetalFX on a device without the scaler. Standard stays selectable
        duo_harness_set_present_why(0, 0, 0)
        m.values["DM_PRESENT_UPSCALE"] = "off"; m.values["DM_PICTURE_FIT"] = "fit"
        m.facts = DeviceFacts(metalFX: false)
        let actions = try XCTUnwrap(row("Upscaling", in: gameMenuItems())).children.compactMap { $0 as? UIAction }
        let metalfx = try XCTUnwrap(actions.first { $0.title == "MetalFX" }), standard = try XCTUnwrap(actions.first { $0.title == "Standard" })
        XCTAssertTrue(metalfx.attributes.contains(.disabled))
        XCTAssertEqual(metalfx.subtitle, "This device has no MetalFX scaler")
        XCTAssertFalse(standard.attributes.contains(.disabled))
        XCTAssertFalse(m.choose(try XCTUnwrap(m.settings.first { $0.env == "DM_PRESENT_UPSCALE" }), "metalfx"), "The model refuses the greyed option as well")
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "off")
    }
}
