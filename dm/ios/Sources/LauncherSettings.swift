// Launcher settings, validation and persistence, and the rules that grey, explain or hide a row. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings, the iOS screen's rows above Advanced); any other or none: Advanced settings
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    let inactive, hint, hide: [Rule]?   // when the row (or one option) is greyed, carries a reason, or is not drawn: LauncherModel's rules below
    let shows: [Rule]?   // the value (option) the row shows while greyed by a whole-row inactive rule with the same terms, the host's value then (Picture at Stretch under Ultrawide): LauncherModel.shown
    let preset: [String: String]?   // the row's value in each preset besides Balanced ("battery", "quality"; settings.tsv's preset meta); absent: no preset touches the row
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool { same(v, def) }
    func same(_ a: String, _ b: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(a) ?? .nan) - (Double(b) ?? .nan)) < 1e-6 : a == b
    }
    // The value a preset gives the row: Balanced its default, Battery and Quality the list's value (the default when the list names none). nil: no preset touches the row
    func target(_ p: LauncherPreset) -> String? {
        guard let preset else { return nil }
        return p == .balanced ? def : preset[p.rawValue] ?? def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }   // no hex: launcher.c's check agrees
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, on, off, inactive, hint, hide, shows, preset }
}
// The settings screen's presets (the chips above the settings, presets-first W1's order): Balanced is the tested defaults; Battery Saver, Quality and Performance are each row's
// preset values from the list. The stored names stay (battery is Battery Saver: only the title changed, W2)
enum LauncherPreset: String, CaseIterable, Identifiable, Sendable {
    case battery, balanced, quality, performance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .battery: return "Battery Saver"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        case .performance: return "Performance"
        }
    }
}
// One section's rows as the screen draws them (LauncherModel.groups)
struct LauncherRowGroup: Identifiable {
    let section: String
    let rows: [Setting]
    var id: String { section }
}
// One of a row's inactive, hint, hide or shows rules (docs/frontends.md, The settings list): it holds while every term in when holds
struct Rule: Decodable, Equatable {
    let option: String?   // the value of a choice or toggle the rule is about; none: the whole row. A shows rule's: the value the row shows
    let when: [String]
    let why: String?      // the reason, one short line; a hide or shows rule has none (nothing is drawn; the row's inactive rule gives the reason)
}
// What the device, its screens and the app have, for the rules' device terms: the iOS launcher (Launcher.swift) and the Mac window (dm/mac/Launcher.swift) fill it in and refresh
// it as it changes. nil is not known, and a term about something not known is false, as a term this reader does not know is: a rule this launcher cannot decide never greys or
// hides a row, so the player keeps every choice the game takes
struct DeviceFacts: Equatable, Sendable {
    enum Kind: String, Sendable { case iphone, ipad, mac }
    var kind: Kind?
    var screen: Double?        // the long side over the short side of the screen the app's window is on (front_ios.m's Ultrawide test)
    var window: Double?        // the same for the app's window, which an iPad under Stage Manager or Split View makes smaller than the screen (front_ios.m's Match screen; the shape Stretch stretches the picture to)
    var hz: Int?               // the fastest connected screen's maximumFramesPerSecond (hle_nvn.c's 120 fps test)
    var haptics: Bool?         // the device has a haptic engine (CHHapticEngine supportsHaptics, as haptics_apple.m and DmGamepad.m test it)
    var controller: Bool?      // a game controller is connected now
    var tv: Bool?              // an external display (a TV) is connected now, where front_ios.m shows the picture whole
    var metalFX: Bool?         // a Metal 4 MetalFX spatial scaler (nvn_mtl.m's test before it upscales)
    var gpuCapture: Bool?      // GPU capture: Metal's capture layer loaded, or an app built for capture (MetalCaptureEnabled): nvn_mtl.m's capture profile, which opens no pipeline archive

