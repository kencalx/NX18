// Beam Home's controller (HomeView.swift): its presses as GameController sends them, never read in a loop. Each edge once; a held direction repeats after 0.4 s, then
// every 0.12 s, by a timer that runs only while a direction is held. Home starts it while it shows and Beam is in front, and stops it otherwise
import AppKit
import Foundation
import GameController

/// The controller's presses as Home reads them: each edge once, a held direction repeating after 0.4 s every 0.12 s
struct PadEdges {
    enum Press: Equatable, Hashable, Sendable { case left, right, up, down, a, b, y, x, minus }
    static let directions: Set<Press> = [.left, .right, .up, .down]
    static let firstRepeat: TimeInterval = 0.4
    static let nextRepeat: TimeInterval = 0.12
    private var held: Set<Press> = []
    private var repeatAt: [Press: TimeInterval] = [:]

    mutating func update(_ now: Set<Press>, time: TimeInterval) -> [Press] {
        var out: [Press] = []
        for p in now {
            if !held.contains(p) { out.append(p); repeatAt[p] = time + Self.firstRepeat }
            else if Self.directions.contains(p), let t = repeatAt[p], time >= t { out.append(p); repeatAt[p] = time + Self.nextRepeat }
        }
        held = now
        repeatAt = repeatAt.filter { now.contains($0.key) }
        return out
    }

    /// When a held direction repeats next; nil when none is held (no timer needed)
    var nextRepeatTime: TimeInterval? { repeatAt.filter { Self.directions.contains($0.key) }.values.min() }

    /// One look at the pad: the D-pad and left stick summed (a direction past half way), the face buttons by position, and −
    struct Reading: Sendable {
        var dpadX: Float = 0, dpadY: Float = 0, stickX: Float = 0, stickY: Float = 0
        var right = false, bottom = false, left = false, top = false, minus = false
    }
    static func presses(_ r: Reading) -> Set<Press> {
        var s: Set<Press> = []
        let x = r.dpadX + r.stickX, y = r.dpadY + r.stickY
        if x < -0.5 { s.insert(.left) }; if x > 0.5 { s.insert(.right) }
        if y > 0.5 { s.insert(.up) }; if y < -0.5 { s.insert(.down) }
        // by position, as a Nintendo pad's labels sit: the right face button is A, the bottom B, the left Y, the top X (NX 18's button glyphs follow the same rule)
        if r.right { s.insert(.a) }
        if r.bottom { s.insert(.b) }
        if r.left { s.insert(.y) }
        if r.top { s.insert(.x) }
        if r.minus { s.insert(.minus) }
        return s
    }
    /// The keyboard's stand-ins for the hints' buttons, with no controller: the letters A, B, X, Y and −
    static func letter(_ s: String) -> Press? {
        switch s.lowercased() { case "a": .a; case "b": .b; case "x": .x; case "y": .y; case "-", "−": .minus; default: nil }
    }
    static func reading(_ g: GCExtendedGamepad) -> Reading {
        Reading(dpadX: g.dpad.xAxis.value, dpadY: g.dpad.yAxis.value, stickX: g.leftThumbstick.xAxis.value, stickY: g.leftThumbstick.yAxis.value,
                right: g.buttonB.isPressed, bottom: g.buttonA.isPressed, left: g.buttonX.isPressed, top: g.buttonY.isPressed,
                minus: g.buttonOptions?.isPressed ?? false)   // − (Options, View, Share): the small button left of centre
    }
}

/// Home's reader: the current controller's value changes in, presses out
@MainActor final class HomePad {
    var onPress: (PadEdges.Press) -> Void = { _ in }
    private(set) var edges = PadEdges()
    private(set) var running = false
    private var attached: GCController?
    private var repeatTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// Home shows and Beam is in front: the current controller's changes, and the next one's when it changes
    func start() {
        guard !running else { return }
        running = true
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidBecomeCurrent, .GCControllerDidStopBeingCurrent] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach(GCController.current) }
            })
        }
        attach(GCController.current)
    }
    /// Home closed, or Beam went behind another app: nothing more is read, nothing is held
    func stop() {
        guard running else { return }
        running = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        detach()
    }

    private func attach(_ c: GCController?) {
        if c === attached, c != nil { return }
        detach()
        guard let c, let g = c.extendedGamepad else { return }
        attached = c
        c.handlerQueue = .main
        _ = edges.update(PadEdges.presses(PadEdges.reading(g)), time: clock())   // what is held already is not a new press (coming back to Beam with A down replays nothing)
        scheduleRepeat()
        g.valueChangedHandler = { [weak self] pad, _ in
            let now = PadEdges.presses(PadEdges.reading(pad))
            MainActor.assumeIsolated { self?.changed(now) }
        }
    }
    private func detach() {
        attached?.extendedGamepad?.valueChangedHandler = nil
        attached = nil
        repeatTask?.cancel(); repeatTask = nil
        _ = edges.update([], time: clock())
    }

    /// A change on the pad (or the repeat timer): the new edges out, and the timer set for the next repeat while a direction is held
    func changed(_ now: Set<PadEdges.Press>) {
        for p in edges.update(now, time: clock()) { onPress(p) }
        scheduleRepeat()
    }
    private func scheduleRepeat() {
        repeatTask?.cancel(); repeatTask = nil
        guard let t = edges.nextRepeatTime else { return }
        let wait = max(t - clock(), 0)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), tolerance: .milliseconds(4))
            guard !Task.isCancelled, let self else { return }
            self.tick()
        }
    }
    private func tick() {   // the held set unchanged: only repeats come out
        guard let g = attached?.extendedGamepad else { return }
        changed(PadEdges.presses(PadEdges.reading(g)))
    }

    /// Where a press goes in Home: its Profile sheet takes B and − (closing it), Home takes the rest, and nothing while a game's settings sheet is up
    enum Route: Equatable { case home(PadEdges.Press), closeProfile, ignore }
    nonisolated static func route(_ p: PadEdges.Press, settingsOpen: Bool, profileOpen: Bool) -> Route {
        if profileOpen { return p == .b || p == .minus ? .closeProfile : .ignore }
        return settingsOpen ? .ignore : .home(p)
    }
}

/// Beam Home's optional menu sounds (Settings, off by default): a soft tick on a move, a click on a choice or an opening, a lower note on going back or closing, the Mac's
/// own system sounds. Silent too when the Mac's "Play user interface sound effects" (Sound settings) is off, as the system's own interface sounds are
enum HomeSounds {
    static var on: Bool { enabled(beam: UserDefaults.standard.bool(forKey: "homeSounds"), system: UserDefaults.standard.object(forKey: systemKey)) }
    static let systemKey = "com.apple.sound.uiaudio.enabled"   // the global domain's switch, absent until the player first turns it off
    nonisolated static func enabled(beam: Bool, system: Any?) -> Bool { beam && ((system as? NSNumber)?.boolValue ?? true) }
    nonisolated static func sound(_ p: PadEdges.Press) -> String {
        switch p { case .left, .right, .up, .down: "Tink"; case .a, .y, .x, .minus: "Pop"; case .b: "Bottle" }
    }
    @MainActor static func play(_ p: PadEdges.Press) {
        guard on else { return }
        NSSound(named: NSSound.Name(sound(p)))?.play()
    }
}
