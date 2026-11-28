// The in-game menu, opened by the gamepad's menu button at the top centre (DmGamepad.m): the controller layout, then the settings-screen settings the running game takes at once
// (front_ios.m dm_setting_live), grouped as on the settings screen, one row each (the touch controls' three: one Touch controls row, touchControlsRow), then the Cheats submenu
// (cheatsMenu), Gate at start (settingsAtStartRow) and Share log (dmShareLog). A pick is saved as Play saves it (LauncherModel.choose), so the settings screen shows it
// at the next start; a setting an env file fixes is shown, not changed. Settings that need the next start (language, pipelines, the frame rate and so on), and the sliders, stay on
// the settings screen, which the menu's title points to. A row that does nothing at the moment says why under its name (gameMenuRow): greyed when nothing the player picks there
// can take effect, still selectable when only the current choice does nothing. The menu is built here once as GameMenuItem rows (gameMenuSections), each time it opens, and drawn
// two ways: by default as NX 18's own panel (GameMenuPanel.swift: NX 18's colours and UI font, touch, controller and VoiceOver), and with DM_GAME_MENU=system as the UIMenu it
// always was (gameMenuItems, uiMenuElement; DmGamepad.m picks), so both show the same rows, notes and actions.
// The Mac's game app builds the same rows in its host (dm/host/Makefile links this file, GameMenuPanel.swift and the launcher's model into dmhost; front_mac.m dm_setting_live):
// no controller layout, touch controls or recording there, Show log in place of Share log, Gate at start is the Mac window's own choice (window.show), and a Quit row
#if os(iOS)
import UIKit
typealias GameMenuAnchor = UIView   // what a pick is anchored to: the menu button (an iPad's popover points at it)
#else
import AppKit
typealias GameMenuAnchor = NSView   // the game window's content view (front_mac.m)
#endif

@MainActor var gameMenuModel: LauncherModel?   // main-actor state: written by dm_show_launcher, read by the menu, both on the main thread; the settings screen's model (Launcher.swift); nil in an app without one: the menu has the layout only

// One row of the in-game menu
struct GameMenuItem: Identifiable {
    enum Kind {
        case action                       // a button: Share log, Reload cheats, a cheat that runs once, a greyed line that only informs
        case toggle(Bool)                 // on or off: ticked in the UIMenu, a switch in the panel (an option of a choice: the one chosen)
        case choice([GameMenuItem])       // one of several (each a .toggle, the current one on): a single-selection submenu, a page of options in the panel
        case submenu([GameMenuSection])   // Cheats, Touch controls
    }
    let id: String                        // unique in the menu: the panel's focus and VoiceOver keep their place by it while the rows are built again
    var title: String
    var subtitle: String?                 // the row's note: why it does nothing at the moment, a fixed value, a cheat's state
    var symbol: String?                   // an SF Symbol
    var disabled = false
    var closesMenu = false                // the panel closes first (Share log: the share sheet or the alert is the system's, over the game)
    var summary = false                   // a submenu whose subtitle sums up its page's values (Touch controls): the panel draws it under the name, VoiceOver reads it as the value
    var kind: Kind
    var perform: (@MainActor (GameMenuAnchor?) -> Void)?   // the pick; its argument is the menu button (an iPad's popover points at it), the game's view on the Mac

    init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, disabled: Bool = false, closesMenu: Bool = false, summary: Bool = false, kind: Kind = .action,
         perform: (@MainActor (GameMenuAnchor?) -> Void)? = nil) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.disabled = disabled; self.closesMenu = closesMenu; self.summary = summary; self.kind = kind
        self.perform = perform
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

