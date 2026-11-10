// Launcher settings, validation and persistence, and the rules that grey, explain or hide a row. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    let inactive, hint, hide: [Rule]?   // when the row (or one option) is greyed, carries a reason, or is not drawn: LauncherModel's rules below
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
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
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, on, off, inactive, hint, hide }
}
// One of a row's inactive, hint or hide rules (docs/frontends.md, The settings list): it holds while every term in when holds
struct Rule: Decodable, Equatable {
    let option: String?   // the value of a choice or toggle the rule is about; none: the whole row
    let when: [String]
    let why: String?      // the reason, one short line; a hide rule has none, as nothing is drawn
}
// What the device, its screens and the app have, for the rules' device terms: the iOS launcher (Launcher.swift) and the Mac window (dm/mac/Launcher.swift) fill it in and refresh
// it as it changes. nil is not known, and a term about something not known is false, as a term this reader does not know is: a rule this launcher cannot decide never greys or
// hides a row, so the player keeps every choice the game takes
struct DeviceFacts: Equatable, Sendable {
    enum Kind: String, Sendable { case iphone, ipad, mac }
    var kind: Kind?
    var screen: Double?        // the long side over the short side of the screen the app's window is on (front_ios.m's Ultrawide test)
    var window: Double?        // the same for the app's window, which an iPad under Stage Manager or Split View makes smaller than the screen (front_ios.m's Match screen)
    var hz: Int?               // the fastest connected screen's maximumFramesPerSecond (hle_nvn.c's 120 fps test)
    var haptics: Bool?         // the device has a haptic engine (CHHapticEngine supportsHaptics, as haptics_apple.m and DmGamepad.m test it)
    var controller: Bool?      // a game controller is connected now
    var tv: Bool?              // an external display (a TV) is connected now, where front_ios.m shows the picture whole
    var metalFX: Bool?         // a Metal 4 MetalFX spatial scaler (nvn_mtl.m's test before it upscales)

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
        default: break
        }
        return t.first?.isLowercase == true ? false : nil   // a device term is lower case, a variable upper case: one this reader does not know is false
    }
}
struct SettingsFile: Decodable { let settings: [Setting] }

@MainActor final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:]
    @Published var facts = DeviceFacts()   // the device the rules are decided on (follow), published so a row greys or comes back as a controller or a TV connects

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

    // Whether the player may pick v for s now: not while a rule greys that option, unless it is the value the row has already. The settings screen's menus draw such an option
    // disabled (LauncherRow.swift), but a menu picker's selectionDisabled is a trait SwiftUI documents for lists, so the model refuses the pick as well (pick, choose)
    func canPick(_ s: Setting, _ v: String) -> Bool { v == (values[s.env] ?? s.def) || optionInactive(s, v) == nil }
    // A pick on the settings screen (LauncherRow.swift's menus and toggles): the value, unless canPick refuses it. Returns whether it took it
    @discardableResult func pick(_ s: Setting, _ v: String) -> Bool {
        guard canPick(s, v) else { fputs("launcher: \(s.env)=\(v) refused: \(optionInactive(s, v) ?? "")\n", stderr); return false }
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
    func refreshFacts() {
        guard let f = factsSource?(), f != facts else { return }
        facts = f
    }
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
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
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            store(s, v)
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
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

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            if !s.isDefault(v) { setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v) (saved choice)\n", stderr) }
        }
    }
}
