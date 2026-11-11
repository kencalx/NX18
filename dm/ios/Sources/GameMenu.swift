// The in-game menu, opened by the gamepad's menu button at the top centre (DmGamepad.m): the controller layout, then the settings-screen settings the running game takes at once
// (front_ios.m dm_setting_live), grouped as on the settings screen, one row each, then the Cheats submenu (cheatsMenu), Settings screen at start (settingsAtStartRow) and Share log
// (dmShareLog). A pick is saved as Play saves it (LauncherModel.choose), so the settings screen shows it at the next start; a setting an env file fixes is shown, not changed. Settings
// that need the next start (language, pipelines, the frame rate and so on), and the sliders, stay on the settings screen, which the menu's title points to. A row that does nothing
// at the moment says why under its name (gameMenuRow): greyed when nothing the player picks there can take effect, still selectable when only the current choice does nothing.
// The menu is built here once as GameMenuItem rows (gameMenuSections), each time it opens, and drawn two ways: by default as NX 18's own panel (GameMenuPanel.swift: NX 18's colours
// and UI font, touch, controller and VoiceOver), and with DM_GAME_MENU=system as the UIMenu it always was (gameMenuItems, uiMenuElement; DmGamepad.m picks), so both show the same
// rows, notes and actions
import UIKit

@MainActor var gameMenuModel: LauncherModel?   // main-actor state: written by dm_show_launcher, read by the menu, both on the main thread; the settings screen's model (Launcher.swift); nil in an app without one: the menu has the layout only

// One row of the in-game menu
struct GameMenuItem: Identifiable {
    enum Kind {
        case action                       // a button: Share log, Reload cheats, a cheat that runs once, a greyed line that only informs
        case toggle(Bool)                 // on or off: ticked in the UIMenu, a switch in the panel (an option of a choice: the one chosen)
        case choice([GameMenuItem])       // one of several (each a .toggle, the current one on): a single-selection submenu, a page of options in the panel
        case submenu([GameMenuSection])   // Cheats
    }
    let id: String                        // unique in the menu: the panel's focus and VoiceOver keep their place by it while the rows are built again
    var title: String
    var subtitle: String?                 // the row's note: why it does nothing at the moment, a fixed value, a cheat's state
    var symbol: String?                   // an SF Symbol
    var disabled = false
    var closesMenu = false                // the panel closes first (Share log: the share sheet or the alert is the system's, over the game)
    var kind: Kind
    var perform: (@MainActor (UIView?) -> Void)?   // the pick; its argument is the menu button (an iPad's popover points at it)

    init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, disabled: Bool = false, closesMenu: Bool = false, kind: Kind = .action,
         perform: (@MainActor (UIView?) -> Void)? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.disabled = disabled; self.closesMenu = closesMenu; self.kind = kind; self.perform = perform
    }

    var isOn: Bool { if case .toggle(let on) = kind { return on }; return false }
    /// A choice's current option, as its title
    var currentOption: String? { if case .choice(let o) = kind { return o.first(where: \.isOn)?.title }; return nil }
}

// A group of rows: an inline section of the UIMenu, a column (or part of one) of the panel
struct GameMenuSection: Identifiable {
    let id: String
    var title = ""                        // the UIMenu's inline title (a cheats file's section), "" for none
    var heading: String?                  // the panel's heading where the UIMenu has no title: the settings screen's section (Game, Controls), More
    var inline = true                     // false: the rows go straight into the parent UIMenu, with no group (Cheats without cheats)
    var items: [GameMenuItem]
    var label: String? { title.isEmpty ? heading : title }
}

@_cdecl("dm_game_menu")
public func dmGameMenu() -> UnsafeMutableRawPointer {
    let menu = MainActor.assumeIsolated {   // DmGamepad.m asks for the menu on the main thread (UIKit); a call from any other thread stops here instead of racing gameMenuModel
        return UIMenu(title: gameMenuTitle(), children: [UIDeferredMenuElement.uncached { done in done(gameMenuItems()) }])   // built each time it opens, so it shows the current choices
    }
    return Unmanaged.passRetained(menu).toOpaque()
}

@MainActor func gameMenuTitle() -> String { gameMenuModel != nil ? "More settings on the start screen" : "" }

// The menu as UIMenu elements (DM_GAME_MENU=system). Its text size is fixed there: front_ios.m startGame
@MainActor func gameMenuItems() -> [UIMenuElement] { uiMenuElements(gameMenuSections()) }   // not private: the Duo harness's menu test reads the rows (dm/ios/tests/duo)

@MainActor func uiMenuElements(_ sections: [GameMenuSection]) -> [UIMenuElement] {
    sections.flatMap { s -> [UIMenuElement] in
        s.inline ? [UIMenu(title: s.title, options: .displayInline, children: s.items.map(uiMenuElement))] : s.items.map(uiMenuElement)
    }
}

