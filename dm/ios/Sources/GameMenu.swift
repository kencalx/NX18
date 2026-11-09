// The in-game menu, opened by the gamepad's menu button at the top centre (DmGamepad.m): the controller layout, then the settings-screen settings the running game takes at once
// (front_ios.m dm_setting_live), grouped as on the settings screen but without its headings, one row each, so the menu stays short over the game (its text size is fixed: front_ios.m
// startGame), then the Cheats submenu (cheatsMenu) and Share log (dmShareLog). A pick is saved as Play saves it (LauncherModel.choose), so the settings screen shows it at the next start; a setting an env file fixes is shown, not changed. Settings
// that need the next start (language, pipelines, the frame rate and so on), and the sliders, stay on the settings screen, which the menu's title points to.
import UIKit

@MainActor var gameMenuModel: LauncherModel?   // main-actor state: written by dm_show_launcher, read by the menu, both on the main thread; the settings screen's model (Launcher.swift); nil in an app without one: the menu has the layout only

@_cdecl("dm_game_menu")
public func dmGameMenu() -> UnsafeMutableRawPointer {
    let menu = MainActor.assumeIsolated {   // DmGamepad.m asks for the menu on the main thread (UIKit); a call from any other thread stops here instead of racing gameMenuModel
        let title = gameMenuModel != nil ? "More settings on the start screen" : ""
        return UIMenu(title: title, children: [UIDeferredMenuElement.uncached { done in done(gameMenuItems()) }])   // built each time it opens, so it shows the current choices
    }
    return Unmanaged.passRetained(menu).toOpaque()
}

@MainActor private func gameMenuItems() -> [UIMenuElement] {
    let names = ["2D", "3D", "Tap"]
    let layouts = (0..<3).filter { dm_pad_layout_offered(Int32($0)) }.map { l in
        UIAction(title: names[l], state: dm_pad_layout() == l ? .on : .off) { _ in dm_pad_layout_set(Int32(l)) }
    }
    let layout = UIMenu(title: "Controller layout", options: .singleSelection, children: layouts)   // a choice's value shows in its submenu: a subtitle would make each row two lines
    var items: [UIMenuElement] = []
    var placed = false
    if let m = gameMenuModel {
        for section in m.sections {
            var rows: [UIMenuElement] = section == "Controls" ? [layout] : []
            if section == "Controls" { placed = true }
            for s in m.rows(in: section) where (s.kind == "choice" || s.kind == "toggle") && dm_setting_live(s.env, nil) { rows.append(gameMenuRow(m, s)) }
            if !rows.isEmpty { items.append(UIMenu(options: .displayInline, children: rows)) }
        }
    }
    if !placed { items.insert(UIMenu(options: .displayInline, children: [layout]), at: 0) }
    if let cheats = cheatsMenu() { items.append(UIMenu(options: .displayInline, children: [cheats])) }
    let share = UIAction(title: "Share log", image: UIImage(systemName: "square.and.arrow.up")) { action in dmShareLog(from: action.sender as? UIView) }   // the gear, for an iPad's popover
    items.append(UIMenu(options: .displayInline, children: [share]))
    return items
}

// Share log: the in-game menu's last row. One share sheet with Documents/log.txt and log.prev.txt (the run before this one, which main.m keeps under that name at each start: a run
// that crashed or that iOS ended), the files docs/playing.md asks for in a bug report. Each is copied into tmp/share-log first, so the sheet reads a snapshot: log.txt is still being
// written while the app runs (APFS clones the copy, which takes no room until the log grows). A missing file is left out; the copies of the share before are deleted at the next (and
// iOS empties tmp by itself). On an iPad the sheet is a popover: it points at the view the share came from (the gear), or sits in the middle of the screen
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

