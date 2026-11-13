// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept; the rules grey, explain and hide rows as the values and the device say, and
// leave every value as it is. Arguments: the iOS and the Mac launcher.json of Breath of the Wild, and the iOS one of Super Mario Bros. Wonder (settings.py, GFXAPI=nvn; the iOS
// lists with the Ultrawide mod)
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        let file = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let suite = "nxnative.launcher-test." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("1", forKey: "launcher.DM_PRESENT_SNAP")   // stored by the old launcher, equal to the default
        d.set("30", forKey: "launcher.DM_FPS_TARGET")    // a changed game setting
        d.set("0", forKey: "launcher.DM_NVN_ENC_THREAD")  // a changed performance setting
        d.set("1", forKey: "launcher.DM_FPS_HOLD")       // a value the toggle does not take (on / off): the default
        d.set("0", forKey: "launcher.DM_PSO_MTL4")       // a retired switch (Metal 4 pipelines are the only path): forgotten
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1); setenv("DM_METAL_HUD", "1", 1)   // set by Documents/env.txt
        let m = LauncherModel(file.settings, defaults: d)
        expect(d.object(forKey: "launcher.DM_PSO_MTL4") == nil && m.values["DM_PSO_MTL4"] != "0", "a retired saved choice is forgotten and not used")
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid", "0x1p-1", "0X1", " 0.75"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite, out-of-range, hex and padded values, as launcher.c does")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_NVN_ENC_THREAD"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_NVN_ENC_THREAD") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_NVN_ENC_THREAD")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        m.reset()
        expect(m.values["DM_NVN_ENC_THREAD"] == "1" && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset shows the defaults")
        expect(d.string(forKey: "launcher.DM_NVN_ENC_THREAD") == "0" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "Reset alone forgets nothing: Quit after it keeps the choices")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.changed, "Reset leaves the env file's value; nothing left to reset")
        m.apply()
        expect(d.string(forKey: "launcher.DM_NVN_ENC_THREAD") == nil && d.string(forKey: "launcher.DM_FPS_TARGET") == nil, "Play after Reset forgets the choices")
        d.set(30, forKey: "launcher.DM_FPS_TARGET"); d.set(false, forKey: "launcher.DM_RUMBLE")   // a number and a boolean, as defaults write -int / -bool stores them
        let typed = LauncherModel(file.settings, defaults: d)
        expect(typed.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def && typed.values["DM_RUMBLE"] == "1", "a saved value that is not a string is ignored, as launcher.c ignores it")
        d.removeObject(forKey: "launcher.DM_FPS_TARGET"); d.removeObject(forKey: "launcher.DM_RUMBLE")
        // Sub-settings: a row with "needs" is drawn only while the setting it names has that value
        m.values["DM_RUMBLE"] = "1"
        expect(m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE_GAIN" }, "a sub-setting is drawn while its setting is on")
        m.values["DM_RUMBLE"] = "0"
        expect(!m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE_GAIN" }, "a sub-setting is hidden while its setting is off")
        expect(m.rows(in: "Controls").contains { $0.env == "DM_RUMBLE" }, "the setting it depends on stays drawn")
        m.values["DM_RUMBLE"] = "1"
        // DM_LAUNCHER=0 skips the screen, not the saved choices; DM_SAVED_CHOICES=0 ignores them and leaves them stored
        let fps = file.settings.first { $0.env == "DM_FPS_TARGET" }!
        d.set("30", forKey: "launcher.DM_FPS_TARGET"); unsetenv("DM_FPS_TARGET")
        LauncherModel(file.settings, defaults: d).applySaved()
        expect(String(cString: getenv("DM_FPS_TARGET")) == "30" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "without the screen, a saved choice goes into the environment and stays saved")
        setenv("DM_SAVED_CHOICES", "0", 1); unsetenv("DM_FPS_TARGET")
        let plain = LauncherModel(file.settings, defaults: d)
        expect(plain.values["DM_FPS_TARGET"] == fps.def, "DM_SAVED_CHOICES=0 starts from the defaults")
        plain.applySaved()
        expect(getenv("DM_FPS_TARGET") == nil, "DM_SAVED_CHOICES=0: nothing saved goes into the environment")
        plain.apply()
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Play uses the screen's values and leaves the saved choices")
        plain.reset()
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Reset leaves the saved choices too")
        unsetenv("DM_SAVED_CHOICES")
        // The Mac window's list (second argument): Basic first, then Advanced in the list's sections; Display mode; the render scale in pixels; values set at launch are fixed
        let mac = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FULLSCREEN"); unsetenv("DM_OPMODE")
        let mm = LauncherModel(mac.settings, defaults: d)
        expect(mm.sections(basic: true) == ["Game", "Controls"] && mm.sections(basic: false) == ["Game", "Controls", "Performance"], "Basic and Advanced keep the list's sections")
        expect(mm.rows(in: "Game", basic: true).map(\.env) == ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_OPMODE", "DM_LANG", "DM_FULLSCREEN"], "Basic rows in the list's order")
        expect(!file.settings.contains { $0.env == "DM_FULLSCREEN" } && mm.values["DM_FULLSCREEN"] == "0", "Display mode is the Mac's, Window by default")
        mm.values["DM_FULLSCREEN"] = "1"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "1" && d.string(forKey: "launcher.DM_FULLSCREEN") == "1", "Fullscreen goes into the environment and is saved")
        mm.values["DM_FULLSCREEN"] = "0"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "0" && d.string(forKey: "launcher.DM_FULLSCREEN") == nil, "Window is the default: set to 0, not saved")
        let macScale = mac.settings.first { $0.env == "DM_RENDER_SCALE" }!
        mm.values["DM_OPMODE"] = "1"
        expect(mm.rangeLabel(macScale, 1) == "1600 × 900 (100 %)" && mm.rangeLabel(macScale, 0.5) == "800 × 450 (50 %)", "docked size in pixels at 1.0 and 0.5")
        mm.values["DM_OPMODE"] = "0"
        expect(mm.rangeLabel(macScale, 0.75) == "960 × 540 (75 %)", "handheld size in pixels")
        let plainScale = try! JSONDecoder().decode(Setting.self, from: Data(#"{"env":"DM_X","kind":"range","label":"X","note":"","default":"1.0","min":0.5,"max":1.0,"step":0.05,"level":"expert"}"#.utf8))
        expect(mm.rangeLabel(plainScale, 0.5) == "50 %" && !plainScale.basic, "no base size: the percentage; an unknown level decodes as Advanced")
        d.set("1", forKey: "launcher.DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "DM_OPMODE", 1); setenv("DM_OPMODE", "0", 1)   // a front end's launch override over a saved choice
        let launched = LauncherModel(mac.settings, defaults: d)
        expect(launched.values["DM_OPMODE"] == "0" && launched.fixed.contains("DM_OPMODE") && launched.fromLaunch.contains("DM_OPMODE"), "a variable set at launch is shown fixed, over the saved choice")
        launched.apply()
        expect(String(cString: getenv("DM_OPMODE")) == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Play keeps the launch value and leaves the saved choice")
        launched.reset(); launched.apply()
        expect(launched.values["DM_OPMODE"] == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Reset then Play keeps the saved choice of a setting fixed at launch")
        unsetenv("DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "", 1); d.removeObject(forKey: "launcher.DM_OPMODE")
        // The cloud-save dialog's answers name the cloud's save (save_sync.c read_choice), whichever side the player keeps
        let lh = String(repeating: "a", count: 32), ch = String(repeating: "b", count: 32)
        let both = SaveSyncReport(line: "sync=1 cloud=1 local=\(lh) saved=1 files=1 size=1 chash=\(ch) csaved=2 cfiles=1 csize=1 cdevice=iPhone17,1 sametitle=1 conflict=1 pull=0")!
        expect(SaveSyncReport.step(both) == .choose && both.localChoice == "local:" + ch && both.cloudChoice == "cloud:" + ch, "both changed: local:<cloud's hash> and cloud:<cloud's hash>")
        let none = SaveSyncReport(line: "sync=1 cloud=0 local=\(lh) saved=1 files=1 size=1 chash=- csaved=0 cfiles=0 csize=0 cdevice=- sametitle=1 conflict=0 pull=0")!
        expect(none.localChoice == "local:none", "no cloud save: local:none")
        let wonder = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        failed += checkRules(ios: file.settings, mac: mac.settings, wonder: wonder.settings, defaults: d)
        failed += checkLauncherLayout(LauncherModel(mac.settings, defaults: d), defaults: d)
        failed += checkPresetsAndLook(ios: file.settings)
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// The rules (docs/frontends.md, The settings list; settings.tsv's inactive, hint and hide): decided on the screen's values and the device facts as they are now, and never
// changing a value, so a greyed or hidden row's choice is saved and passed to the game as before
@MainActor func checkRules(ios: [Setting], mac: [Setting], wonder: [Setting], defaults d: UserDefaults) -> Int {
    var failed = 0
    func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
    func row(_ m: LauncherModel, _ env: String) -> Setting { m.settings.first { $0.env == env }! }
    func drawn(_ m: LauncherModel, _ env: String) -> Bool { m.sections.contains { m.rows(in: $0).contains { $0.env == env } } }
    let iphone = DeviceFacts(kind: .iphone, screen: 2.17, window: 2.17, hz: 120, haptics: true, controller: false, tv: false, metalFX: true)   // an iPhone 18 Pro Max
    var ipad = DeviceFacts(kind: .ipad, screen: 1.45, window: 1.45, hz: 120, haptics: false, controller: false, tv: false, metalFX: true)   // an iPad Pro M4, 13 inch
    setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_METAL_HUD")
    d.set("0.3", forKey: "launcher.DM_RUMBLE_MIN"); d.set("0", forKey: "launcher.DM_TOUCH_HAPTICS"); d.set("1", forKey: "launcher.DM_MOD_ULTRAWIDE")

    let m = LauncherModel(ios, defaults: d)
    expect(drawn(m, "DM_MOD_ULTRAWIDE") && drawn(m, "DM_TOUCH_HAPTICS") && m.reason(row(m, "DM_RUMBLE")) == nil, "nothing is hidden or explained while the device is not known")
    m.follow({ iphone }, on: [])
    expect(m.facts == iphone, "follow takes the facts at once")
    let cutoff = row(m, "DM_RUMBLE_MIN")
    expect(m.inactiveWhy(cutoff) == nil, "Rumble cutoff works at the default strength")
    m.values["DM_RUMBLE_GAIN"] = "0.00"   // the slider's format
    expect(m.inactiveWhy(cutoff) == "Rumble strength is 0 %" && m.reason(cutoff)?.inactive == true, "Rumble cutoff is greyed at 0 % strength, the slider's 0.00 compared as a number")
    expect(m.values["DM_RUMBLE_MIN"] == "0.3", "greying keeps the saved choice")
    m.values["DM_RUMBLE_GAIN"] = "0.10"
    expect(m.inactiveWhy(cutoff) == nil, "and the row comes back as the strength does")
    m.values["DM_RUMBLE_GAIN"] = "0.00"
    let hold = row(m, "DM_FPS_HOLD")
    m.values["DM_FPS_TARGET"] = "30"
    expect(m.inactiveWhy(hold) == "Only matters at 60 fps", "Hold frames when late is greyed at 30 fps")
    m.values["DM_FPS_TARGET"] = "60"
    expect(m.inactiveWhy(hold) == nil, "and works at 60")
    // MetalFX's spatial scaler keeps the picture's shape (nvn_mtl.m fx_why), so MetalFX is greyed where Stretch changes it, the saved choice kept: Fit or Fill brings it back.
    // Breath of the Wild has Picture shape, and on Match screen Stretch changes the picture's shape only where the window is 16:9 or wider (the picture is the window's own
    // shape on an iPad)
    let upscale = row(m, "DM_PRESENT_UPSCALE")
    let notStretch = "Not with Stretch: pick Fit or Fill"
    m.values["DM_PRESENT_UPSCALE"] = "metalfx"; m.values["DM_PICTURE_FIT"] = "stretch"; m.values["DM_MOD_ULTRAWIDE"] = "0"
    expect(m.values["DM_SCREEN_ASPECT"] == "auto" && m.optionInactive(upscale, "metalfx") == notStretch && m.inactiveWhy(upscale) == nil
           && m.reason(upscale)?.why == notStretch && m.reason(upscale)?.inactive == true, "MetalFX with Stretch on an iPhone: greyed, the row itself not")
    expect(m.values["DM_PRESENT_UPSCALE"] == "metalfx" && m.shown(upscale) == "metalfx", "greying MetalFX keeps the saved choice, and the row shows it")
    expect(m.pick(upscale, "off") && m.values["DM_PRESENT_UPSCALE"] == "off", "Standard can be picked")
    expect(!m.pick(upscale, "metalfx") && m.values["DM_PRESENT_UPSCALE"] == "off", "and MetalFX then cannot be picked again under Stretch")
    m.values["DM_PRESENT_UPSCALE"] = "metalfx"
    m.facts.tv = true
    expect(m.reason(upscale) == nil, "with a TV connected the picture is shown there whole, and MetalFX runs")
    m.facts = ipad
    expect(m.reason(upscale) == nil, "an iPad on Match screen: Stretch stretches nothing, MetalFX works")
    m.values["DM_SCREEN_ASPECT"] = "0"
    expect(m.optionInactive(upscale, "metalfx") == notStretch, "an iPad with the 16:9 picture: greyed")
    m.values["DM_SCREEN_ASPECT"] = "1.43"
    expect(m.optionInactive(upscale, "metalfx") == notStretch, "and with the Duo's 1.43:1 in a 1.45:1 window, 1.4 % off its shape")
    m.facts.window = 1.43
    expect(m.optionInactive(upscale, "metalfx") == nil, "an iPhone Duo's window: the picture's own shape, MetalFX works")
    m.facts.window = 1.78; m.values["DM_SCREEN_ASPECT"] = "0"
    expect(m.optionInactive(upscale, "metalfx") == nil, "a 16:9 window with the 16:9 picture: MetalFX works")
    m.values["DM_SCREEN_ASPECT"] = "auto"; m.facts = iphone
    expect(m.optionInactive(upscale, "metalfx") == notStretch, "the iPhone again: greyed")
    m.values["DM_PICTURE_FIT"] = "fit"
    expect(m.reason(upscale) == nil && m.optionInactive(upscale, "metalfx") == nil && m.values["DM_PRESENT_UPSCALE"] == "metalfx",
           "Fit brings MetalFX back, the saved choice as it was")
    m.values["DM_PICTURE_FIT"] = "fill"
    expect(m.reason(upscale) == nil, "and so does Fill")
    m.values["DM_PICTURE_FIT"] = "fit"
    m.values["DM_MOD_ULTRAWIDE"] = "1"
    // Ultrawide on a screen wider than 16:9 stretches the picture: Picture greyed, and on a 16:9 screen Ultrawide itself
    let picture = row(m, "DM_PICTURE_FIT"), ultrawide = row(m, "DM_MOD_ULTRAWIDE")
    expect(m.values["DM_MOD_ULTRAWIDE"] == "1" && m.inactiveWhy(picture) == "Ultrawide always stretches the picture" && m.inactiveWhy(ultrawide) == nil, "Ultrawide greys Picture on a 2.17:1 screen")
    expect(m.hintWhy(upscale) == "With Ultrawide, only when the game draws a smaller picture", "and gives MetalFX its hint")
    // Greyed, Picture shows the Stretch the game is held at, and Picture shape the 16:9 picture (settings.tsv's shows), while the player's choices stay as they are
    let shape = row(m, "DM_SCREEN_ASPECT")
    m.values["DM_PICTURE_FIT"] = "fill"; m.values["DM_SCREEN_ASPECT"] = "1.43"
    expect(m.shown(picture) == "stretch" && m.binding(picture).wrappedValue == "stretch" && m.shown(shape) == "0", "Ultrawide: Picture shows Stretch, Picture shape 16:9")
    expect(m.values["DM_PICTURE_FIT"] == "fill" && m.values["DM_SCREEN_ASPECT"] == "1.43", "and the saved choices are not changed")
    m.binding(picture).wrappedValue = "fit"
    expect(!m.pick(picture, "fit") && !m.choose(picture, "stretch") && !m.advance(picture, by: 1) && m.values["DM_PICTURE_FIT"] == "fill", "the greyed row refuses every pick, the shown value too")
    m.facts.screen = 1.78
    expect(m.inactiveWhy(ultrawide) == "This screen isn't wider than 16:9" && m.inactiveWhy(picture) == nil, "a 16:9 screen greys Ultrawide and gives Picture back")
    expect(m.shown(picture) == "fill" && m.shown(shape) == "1.43", "with the player's choices shown again")
    m.facts.screen = 2.17
    m.apply()
    expect(d.string(forKey: "launcher.DM_PICTURE_FIT") == "fill" && String(cString: getenv("DM_PICTURE_FIT")) == "fill" && d.string(forKey: "launcher.DM_SCREEN_ASPECT") == "1.43",
           "Play saves and passes the player's Fill, not the Stretch shown (front_ios.m holds Stretch itself)")
    d.removeObject(forKey: "launcher.DM_PICTURE_FIT"); d.removeObject(forKey: "launcher.DM_SCREEN_ASPECT"); unsetenv("DM_PICTURE_FIT"); unsetenv("DM_SCREEN_ASPECT")
    m.values["DM_PICTURE_FIT"] = "fit"; m.values["DM_SCREEN_ASPECT"] = "auto"
    m.facts.screen = 1.78
    m.facts = iphone
    m.values["DM_MOD_ULTRAWIDE"] = "0"
    expect(m.inactiveWhy(picture) == nil, "Ultrawide off: Picture works")
    m.values["DM_MOD_ULTRAWIDE"] = "1"
    // An iPad: Ultrawide and Touch feedback can never work there and are not drawn; rumble needs a controller
    m.facts = ipad
    expect(!drawn(m, "DM_MOD_ULTRAWIDE") && !drawn(m, "DM_TOUCH_HAPTICS") && drawn(m, "DM_TOUCH_SIZE"), "the iPad hides Ultrawide and Touch feedback")
    expect(m.values["DM_MOD_ULTRAWIDE"] == "1" && m.values["DM_TOUCH_HAPTICS"] == "0", "hiding keeps the values")
    expect(m.hintWhy(row(m, "DM_RUMBLE")) == "Rumble needs a controller on this device" && m.hintWhy(row(m, "DM_RUMBLE_GAIN")) != nil, "rumble on an iPad without a controller: a hint")
    ipad.controller = true; m.facts = ipad
    expect(m.hintWhy(row(m, "DM_RUMBLE")) == nil, "with a controller connected, none")
    m.facts = iphone
    expect(drawn(m, "DM_MOD_ULTRAWIDE") && drawn(m, "DM_TOUCH_HAPTICS") && m.hintWhy(row(m, "DM_RUMBLE")) == nil, "the iPhone draws them, and its haptic engine plays rumble")
    m.facts = ipad
    m.apply()
    expect(d.string(forKey: "launcher.DM_RUMBLE_MIN") == "0.3" && d.string(forKey: "launcher.DM_TOUCH_HAPTICS") == "0" && d.string(forKey: "launcher.DM_MOD_ULTRAWIDE") == "1",
           "Play saves the choices of greyed and hidden rows")
    expect(String(cString: getenv("DM_RUMBLE_MIN")) == "0.3" && String(cString: getenv("DM_TOUCH_HAPTICS")) == "0" && String(cString: getenv("DM_MOD_ULTRAWIDE")) == "1",
           "and passes them to the game")
    expect(m.changed, "a greyed or hidden row's choice counts for Reset")
    m.reset()
    expect(m.values["DM_RUMBLE_MIN"] == cutoff.def && m.values["DM_TOUCH_HAPTICS"] == row(m, "DM_TOUCH_HAPTICS").def, "Reset resets greyed and hidden rows too")
    for k in ["DM_RUMBLE_MIN", "DM_TOUCH_HAPTICS", "DM_MOD_ULTRAWIDE"] { d.removeObject(forKey: "launcher." + k) }
    unsetenv("DM_RUMBLE_MIN"); unsetenv("DM_TOUCH_HAPTICS"); unsetenv("DM_MOD_ULTRAWIDE")

    // Switches no row sets, from the environment (an env file): all controllers as player 1, GPU capture
    setenv("DM_PAD_MERGE", "1", 1); setenv("DM_GPU_CAPTURE", "1", 1)
    let e = LauncherModel(ios, defaults: d)
    expect(e.inactiveWhy(row(e, "DM_PAD_PRESS_TO_JOIN")) == "All controllers are player 1 (env.txt)", "DM_PAD_MERGE=1 greys Press a button to join")
    expect(!e.settings.contains { $0.env == "DM_PSO_MTL4" }, "no Metal 4 pipelines row: every pipeline is built through MTL4Compiler")
    expect(e.inactiveWhy(row(e, "DM_PSO_PREBUILD")) == "Off while GPU capture is on", "GPU capture set to anything greys the pipeline prebuild (the capture profile opens no archive)")
    unsetenv("DM_PAD_MERGE"); unsetenv("DM_GPU_CAPTURE")
    let plain = LauncherModel(ios, defaults: d)
    expect(plain.inactiveWhy(row(plain, "DM_PAD_PRESS_TO_JOIN")) == nil && plain.inactiveWhy(row(plain, "DM_PSO_PREBUILD")) == nil, "without them, neither")

    // Super Mario Bros. Wonder has no Picture shape: Stretch stretches its 16:9 picture on an iPhone and on a 4:3 iPad, so MetalFX is greyed there; in a 16:9 window it works
    let w = LauncherModel(wonder, defaults: d)
    w.facts = iphone
    let wu = row(w, "DM_PRESENT_UPSCALE")
    w.values["DM_PICTURE_FIT"] = "stretch"
    expect(w.optionInactive(wu, "metalfx") == "Not with Stretch: pick Fit or Fill" && w.optionHint(wu, "metalfx") == nil && w.inactiveWhy(wu) == nil,
           "MetalFX with Stretch: greyed, Standard still selectable")
    w.facts.window = 1.33
    expect(w.optionInactive(wu, "metalfx") == "Not with Stretch: pick Fit or Fill", "a 4:3 window: greyed")
    w.facts.window = 1.77
    expect(w.optionInactive(wu, "metalfx") == nil, "a window within 1 % of 16:9: the picture keeps its shape, MetalFX works")
    w.facts = iphone; w.facts.tv = true
    expect(w.optionInactive(wu, "metalfx") == nil && w.optionHint(wu, "metalfx") == nil, "with a TV connected the picture is shown there whole, and MetalFX runs")
    w.facts = iphone; w.values["DM_PICTURE_FIT"] = "fit"; w.values["DM_MOD_ULTRAWIDE"] = "1"
    expect(w.optionHint(wu, "metalfx") == "With Ultrawide, only when the game draws a smaller picture", "Ultrawide gives MetalFX its hint too")
    w.values["DM_MOD_ULTRAWIDE"] = "0"; w.facts.metalFX = false
    expect(w.optionInactive(wu, "metalfx") == "This device has no MetalFX scaler", "a device without the scaler greys MetalFX")
    // A greyed option cannot be picked, whatever the control drawing it lets through (a menu picker's selectionDisabled): the model refuses it, on the settings screen and in the menu
    w.values["DM_PRESENT_UPSCALE"] = "off"
    w.binding(wu).wrappedValue = "metalfx"
    expect(w.values["DM_PRESENT_UPSCALE"] == "off" && !w.pick(wu, "metalfx") && !w.choose(wu, "metalfx"), "a greyed option is refused")
    expect(w.pick(wu, "off"), "the value the row has stays pickable")
    w.values["DM_PRESENT_UPSCALE"] = "metalfx"
    expect(w.pick(wu, "metalfx") && w.values["DM_PRESENT_UPSCALE"] == "metalfx", "and so does a greyed option already chosen (a saved choice)")
    w.values["DM_PRESENT_UPSCALE"] = "off"; w.facts.metalFX = nil
    expect(w.optionInactive(wu, "metalfx") == nil, "not known (the iPhone before the game's Metal device): not greyed")
    w.binding(wu).wrappedValue = "metalfx"
    expect(w.values["DM_PRESENT_UPSCALE"] == "metalfx", "and the pick goes through")
    w.values["DM_PRESENT_UPSCALE"] = "off"

    // The Mac: the packer writes the Bluetooth key with every list (pack_app.py info_plist), so nothing greys Switch 2 controllers
    let mm = LauncherModel(mac, defaults: d)
    mm.facts = DeviceFacts(kind: .mac, hz: 60, haptics: false, controller: false, tv: false, metalFX: true)
    expect(mm.inactiveWhy(row(mm, "DM_SW2")) == nil && mm.reason(row(mm, "DM_SW2")) == nil, "Switch 2 controllers: no rule")

    // Terms on their own: an option greyed by the display's rate, a value's other spelling, and terms a reader cannot decide
    let rules = try! JSONDecoder().decode(SettingsFile.self, from: Data(#"""
        {"settings": [
         {"env": "DM_PRESENT_UPSCALE", "kind": "choice", "label": "U", "note": "", "default": "off", "options": [["off", "Standard"], ["metalfx", "MetalFX"]]},
         {"env": "DM_FPS_TARGET", "kind": "choice", "label": "F", "note": "", "default": "60", "options": [["30", "30 fps"], ["60", "60 fps"], ["120", "120 fps"]],
          "inactive": [{"option": "120", "when": ["hz<120"], "why": "This display can't show 120 Hz"}]},
         {"env": "DM_X", "kind": "toggle", "label": "X", "note": "n", "default": "0", "hint": [{"when": ["DM_PRESENT_UPSCALE=metalfx/1"], "why": "a"}],
          "inactive": [{"when": ["future:thing"], "why": "b"}, {"when": ["DM_NOT_HERE!=1"], "why": "c"}, {"when": [], "why": "d"}, {"when": ["DM_PRESENT_UPSCALE=metalfx", "device:mac/ipad"], "why": "e"}],
          "hide": [{"when": ["device:mac", "hz>=120"]}]}]}
        """#.utf8))
    let r = LauncherModel(rules.settings, defaults: d)
    let fps = row(r, "DM_FPS_TARGET"), x = row(r, "DM_X")
    expect(r.optionInactive(fps, "120") == nil, "the display's rate not known: 120 fps offered")
    r.facts = DeviceFacts(kind: .mac, hz: 60)
    expect(r.optionInactive(fps, "120") == "This display can't show 120 Hz" && r.optionInactive(fps, "60") == nil && r.inactiveWhy(fps) == nil, "a 60 Hz display greys 120 fps alone")
    r.values["DM_PRESENT_UPSCALE"] = "1"   // nvn_upscale_pick.h's other spelling of metalfx, as an env file can set it
    expect(r.hintWhy(x) == "a" && r.reason(x)?.inactive == false, "a term matches a value's other spelling")
    expect(r.inactiveWhy(x) == nil, "an unknown term, a variable no row or environment has (with != too) and an empty rule never hold")
    r.values["DM_PRESENT_UPSCALE"] = "metalfx"
    expect(r.inactiveWhy(x) == "e", "device:mac/ipad holds on a Mac")
    expect(!r.hidden(x), "hide needs every term: a 60 Hz Mac draws the row")
    r.facts.hz = 120
    expect(r.hidden(x) && r.values["DM_X"] == "0", "a 120 Hz Mac hides it, value kept")
    expect(DeviceFacts().device("DM_X=1") == nil && DeviceFacts(screen: 2).device("screen>=1.85") == true && DeviceFacts(screen: 2).device("screen<1.85") == false
           && DeviceFacts().device("screen>=1.85") == false && DeviceFacts(haptics: false).device("haptics:none") == true && DeviceFacts().device("mfx:none") == false
           && DeviceFacts(metalFX: false).device("mfx:none") == true && DeviceFacts().device("plist:-K") == false
           && DeviceFacts().device("capture:on") == false && DeviceFacts(gpuCapture: true).device("capture:on") == true, "device terms, and a fact not known (or a term not known) is false")
    return failed
}

// The NX 18 screen's model and shared pieces: presets (settings.tsv's preset meta) applied through pick, the basic / Advanced split, a controller's step on a row, "Skip this screen
// next time", the mark's geometry, the status line and the art's average colour
@MainActor func checkPresetsAndLook(ios: [Setting]) -> Int {
    var failed = 0
    func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
    let suite = "nxnative.launcher-test." + UUID().uuidString
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    setenv("DM_ENV_FILE_KEYS", "", 1); setenv("DM_ENV_LAUNCH_KEYS", "", 1); unsetenv("DM_SAVED_CHOICES")
    let iphone = DeviceFacts(kind: .iphone, screen: 2.17, window: 2.17, hz: 120, haptics: true, controller: false, tv: false, metalFX: true)
    func row(_ m: LauncherModel, _ env: String) -> Setting { m.settings.first { $0.env == env }! }
    let m = LauncherModel(ios, defaults: d)
    m.facts = iphone
    let fpsDef = row(m, "DM_FPS_TARGET").def
    expect(row(m, "DM_RENDER_SCALE").preset == ["battery": "0.75", "quality": "1.0"] && row(m, "DM_OPMODE").preset == nil, "presets decode; a row without one has none")
    expect(m.hasPresets && m.activePreset == .balanced, "the tested defaults are Balanced")
    m.values["DM_OPMODE"] = "0"; m.values["DM_LANG"] = "ja"
    m.applyPreset(.battery)
    expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_RENDER_SCALE"] == "0.75" && m.values["DM_PRESENT_UPSCALE"] == "off" && m.values["DM_POST_AA"] == "off"
           && m.values["DM_PRESENT_SHARPEN"] == "0", "Battery: 30 fps, a lower render scale, no MetalFX, no anti-aliasing or sharpening")
    expect(m.values["DM_OPMODE"] == "0" && m.values["DM_LANG"] == "ja" && m.activePreset == .battery, "a preset leaves the other rows; Battery is the chosen chip")
    m.applyPreset(.quality)
    expect(m.values["DM_FPS_TARGET"] == fpsDef && m.values["DM_PRESENT_UPSCALE"] == "metalfx" && m.values["DM_POST_AA"] == "edge" && m.values["DM_RENDER_SCALE"] == "1.0"
           && m.activePreset == .quality, "Quality: the tested frame rate, MetalFX, edge smoothing, full render scale")
    m.values["DM_POST_AA"] = "edge-sharp"
    expect(m.activePreset == nil, "values matching no preset: no chip")
    m.applyPreset(.balanced)
    expect(m.activePreset == .balanced && m.values["DM_PRESENT_UPSCALE"] == "off" && m.values["DM_OPMODE"] == "0", "Balanced brings the preset rows back to their defaults, and only those")
    m.facts.metalFX = false
    m.applyPreset(.quality)
    expect(m.values["DM_PRESENT_UPSCALE"] == "off" && m.values["DM_POST_AA"] == "edge" && m.activePreset == .quality, "a greyed option is not picked; the preset still counts as chosen")
    m.facts = iphone
    setenv("DM_ENV_FILE_KEYS", "DM_FPS_TARGET", 1); setenv("DM_FPS_TARGET", "60", 1)
    let fixed = LauncherModel(ios, defaults: d)
    fixed.applyPreset(.battery)
    expect(fixed.values["DM_FPS_TARGET"] == "60" && fixed.values["DM_POST_AA"] == "off" && fixed.activePreset == .battery, "a preset never changes an env file's value")
    setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FPS_TARGET")
    let gain = row(m, "DM_RUMBLE_GAIN")
    expect(gain.preset == nil && gain.target(.battery) == nil && row(m, "DM_POST_AA").target(.balanced) == row(m, "DM_POST_AA").def, "a row without a preset has no target; Balanced is the default")

    // Basic first, the others under Advanced; a list without basic rows shows every row first
    let basic = m.groups(basic: true), advanced = m.groups(basic: false)
    expect(m.hasBasicRows && basic.map(\.section) == ["Game", "Controls"] && basic.allSatisfy { $0.rows.allSatisfy(\.basic) }, "basic rows first, in their sections")
    expect(advanced.contains { $0.section == "Performance" } && advanced.allSatisfy { !$0.rows.isEmpty && $0.rows.allSatisfy { !$0.basic } }, "the others under Advanced, no empty section")
    let flat = LauncherModel(ios.filter { !$0.basic }, defaults: d)
    expect(!flat.hasBasicRows && flat.groups(basic: true).map(\.section) == flat.sections && flat.groups(basic: false).isEmpty, "no basic rows: everything first, nothing under Advanced")

    // A controller's step: options cycle, greyed ones skipped; a range by its step; a toggle flips; a fixed or greyed row stays
    m.values["DM_POST_AA"] = "off"
    let aa = row(m, "DM_POST_AA"), scale = row(m, "DM_RENDER_SCALE"), rumble = row(m, "DM_RUMBLE"), up = row(m, "DM_PRESENT_UPSCALE")
    expect(m.advance(aa, by: 1) && m.values["DM_POST_AA"] == "edge" && m.advance(aa, by: -1) && m.advance(aa, by: -1) && m.values["DM_POST_AA"] == "edge-sharp", "a choice steps and wraps")
    m.values["DM_RENDER_SCALE"] = "1.0"
    expect(!m.advance(scale, by: 1) && m.advance(scale, by: -1) && m.values["DM_RENDER_SCALE"] == "0.95", "a range moves by its step and stops at its end")
    let wasRumble = m.values["DM_RUMBLE"]
    expect(m.advance(rumble, by: 1) && m.values["DM_RUMBLE"] != wasRumble, "a toggle flips")
    m.values["DM_PRESENT_UPSCALE"] = "off"; m.facts.metalFX = false
    expect(!m.advance(up, by: 1) && m.values["DM_PRESENT_UPSCALE"] == "off", "a greyed option is skipped (nothing else to pick)")
    m.facts = iphone
    m.values["DM_RUMBLE"] = "1"; m.values["DM_RUMBLE_GAIN"] = "0"
    expect(!m.editable(row(m, "DM_RUMBLE_MIN")) && !m.advance(row(m, "DM_RUMBLE_MIN"), by: 1), "a greyed row does not move")
    expect(!fixed.editable(row(fixed, "DM_FPS_TARGET")) && !fixed.advance(row(fixed, "DM_FPS_TARGET"), by: 1), "nor does a fixed one")

    // Skip this screen next time; DM_LAUNCHER wins both ways
    expect(!m.skipAtStart && !LauncherModel.skipsAtStart(defaults: d, environment: [:]), "the screen shows by default")
    m.skipAtStart = true
    expect(d.bool(forKey: "launcher.skip") && LauncherModel.skipsAtStart(defaults: d, environment: [:]) && LauncherModel(ios, defaults: d).skipAtStart, "skip is stored at once and read back")
    expect(!LauncherModel.skipsAtStart(defaults: d, environment: ["DM_LAUNCHER": "1"]) && LauncherModel.skipsAtStart(defaults: d, environment: ["DM_LAUNCHER": "0"]), "DM_LAUNCHER decides while set")
    m.skipAtStart = false
    expect(d.object(forKey: "launcher.skip") == nil && LauncherModel.skipsAtStart(defaults: d, environment: ["DM_LAUNCHER": "0"]), "off removes the key; DM_LAUNCHER=0 still skips")
    // DM_LAUNCHER fixes the choice only when an env file or the launch set it, not when main.m's program record did (that skips one start)
    expect(!LauncherModel.launcherSetByEnv(environment: [:]) && LauncherModel.launcherSetByEnv(environment: ["DM_LAUNCHER": "0"]), "no DM_LAUNCHER decides nothing; one without the key lists decides")
    expect(LauncherModel.launcherSetByEnv(environment: ["DM_LAUNCHER": "0", "DM_ENV_FILE_KEYS": "DM_FOO DM_LAUNCHER", "DM_ENV_LAUNCH_KEYS": ""]), "an env file's DM_LAUNCHER decides")
    expect(LauncherModel.launcherSetByEnv(environment: ["DM_LAUNCHER": "1", "DM_ENV_FILE_KEYS": "", "DM_ENV_LAUNCH_KEYS": "DM_LAUNCHER"]), "the launch's DM_LAUNCHER decides")
    expect(!LauncherModel.launcherSetByEnv(environment: ["DM_LAUNCHER": "0", "DM_ENV_FILE_KEYS": "DM_FOO", "DM_ENV_LAUNCH_KEYS": "DM_LAUNCHERX"]), "a program record's DM_LAUNCHER=0 leaves the player's choice")

    // The Mac's about.json reader: a field of another type is none, the others still show (dm/mac/Launcher.swift LauncherExtras.About)
    let about = try? JSONDecoder().decode(LauncherExtras.About.self, from: Data(#"{"name": " Game ", "intro": "  ", "description": "Text", "publisher": ["Nintendo"], "releaseDate": 20191031, "source": "titledb"}"#.utf8))
    expect(about?.name == "Game" && about?.intro == nil && about?.description == "Text" && about?.publisher == nil && about?.releaseDate == nil && about?.hasText == true, "the Mac reads about.json leniently")

    // The mark: make_logo.py's geometry fitted into the rect
    let box = CGRect(x: 0, y: 0, width: 291.6, height: 130)
    let pill = NX18MarkShape(part: .pill).path(in: box).boundingRect, cyan = NX18MarkShape(part: .cyan).path(in: box).boundingRect
    let coral = NX18MarkShape(part: .coral).path(in: box).boundingRect, digits = NX18MarkShape(part: .digits).path(in: box).boundingRect
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.05 }
    expect(near(NX18MarkShape.aspect, 291.6 / 130) && near(pill.minX, 206) && near(pill.minY, 0) && near(pill.width, 85.6) && near(pill.height, 65.52), "the 18's pill")
    expect(near(cyan.minX, 0) && near(cyan.maxX, 186) && near(cyan.maxY, 130) && near(cyan.minY, 26), "the N and X span the letters, below the pill's rise")
    expect(near(coral.minX, 104) && near(coral.maxX, 186) && digits.minX > pill.minX && digits.maxX < pill.maxX && digits.maxY < pill.maxY, "the X's under stroke; the digits inside the pill")
    let half = NX18MarkShape(part: .cyan).path(in: CGRect(x: 10, y: 10, width: 400, height: 65)).boundingRect
    expect(near(half.height, 52) && near(half.minY, 10 + 13), "scaled to the rect's height, aspect kept")

    // The status line: the parts known, in order
    let now = Date()
    let st = LauncherStatus(lastPlayed: now.addingTimeInterval(-7200), cloud: .synced, memoryFree: 3 << 30, console: .switch2)
    let parts = st.parts(now: now)
    expect(parts.map(\.id) == ["console", "played", "cloud", "memory"] && parts[0].text == "Switch 2" && parts[0].dot == NX18Palette.coral
           && parts[1].text.hasPrefix("Last played ") && parts[2].text == "Save synced" && parts[3].text == "\(3.0.formatted(.number.precision(.fractionLength(1)))) GB free", "status parts")
    expect(LauncherStatus(console: .switch1).parts().map(\.text) == ["Switch 1"] && LauncherStatus.Console.switch1.dot == NX18Palette.cyan
           && LauncherStatus.Console(rawValue: "switch3") == nil
           && LauncherStatus().parts().isEmpty && LauncherStatus(cloud: .on).parts().map(\.text) == ["Cloud saves on"], "unknown parts are left out")
    let withConsole = try! JSONDecoder().decode(SettingsFile.self, from: Data(#"{"game": "0400486024DEC000", "console": "switch2", "settings": []}"#.utf8))
    let without = try! JSONDecoder().decode(SettingsFile.self, from: Data(#"{"game": "0100DCA0064A6000", "settings": []}"#.utf8))
    expect(withConsole.console == "switch2" && without.console == nil, "launcher.json's console, optional")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
    let older = Date(timeIntervalSince1970: 1_700_000_000), newer = Date(timeIntervalSince1970: 1_800_000_000)
    for (name, date) in [("x", older), ("a/y", newer)] {
        let u = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: Data([1]))
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
    }
    expect(LauncherStatus.lastModified(under: dir) == newer && LauncherStatus.lastModified(under: dir.appendingPathComponent("none")) == nil, "last played: the newest file under the save folder")
    try? FileManager.default.removeItem(at: dir)

    // The art's average colour on the CPU, mixed at most 12 % into the background
    let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
    let avg = NX18Palette.average(of: ctx.makeImage()!)
    expect(avg.map { abs($0.r - 0.5) < 0.05 && $0.g < 0.02 && abs($0.b - 0.5) < 0.05 } == true, "the average of half red, half blue")
    expect(NX18Palette.background(tint: nil) == NX18Palette.background && NX18Palette.background(tint: NX18RGB(r: 1, g: 1, b: 1), amount: 0.5) == NX18Palette.mix(0x1E1E21, NX18RGB(r: 1, g: 1, b: 1), 0.12),
           "no tint: the background; a tint is capped at 12 %")

    // The game's logo (dm/logo.png): found beside the art, decoded on the CPU with its transparency, shown at a size that keeps its shape; a file that is not an image leaves the name
    let res = FileManager.default.temporaryDirectory.appendingPathComponent(suite + "-logo")
    let dm = res.appendingPathComponent("dm")
    try? FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
    let wordmark = CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    wordmark.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); wordmark.fill(CGRect(x: 20, y: 20, width: 360, height: 60))   // white on transparent, as a wordmark is
    let png = dm.appendingPathComponent("logo.png")
    if let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(dest, wordmark.makeImage()!, nil); _ = CGImageDestinationFinalize(dest) }
    let decoded = NX18Logo.decode(png)
    expect(decoded?.width == 364 && decoded?.height == 64 && [.premultipliedLast, .premultipliedFirst, .last, .first].contains(decoded?.alphaInfo),
           "a logo decodes on the CPU keeping its transparency, trimmed to its visible pixels with 2 to spare")
    let found = LauncherExtras.load(resources: res)
    expect(found.logo.map { $0.size == NSSize(width: 364, height: 64) } == true && !found.logoDark, "the Mac window finds dm/logo.png; a white logo is not dark")
    // a wordmark centred in a padded square canvas (a common --logo or SteamGridDB export) is trimmed to the wordmark, so it fits and aligns by itself; one filling its canvas is kept whole
    let padded = CGContext(data: nil, width: 1200, height: 1200, bitsPerComponent: 8, bytesPerRow: 4800, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    padded.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); padded.fill(CGRect(x: 0, y: 450, width: 1200, height: 300))
    let paddedTrim = NX18Logo.trimmed(padded.makeImage()!)
    let full = CGContext(data: nil, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    full.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); full.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
    expect(paddedTrim?.width == 1200 && paddedTrim?.height == 304 && NX18Logo.trimmed(full.makeImage()!).map { $0.width == 40 && $0.height == 10 } == true,
           "a padded canvas is trimmed to its wordmark; an image with no margin is kept whole")
    let black = CGContext(data: nil, width: 40, height: 10, bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    black.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)); black.fill(CGRect(x: 4, y: 2, width: 20, height: 6))   // a black wordmark on mostly transparent pixels
    expect(NX18Logo.isDark(black.makeImage()!) && decoded.map { !NX18Logo.isDark($0) } == true, "a black logo is dark (its transparent pixels do not count), a white one is not")
    func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
        let c = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); return c.makeImage()!
    }
    expect(!NX18Logo.isDark(solid(1, 0, 0)) && !NX18Logo.isDark(solid(0.902, 0, 0.07)) && !NX18Logo.isDark(solid(0, 0, 1)) && !NX18Logo.isDark(solid(0.1, 0.2, 0.9)),
           "a saturated red or blue logo is not dark: it keeps the dark shadow")
    expect(NX18Logo.fitted(CGSize(width: 400, height: 100), maxWidth: 360, maxHeight: 96) == CGSize(width: 360, height: 90)
           && NX18Logo.fitted(CGSize(width: 200, height: 200), maxWidth: 360, maxHeight: 72) == CGSize(width: 72, height: 72)
           && NX18Logo.fitted(.zero, maxWidth: 360, maxHeight: 72) == .zero, "a wide logo is held by the width, a square one by the height, keeping its shape")
    let clear = CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(dest, clear.makeImage()!, nil); _ = CGImageDestinationFinalize(dest) }
    expect(NX18Logo.decode(png) == nil && LauncherExtras.load(resources: res).logo == nil, "a logo with no visible pixels is none: the name shows")
    try? Data("not a picture".utf8).write(to: png)
    expect(NX18Logo.decode(png) == nil && LauncherExtras.load(resources: res).logo == nil, "a logo that cannot be decoded is none: the name shows")
    try? FileManager.default.removeItem(at: png)
    expect(NX18Logo.decode(png) == nil && LauncherExtras.load(resources: res).logo == nil, "no dm/logo.png: no logo")
    try? FileManager.default.removeItem(at: res)
    return failed
}