#if os(iOS)
@_cdecl("dm_game_menu")
public func dmGameMenu(_ button: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let bits = UInt(bitPattern: button)   // the pointer as a number into the main actor's closure (a raw pointer is not Sendable)
    let menu = MainActor.assumeIsolated {   // DmGamepad.m asks for the menu on the main thread (UIKit); a call from any other thread stops here instead of racing gameMenuModel
        systemMenuButton = UnsafeMutableRawPointer(bitPattern: bits).map { Unmanaged<UIButton>.fromOpaque($0).takeUnretainedValue() }
        GameDocumentsStore.shared.menuChanged = refreshVisibleSystemMenu
        return UIMenu(title: gameMenuTitle(), identifier: systemMenuRoot,
                      children: [UIDeferredMenuElement.uncached { done in done(gameMenuItems()) }])   // built each time it opens, so it shows the current choices
    }
    return Unmanaged.passRetained(menu).toOpaque()
}
private let systemMenuRoot = UIMenu.Identifier("org.nx18.game-menu")
@MainActor private weak var systemMenuButton: UIButton?   // the menu button holding the UIMenu (DmGamepad.m), not retained here
// The documents' listing came back while the UIMenu shows (its first open lists them): its top level is built again, so Manual & documents appears without closing and opening
// it. Only the top level: a submenu the player went into is left as it is (they see the row when they go back). Nothing when no menu is up
@MainActor private func refreshVisibleSystemMenu() {
    systemMenuButton?.contextMenuInteraction?.updateVisibleMenu { m in m.identifier == systemMenuRoot ? m.replacingChildren(gameMenuItems()) : m }
}


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
#endif

#if os(iOS)
@MainActor func gameMenuTitle() -> String { gameMenuModel != nil ? "More on the settings screen" : "" }
#else
@MainActor func gameMenuTitle() -> String { gameMenuModel != nil ? "More in the settings window" : "" }
#endif

// The rows, built each time the menu opens (and after each pick in the panel), so they show the current choices
@MainActor func gameMenuSections() -> [GameMenuSection] {
    gameMenuModel?.refreshFacts()   // the rules' device terms as they are now: the app's window (an iPad's, resized while the game runs; MetalFX's Stretch rules), a TV
    #if os(iOS)
    let names = ["2D", "3D", "Tap"]
    let layouts = (0..<3).filter { dm_pad_layout_offered(Int32($0)) }.map { l in
        GameMenuItem(id: "layout=\(l)", title: names[l], kind: .toggle(dm_pad_layout() == l)) { _ in dm_pad_layout_set(Int32(l)) }
    }
    let layout: GameMenuItem? = GameMenuItem(id: "layout", title: "Controller layout", kind: .choice(layouts))
    #else
    let layout: GameMenuItem? = nil   // the touch controls' layout: the Mac has none
    #endif
    var sections: [GameMenuSection] = []
    var placed = layout == nil
    if let m = gameMenuModel {
        for section in m.sections {
            var rows: [GameMenuItem] = section == "Controls" ? (layout.map { [$0] } ?? []) : []
            if section == "Controls" { placed = true }
            var touch: [(setting: Setting, item: GameMenuItem)] = [], touchAt = 0   // the touch controls' rows shown, and where the first was
            for s in m.rows(in: section) where (s.kind == "choice" || s.kind == "toggle") && dm_setting_live(s.env, nil) {
                if touchControlEnvs.contains(s.env) { if touch.isEmpty { touchAt = rows.count }; touch.append((s, gameMenuRow(m, s))) } else { rows.append(gameMenuRow(m, s)) }
            }
            if !touch.isEmpty { rows.insert(contentsOf: touch.count > 1 ? [touchControlsRow(m, touch)] : touch.map(\.item), at: touchAt) }   // one alone stays a plain row
            if !rows.isEmpty { sections.append(GameMenuSection(id: "section:\(section)", heading: section, items: rows)) }
        }
    }
    if !placed, let layout { sections.insert(GameMenuSection(id: "section:Controls", heading: "Controls", items: [layout]), at: 0) }
    if let cheats = cheatsMenu() { sections.append(GameMenuSection(id: "section:cheats", heading: "More", items: [cheats])) }
    if let docs = gameDocumentsRow() { sections.append(GameMenuSection(id: "section:docs", heading: "More", items: [docs])) }   // Manual & documents (GameDocumentsViewer.swift)
    #if os(iOS)
    let shot = GameMenuItem(id: "screenshot", title: "Take Screenshot", subtitle: "Saved in the game's Captures folder", symbol: "camera", closesMenu: true) { anchor in dm_capture_screenshot(anchor) }   // DmCapture.m: the next frame, once the panel is gone
    let rec = dm_capture_recording()
    let record = GameMenuItem(id: "record", title: rec ? "Stop Recording" : "Start Recording", subtitle: rec ? { let t = dm_capture_recording_seconds(); return "Recording for \(t / 60):\(String(format: "%02d", t % 60))" }() : "The game and its sound, until you stop it", symbol: rec ? "stop.circle" : "record.circle", closesMenu: true) { anchor in dm_capture_record_toggle(anchor) }   // DmCapture.m: ScreenCaptureKit
    let share = GameMenuItem(id: "share", title: "Share log", symbol: "square.and.arrow.up", closesMenu: true) { anchor in dmShareLog(from: anchor) }
    var last: [GameMenuItem] = []
    if let m = gameMenuModel { last.append(settingsAtStartRow(m)) }
    sections.append(GameMenuSection(id: "section:app", heading: "More", items: [shot, record] + last + [share]))
    #else
    sections.append(GameMenuSection(id: "section:app", heading: "More", items: macMoreRows()))
    #endif
    return sections
}