@MainActor private func cheatsMenu() -> UIMenuElement? {
    if String(cString: dm_cheats_dir_path()).isEmpty { return nil }   // no cheats folder (DM_CHEATS=""), or the host is still loading them (hle_cheats.c): no submenu, until an open after that
    let reload = UIAction(title: "Reload cheats", image: UIImage(systemName: "arrow.clockwise")) { _ in dm_cheats_reload() }
    let build = String(cString: dm_cheats_build())
    let n = Int(dm_cheats_ncheats())
    if dm_cheats_found() == 0 || n == 0 {
        let none = UIAction(title: build.isEmpty ? "No cheat file" : "No cheats for build \(build)", attributes: .disabled) { _ in }
        none.subtitle = "Files app › this app › cheats › \(build.isEmpty ? "<build ID>" : build).txt, then Reload"
        var rows: [UIMenuElement] = [none]
        let others = Int(dm_cheats_nothers())
        if others > 0 {
            let o = UIAction(title: others == 1 ? "1 file is for another game version" : "\(others) files are for other game versions", attributes: .disabled) { _ in }
            rows.append(o)
        }
        rows.append(reload)
        return UIMenu(title: "Cheats", subtitle: "None loaded", image: UIImage(systemName: "wand.and.stars"), children: rows)
    }
    let master = dm_cheats_master() != 0
    let masterRow = UIAction(title: "Cheats on", state: master ? .on : .off) { _ in dm_cheats_master_set(master ? 0 : 1) }
    var groups: [UIMenuElement] = [UIMenu(options: .displayInline, children: [masterRow])]
    var rows: [UIMenuElement] = [], section = "", on = 0
    func flush() {
        if !rows.isEmpty { groups.append(UIMenu(title: section, options: .displayInline, children: rows)) }
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
        let row: UIAction
        switch kind {
        case 1:   // a master: always on
            row = UIAction(title: name, attributes: .disabled, state: .on) { _ in }
            row.subtitle = "Always on"
        case 2:   // broken, or turned off while running: the reason
            row = UIAction(title: name, attributes: .disabled, state: .off) { _ in }
            row.subtitle = why.isEmpty ? "Cannot run" : why
        default:
            let once = flags & cheatOnce != 0
            row = UIAction(title: name, attributes: master ? [] : .disabled, state: isOn && !once ? .on : .off) { _ in dm_cheat_toggle(i) }
            if once { row.subtitle = "Runs once when tapped" } else if !why.isEmpty { row.subtitle = why }
            if isOn && !once { on += 1 }
        }
        rows.append(row)
    }
    flush()
    groups.append(UIMenu(options: .displayInline, children: [reload]))
    let version = String(cString: dm_cheats_version())
    let subtitle = !master ? "Off" : on == 0 ? "None on" : "\(on) on"
    return UIMenu(title: version.isEmpty ? "Cheats" : "Cheats (\(version))", subtitle: subtitle, image: UIImage(systemName: "wand.and.stars"), children: groups)
}

@MainActor private func gameMenuRow(_ m: LauncherModel, _ s: Setting) -> UIMenuElement {
    let now = m.values[s.env] ?? s.def, fixed = m.fixed.contains(s.env)
    let attributes: UIMenuElement.Attributes = fixed ? .disabled : []
    func pick(_ v: String) { if m.choose(s, v) { dm_setting_env(s.env, v) }; _ = dm_setting_live(s.env, v) }   // saved, into the environment (under front_ios.m's lock), then applied
    if s.kind == "toggle" {
        let a = UIAction(title: s.label, attributes: attributes, state: now == s.onValue ? .on : .off) { _ in pick(now == s.onValue ? s.offValue : s.onValue) }
        if fixed { a.subtitle = "Set in env.txt" }
        return a
    }
    let options = s.options ?? []
    let current = options.first { $0[0] == now }?[1] ?? now
    let actions = options.map { o in UIAction(title: o[1], attributes: attributes, state: o[0] == now ? .on : .off) { _ in pick(o[0]) } }
    return UIMenu(title: s.label, subtitle: fixed ? "\(current), set in env.txt" : nil, options: .singleSelection, children: actions)
}
