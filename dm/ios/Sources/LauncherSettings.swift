// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note: String
    var def: String        // the default; LauncherModel sets a screen=nearest row's from the device's screen
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    let screen: String?    // "nearest": a choice of picture shapes whose default on an iPhone or iPad is the option nearest the screen's shape (nearestShape)
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
    // screen=nearest: the option whose shape (its value as width / height, 0 for 16:9) is nearest a screen of width / height r, as a ratio (a 2.17:1 iPhone: 16:9; a 4:3 iPad: 1.43:1); nil when no option is a shape
    func nearestShape(_ r: Double) -> String? {
        var best: String? = nil
        var bestDistance = Double.infinity
        for o in options ?? [] {
            guard let v = o.first, let a = Double(v), a.isFinite, a >= 0 else { continue }
            let ratio: Double = (a == 0 ? 16.0 / 9.0 : a) / r
            let distance: Double = abs(log(ratio))   // as a ratio: 1.6 is as far from 2 as 2 from 2.5
            if distance < bestDistance { best = v; bestDistance = distance }
        }
        return best
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, on, off, screen }
}
struct SettingsFile: Decodable { let settings: [Setting] }

// One line to the log (stderr, which main.m sends to Documents/log.txt and the Mac launcher to the game's log): through FileHandle, as the C stream stderr is shared mutable
// state the Swift 6 language mode refuses (the iOS app and the Mac launcher, which compiles this file too, build in it). The throwing write(contentsOf:): write(_:) raises an
// Objective-C exception when the write fails (a full disk), which Swift cannot catch and which ended the app; a line that cannot be written is lost, as the host's fprintf loses it
func launcherLog(_ line: String) { try? FileHandle.standardError.write(contentsOf: Data(line.utf8)) }

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:]

    private let defaults: UserDefaults

    // screen: the device's screen as width / height in landscape (the iOS launcher), for the rows marked screen=nearest; nil (the Mac window, the tests) keeps every list default
    init(_ settings: [Setting], screen: Double? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = settings.map { (s: Setting) -> Setting in
            guard s.screen == "nearest", let r = screen, r.isFinite, r > 0, let d = s.nearestShape(r) else { return s }
            let shape = String(format: "%.2f", r)
            launcherLog("launcher: \(s.env) defaults to \(d) on this \(shape):1 screen, the option nearest its shape (the list's default: \(s.def))\n")
            var t = s; t.def = d; return t
        }
        let env = ProcessInfo.processInfo.environment
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { launcherLog("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n") }
        for s in self.settings {   // with the defaults the screen chose
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: "launcher." + s.env) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
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
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) } }
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
        launcherLog("launcher: settings reset to the game's defaults\n")
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { launcherLog("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n"); continue }
            store(s, v)
            setenv(s.env, v, 1); launcherLog("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n")
        }
    }
    private func store(_ s: Setting, _ v: String) {
        if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) } }
    }

    // A choice made while the game runs (the iOS in-game menu, GameMenu.swift): saved as Play saves it, so the settings screen shows it at the next start. A value an env file or the
    // launch fixed stays. Returns whether it took the value; the menu then puts it into the environment through front_ios.m's dm_setting_env, not setenv here: the host's threads run
    // by then, and setenv rewrites or reallocates the value a pointer from another thread's getenv points at (dm_setting_env holds the lock such a reader copies it under)
    func choose(_ s: Setting, _ v: String) -> Bool {
        guard !fixed.contains(s.env), s.accepts(v) else { return false }
        values[s.env] = v; store(s, v)
        launcherLog("launcher: \(s.env)=\(v) (in-game menu)\n")
        return true
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            if !s.isDefault(v) { setenv(s.env, v, 1); launcherLog("launcher: \(s.env)=\(v) (saved choice)\n") }
        }
    }
}
