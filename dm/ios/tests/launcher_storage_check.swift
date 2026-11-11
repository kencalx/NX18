// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept; the rules grey, explain and hide rows as the values and the device say, and
// leave every value as it is. Arguments: the iOS and the Mac launcher.json of Breath of the Wild, and the iOS one of Super Mario Bros. Wonder (settings.py, GFXAPI=nvn; the iOS
// lists with the Ultrawide mod)
import Foundation
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
        let wonder = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        failed += checkRules(ios: file.settings, mac: mac.settings, wonder: wonder.settings, defaults: d)
        failed += checkLauncherLayout(LauncherModel(mac.settings, defaults: d), defaults: d)
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
    // MetalFX with Stretch runs only for a crop smaller than its texture (Breath of the Wild's handheld picture), which the present knows: a hint, not greyed. Breath of the
    // Wild has Picture shape, and on Match screen Stretch changes the picture's shape only where the window is 16:9 or wider (the picture is the window's own shape on an iPad)
    let upscale = row(m, "DM_PRESENT_UPSCALE")
    m.values["DM_PRESENT_UPSCALE"] = "metalfx"; m.values["DM_PICTURE_FIT"] = "stretch"; m.values["DM_MOD_ULTRAWIDE"] = "0"
    expect(m.values["DM_SCREEN_ASPECT"] == "auto" && m.optionInactive(upscale, "metalfx") == nil && m.hintWhy(upscale) == "With Stretch, only when the game draws a smaller picture"
           && m.reason(upscale)?.inactive == false, "MetalFX with Stretch on an iPhone: a hint")
    m.facts = ipad
    expect(m.reason(upscale) == nil, "an iPad on Match screen: Stretch stretches nothing, no hint")
    m.values["DM_SCREEN_ASPECT"] = "0"
    expect(m.hintWhy(upscale) == "With Stretch, only when the game draws a smaller picture", "an iPad with the 16:9 picture: the hint")
    m.values["DM_SCREEN_ASPECT"] = "auto"; m.facts = iphone
    m.values["DM_PICTURE_FIT"] = "fit"
    expect(m.reason(upscale) == nil, "no hint with Fit and Ultrawide off")
    m.values["DM_MOD_ULTRAWIDE"] = "1"
    // Ultrawide on a screen wider than 16:9 stretches the picture: Picture greyed, and on a 16:9 screen Ultrawide itself
    let picture = row(m, "DM_PICTURE_FIT"), ultrawide = row(m, "DM_MOD_ULTRAWIDE")
    expect(m.values["DM_MOD_ULTRAWIDE"] == "1" && m.inactiveWhy(picture) == "Ultrawide always stretches the picture" && m.inactiveWhy(ultrawide) == nil, "Ultrawide greys Picture on a 2.17:1 screen")
    expect(m.hintWhy(upscale) == "With Ultrawide, only when the game draws a smaller picture", "and gives MetalFX its hint")
    m.facts.screen = 1.78
    expect(m.inactiveWhy(ultrawide) == "This screen isn't wider than 16:9" && m.inactiveWhy(picture) == nil, "a 16:9 screen greys Ultrawide and gives Picture back")
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

    // Super Mario Bros. Wonder has no Picture shape: Stretch always stretches its 16:9 picture on an iPhone, so MetalFX gets the hint; only a device without the scaler greys it
    let w = LauncherModel(wonder, defaults: d)
    w.facts = iphone
    let wu = row(w, "DM_PRESENT_UPSCALE")
    w.values["DM_PICTURE_FIT"] = "stretch"
    expect(w.optionInactive(wu, "metalfx") == nil && w.optionHint(wu, "metalfx") == "With Stretch, only when the game draws a smaller picture" && w.inactiveWhy(wu) == nil,
           "MetalFX with Stretch: selectable, with the hint")
    w.facts.tv = true
    expect(w.optionHint(wu, "metalfx") == nil, "with a TV connected the picture is shown there whole, and MetalFX runs")
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