// The panel's first page in the Gate's language (gate-ui §19.2, presets-first §8): the preset chooser (the panel draws it from the launcher's model), the live quick tiles,
// 3 per row (Picture, Console mode, Vitals, Game rumble, Touch controls, Controller layout: each only where the game takes it live and the list shows it), and the doors:
// Customize (the live rows a preset sets, then the other live rows, then Back to the base while Custom), Cheats (only with a cheats folder), Manual & documents (only when there is
// one: GameDocumentsViewer.swift) and More (Take Screenshot, Gate at start, Share log). Four doors stand two by two (GameMenuLayout.doorLines).
// The same items as gameMenuSections (its rows, ids and actions), so a pick does what it does in the UIMenu; DM_GAME_MENU=system keeps that flat list
struct GameMenuHome {
    var tiles: [GameMenuItem] = []
    var doors: [GameMenuItem] = []
}
#if os(iOS)
let gameMenuTileOrder = ["DM_PICTURE_FIT", "DM_OPMODE", "DM_SHOW_FPS", "DM_RUMBLE", "touch", "layout"]
#else
let gameMenuTileOrder = ["DM_OPMODE", "DM_FULLSCREEN", "DM_RUMBLE"]   // the Mac's Gate swaps Display mode in for Picture (LauncherPanel.swift gateQuickFirst); no touch controls
#endif

@MainActor func gameMenuHome() -> GameMenuHome {
    let flat = gameMenuSections().flatMap(\.items)
    func item(_ key: String) -> GameMenuItem? {
        switch key {
        case "touch": return flat.first { $0.id == "touch" } ?? flat.first { touchControlEnvs.contains(String($0.id.dropFirst(4))) }
        case "layout": return flat.first { $0.id == "layout" }
        default: return flat.first { $0.id == "row:\(key)" }
        }
    }
    var home = GameMenuHome()
    home.tiles = gameMenuTileOrder.compactMap(item)
    let onTiles = Set(home.tiles.map(\.id) + flat.filter { touchControlEnvs.contains(String($0.id.dropFirst(4))) }.map(\.id))
    let rest = flat.filter { $0.id.hasPrefix("row:") && !onTiles.contains($0.id) }
    var groups: [GameMenuSection] = []
    if let m = gameMenuModel {
        let preset = Set(m.presetRows.map { "row:\($0.env)" })
        let a = rest.filter { preset.contains($0.id) }, b = rest.filter { !preset.contains($0.id) }
        if !a.isEmpty { groups.append(GameMenuSection(id: "customize.preset", heading: "Picture", items: a)) }
        if !b.isEmpty { groups.append(GameMenuSection(id: "customize.other", heading: "Other choices", items: b)) }
        if m.isCustom {
            let base = m.basePreset
            groups.append(GameMenuSection(id: "customize.back", items: [GameMenuItem(id: "customize.back", title: "Back to \(base.title)", subtitle: "The preset's settings again", symbol: "arrow.uturn.backward") { _ in
                _ = gameMenuApplyPreset(m) { m.backToBase() }
            }]))
        }
    } else if !rest.isEmpty {
        groups.append(GameMenuSection(id: "customize.other", heading: "Other choices", items: rest))
    }
    if !groups.isEmpty {
        let n = groups.flatMap(\.items).filter { $0.id.hasPrefix("row:") }.count
        home.doors.append(GameMenuItem(id: "door.customize", title: "Customize", subtitle: n == 1 ? "1 setting" : "\(n) settings", symbol: "slider.horizontal.3", kind: .submenu(groups)))
    }
    if let cheats = flat.first(where: { $0.id == "cheats" }) { home.doors.append(cheats) }
    if let docs = flat.first(where: { $0.id == "docs" }) { home.doors.append(docs) }   // Manual & documents, only when the game has a manual, a guide or a document of the player's
    let more = flat.filter { gameMenuMoreIDs.contains($0.id) }
    home.doors.append(GameMenuItem(id: "door.more", title: "More", subtitle: gameMenuMoreSummary, symbol: "ellipsis.circle", kind: .submenu([GameMenuSection(id: "more.all", inline: false, items: more)])))
    return home
}