    // A device term's truth: nil when t is not a device term (another row's value or the environment, LauncherModel.holds); false when the fact is not known
    func device(_ t: String) -> Bool? {
        if t.hasPrefix("device:") { return kind.map { k in t.dropFirst(7).split(separator: "/").contains { $0 == k.rawValue } } ?? false }
        for (name, have) in [("screen", screen), ("window", window), ("hz", hz.map(Double.init))] where t.hasPrefix(name) {
            let rest = t.dropFirst(name.count)
            if rest.hasPrefix(">="), let r = Double(rest.dropFirst(2)) { return have.map { $0 >= r } ?? false }
            if rest.hasPrefix("<"), let r = Double(rest.dropFirst()) { return have.map { $0 < r } ?? false }
            return false
        }
        switch t {
        case "haptics:none": return haptics.map { !$0 } ?? false
        case "controller:none": return controller.map { !$0 } ?? false
        case "tv:none": return tv.map { !$0 } ?? false
        case "mfx:none": return metalFX.map { !$0 } ?? false
        case "capture:on": return gpuCapture ?? false
        default: break
        }
        return t.first?.isLowercase == true ? false : nil   // a device term is lower case, a variable upper case: one this reader does not know is false
    }
}
// console: switch1 or switch2 (settings.py console()), for the status line; presets: the chips to draw, Balanced among them (settings.py DRAWN; absent in an older list:
// Battery Saver, Balanced, Quality); moves: per drawn preset, the rows it moves in this game, for its note
// The menus' feel (gate-ui GW11, GW12, G4): what a press did, for the haptic and the optional Menu sounds tone (NX18Feel.swift sets LauncherModel.feel on iOS; nil elsewhere)
enum LauncherFeel: Sendable { case move, select, toggle, preset, back, refuse, play }

// preset_env: per drawn preset, switches no row sets that it gives the host (settings.py PRESET_ENV: Donkey Kong Bananza's Battery Saver DM_FPS_CTL=hold30); absent: none
struct SettingsFile: Decodable {
    let settings: [Setting]; let console: String?; let presets: [String]?; let moves: [String: [String]]?; var presetEnv: [String: [String: String]]? = nil
    enum CodingKeys: String, CodingKey { case settings, console, presets, moves, presetEnv = "preset_env" }
}

