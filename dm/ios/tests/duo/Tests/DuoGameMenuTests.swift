import UIKit
import XCTest
@testable import DuoHarness

// The in-game menu's rows as GameMenu.swift builds them from a launcher model, on the production root view controller: a row the front end holds is greyed with its reason, an
// option a launcher rule greys cannot be picked, and the running game's note (front_ios.m dm_setting_why, fed here by the harness's present stub) is the row's subtitle, before
// a launcher hint, which the game's word that the choice works (dm_setting_working) leaves out
final class DuoGameMenuTests: XCTestCase {
    private static let list = """
    {"schema": 1, "settings": [
     {"env": "DM_PRESENT_UPSCALE", "kind": "choice", "section": "Game", "label": "Upscaling", "note": "", "default": "off",
      "options": [["off", "Standard"], ["metalfx", "MetalFX"]],
      "inactive": [{"option": "metalfx", "when": ["mfx:none"], "why": "This device has no MetalFX scaler"}],
      "hint": [{"option": "metalfx", "when": ["DM_PICTURE_FIT=stretch"], "why": "With Stretch, only when the game draws a smaller picture"}]},
     {"env": "DM_PICTURE_FIT", "kind": "choice", "section": "Game", "label": "Picture", "note": "", "default": "fit",
      "options": [["fit", "Fit"], ["fill", "Fill"], ["stretch", "Stretch"]],
      "inactive": [{"when": ["DM_MOD_ULTRAWIDE=1", "screen>=1.85"], "why": "Ultrawide always stretches the picture"}]},
     {"env": "DM_MOD_ULTRAWIDE", "kind": "toggle", "section": "Game", "label": "Ultrawide", "note": "", "default": "0"}
    ]}
    """

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
            duo_harness_set_present_why(0, 0, 0)
            defaults.removePersistentDomain(forName: suite)
        }

        // Ultrawide holds Stretch: Picture is shown, greyed, with the reason; the saved choice is not touched
        m.values["DM_PICTURE_FIT"] = "fill"
        root.setValue(true, forKey: "ultrawideStretch")
        let picture = try XCTUnwrap(row("Picture", in: gameMenuItems()), "The Picture row is shown while Ultrawide holds Stretch")
        XCTAssertEqual(picture.subtitle, "Ultrawide always stretches the picture")
        let options = picture.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(options.count, 3)
        XCTAssertTrue(options.allSatisfy { $0.attributes.contains(.disabled) }, "No option can be picked")
        XCTAssertEqual(options.first { $0.state == .on }?.title, "Fill", "The saved choice is still the one ticked")
        XCTAssertEqual(m.values["DM_PICTURE_FIT"], "fill")
        XCTAssertNil(row("Ultrawide", in: gameMenuItems()), "Ultrawide needs the next start: not in the menu")
        root.setValue(false, forKey: "ultrawideStretch")
        let free = try XCTUnwrap(row("Picture", in: gameMenuItems()))
        XCTAssertNil(free.subtitle)
        XCTAssertFalse(free.children.compactMap { $0 as? UIAction }.contains { $0.attributes.contains(.disabled) })

        // A launcher hint on MetalFX under Stretch: both options stay selectable, and with Standard chosen the row has nothing to say
        m.values["DM_PICTURE_FIT"] = "stretch"
        var upscaling = try XCTUnwrap(row("Upscaling", in: gameMenuItems()))
        var actions = upscaling.children.compactMap { $0 as? UIAction }
        XCTAssertFalse(actions.contains { $0.attributes.contains(.disabled) }, "A hint greys nothing")
        XCTAssertNil(upscaling.subtitle, "Standard chosen: nothing to say about the row")

        // MetalFX chosen: the running game's note comes first, and the row stays selectable
        m.values["DM_PRESENT_UPSCALE"] = "metalfx"
        duo_harness_set_present_why(Int32(DM_FX_STRETCHED), 0, 0)
        upscaling = try XCTUnwrap(row("Upscaling", in: gameMenuItems()))
        XCTAssertEqual(upscaling.subtitle, "Not upscaling: picture is stretched")
        actions = upscaling.children.compactMap { $0 as? UIAction }
        XCTAssertFalse(try XCTUnwrap(actions.first { $0.title == "Standard" }).attributes.contains(.disabled), "Standard can still be picked")
        // Without a note from the game (before the first present), the launcher's hint for the choice made
        duo_harness_set_present_why(0, 0, 0)
        XCTAssertEqual(row("Upscaling", in: gameMenuItems())?.subtitle, "With Stretch, only when the game draws a smaller picture")
        // MetalFX upscaled at the last present (a crop smaller than its texture): the hint, which says it may not, is left out
        duo_harness_set_present_why(Int32(DM_FX_UPSCALED), 0, 0)
        XCTAssertNil(row("Upscaling", in: gameMenuItems())?.subtitle, "MetalFX working: no note")
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "metalfx", "A note changes no choice")

        // A launcher rule greys one option: MetalFX on a device without the scaler. Standard stays selectable
        duo_harness_set_present_why(0, 0, 0)
        m.values["DM_PRESENT_UPSCALE"] = "off"; m.values["DM_PICTURE_FIT"] = "fit"
        m.facts = DeviceFacts(metalFX: false)
        actions = try XCTUnwrap(row("Upscaling", in: gameMenuItems())).children.compactMap { $0 as? UIAction }
        let metalfx = try XCTUnwrap(actions.first { $0.title == "MetalFX" }), standard = try XCTUnwrap(actions.first { $0.title == "Standard" })
        XCTAssertTrue(metalfx.attributes.contains(.disabled))
        XCTAssertEqual(metalfx.subtitle, "This device has no MetalFX scaler")
        XCTAssertFalse(standard.attributes.contains(.disabled))
        XCTAssertFalse(m.choose(try XCTUnwrap(m.settings.first { $0.env == "DM_PRESENT_UPSCALE" }), "metalfx"), "The model refuses the greyed option as well")
        XCTAssertEqual(m.values["DM_PRESENT_UPSCALE"], "off")
    }
}