// The More door's rows (gameMenuSections' last section) and its summary
#if os(iOS)
let gameMenuMoreIDs: Set<String> = ["screenshot", "record", GameMenuExit.rowID, "share"]
let gameMenuMoreSummary = "Screenshot, Recording, Exit to Gate, Share log"
#else
let gameMenuMoreIDs: Set<String> = ["screenshot", GameMenuExit.rowID, "log", "quit"]
let gameMenuMoreSummary = "Screenshot, Exit, Log, Quit"   // Exit: to the Gate, or to Beam after a start from Beam (macExitRow)
#endif

// A preset change in game (gate-ui §19.3): the launcher's model moves and saves the values (LauncherModel.inGame); the rows the game takes live go into the environment under
// front_ios.m's lock and apply at once (dm_setting_env, dm_setting_live), the others wait for the next start. Returns what changed now and what waits, as short words
@MainActor func gameMenuApplyPreset(_ m: LauncherModel, _ change: () -> Void) -> (now: [String], next: [String]) {
    var now: [String] = [], next: [String] = []
    for s in m.inGame(change) {
        let v = m.values[s.env] ?? s.def
        if dm_setting_live(s.env, nil) { dm_setting_env(s.env, v); _ = dm_setting_live(s.env, v); now.append(gameMenuWords(m, s)) } else { next.append(gameMenuWords(m, s)) }
    }
    now += gameMenuPresetEnv(m)   // also when no row moved: Undo or Back can change the preset alone
    return (now, next)
}

// The preset the values are now (LauncherModel.presetEnvValue) into the environment while the game runs, under front_ios.m's lock as a pick goes (dm_setting_env): the host's frame
// generation reads DM_PRESET again once a second through front_env_copy (nvn_framegen.inc fg_power_why) and steps aside in Battery Saver, or comes back from it. After every preset
// change in game (gameMenuApplyPreset: a chip, L / R, X, Back to the base, Undo) and a hand change to a preset row, which can make it Custom or another preset. Nothing without
// frame generation (LauncherModel.framegenOn), when an env file or the launch set DM_PRESET, or when it is already that.
// The preset's switches no row sets (LauncherModel.presetSwitches: Bananza's Battery Saver DM_FPS_CTL=hold30) go in the same way; the host reads DM_FPS_CTL again once a second
// (hle_fctl.c fctl_mode_poll), so they apply while the game runs. Returns their words for the toast ("Steady 30 fps", "Up to 60 fps")
@discardableResult @MainActor func gameMenuPresetEnv(_ m: LauncherModel) -> [String] {
    var words: [String] = []
    for (e, v) in m.presetSwitches where (getenv(e).map { String(cString: $0) } ?? "") != v {   // the main thread is the only one that writes them
        dm_setting_env(e, v); fputs("launcher: \(e)=\(v) (in-game menu)\n", stderr)
        if e == "DM_FPS_CTL" { words.append(v == "hold30" ? "Steady 30 fps" : "Up to 60 fps") }
    }
    guard LauncherModel.framegenOn, let p = m.presetEnvValue, getenv("DM_PRESET").map({ String(cString: $0) }) != p else { return words }
    dm_setting_env("DM_PRESET", p); fputs("launcher: DM_PRESET=\(p) (in-game menu)\n", stderr)
    return words
}

// What a preset row's value is now in a few words: "30 fps", "Render scale 85 %", "Upscaling MetalFX"
@MainActor func gameMenuWords(_ m: LauncherModel, _ s: Setting) -> String {
    let v = m.gateValue(s)
    return s.label == "Frame rate" ? v : "\(s.label) \(v)"
}

// The preset rows the game does not take live whose saved value differs from the one this run started with (the environment at Play: Launcher.swift apply, or applySaved's
// saved choices over the defaults): "At next start: 30 fps". Read when the menu draws, so it holds across openings and ends with the run
@MainActor func gameMenuPending(_ m: LauncherModel) -> [String] {
    m.presetRows.filter { m.visible($0) && !m.hidden($0) && !dm_setting_live($0.env, nil) }.compactMap { s in
        let started = getenv(s.env).map { String(cString: $0) } ?? s.def
        return s.same(started, m.values[s.env] ?? s.def) ? nil : gameMenuWords(m, s)
    }
}

