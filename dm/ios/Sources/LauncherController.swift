// The settings screen's controller navigation (Launcher.swift's LauncherView). While the screen is up a game controller moves a cyan focus ring over the preset chips, Play, Game guide,
// About, every setting row, Advanced, Reset, Cloud saves and Skip this screen next time: up / down (the D-pad or the left stick, repeating while held) moves, left / right moves
// along a line of buttons or changes the focused row (a choice's next option it may pick, a slider by one step: LauncherModel.advance), A presses (a switch flips, a menu row
// takes its next option), + plays, Y opens the game guide, B closes an open guide or About sheet or the iCloud Drive folder picker. While the guide's page is up every button is the page's (GuideViewer.swift
// LauncherGuidePageModel.handle: B goes back, L / R turn its pages) and ZL / ZR switch between the guide and the manual.
// The buttons are read by polling (LauncherGamepad.run, a task of the view, 60 times a second): no handler is set on any controller, so none is left behind when Play hands the
// controllers over to the game (DmGamepad.m sets its own after startGame), and a controller that connects while the screen is up is read from its next poll on. A and + act on their
// release, so the A that pressed Play is up before the game reads the controller. Only a real release counts: a button held when the screen appears, when a sheet opens or closes,
// when a controller connects or goes (its buttons vanish with it) or while the app is not active (input then reads as nothing) counts only once it was released after that.
// A Nintendo pad's buttons go by their labels and any other pad's by position, as in the game (dm/host/pad_apple.h): Switch A is the right button.
import GameController
import SwiftUI
import UIKit

// What the focus ring can be on
enum LauncherFocus: Hashable, Sendable {
    case preset(LauncherPreset), play, guide, about, row(String), advanced, reset, cloud, skip
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

@MainActor final class LauncherGamepad: ObservableObject {
    @Published private(set) var connected = false   // a controller with an extended gamepad profile is connected: the focus ring shows
    @Published private(set) var glyphs = NXPadGlyphs()   // the hints' glyphs and VoiceOver names of the first pad's A, B, X, Y and + (NXButtonGlyph.swift: "Press B to play" on an Xbox pad, whose right button plays)

    private enum Key: CaseIterable { case up, down, left, right, a, b, x, y, plus, minus, l, r, zl, zr }
    private var held: Set<Key> = []
    private var blocked: Set<Key>   // held when the screen appeared, when a sheet opened or closed, when the pads changed or the app was inactive: ignored until released
    private var nextRepeat: [Key: TimeInterval] = [:]
    private var pads: Set<ObjectIdentifier> = []   // the controllers of the last poll
    private var glyphPad: ObjectIdentifier?   // the pad the glyphs were last read from, and polls since: a new first pad is read at once, the same one again about every 0.5 s
    private var glyphPolls = Int.max          // (a remap in Settings, names that come late), not 60 times a second

    init() {
        let now = GCController.controllers().filter { $0.extendedGamepad != nil }
        blocked = now.reduce(into: Set<Key>()) { $0.formUnion(Self.keys($1)) }
        pads = Set(now.map(ObjectIdentifier.init))
    }