@MainActor func uiMenuElement(_ i: GameMenuItem) -> UIMenuElement {
    let image = i.symbol.flatMap { UIImage(systemName: $0) }
    switch i.kind {
    case .choice(let options):   // a choice's value shows in its submenu: a subtitle would make each row two lines
        return UIMenu(title: i.title, subtitle: i.subtitle, image: image, options: .singleSelection, children: options.map(uiMenuElement))
    case .submenu(let sections):
        return UIMenu(title: i.title, subtitle: i.subtitle, image: image, children: uiMenuElements(sections))
    case .action, .toggle:
        let perform = i.perform
        let state: UIMenuElement.State = i.isOn ? .on : .off
        let a = UIAction(title: i.title, image: image, attributes: i.disabled ? .disabled : [], state: state) { action in perform?(action.sender as? UIView) }   // the menu button, for an iPad's popover
        a.subtitle = i.subtitle
        return a
    }
}

// The rows, built each time the menu opens (and after each pick in the panel), so they show the current choices
@MainActor func gameMenuSections() -> [GameMenuSection] {
    let names = ["2D", "3D", "Tap"]
    let layouts = (0..<3).filter { dm_pad_layout_offered(Int32($0)) }.map { l in
        GameMenuItem(id: "layout=\(l)", title: names[l], kind: .toggle(dm_pad_layout() == l)) { _ in dm_pad_layout_set(Int32(l)) }
    }
    let layout = GameMenuItem(id: "layout", title: "Controller layout", kind: .choice(layouts))
    var sections: [GameMenuSection] = []
    var placed = false
    if let m = gameMenuModel {
        for section in m.sections {
            var rows: [GameMenuItem] = section == "Controls" ? [layout] : []
            if section == "Controls" { placed = true }
            for s in m.rows(in: section) where (s.kind == "choice" || s.kind == "toggle") && dm_setting_live(s.env, nil) { rows.append(gameMenuRow(m, s)) }
            if !rows.isEmpty { sections.append(GameMenuSection(id: "section:\(section)", heading: section, items: rows)) }
        }
    }
    if !placed { sections.insert(GameMenuSection(id: "section:Controls", heading: "Controls", items: [layout]), at: 0) }
    if let cheats = cheatsMenu() { sections.append(GameMenuSection(id: "section:cheats", heading: "More", items: [cheats])) }
    let share = GameMenuItem(id: "share", title: "Share log", symbol: "square.and.arrow.up", closesMenu: true) { anchor in dmShareLog(from: anchor) }
    var last: [GameMenuItem] = []
    if let m = gameMenuModel { last.append(settingsAtStartRow(m)) }
    sections.append(GameMenuSection(id: "section:app", heading: "More", items: last + [share]))
    return sections
}

// Settings screen at start: ticked while the settings screen shows when the app starts, unticked while the player's Skip this screen next time skips it (launcher.skip, stored at once:
// LauncherModel.skipAtStart). Picking it brings the screen back at the next start, or skips it again. Greyed while DM_LAUNCHER from an env file or the launch decides
// (LauncherModel.launcherSetByEnv); main.m's own DM_LAUNCHER=0 for a start from a program record skips only that start, so the row stays the player's then
@MainActor func settingsAtStartRow(_ m: LauncherModel) -> GameMenuItem {
    let env = ProcessInfo.processInfo.environment
    let fixed = LauncherModel.launcherSetByEnv(environment: env)
    let on = fixed ? env["DM_LAUNCHER"] != "0" : !m.skipAtStart
    return GameMenuItem(id: "atstart", title: "Settings screen at start", subtitle: fixed ? "Set by an env file" : nil, symbol: "slider.horizontal.3", disabled: fixed, kind: .toggle(on)) { _ in
        m.skipAtStart.toggle()
    }
}

