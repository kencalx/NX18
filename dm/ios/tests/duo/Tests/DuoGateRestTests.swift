// The rest of the Gate (gate-ui §16 A9a-2b steps 4, 5, 9): glass and its fallbacks, the idle rules for the rails and the pad poll, VoiceOver's values and the W13 line
import GameController
import SwiftUI
import UIKit
import XCTest
@testable import DuoHarness

final class DuoGateRestTests: XCTestCase {
    // Glass: off under Low Power Mode and DM_UI_GLASS=0, off from a serious thermal state, and back only after 60 s at fair or lower (§11's hysteresis)
    func testGlassPolicyFallbacksAndThermalHysteresis() {
        var hot = false; var calm: Date?
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertTrue(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .nominal, hot: &hot, calmSince: &calm, now: t0))
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: true, lowPower: false, thermal: .nominal, hot: &hot, calmSince: &calm, now: t0), "DM_UI_GLASS=0")
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: false, lowPower: true, thermal: .nominal, hot: &hot, calmSince: &calm, now: t0), "Low Power Mode")
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .serious, hot: &hot, calmSince: &calm, now: t0), "serious")
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .fair, hot: &hot, calmSince: &calm, now: t0.addingTimeInterval(1)), "calm, but not for 60 s yet")
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .fair, hot: &hot, calmSince: &calm, now: t0.addingTimeInterval(59)))
        XCTAssertTrue(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .fair, hot: &hot, calmSince: &calm, now: t0.addingTimeInterval(62)), "back after 60 s at fair")
        XCTAssertFalse(hot)
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .critical, hot: &hot, calmSince: &calm, now: t0.addingTimeInterval(70)))
        XCTAssertFalse(NX18GlassPolicy.decide(forcedOff: false, lowPower: false, thermal: .nominal, hot: &hot, calmSince: &calm, now: t0.addingTimeInterval(71)), "the hold starts again")
    }

    // The rails run one cycle, then rest on the still line; an input runs one more, at most one queued (GW19). The cycle ends at the start's picture, so the rest has no jump
    @MainActor
    func testRailsRunOneCycleThenRestAndAPulseRunsOneMore() throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow))
        let rails = NX18RailsFlowView(axis: .vertical)
        rails.frame = CGRect(x: 0, y: 0, width: 2.5, height: 300)
        window.addSubview(rails); rails.layoutIfNeeded()
        let slide = try XCTUnwrap(rails.layer.sublayers?.first?.animation(forKey: NX18RailsFlowView.key) as? CABasicAnimation)
        XCTAssertEqual(slide.repeatCount, 1, "one cycle, not endless")
        XCTAssertTrue(slide.isRemovedOnCompletion, "at rest nothing stays on the render server")
        XCTAssertEqual(abs((slide.toValue as! CGFloat) - (slide.fromValue as! CGFloat)), 600, accuracy: 0.5, "two lengths: the end looks as the start")
        rails.layer.sublayers?.first?.removeAllAnimations()   // as at the cycle's end
        XCTAssertFalse(rails.isFlowing, "at rest")
        NX18RailsIdle.pulse()
        XCTAssertTrue(rails.isFlowing, "an input runs one more cycle")
        rails.removeFromSuperview()
    }

    // The Gate's pad loop sleeps when nothing changes (GW20): at once with no controller connected, about 2 s after the last change with one (a Simulator may
    // have one connected); it does not poll every 16 ms then, and the wait ends with the screen
    @MainActor
    func testPadLoopSleepsWhenInputIsIdle() async throws {
        let pad = LauncherGamepad()
        let task = Task { await pad.run { _ in } }
        try await Task.sleep(for: .milliseconds(2800))
        XCTAssertTrue(pad.waiting, "asleep: no controller, or no input change for 2 s")
        XCTAssertEqual(pad.idleWaits, 1, "one wait, no 16 ms loop")
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(pad.waiting, "the wait ends with the screen")
    }

    // VoiceOver: a row's value says "changed from Balanced" where the dot shows; W13 names the first power-costing quick tile while Battery Saver is lit
    @MainActor
    func testChangedFromValueAndBatterySaverHintLine() throws {
        let json = #"{"presets": ["battery", "balanced", "quality"], "moves": {"battery": ["DM_FPS_TARGET"]}, "settings": ["#
            + #"{"env": "DM_OPMODE", "kind": "choice", "section": "Game", "label": "Console mode", "note": "", "default": "1", "options": [["1", "Docked"], ["0", "Handheld"]]},"#
            + #"{"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"]], "preset": {"battery": "30"}}]}"#
        let file = try JSONDecoder().decode(SettingsFile.self, from: Data(json.utf8))
        let m = LauncherModel(file.settings, defaults: UserDefaults(suiteName: "duo-rest-\(UUID().uuidString)")!)
        m.takeList(file)
        let fps = try XCTUnwrap(m.gateRow("DM_FPS_TARGET"))
        XCTAssertFalse(m.changedFromBase(fps))
        m.values["DM_FPS_TARGET"] = "30"
        XCTAssertTrue(m.changedFromBase(fps), "the dot, and VoiceOver's \"changed from Balanced\"")
        m.applyPreset(.battery)
        XCTAssertEqual(m.activePreset, .battery)
        m.values["DM_OPMODE"] = "1"
        XCTAssertEqual(m.settings.first { $0.env == "DM_OPMODE" }.map { m.shown($0) }, "1", "Docked while Battery Saver is lit: W13's line is \"Handheld mode saves more\"")
    }
}