    // Whether any controller button is held now (dm_show_launcher: a held button shows the screen although the player chose to skip it)
    static func anyHeld() -> Bool { GCController.controllers().contains { c in
        guard let g = c.extendedGamepad else { return false }
        return g.allButtons.contains { $0.isPressed } || g.dpad.xAxis.value != 0 || g.dpad.yAxis.value != 0
    } }
    // Waits up to window for a held controller button (true at once when one is), for dm_show_launcher's skip: at a cold start GameController lists the controllers already
    // paired only a moment after the app's first screen appears (GCControllerDidConnect), and their buttons once the app is active. Polled on the main actor, so nothing
    // runs on the controllers' handlers. Best effort: a pad that takes longer than window to show up is not seen
    static func heldAtStart(within window: Duration) async -> Bool {
        let end = ContinuousClock.now.advanced(by: window)
        while ContinuousClock.now < end {
            if anyHeld() { return true }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return anyHeld()
    }

    // A Switch layout's button from a pad: a Nintendo pad by label, any other by position (pad_apple.h dm_pad_face): right A, bottom B, top X, left Y. Also the in-game menu's hints (GameMenuPanel.swift)
    nonisolated static func labelled(_ c: GCController) -> Bool { c.productCategory == "Switch Pro Controller" || c.productCategory.contains("Joy-Con") }
    private static func keys(_ c: GCController) -> Set<Key> {
        guard let g = c.extendedGamepad else { return [] }
        let byLabel = labelled(c)
        let a = byLabel ? g.buttonA : g.buttonB, b = byLabel ? g.buttonB : g.buttonA, x = byLabel ? g.buttonX : g.buttonY, y = byLabel ? g.buttonY : g.buttonX
        let sx = g.leftThumbstick.xAxis.value, sy = g.leftThumbstick.yAxis.value
        var k = Set<Key>()
        if g.dpad.up.isPressed || sy > 0.6 { k.insert(.up) }
        if g.dpad.down.isPressed || sy < -0.6 { k.insert(.down) }
        if g.dpad.left.isPressed || sx < -0.6 { k.insert(.left) }
        if g.dpad.right.isPressed || sx > 0.6 { k.insert(.right) }
        if a.isPressed { k.insert(.a) }
        if b.isPressed { k.insert(.b) }
        if x.isPressed { k.insert(.x) }
        if y.isPressed { k.insert(.y) }
        if g.buttonMenu.isPressed { k.insert(.plus) }
        if g.buttonOptions?.isPressed == true { k.insert(.minus) }
        if g.leftShoulder.isPressed { k.insert(.l) }
        if g.rightShoulder.isPressed { k.insert(.r) }
        if g.leftTrigger.isPressed { k.insert(.zl) }
        if g.rightTrigger.isPressed { k.insert(.zr) }
        return k
    }
    private static func pressedNow() -> Set<Key> { GCController.controllers().reduce(into: Set<Key>()) { $0.formUnion(keys($1)) } }

    // Polls every connected controller until the task is cancelled (the screen goes), calling handle on the main actor for each event
    func run(_ handle: @escaping @MainActor (LauncherPadEvent) -> Void) async {
        while !Task.isCancelled {
            poll(handle)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
    // After a sheet opens or closes: the buttons held now (the A that opened it) wait for their release
    func holdUntilReleased() { blocked.formUnion(held) }

    private func poll(_ handle: @MainActor (LauncherPadEvent) -> Void) {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        if connected != !pads.isEmpty { connected = !pads.isEmpty }
        let first = pads.first.map(ObjectIdentifier.init)
        if first != glyphPad || glyphPolls >= 30 {
            glyphPad = first; glyphPolls = 0
            let g = NXPadGlyphs.of(pads.first)
            if glyphs != g { glyphs = g }
        } else { glyphPolls += 1 }
        let now = pads.reduce(into: Set<Key>()) { $0.formUnion(Self.keys($1)) }
        // A key that vanishes because its pad went (or one that appears with a new pad), or while the app is not active (its input reads as nothing), is no press or release:
        // everything held stays blocked until it is released for real
        let ids = Set(pads.map(ObjectIdentifier.init))
        if ids != self.pads || UIApplication.shared.applicationState != .active {
            self.pads = ids
            blocked.formUnion(held); blocked.formUnion(now)
            held = []; nextRepeat = [:]
            return
        }
        blocked.formIntersection(now)
        let t = ProcessInfo.processInfo.systemUptime
        for k in Key.allCases where !blocked.contains(k) {
            let down = now.contains(k), was = held.contains(k)
            switch k {
            case .up, .down, .left, .right:   // on the press, then again while held
                if down && !was { nextRepeat[k] = t + 0.4; handle(event(k)) }
                else if down, let r = nextRepeat[k], t >= r { nextRepeat[k] = t + 0.11; handle(event(k)) }
            case .a, .plus:   // on the release (the game must not see the A that pressed Play)
                if !down && was { handle(event(k)) }
            default:
                if down && !was { handle(event(k)) }
            }
        }
        held = now.subtracting(blocked)
    }
    private func event(_ k: Key) -> LauncherPadEvent {
        switch k {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .a: return .a
        case .b: return .b
        case .x: return .x
        case .y: return .y
        case .plus: return .plus
        case .minus: return .minus
        case .l: return .l
        case .r: return .r
        case .zl: return .zl
        case .zr: return .zr
        }
    }
}

// What an open sheet scrolls by when the controller asks (the guide's web view or PDF, the About text): set by the sheet that is up
@MainActor final class LauncherScroller {
    var scroll: ((CGFloat) -> Void)?
    var page: ((Int) -> Void)?   // L / R (ZL / ZR on the guide's page): the guide's other document (the guide or the manual)
    var pad: ((LauncherPadEvent) -> Bool)?   // the open sheet's own handling of a controller event (the guide's page takes every button): true when it took it
}

extension UIScrollView {
    // Scrolls by dy points, kept within the content
    func nudge(by dy: CGFloat) {
        let top = -adjustedContentInset.top, bottom = Swift.max(top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        setContentOffset(CGPoint(x: contentOffset.x, y: Swift.min(Swift.max(contentOffset.y + dy, top), bottom)), animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