// Touch controls: the touch controls' rows (Touch control size, Touch control opacity, and Touch feedback where the device has haptics: the launcher's hide rule leaves it out
// of m.rows elsewhere) as one row opening a page of them, as Cheats does, where each choice opens its options and B goes back a page at a time. Its subtitle sums up their values
// ("Large · Normal · Feedback on", without a hidden row's part), or, while the touch controls are hidden (a controller, the Tap layout), says so as Touch feedback's own note does
// (front_ios.m dm_setting_why). The settings screen keeps its three rows
private let touchControlEnvs: Set<String> = ["DM_TOUCH_SIZE", "DM_TOUCH_OPACITY", "DM_TOUCH_HAPTICS"]

@MainActor private func touchControlsRow(_ m: LauncherModel, _ rows: [(setting: Setting, item: GameMenuItem)]) -> GameMenuItem {
    let parts = rows.map { r -> String in
        if case .choice = r.item.kind { return r.item.currentOption ?? m.shown(r.setting) }   // a choice: the option it has, or an env file's value no option has (DM_TOUCH_SIZE=0.9), as its row's subtitle shows it
        let name = r.setting.label.hasPrefix("Touch ") ? String(r.setting.label.dropFirst(6)) : r.setting.label   // Touch feedback: "Feedback on"
        return name.prefix(1).uppercased() + name.dropFirst() + (r.item.isOn ? " on" : " off")
    }
    let hidden = dm_setting_why("DM_TOUCH_HAPTICS").map { String(cString: $0) }
    return GameMenuItem(id: "touch", title: "Touch controls", subtitle: hidden ?? parts.joined(separator: " · "), summary: true,
                        kind: .submenu([GameMenuSection(id: "touch.all", inline: false, items: rows.map(\.item))]))
}

// Exit and return to Gate (the owner, 2026-11-27; the row was Gate at start, which stays on the Gate itself: Skip this screen next time). The row opens a confirmation page of
// the panel (GameMenuPanel.swift: the question and its warning head the page, Keep Playing has the focus, B and the ‹ go back without exiting); Exit to Gate, in the second
// accent, ends the game. The game cannot be unloaded inside the process, and iOS cannot start the process again, so the iPhone and iPad end it as oe::ExecuteProgram's
// hand-over does and show the Gate at the next start, once (front_ios.m dm_exit_to_gate, LauncherModel.gateNextKey); the Mac quits and opens the app again at its settings
// window, or goes back to Beam after a start from Beam (macExitToGate). The UIMenu (DM_GAME_MENU=system) shows the page as a submenu of the two
enum GameMenuExit {
    static let rowID = "exit", yesID = "exit.yes", noID = "exit.no"
    static let title = "Exit and return to Gate", note = "Ends the game; unsaved progress is lost"
    static let question = "Exit the game?", warning = "Progress since your last save is lost."

    @MainActor static func make(title: String = Self.title, note: String = Self.note, yes yesTitle: String = "Exit to Gate", exit: @escaping @MainActor () -> Void) -> GameMenuItem {
        let leave = GameMenuItem(id: Self.yesID, title: yesTitle, symbol: "rectangle.portrait.and.arrow.right", closesMenu: true) { _ in exit() }
        let stay = GameMenuItem(id: Self.noID, title: "Keep Playing", symbol: "gamecontroller")   // GameMenuPanelModel.activate: back a page
        return GameMenuItem(id: Self.rowID, title: title, subtitle: note, symbol: "rectangle.portrait.and.arrow.right",
                            kind: .submenu([GameMenuSection(id: Self.rowID + ".confirm", inline: false, items: [leave, stay])]))
    }
}