// Share log: the in-game menu's last row. One share sheet with Documents/log.txt and log.prev.txt (the run before this one, which main.m keeps under that name at each start: a run
// that crashed or that iOS ended), the files docs/playing.md asks for in a bug report. Each is copied into tmp/share-log first, so the sheet reads a snapshot: log.txt is still being
// written while the app runs (APFS clones the copy, which takes no room until the log grows). A missing file is left out; the copies of the share before are deleted at the next (and
// iOS empties tmp by itself). On an iPad the sheet is a popover: it points at the view the share came from (the menu button), or sits in the middle of the screen
@MainActor func dmShareLog(from anchor: UIView?) {
    let fm = FileManager.default
    guard let doc = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let dir = fm.temporaryDirectory.appendingPathComponent("share-log", isDirectory: true)
    try? fm.removeItem(at: dir)
    do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
        fputs("[RED] share log: \(dir.path) cannot be made: \(error.localizedDescription)\n", stderr); return
    }
    let sources: [URL] = [doc.appendingPathComponent("log.txt"), doc.appendingPathComponent("log.prev.txt")]
    var files: [URL] = []
    for src in sources where fm.fileExists(atPath: src.path) {
        let copy = dir.appendingPathComponent(src.lastPathComponent)
        do { try fm.copyItem(at: src, to: copy); files.append(copy) } catch { fputs("[RED] share log: \(src.lastPathComponent) cannot be copied: \(error.localizedDescription)\n", stderr) }
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let key = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
    var top: UIViewController? = anchor?.window?.rootViewController ?? key?.rootViewController
    while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
    guard let presenter = top else { fputs("[RED] share log: no window to show the share sheet in\n", stderr); return }
    if files.isEmpty {
        let a = UIAlertController(title: "Share log", message: "There is no log yet.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(a, animated: true); return
    }
    let sheet = UIActivityViewController(activityItems: files, applicationActivities: nil)
    if let pop = sheet.popoverPresentationController {   // an iPad: a popover needs a place
        if let a = anchor, a.window != nil { pop.sourceView = a; pop.sourceRect = a.bounds }
        else { let v: UIView = presenter.view; pop.sourceView = v; pop.sourceRect = CGRect(x: v.bounds.midX, y: v.bounds.midY, width: 1, height: 1); pop.permittedArrowDirections = [] }
    }
    presenter.present(sheet, animated: true)
    let listed = files.map { $0.lastPathComponent }.joined(separator: ", ")
    fputs("share log: \(listed)\n", stderr)
}

// Cheats: the Atmosphère cheat file of this build in the cheats folder (Documents/cheats, which main.m makes; in the Files app under the app's name), as the Mac's Cheats menu
// shows it (front_mac.m): one row per cheat, a tap turns it on or off and is remembered (<build ID>.enabled); a "{master}" code is always on; a cheat that cannot run here
// shows why, disabled (the iPhone's code pages are signed, so a cheat that rewrites code runs only on the Mac: pack a code patch into the app instead, the NSP script's mods
// folder). An on / off pair is one row; a "set" cheat runs once when tapped. Then the master switch and Reload, which reads the folder again after a file was copied in.
private let cheatLabel: Int32 = 1, cheatPairOff: Int32 = 16, cheatOnce: Int32 = 32   // dm.h DM_CHEAT_*

@MainActor private func cheatsMenu() -> GameMenuItem? {
    if String(cString: dm_cheats_dir_path()).isEmpty { return nil }   // no cheats folder (DM_CHEATS=""), or the host is still loading them (hle_cheats.c): no submenu, until an open after that
    let reload = GameMenuItem(id: "cheats.reload", title: "Reload cheats", symbol: "arrow.clockwise") { _ in dm_cheats_reload() }
    let build = String(cString: dm_cheats_build())
    let n = Int(dm_cheats_ncheats())
    if dm_cheats_found() == 0 || n == 0 {
        var rows = [GameMenuItem(id: "cheats.none", title: build.isEmpty ? "No cheat file" : "No cheats for build \(build)",
                                 subtitle: "Files app › this app › cheats › \(build.isEmpty ? "<build ID>" : build).txt, then Reload", disabled: true)]
        let others = Int(dm_cheats_nothers())
        if others > 0 {
            rows.append(GameMenuItem(id: "cheats.others", title: others == 1 ? "1 file is for another game version" : "\(others) files are for other game versions", disabled: true))
        }
        rows.append(reload)
        return GameMenuItem(id: "cheats", title: "Cheats", subtitle: "None loaded", symbol: "wand.and.stars", kind: .submenu([GameMenuSection(id: "cheats.all", inline: false, items: rows)]))
    }
    let master = dm_cheats_master() != 0
    let masterRow = GameMenuItem(id: "cheats.master", title: "Cheats on", kind: .toggle(master)) { _ in dm_cheats_master_set(master ? 0 : 1) }
    var groups = [GameMenuSection(id: "cheats.master", items: [masterRow])]
    var rows: [GameMenuItem] = [], section = "", on = 0
    func flush() {
        if !rows.isEmpty { groups.append(GameMenuSection(id: "cheats.section.\(groups.count)", title: section, items: rows)) }
        rows = []
    }
    for i in 0..<Int32(n) {
        let flags = dm_cheat_flags_at(i), kind = dm_cheat_kind_at(i)
        if flags & cheatLabel != 0 || flags & cheatPairOff != 0 { continue }   // credits and section markers; an on / off pair's off half is its on half's row
        let sec = String(cString: dm_cheat_section_at(i))
        if sec != section { flush(); section = sec }
        let name = String(cString: dm_cheat_name_at(i))
        let why = String(cString: dm_cheat_why_at(i)).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        let isOn = dm_cheat_on_at(i) != 0
        let id = "cheat:\(i)"
        switch kind {
        case 1:   // a master: always on
            rows.append(GameMenuItem(id: id, title: name, subtitle: "Always on", disabled: true, kind: .toggle(true)))
        case 2:   // broken, or turned off while running: the reason
            rows.append(GameMenuItem(id: id, title: name, subtitle: why.isEmpty ? "Cannot run" : why, disabled: true, kind: .toggle(false)))
        default:
            let once = flags & cheatOnce != 0
            let note: String? = once ? "Runs once when tapped" : why.isEmpty ? nil : why
            rows.append(GameMenuItem(id: id, title: name, subtitle: note, disabled: !master, kind: once ? .action : .toggle(isOn)) { _ in dm_cheat_toggle(i) })
            if isOn && !once { on += 1 }
        }
    }
    flush()
    groups.append(GameMenuSection(id: "cheats.reload", items: [reload]))
    let version = String(cString: dm_cheats_version())
    let subtitle = !master ? "Off" : on == 0 ? "None on" : "\(on) on"
    return GameMenuItem(id: "cheats", title: version.isEmpty ? "Cheats" : "Cheats (\(version))", subtitle: subtitle, symbol: "wand.and.stars", kind: .submenu(groups))
}

// One live setting's row. Its subtitle is the reason it does nothing at the moment, the first that holds of:
// - the front end holds its value (dm_setting_held: Picture while Ultrawide stretches the picture), or a launcher rule greys the whole row (LauncherModel.inactiveWhy): the row is
//   greyed, so it cannot be changed, as on the settings screen, and ticks the value the game has then (dm_setting_held_value's Stretch, else the launcher's shows rule,
//   LauncherModel.shown), not the saved choice, which stays as it is;
// - the running game's own state (front_ios.m dm_setting_why: MetalFX not upscaling a stretched picture, the touch controls hidden by a controller), read each time the menu
//   opens, as it is built then;
// - a launcher rule about the choice made or the device (LauncherModel.reason: Rumble needs a controller on this device), unless the running game says the choice works right
//   now (front_ios.m dm_setting_working: MetalFX upscaled at the last present, where the launcher's hint can only say it may not under Stretch).
// An option a rule greys (MetalFX on a device without the scaler) cannot be picked, with its reason under it; the others stay selectable. Nothing here changes a saved choice.
// An env file's value is shown, not changed, as before
@MainActor private func gameMenuRow(_ m: LauncherModel, _ s: Setting) -> GameMenuItem {
    let held = dm_setting_held(s.env), fixed = m.fixed.contains(s.env)
    let now = (held ? dm_setting_held_value(s.env).map { String(cString: $0) } : nil) ?? m.shown(s)   // the value the game has: Stretch while Ultrawide holds Picture
    let live: String? = dm_setting_why(s.env).map { String(cString: $0) }
    let greyed: String? = held ? (live ?? "") : m.inactiveWhy(s)
    let why = greyed ?? live ?? (dm_setting_working(s.env) ? nil : m.reason(s)?.why)
    let note = why.flatMap { $0.isEmpty ? nil : $0 }
    let locked = fixed || greyed != nil
    func pick(_ v: String) { if m.choose(s, v) { dm_setting_env(s.env, v) }; _ = dm_setting_live(s.env, v) }   // saved, into the environment (under front_ios.m's lock), then applied
    if s.kind == "toggle" {
        let next = now == s.onValue ? s.offValue : s.onValue
        return GameMenuItem(id: "row:\(s.env)", title: s.label, subtitle: fixed ? "Set in env.txt" : note,
                            disabled: locked || m.optionInactive(s, next) != nil, kind: .toggle(now == s.onValue)) { _ in pick(next) }   // the value it would switch to may be greyed
    }
    let options = s.options ?? []
    let current = options.first { $0[0] == now }?[1] ?? now
    let picks = options.map { o in
        let off = o[0] == now ? nil : m.optionInactive(s, o[0])
        return GameMenuItem(id: "row:\(s.env)=\(o[0])", title: o[1], subtitle: !locked ? off.flatMap { $0.isEmpty ? nil : $0 } : nil,
                            disabled: locked || off != nil, kind: .toggle(o[0] == now)) { _ in pick(o[0]) }
    }
    return GameMenuItem(id: "row:\(s.env)", title: s.label, subtitle: fixed ? "\(current), set in env.txt" : note, kind: .choice(picks))
}
