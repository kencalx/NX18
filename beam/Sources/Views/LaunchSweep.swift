// The start of a game from Beam (Library.play, the one path every Play takes): the Beam dashes (the three coral strokes either side of BEAM in Beam's title,
// docs/images/nx18/make_logo.py dashes()) streak left to right across a dark veil on the display Beam's window is on, drawing the cyan-to-coral line behind the middle one,
// then the veil gets out of the way. The game is started at the same moment, never after: the veil only covers the wait. It fades the moment Beam stops being the
// app in front (the game's window, or any other app, came up), so it never covers the game; else it holds, still, for a short while after the sweep and fades.
// Reduce Motion: the veil alone, faded in and out. A borderless panel that takes no clicks, closed when it has faded: nothing runs after it
import AppKit

enum LaunchSweep {
    enum Style: Equatable { case sweep, fade }

    /// Which start gets which: none when Beam is not the app in front (a veil over another app would hide what the player is looking at), the plain fade under Reduce Motion
    static func style(beamActive: Bool, reduceMotion: Bool) -> Style? {
        guard beamActive else { return nil }
        return reduceMotion ? .fade : .sweep
    }

    /// The timeline, in seconds: the veil coming in, the dashes' flight (0 for the fade), the still hold after it at most, the veil going
    struct Timeline: Equatable { let veilIn, motion, hold, out: Double; var shown: Double { veilIn + motion } }
    static func timeline(_ s: Style) -> Timeline {
        switch s {
        case .sweep: Timeline(veilIn: 0.15, motion: 0.85, hold: 2.0, out: 0.3)
        case .fade: Timeline(veilIn: 0.2, motion: 0, hold: 1.5, out: 0.25)
        }
    }

    /// The dashes as make_logo.py draws them: (vertical offset from the middle one, length), in the logo's units, stroke width `stroke`; the middle one longest
    static let dashes: [(dy: Double, length: Double)] = [(-34, 34), (0, 58), (34, 34)]
    static let stroke = 18.0
    /// The logo's units in points on a screen `height` points tall, and how much longer a dash is drawn in flight (a streak)
    static func unit(height: Double) -> Double { height / 900 }
    static let streak = 3.0

    @MainActor private static var shown: SweepPanel?

    /// Shows the sweep for a start, when the start gets one. Returns what it showed
    @MainActor @discardableResult static func begin(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> Style? {
        guard let s = style(beamActive: NSApp.isActive, reduceMotion: reduceMotion),
              let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main else { return nil }
        shown?.close(after: 0)
        let p = SweepPanel(screen: screen, style: s) { if shown === $0 { shown = nil } }
        shown = p
        p.run()
        return s
    }

    /// The game ended (or never started): the veil goes now if it is still up
    @MainActor static func end() { shown?.close(after: 0) }
}

/// The veil and its dashes
@MainActor private final class SweepPanel {
    private let panel: NSPanel
    private let style: LaunchSweep.Style
    private let timeline: LaunchSweep.Timeline
    private let onClosed: (SweepPanel) -> Void
    private var resign: NSObjectProtocol?
    private var closing = false

    init(screen: NSScreen, style: LaunchSweep.Style, onClosed: @escaping (SweepPanel) -> Void) {
        self.style = style; timeline = LaunchSweep.timeline(style); self.onClosed = onClosed
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        panel.level = .statusBar   // over Beam's windows and the menu bar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]   // over Beam Home's full-screen space too
        panel.ignoresMouseEvents = true
        panel.isOpaque = false; panel.hasShadow = false; panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.setAccessibilityElement(false)
        panel.alphaValue = 0
        let v = NSView(frame: CGRect(origin: .zero, size: screen.frame.size)); v.wantsLayer = true
        v.layer?.backgroundColor = Self.rgb(0x1E1E21, alpha: 0.97)   // NX18Palette.background, the Gate's screen
        panel.contentView = v
    }

    func run() {
        // The game's window (or anything else) coming to the front ends the veil at once: an event, no polling
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(after: 0) }
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = timeline.veilIn; panel.animator().alphaValue = 1 }
        if style == .sweep, let layer = panel.contentView?.layer { addDashes(to: layer, start: timeline.veilIn * 0.5) }
        close(after: timeline.shown + timeline.hold)
    }

    /// Fades the veil out `delay` seconds from now (at once for 0) and closes it; the first call that comes due wins
    func close(after delay: Double) {
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.close(after: 0) }; return }
        guard !closing else { return }
        closing = true
        if let resign { NotificationCenter.default.removeObserver(resign) }; resign = nil
        NSAnimationContext.runAnimationGroup({ c in c.duration = timeline.out; panel.animator().alphaValue = 0 }) { [self] in
            MainActor.assumeIsolated { panel.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }; panel.orderOut(nil); onClosed(self) }
        }
    }

    private func addDashes(to root: CALayer, start: Double) {
        let size = root.bounds.size, u = LaunchSweep.unit(height: size.height), w = LaunchSweep.stroke * u, midY = size.height / 2
        let curve = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)   // quick off the mark, gliding out
        let begin = CACurrentMediaTime() + start, flight = timeline.motion * 0.8
        // The line the middle dash draws: a hairline, cyan into coral, growing from the left edge with it, then fading
        let line = CAGradientLayer()
        line.colors = [Self.rgb(NX18Palette.cyanHex), Self.rgb(NX18Palette.coralHex)]
        line.startPoint = CGPoint(x: 0, y: 0.5); line.endPoint = CGPoint(x: 1, y: 0.5)
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.frame = CGRect(x: 0, y: midY - 1, width: size.width, height: 2)
        line.transform = CATransform3DMakeScale(0, 1, 1)
        root.addSublayer(line)
        let grow = CABasicAnimation(keyPath: "transform.scale.x"); grow.fromValue = 0; grow.toValue = 1
        grow.beginTime = begin; grow.duration = flight; grow.timingFunction = curve; grow.fillMode = .both; grow.isRemovedOnCompletion = false
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        fade.beginTime = begin + flight; fade.duration = timeline.motion - flight; fade.fillMode = .both; fade.isRemovedOnCompletion = false
        line.add(grow, forKey: "grow"); line.add(fade, forKey: "fade")
        // The three dashes, each a rounded stroke shaded cyan at its tail to coral at its head; the middle one leads, the outer two a beat behind
        for (dy, length) in LaunchSweep.dashes {
            let len = length * u * LaunchSweep.streak
            let d = CAGradientLayer()
            d.colors = [Self.rgb(NX18Palette.cyanHex, alpha: 0), Self.rgb(NX18Palette.cyanHex), Self.rgb(NX18Palette.coralHex)]
            d.locations = [0, 0.35, 1]
            d.startPoint = CGPoint(x: 0, y: 0.5); d.endPoint = CGPoint(x: 1, y: 0.5)
            d.bounds = CGRect(x: 0, y: 0, width: len, height: w); d.cornerRadius = w / 2
            let y = midY - dy * u   // the logo's y grows downward, the layer's upward
            d.position = CGPoint(x: -len / 2, y: y)
            root.addSublayer(d)
            let move = CABasicAnimation(keyPath: "position.x"); move.fromValue = -len / 2; move.toValue = size.width + len / 2
            move.beginTime = begin + (dy == 0 ? 0 : 0.07); move.duration = flight; move.timingFunction = curve
            move.fillMode = .both; move.isRemovedOnCompletion = false
            d.add(move, forKey: "move")
        }
    }

    private static func rgb(_ hex: UInt32, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }
}