#if os(iOS)
// The More page's Gate row (the name kept from Gate at start: the menu's sections call it), on an app with a Gate (a launcher model)
@MainActor func settingsAtStartRow(_ m: LauncherModel) -> GameMenuItem {
    GameMenuExit.make { dm_exit_to_gate() }
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
#else
// The Mac's More rows: Take Screenshot (front_mac.m's own, as Capture and ⇧⌘S take it), Exit and return to Gate, Show log, Quit
@MainActor func macMoreRows() -> [GameMenuItem] {
    let shot = GameMenuItem(id: "screenshot", title: "Take Screenshot", subtitle: "Saved in the game's Captures folder", symbol: "camera", closesMenu: true) { _ in dm_mac_capture() }
    let log = GameMenuItem(id: "log", title: "Show log", subtitle: "The log in Finder, for a bug report", symbol: "doc.text.magnifyingglass", closesMenu: true) { _ in macShowLog() }
    let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "the game"
    let quit = GameMenuItem(id: "quit", title: "Quit \(name)", subtitle: "As ⌘Q: unsaved progress is lost", symbol: "power", closesMenu: true) { _ in NSApp.terminate(nil) }
    return [shot, macExitRow(), log, quit]
}

// Exit and return to Gate on the Mac (GameMenuExit): after a start from Beam (GamePlayer.swift sets DM_STARTED_BY=beam, with DM_LAUNCHER=0) the game quits and Beam comes to the
// front, its Home; otherwise the game quits and the app opens again at its settings window, once (launcher.c, once the host has ended and the save went to the cloud)
enum MacExitTarget: Equatable, Sendable {
    case beam, gate
    static let beamBundleID = "org.nx18.beam"
    nonisolated static func of(_ environment: [String: String]) -> MacExitTarget { environment["DM_STARTED_BY"] == "beam" ? .beam : .gate }
}

@MainActor func macExitRow() -> GameMenuItem {
    MacExitTarget.of(ProcessInfo.processInfo.environment) == .beam
        ? GameMenuExit.make(title: "Exit and return to Beam", note: "Ends the game; unsaved progress is lost", yes: "Exit to Beam") { macExitToGate() }
        : GameMenuExit.make { macExitToGate() }
}

// The exit itself: the same orderly quit as the Quit row (NSApp terminate: the save writer and the other exit handlers run as for ⌘Q). For the Gate, the one-shot key first,
// written through to the preferences store before the quit, which launcher.c reads once the host has ended. For Beam, Beam is brought forward first, while this app is still the
// active one (the system's cooperative activation lets the active app hand over); a Beam no longer running is opened
@MainActor func macExitToGate() {
    switch MacExitTarget.of(ProcessInfo.processInfo.environment) {
    case .beam:
        if let beam = NSRunningApplication.runningApplications(withBundleIdentifier: MacExitTarget.beamBundleID).first {
            _ = beam.activate(from: NSRunningApplication.current, options: [])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacExitTarget.beamBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        fputs("game menu: exit chosen; the game quits and Beam comes to the front\n", stderr)
    case .gate:
        UserDefaults.standard.set(true, forKey: LauncherModel.gateNextKey)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        fputs("game menu: exit chosen; the game quits and the app opens again at the settings window\n", stderr)
    }
    NSApp.terminate(nil)
}

// Show log: this run's log (~/Library/Logs/nxnative/<title ID>.log, launcher.c) selected in Finder, which docs/playing.md asks for in a bug report. The path is not logged
@MainActor func macShowLog() {
    guard let id = Bundle.main.object(forInfoDictionaryKey: "DMTitleID") as? String, !id.isEmpty else { return }
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nxnative", isDirectory: true)
    let log = logs.appendingPathComponent("\(id).log")
    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: log.path) ? log : logs])
    fputs("show log: in Finder\n", stderr)
}
#endif

// Cheats: the Atmosphère cheat file of this build in the cheats folder (Documents/cheats, which main.m makes; in the Files app under the app's name), as the Mac's Cheats menu
// shows it (front_mac.m): one row per cheat, a tap turns it on or off and is remembered (<build ID>.enabled); a "{master}" code is always on; a cheat that cannot run here
// shows why, disabled (the iPhone's code pages are signed, so a cheat that rewrites code runs only on the Mac: pack a code patch into the app instead, the NSP script's mods
// folder). An on / off pair is one row; a "set" cheat runs once when tapped. Then the master switch and Reload, which reads the folder again after a file was copied in.
#if os(iOS)
private let cheatsPlace = "Files app › this app › cheats"
#else
private let cheatsPlace = "Cheats menu › Open cheats folder"   // front_mac.m's Cheats menu
#endif
private let cheatLabel: Int32 = 1, cheatPairOff: Int32 = 16, cheatOnce: Int32 = 32   // dm.h DM_CHEAT_*

