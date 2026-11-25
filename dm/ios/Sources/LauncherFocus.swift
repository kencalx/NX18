// The Gate's focus model, shared by the iPhone, iPad and Mac launchers: what the focus ring can be on, the lines it moves along, and the events that move it (a
// controller's on iOS, the keyboard's on the Mac). LauncherController.swift reads the pads; LauncherPanel.swift draws the ring
import Foundation

// What the focus ring can be on: the hero's buttons, and the Gate panel's chips, tiles, doors, rows and actions (LauncherPanel.swift)
enum LauncherFocus: Hashable, Sendable {
    case preset(LauncherPreset), play, guide, about
    case tile(String)              // a quick tile on the main page: a setting's env, or "touch" (the Touch controls page)
    case door(String)              // "customize" or "cloud"
    case row(String)               // a setting's row on Customize or Touch controls
    case option(String, String)    // one option of a tick list: the setting's env and the value
    case action(String)            // "gate" (Gate at start), "cloud.choose", "cloud.off"
    case pageBack, backToPreset, reset, acknowledgements
    case mark                      // the NX 18 mark above Play: opens the NX 18 card (G12, G13)
    case card(String)              // an item of the open NX 18 card: "close" or "appearance" (NX18Card.swift)
}

// The focusable items as lines on the screen, in order: up / down go from line to line (keeping the column where the next line has it), left / right along a line
struct LauncherFocusMap: Equatable {
    let lines: [[LauncherFocus]]

    func contains(_ f: LauncherFocus) -> Bool { lines.contains { $0.contains(f) } }
    private func place(_ f: LauncherFocus) -> (line: Int, column: Int)? {
        for (l, line) in lines.enumerated() { if let c = line.firstIndex(of: f) { return (l, c) } }
        return nil
    }
    // The item a step up (-1) or down (+1) reaches; the same item at either end (no wrap). From nothing (or an item no longer drawn): the first item
    func vertical(_ from: LauncherFocus?, _ step: Int) -> LauncherFocus? {
        guard let from, let p = place(from) else { return lines.first?.first }
        let l = Swift.min(Swift.max(p.line + step.signum(), 0), lines.count - 1)
        guard l != p.line else { return from }
        return lines[l][Swift.min(p.column, lines[l].count - 1)]
    }
    // The item a step left (-1) or right (+1) reaches on the same line; nil on a line of one item (the step changes the row instead) or past either end
    func horizontal(_ from: LauncherFocus, _ step: Int) -> LauncherFocus? {
        guard let p = place(from), lines[p.line].count > 1 else { return nil }
        let c = p.column + step.signum()
        return lines[p.line].indices.contains(c) ? lines[p.line][c] : nil
    }
}

// One controller event for the screen
enum LauncherPadEvent: Equatable, Sendable { case up, down, left, right, a, b, x, y, plus, minus, l, r, zl, zr }