@MainActor final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:]
    var console: String?   // launcher.json's console (SettingsFile), shown under the game's name
    // The chips to draw (launcher.json's presets, W1's order; Balanced always): set from the list after init (Launcher.swift), every preset but Performance for an older list
    var offeredPresets: [LauncherPreset] = [.battery, .balanced, .quality]
    var presetMoves: [String: [String]] = [:]   // launcher.json's moves: the rows each preset moves here (W12's notes)
    var presetEnv: [String: [String: String]] = [:]   // launcher.json's preset_env: the switches no row sets that a preset gives the host
    func takeList(_ file: SettingsFile) {
        console = file.console
        if let p = file.presets {
            let named = Set(p.compactMap(LauncherPreset.init(rawValue:)))
            offeredPresets = LauncherPreset.allCases.filter { $0 == .balanced || named.contains($0) }
        }
        presetMoves = file.moves ?? [:]
        presetEnv = file.presetEnv ?? [:]
        loadPresetState()
    }
    // The base preset ("Custom (from Balanced)" and Back go to it; launcher.preset) and whether the player chose it (a chip tap, L / R, X or Back: launcher.presetTapped)
    @Published private(set) var basePreset: LauncherPreset = .balanced
    @Published private(set) var presetTapped = false
    // The state before the last change that left Custom (a chip, L / R, X, Back): Undo puts it back (presets-first W9); dropped at the next preset change or when the toast ends
    @Published private(set) var undoState: (values: [String: String], base: LauncherPreset, tapped: Bool)?
    @Published private(set) var presetChange = 0   // counts the player's preset changes: the toast (W9) shows for each
    static var feel: ((LauncherFeel) -> Void)? = nil   // the menus' haptic and sound (NX18Feel.swift); nil: none
    nonisolated static let presetKey = "launcher.preset", tappedKey = "launcher.presetTapped", presetValuesKey = "launcher.presetValues"
    nonisolated static let presetTableVersion = "1"   // presetValues' "_v": a later build that retunes a preset's values may bump it
    @Published var facts = DeviceFacts()   // the device the rules are decided on (follow), published so a row greys or comes back as a controller or a TV connects
    // "Skip this screen next time" (launcher.skip): stored as it changes, not at Play, so the in-game menu's "Settings screen at start" can turn it off while the game runs
    @Published var skipAtStart = false {
        didSet { if skipAtStart != oldValue { LauncherModel.setSkipAtStart(skipAtStart, defaults: defaults) } }
    }

    private let defaults: UserDefaults
    private let environment: [String: String]   // for a rule's switch that no row sets (DM_PAD_MERGE from an env file): the process's, as the host reads it
    private let byEnv: [String: Setting]
    private var factsSource: (@MainActor () -> DeviceFacts)?
    private var observers: [NSObjectProtocol] = []

    init(_ settings: [Setting], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = settings
        let env = ProcessInfo.processInfo.environment
        environment = env
        byEnv = Dictionary(settings.map { ($0.env, $0) }, uniquingKeysWith: { a, _ in a })
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { fputs("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n", stderr) }
        Self.forgetRetired(defaults)
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: "launcher." + s.env) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
        _skipAtStart = Published(initialValue: defaults.bool(forKey: LauncherModel.skipKey))   // the stored choice, without storing it again (didSet)
    }

    // Saved choices of switches the host no longer has, removed from the preferences so that an old install's choice neither comes back nor lingers there; once, since nothing
    // stores them again. DM_PSO_MTL4: render pipelines are always Metal 4's (MTL4Compiler), and the MTLDevice path an install could have saved (0) is gone. Removed with
    // DM_SAVED_CHOICES=0 too: no build offers them. The Mac's launcher.c calls it through dm_mac_forget_retired (dm/mac/Launcher.swift), with the window or without
    nonisolated static let retired = ["DM_PSO_MTL4"]
    nonisolated static func forgetRetired(_ defaults: UserDefaults) {
        for env in retired where defaults.object(forKey: "launcher." + env) != nil {
            defaults.removeObject(forKey: "launcher." + env)
            fputs("launcher: saved choice \(env) forgotten: this build no longer has it\n", stderr)
        }
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    func visible(_ s: Setting) -> Bool {
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let key = String(n[n.startIndex..<eq]), want = String(n[n.index(after: eq)...])
        guard let v = values[key] else { return true }
        return v == want
    }
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) && !hidden($0) } }

    // The rules (docs/frontends.md, The settings list). A row another setting or the device makes useless is greyed with the reason as its note (inactive), one that works only
    // in some situations keeps its note and adds the reason (hint), one that can never work on this device is not drawn (hide). They are decided on the screen's values and the
    // device as they are now, so a row greys and comes back as the player changes another. None of them changes a value: a greyed or hidden row keeps its choice, which Play saves
    // and passes to the game like any other (the host ignores it while the rule holds), so the choice is back when the rule stops holding, and Reset resets it too

    // A rule term's truth: a device term (DeviceFacts.device), else <VAR>=<v>/<v> or <VAR>!=<v>/<v> on the value of the row that sets <VAR> as the screen shows it (a range
    // compared as a number, so 0 matches the slider's 0.00), or on the environment for a variable no row sets (=* while it is set to anything). A variable neither has is false,
    // with != too: a rule about a setting this game does not have never holds
    func holds(_ t: String) -> Bool {
        if let d = facts.device(t) { return d }
        guard let op = t.range(of: "!=") ?? t.range(of: "=") else { return false }
        let name = String(t[..<op.lowerBound]), wanted = t[op.upperBound...].split(separator: "/").map(String.init), negate = t[op] == "!="
        let match: Bool
        if let s = byEnv[name] {
            let v = values[name] ?? s.def
            match = wanted.contains { s.kind == "range" ? abs((Double(v) ?? .nan) - (Double($0) ?? .nan)) < 1e-6 : v == $0 }
        } else if let v = environment[name] {
            match = wanted.contains { $0 == "*" || $0 == v }
        } else { return false }
        return match != negate
    }
    private func holding(_ rules: [Rule]?, option: String?) -> Rule? { rules?.first { $0.option == option && !$0.when.isEmpty && $0.when.allSatisfy(holds) } }
    // The row is not drawn: it can never do anything on this device (Ultrawide and Touch feedback on an iPad)
    func hidden(_ s: Setting) -> Bool { s.hide?.contains { !$0.when.isEmpty && $0.when.allSatisfy(holds) } ?? false }
    // The whole row is greyed, for this reason (Rumble cutoff at 0 % strength)
    func inactiveWhy(_ s: Setting) -> String? { holding(s.inactive, option: nil).map { $0.why ?? "" } }
    // One option is greyed, for this reason (MetalFX on a device without the scaler, 120 fps on a 60 Hz display): the row stays selectable
    func optionInactive(_ s: Setting, _ v: String) -> String? { holding(s.inactive, option: v).map { $0.why ?? "" } }
    // One option works only in some situations, for this reason (Match screen where it is 16:9 anyway)
    func optionHint(_ s: Setting, _ v: String) -> String? { holding(s.hint, option: v)?.why }
    // The row works only in some situations, for this reason: a hint on the row, or on the option chosen now
    func hintWhy(_ s: Setting) -> String? { holding(s.hint, option: nil)?.why ?? optionHint(s, values[s.env] ?? s.def) }
    // The reason the row shows, and whether it is greyed (an inactive rule wins over a hint): the row's own inactive rule, else that of the option chosen now (the player can
    // still pick another), else a hint. The note under the row becomes the reason when the row does nothing, and adds it to the note when the row works only sometimes
    func reason(_ s: Setting) -> (why: String, inactive: Bool)? {
        if let why = inactiveWhy(s) ?? optionInactive(s, values[s.env] ?? s.def) { return (why, true) }
        return hintWhy(s).map { ($0, false) }
    }

    // The value the row shows: the player's choice, except while a whole-row inactive rule greys it and a shows rule with the same terms holds (settings.tsv's shows), when it
    // shows that rule's value, the one the host uses then (Ultrawide holds Picture at Stretch, front_ios.m startGame). The choice itself is not changed: Play saves and passes it
    // as before, and the row shows it again when the rule stops holding. The row's control, the controller's step, the presets and the in-game menu draw this value; the rules
    // (holds) test the saved one
    func shown(_ s: Setting) -> String {
        let v = values[s.env] ?? s.def
        guard inactiveWhy(s) != nil, let o = s.shows?.first(where: { $0.option != nil && !$0.when.isEmpty && $0.when.allSatisfy(holds) })?.option, s.accepts(o) else { return v }
        return o
    }

    // Whether the player may pick v for s now: not while a rule greys the row or that option, unless it is the value the row has already. The settings screen draws a greyed
    // row disabled and such an option disabled (LauncherRow.swift), but a menu picker's selectionDisabled is a trait SwiftUI documents for lists, so the model refuses the pick
    // as well (pick, choose)
    func canPick(_ s: Setting, _ v: String) -> Bool { v == (values[s.env] ?? s.def) || (inactiveWhy(s) == nil && optionInactive(s, v) == nil) }
    // A pick on the settings screen (LauncherRow.swift's menus and toggles): the value, unless canPick refuses it. Returns whether it took it
    @discardableResult func pick(_ s: Setting, _ v: String) -> Bool {
        guard canPick(s, v) else { fputs("launcher: \(s.env)=\(v) refused: \(inactiveWhy(s) ?? optionInactive(s, v) ?? "")\n", stderr); return false }
        values[s.env] = v
        return true
    }

    // The device facts from source, now and again on each of the notifications (a controller or a screen that connects or leaves), and when a view calls refreshFacts (the
    // window resized). The refresh waits for the next main-actor turn, as a scene that disconnects is still listed while its notification is delivered
    func follow(_ source: @escaping @MainActor () -> DeviceFacts, on names: [Notification.Name]) {
        factsSource = source
        facts = source()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = names.map { NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshFacts() } } }
    }
    // follow's observers go with the model. It normally lives on as the in-game menu's (gameMenuModel); this matters only for one that is let go (the Duo tests let theirs go)
    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func refreshFacts() {
        guard let f = factsSource?(), f != facts else { return }
        facts = f
    }
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
    // Whether any drawn row is basic; without one the screen has nothing to put first, and shows every row (no empty section, no Advanced)
    var hasBasicRows: Bool { sections.contains { rows(in: $0).contains { $0.basic } } }
    // The iOS screen's split: basic: true gives the rows shown first, false those under Advanced, each in the list's sections and order, empty sections left out. A game
    // without basic rows gets every row in the first part and nothing under Advanced
    func groups(basic: Bool) -> [LauncherRowGroup] {
        let split = hasBasicRows
        if !split && !basic { return [] }
        return sections.compactMap { section in
            let r = split ? rows(in: section, basic: basic) : rows(in: section)
            return r.isEmpty ? nil : LauncherRowGroup(section: section, rows: r)
        }
    }
    // A range's label: its percentage, with the size in pixels for the chosen console mode when the list has the base size (the render scale)
    func rangeLabel(_ s: Setting, _ v: Double) -> String {
        let p = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return p }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return p }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(p))"
    }
    var changed: Bool { settings.contains { !fixed.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset() {
        for s in settings where !fixed.contains(s.env) { values[s.env] = s.def }
        basePreset = .balanced; presetTapped = false; undoState = nil
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // The choices stored as apply() stores them, without putting them into this process's environment: a front end that edits a game's settings for it (NX 18 Beam's
    // settings sheet, beam/Sources/Views/GameSettingsView.swift) saves them where the game's own window would, and the game reads them at its next start
    func save() {
        startPreset()
        for s in settings where !fixed.contains(s.env) { store(s, values[s.env] ?? s.def) }
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        startPreset()
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            store(s, v)
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
        exportPreset()
    }
    // The preset the settings are (battery, balanced, quality, performance; custom when none), for the host, not a row: frame generation steps aside in Battery Saver (DM_FRAMEGEN,
    // nvn_framegen.inc fg_power_why, which reads it again once a second). nil without presets, or when an env file or the launch set DM_PRESET (it stays). With frame generation on
    // (framegenOn) every start sets it before the game does: Play (apply), a start without the screen (applySaved: Skip this screen next time, DM_LAUNCHER=0, a home screen shortcut,
    // a program handing over), and the Mac's start without its window (dm/mac/Launcher.swift dm_mac_preset_env); the in-game menu sets it again after a preset change or a hand
    // change to a preset row, under front_ios.m's lock (GameMenu.swift gameMenuPresetEnv)
    var presetEnvValue: String? { hasPresets && environment["DM_PRESET"] == nil ? (activePreset?.rawValue ?? "custom") : nil }
    // DM_FRAMEGEN=1 without DM_PRESENT_REPEAT=1, read when asked as the host reads it once (nvn_framegen.inc fg_on; the env files and the launch environment are in before the settings
    // screen, and neither has a row or menu pick): frame generation is DM_PRESET's only reader, so without it nothing exports the preset or logs it, at a start or in game
    nonisolated static var framegenOn: Bool {
        guard let e = getenv("DM_FRAMEGEN"), strcmp(e, "1") == 0 else { return false }
        return getenv("DM_PRESENT_REPEAT").map { strcmp($0, "1") != 0 } ?? true
    }
    // The preset's switches no row sets (preset_env), each with the value it takes for the preset the settings are now: the preset's own, or "" (the host's default) for any other
    // preset and for Custom. A switch an env file or the launch set stays (left out). Bananza's Battery Saver: DM_FPS_CTL=hold30, which the host reads again once a second
    // (hle_fctl.c fctl_mode_poll), so the in-game menu's change applies while the game runs
    var presetSwitches: [(env: String, value: String)] {
        let p = activePreset?.rawValue
        let names = Set(presetEnv.values.flatMap { $0.keys }).sorted().filter { !fixed.contains($0) }
        return names.map { e in (env: e, value: p.flatMap { presetEnv[$0]?[e] } ?? "") }
    }
    // Before the game starts (its threads do not run yet, so setenv is safe here)
    func exportPreset() {
        for (e, v) in presetSwitches { setenv(e, v, 1); fputs("launcher: \(e)=\(v)\(v.isEmpty ? " (the host's default)" : "") (preset \(activePreset?.rawValue ?? "custom"))\n", stderr) }
        guard Self.framegenOn, let p = presetEnvValue else { return }
        setenv("DM_PRESET", p, 1); fputs("launcher: DM_PRESET=\(p)\n", stderr)
    }
    private func store(_ s: Setting, _ v: String) {
        if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) } }
    }

    // A choice made while the game runs (the iOS in-game menu, GameMenu.swift): saved as Play saves it, so the settings screen shows it at the next start. A value an env file or the
    // launch fixed stays. Returns whether it took the value; the menu then puts it into the environment through front_ios.m's dm_setting_env, not setenv here: the host's threads run
    // by then, and setenv rewrites or reallocates the value a pointer from another thread's getenv points at (dm_setting_env holds the lock such a reader copies it under)
    func choose(_ s: Setting, _ v: String) -> Bool {
        guard !fixed.contains(s.env), s.accepts(v), canPick(s, v) else { return false }
        values[s.env] = v; store(s, v)
        fputs("launcher: \(s.env)=\(v) (in-game menu)\n", stderr)
        return true
    }

    // A row the player can change now: not fixed by an env file or the launch, not greyed by a rule
    func editable(_ s: Setting) -> Bool { !fixed.contains(s.env) && inactiveWhy(s) == nil }

    // A controller's step on a row (left / right as -1 / +1, A as +1): a choice moves to the next option the player may pick (wrapping, greyed options skipped), a range moves by
    // its step (clamped, written as the slider writes it), a toggle flips. Nothing on a row that is not editable. Returns whether the value changed
    @discardableResult func advance(_ s: Setting, by delta: Int) -> Bool {
        let moved = step(s, by: delta)
        if moved { Self.feel?(s.kind == "toggle" ? .toggle : .select) }
        return moved
    }
    private func step(_ s: Setting, by delta: Int) -> Bool {
        guard delta != 0, editable(s) else { return false }
        let v = shown(s)   // the saved choice: a row that shows another value is greyed, and stops above
        switch s.kind {
        case "choice":
            let opts = (s.options ?? []).map { $0[0] }
            let n = opts.count
            guard n > 1 else { return false }
            var i = opts.firstIndex(of: v) ?? (delta > 0 ? -1 : n)   // a value the list does not have (an env file's spelling): from the first or the last option
            for _ in 0..<n {
                i = ((i + delta.signum()) % n + n) % n
                if opts[i] == v { return false }
                if canPick(s, opts[i]) { return pick(s, opts[i]) }
            }
            return false
        case "range":
            let lo = s.min ?? 0, hi = s.max ?? 1, st = s.step ?? 0.05
            let cur = Double(v) ?? hi
            let next = Swift.min(hi, Swift.max(lo, lo + (((cur - lo) / st).rounded() + Double(delta)) * st))
            guard abs(next - cur) > 1e-6 else { return false }
            values[s.env] = String(format: "%.2f", next)
            return true
        default:
            return pick(s, v == s.onValue ? s.offValue : s.onValue)
        }
    }

    // Presets (the chips above the settings). A preset sets each row the list gives a preset value, through pick, so it never changes a row an env file or the launch fixed, a row a rule
    // greys, or picks an option a rule greys; every other row keeps the player's choice. Balanced is the tested defaults of those rows (Reset sets every row)
    var presetRows: [Setting] { settings.filter { $0.preset != nil && !fixed.contains($0.env) } }
    var hasPresets: Bool { !presetRows.isEmpty }
    // The value a preset gives a row on this device: its target, or where a rule greys that option the highest option of the row not greyed (presets-first P9: Performance's 120 fps
    // on a 60 Hz screen gives 60)
    func presetValue(_ s: Setting, _ t: String) -> String {
        guard s.kind == "choice", optionInactive(s, t) != nil, let opts = s.options?.map({ $0[0] }), let i = opts.firstIndex(of: t) else { return t }
        return opts[..<i].last { optionInactive(s, $0) == nil } ?? t
    }
    // Whether applying the preset leaves the row as it is: it has the value already, or the preset may not change it now
    private func presetLeaves(_ s: Setting, _ p: LauncherPreset) -> Bool {
        guard let t0 = s.target(p) else { return true }
        let t = presetValue(s, t0)
        return s.same(shown(s), t) || inactiveWhy(s) != nil || !canPick(s, t)
    }
    // The preset the screen's values are, for the chip drawn as chosen: the base when its values match, then the first drawn one whose applying would change nothing (Balanced,
    // Battery Saver, Quality, Performance); nil when none (Custom), or without presets
    var activePreset: LauncherPreset? {
        let rows = presetRows
        guard !rows.isEmpty else { return nil }
        let order = [basePreset] + [LauncherPreset.balanced, .battery, .quality, .performance].filter { $0 != basePreset }
        return order.filter(offeredPresets.contains).first { p in rows.allSatisfy { presetLeaves($0, p) } }
    }
    // Set the preset's values. A row a value set here greys or frees is decided as the rows go, and once more after them, as a later row's value can free an earlier one.
    // tapped: the player chose it (a chip, L / R, X or Back), which also keeps the state before for Undo (W9); a retune passes the stored choice
    func applyPreset(_ p: LauncherPreset, tapped: Bool = true) {
        if tapped { undoState = (Dictionary(uniqueKeysWithValues: presetRows.map { ($0.env, values[$0.env] ?? $0.def) }), basePreset, presetTapped); presetChange += 1; Self.feel?(.preset) }
        for _ in 0..<3 {
            var moved = false
            for s in presetRows where !presetLeaves(s, p) {
                if let t = s.target(p), pick(s, presetValue(s, t)) { moved = true }
            }
            if !moved { break }
        }
        basePreset = p; presetTapped = tapped
        fputs("launcher: preset \(p.rawValue)\(activePreset == p ? "" : " (some rows kept: fixed or greyed)")\n", stderr)
    }
    // L / R: the next or previous drawn preset, with wrap, from the lit one (or the base while Custom)
    func stepPreset(_ d: Int) {
        let all = offeredPresets
        guard !all.isEmpty else { return }
        let i = all.firstIndex(of: activePreset ?? basePreset) ?? all.firstIndex(of: .balanced) ?? 0
        applyPreset(all[((i + d) % all.count + all.count) % all.count])
    }

    // MARK: The base preset (presets-first §10, §11)

    // The stored base, read once the list's presets are known (takeList); none stored: the nearest preset, as a player who saved choices before this build had none
    func loadPresetState() {
        let stored = ignoreSaved ? nil : defaults.string(forKey: Self.presetKey)
        if let raw = stored, let p = LauncherPreset(rawValue: raw) {
            if offeredPresets.contains(p) { basePreset = p }
            else { basePreset = .balanced; fputs("launcher: base preset \(raw) is not drawn in this build: Balanced\n", stderr) }
        } else { basePreset = nearestPreset }
        presetTapped = !ignoreSaved && defaults.bool(forKey: Self.tappedKey) && stored != nil
    }
    // The drawn preset fewest preset rows differ from, Balanced on a tie (and first): a player's hand changes are Custom from it
    var nearestPreset: LauncherPreset {
        let rows = presetRows
        func misses(_ p: LauncherPreset) -> Int { rows.filter { !presetLeaves($0, p) }.count }
        return offeredPresets.sorted { a, b in (misses(a), a == .balanced ? 0 : 1) < (misses(b), b == .balanced ? 0 : 1) }.first ?? .balanced
    }
    // While the values match no drawn preset: Custom, from the base
    var isCustom: Bool { hasPresets && activePreset == nil }
    var presetLabel: String { activePreset.map(\.title) ?? "Custom (from \(basePreset.title))" }
    // A row whose value differs from the base preset's (Customize's dot, "changed from Balanced")
    func changedFromBase(_ s: Setting) -> Bool { s.target(basePreset).map { !s.same(shown(s), presetValue(s, $0)) } ?? false }
    // Back to the base: only the preset rows change (W4)
    func backToBase() { applyPreset(basePreset) }
    func undo() {
        guard let u = undoState else { return }
        for (k, v) in u.values { values[k] = v }
        basePreset = u.base; presetTapped = u.tapped; undoState = nil
        fputs("launcher: preset change undone: \(presetLabel)\n", stderr)
    }
    func dropUndo() { undoState = nil }
    // The rows the preset moves in this game (launcher.json's moves; else from the rows), for its note and the toast
    func moves(_ p: LauncherPreset) -> [Setting] {
        if p == .balanced { return [] }
        if let envs = presetMoves[p.rawValue] { return envs.compactMap { e in settings.first { $0.env == e } } }
        return presetRows.filter { s in s.target(p).map { !s.same($0, s.def) } ?? false }
    }
    // Before the game starts, from apply() and applySaved(): the retune (a later build changed the base's values and nobody edited them: apply them again), then the base and the
    // values it set are stored for the next start (§11)
    func startPreset() {
        guard hasPresets, !ignoreSaved else { return }
        var saved = defaults.dictionary(forKey: Self.presetValuesKey) as? [String: String] ?? [:]
        saved.removeValue(forKey: "_v")
        if !saved.isEmpty {
            let rows = presetRows.filter { saved[$0.env] != nil }
            let untouched = rows.allSatisfy { s in s.same(values[s.env] ?? s.def, saved[s.env]!) }
            let retuned = rows.contains { s in s.target(basePreset).map { !s.same(saved[s.env]!, presetValue(s, $0)) } ?? false }
            if untouched && retuned { applyPreset(basePreset, tapped: presetTapped); fputs("launcher: the \(basePreset.title) preset's values changed in this build: applied again\n", stderr) }
        }
        storePresetState()
        fputs("launcher: preset \(presetLabel)\(presetTapped ? "" : " (not chosen by a tap)")\n", stderr)
    }
    // The base, whether it was tapped, and the values it set, for the next start's retune check (§11): at the start (startPreset) and after a preset change in game (inGame)
    func storePresetState() {
        guard hasPresets, !ignoreSaved else { return }
        var targets: [String: String] = ["_v": Self.presetTableVersion]
        for s in presetRows { if let t = s.target(basePreset) { targets[s.env] = presetValue(s, t) } }
        defaults.set(targets, forKey: Self.presetValuesKey)
        defaults.set(basePreset.rawValue, forKey: Self.presetKey)
        if presetTapped { defaults.set(true, forKey: Self.tappedKey) } else { defaults.removeObject(forKey: Self.tappedKey) }
    }

    // A preset change while the game runs (the in-game menu: a chip, L / R, X, Back to X, Undo; gate-ui §19.3): the values move as on the Gate, each preset row that moved is
    // saved at once (as choose saves a pick), and the base is stored, so the Gate shows the new preset next time. Returns the rows that moved: the menu applies the live ones
    // now (front_ios.m dm_setting_live) and says the rest change at the next start. Nothing goes into the environment here (the menu does that under front_ios.m's lock)
    @discardableResult func inGame(_ change: () -> Void) -> [Setting] {
        let before = Dictionary(uniqueKeysWithValues: presetRows.map { ($0.env, values[$0.env] ?? $0.def) })
        change()
        let moved = presetRows.filter { !$0.same(before[$0.env] ?? $0.def, values[$0.env] ?? $0.def) }
        for s in moved { let v = values[s.env] ?? s.def; store(s, v); fputs("launcher: \(s.env)=\(v) (in-game menu, \(presetLabel))\n", stderr) }
        storePresetState()
        return moved
    }

    // "Skip this screen next time" (launcher.skip in the app's preferences): the game starts at once with the saved choices, as with DM_LAUNCHER=0
    nonisolated static let skipKey = "launcher.skip"
    // Whether the settings screen is skipped at start: DM_LAUNCHER from an env file or the launch decides while it is set (0 skips, any other value shows the screen), else the
    // player's choice. A front end may still show the screen when the player asks for it at start (a controller button held: Launcher.swift, best effort)
    nonisolated static func skipsAtStart(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let v = environment["DM_LAUNCHER"], !v.isEmpty { return v == "0" }
        return defaults.bool(forKey: skipKey)
    }
    // Whether DM_LAUNCHER came from an env file or the launch environment (DM_ENV_FILE_KEYS / DM_ENV_LAUNCH_KEYS, main.m or launcher.c), so the player's choice cannot change it.
    // main.m sets DM_LAUNCHER=0 itself for a start from a program record (a game of several programs handing over): that skips this one start only and leaves the choice the
    // player's. Without either list (a process main.m did not start) any DM_LAUNCHER decides
    nonisolated static func launcherSetByEnv(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let v = environment["DM_LAUNCHER"], !v.isEmpty else { return false }
        let lists = [environment["DM_ENV_FILE_KEYS"], environment["DM_ENV_LAUNCH_KEYS"]].compactMap { $0 }
        if lists.isEmpty { return true }
        return lists.contains { $0.split(separator: " ").contains("DM_LAUNCHER") }
    }
    // The player's choice, stored at once (the toggle; the in-game menu's "Settings screen at start" sets false). Off is no key, as the other choices keep only what differs
    nonisolated static func setSkipAtStart(_ on: Bool, defaults: UserDefaults = .standard) {
        if on { defaults.set(true, forKey: skipKey) } else { defaults.removeObject(forKey: skipKey) }
        fputs("launcher: skip at start \(on ? "on" : "off")\n", stderr)
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written. Console mode's default goes into the environment
    // too: for a Switch 2 game on iOS the list's default (Handheld, settings.tsv) differs from the host's own (DM_GAME_OPMODE, docked). Other defaults stay unset, as before
    func applySaved() {
        startPreset()
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            let saved = !s.isDefault(v)
            if saved || s.env == "DM_OPMODE" { setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(saved ? " (saved choice)" : "")\n", stderr) }
        }
        exportPreset()   // the saved choices' preset, as Play sets it
    }
}