@MainActor private func cheatsMenu() -> GameMenuItem? {
    if String(cString: dm_cheats_dir_path()).isEmpty { return nil }   // no cheats folder (DM_CHEATS=""), or the host is still loading them (hle_cheats.c): no submenu, until an open after that
    let reload = GameMenuItem(id: "cheats.reload", title: "Reload cheats", symbol: "arrow.clockwise") { _ in dm_cheats_reload() }
    let build = String(cString: dm_cheats_build())
    let n = Int(dm_cheats_ncheats())
    if dm_cheats_found() == 0 || n == 0 {
        var rows = [GameMenuItem(id: "cheats.none", title: build.isEmpty ? "No cheat file" : "No cheats for build \(build)",
                                 subtitle: "\(cheatsPlace) › \(build.isEmpty ? "<build ID>" : build).txt, then Reload", disabled: true)]
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
// - a launcher rule that greys the choice made (LauncherModel.optionInactive: MetalFX under a Stretch that changes the picture's shape, or on a device without the scaler), as
//   the settings screen's note says it, at once after the pick that brought it (Picture set to Stretch here), before the next present can tell;
// - the running game's own state (front_ios.m dm_setting_why: MetalFX not upscaling a stretched picture, the touch controls hidden by a controller), read each time the menu
//   opens, as it is built then;
// - a launcher rule about the choice made or the device (LauncherModel.reason: Rumble needs a controller on this device), unless the running game says the choice works right
//   now (front_ios.m dm_setting_working: MetalFX upscaled at the last present, where the launcher's hint can only say it may not under Ultrawide).
// An option a rule greys (MetalFX on a device without the scaler, or under Stretch) cannot be picked, with its reason under it; the others stay selectable. The option chosen
// is drawn greyed as well while a rule greys it, ticked, as the settings screen's menu draws it: picking it again would change nothing. Nothing here changes a saved choice.
// An env file's or the launch's value is shown, not changed, as before, said as the settings screen says it (LauncherRow.swift)
@MainActor private func gameMenuRow(_ m: LauncherModel, _ s: Setting) -> GameMenuItem {
    let held = dm_setting_held(s.env), fixed = m.fixed.contains(s.env)
    let now = (held ? dm_setting_held_value(s.env).map { String(cString: $0) } : nil) ?? m.shown(s)   // the value the game has: Stretch while Ultrawide holds Picture
    let live: String? = dm_setting_why(s.env).map { String(cString: $0) }
    let greyed: String? = held ? (live ?? "") : m.inactiveWhy(s)
    let ruled = m.optionInactive(s, now)   // the choice made does nothing while the rule holds (MetalFX with Stretch)
    let why = greyed ?? ruled ?? live ?? (dm_setting_working(s.env) ? nil : m.reason(s)?.why)
    let note = why.flatMap { $0.isEmpty ? nil : $0 }
    let locked = fixed || greyed != nil
    func pick(_ v: String) { if m.choose(s, v) { dm_setting_env(s.env, v); if s.preset != nil { gameMenuPresetEnv(m) } }; _ = dm_setting_live(s.env, v) }   // saved, into the environment (under front_ios.m's lock), then applied; a preset row's change can change the preset
    if s.kind == "toggle" {
        let next = now == s.onValue ? s.offValue : s.onValue
        return GameMenuItem(id: "row:\(s.env)", title: s.label, subtitle: fixed ? (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file") : note,
                            disabled: locked || m.optionInactive(s, next) != nil, kind: .toggle(now == s.onValue)) { _ in pick(next) }   // the value it would switch to may be greyed
    }
    let options = s.options ?? []
    let current = options.first { $0[0] == now }?[1] ?? now
    let picks = options.map { o in
        let off = m.optionInactive(s, o[0])
        return GameMenuItem(id: "row:\(s.env)=\(o[0])", title: o[1], subtitle: !locked ? off.flatMap { $0.isEmpty ? nil : $0 } : nil,
                            disabled: locked || off != nil, kind: .toggle(o[0] == now)) { _ in pick(o[0]) }
    }
    return GameMenuItem(id: "row:\(s.env)", title: s.label, subtitle: fixed ? "\(current), \(m.fromLaunch.contains(s.env) ? "set at launch" : "set by an env file")" : note, kind: .choice(picks))
}
