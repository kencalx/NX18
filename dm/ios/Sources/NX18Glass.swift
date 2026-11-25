// Liquid Glass as a subtle accent (gate-ui §11, O8): only where art or a game sits right behind, one layer per region, .regular with a low tint, and no text on glass but a
// hero button's own label. The Gate's hero buttons (Play, Guide, About) are faint glass over the key art's scrim; the NX 18 card has a glass rim around a solid fill. With
// no art there is nothing to refract, so they draw solid, as they do under the fallbacks:
//   Reduce Transparency, Increase Contrast, Low Power Mode, a serious or critical thermal state (glass comes back only after 60 s at fair or lower), DM_UI_GLASS=0.
// No opacity is ever put on a glass view or its ancestors (that stops the refraction and leaves a flat grey shape): the switch swaps the Glass value (.regular ↔ .identity)
// on the same view and fades in the solid fill underneath. Shared by the iPhone, iPad and Mac launchers
import Combine
import Foundation
import SwiftUI

// Whether glass may draw now, from the system states the views cannot read from their environment (Low Power Mode, the thermal state) and DM_UI_GLASS. Main actor
@MainActor final class NX18GlassPolicy: ObservableObject {
    static let shared = NX18GlassPolicy()
    static let forcedOff: Bool = { ProcessInfo.processInfo.environment["DM_UI_GLASS"] == "0" }()
    nonisolated static let thermalHold: TimeInterval = 60   // seconds at fair or lower before glass comes back after a serious thermal state
    @Published private(set) var allowed: Bool
    private var hot = false, calmSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var calmTask: Task<Void, Never>?

    init() {
        allowed = !Self.forcedOff
        guard !Self.forcedOff else { return }
        for n in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } })
        }
        update()
    }
    // The decision for the given inputs, the testable part (the Duo harness): hysteresis on heat
    nonisolated static func decide(forcedOff: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState, hot: inout Bool, calmSince: inout Date?, now: Date) -> Bool {
        if forcedOff || lowPower { return false }
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { hot = true; calmSince = nil; return false }
        if hot {
            let since = calmSince ?? now; calmSince = since
            if now.timeIntervalSince(since) < thermalHold { return false }
            hot = false; calmSince = nil
        }
        return true
    }
    func update() {
        let a = Self.decide(forcedOff: Self.forcedOff, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState,
                            hot: &hot, calmSince: &calmSince, now: Date())
        if a != allowed { allowed = a }
        calmTask?.cancel(); calmTask = nil
        if hot, ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue {   // calm again: look once more when the hold is over (one wake, no polling)
            calmTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.thermalHold + 0.5))
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
    }
}

// A surface with glass where allowed, else the solid fill with a hairline (§11's Edges rule: a hand-drawn hairline only on solid surfaces)
struct NX18Surface<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let hairline: Color
    var tint: Color? = nil
    var interactive = false
    let art: Bool
    @ObservedObject private var policy = NX18GlassPolicy.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var on: Bool { art && policy.allowed && !reduceTransparency && contrast != .increased }
    private var glass: Glass {
        guard on else { return .identity }
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        return interactive ? g.interactive() : g
    }
    func body(content: Content) -> some View {
        content
            .background { shape.fill(fill).opacity(on ? 0 : 1).animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: on) }   // the solid fill fades in under the glass, never the glass
            .overlay { if !on { shape.strokeBorder(hairline, lineWidth: 1) } }
            .glassEffect(glass, in: shape)
    }
}

extension View {
    func nx18Surface<S: InsettableShape>(_ shape: S, fill: Color, hairline: Color, tint: Color? = nil, interactive: Bool = false, art: Bool) -> some View {
        modifier(NX18Surface(shape: shape, fill: fill, hairline: hairline, tint: tint, interactive: interactive, art: art))
    }
}

// The hero buttons' press: smaller while held, never dimmer (no opacity on glass)
struct NX18HeroButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}
