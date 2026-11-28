// Beam's use of NX 18's two colours (the logo's cyan and coral, NX18Palette): cyan for state (ready, tested, the sidebar), coral for action and what is chosen, and the
// cyan-to-coral line where something moves or is in focus (the phone's rails). Errors stay coral with a warning symbol beside them, so colour is never the only signal
import GameController
import SwiftUI

extension NX18Palette {
    /// The rails' gradient, cyan into coral, left to right
    static var brand: LinearGradient { LinearGradient(colors: [cyan, coral], startPoint: .leading, endPoint: .trailing) }
    /// One of the two colours for a name, the same every time (placeholders, lists of like items): about half the names get each
    static func accent(for key: String) -> Color { key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 2 == 0 ? cyan : coral }
    static func accent(at index: Int) -> Color { index % 2 == 0 ? cyan : coral }
}

/// A progress bar in the rails' gradient: a share when known, else a short gradient band sweeping across (still under Reduce Motion)
struct NX18Bar: View {
    var value: Double?
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if let value {
                    Capsule().fill(NX18Palette.brand).frame(width: max(height, g.size.width * min(max(value, 0), 1)))
                        .animation(.snappy, value: value)
                } else {
                    Capsule().fill(NX18Palette.brand).frame(width: g.size.width * 0.3)
                        .offset(x: reduceMotion ? g.size.width * 0.35 : (sweep ? g.size.width * 0.7 : 0))
                        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true } } }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

// ---- Beam Home's controls (Home, its Album and viewer, the Profile sheet) ----

/// A small control floating over Beam Home's art (the top bar's Library, Album, Renew All and Profile, the Album's way back, the viewer's actions): Liquid Glass where
/// NX 18's glass rule allows it (NX18Surface: not under Reduce Transparency, Increase Contrast, Low Power Mode or heat), else the solid charcoal with a hairline. No opacity on it
struct HomeCapsule<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Color? = nil
    var interactive = true   // a control: the glass answers the pointer. Not on a surface that only shows something (the hints, a progress card)
    func body(content: Content) -> some View {
        content
            .nx18Surface(shape, fill: tint.map { $0.opacity(0.35) } ?? NX18Palette.charcoal, hairline: GateColor.hairline, tint: tint, interactive: interactive, art: true)
            .contentShape(shape)
    }
}
extension View {
    func homeCapsule(tint: Color? = nil) -> some View { modifier(HomeCapsule(shape: Capsule(), tint: tint)) }
    func homeSurface<S: InsettableShape>(_ shape: S, interactive: Bool = true) -> some View { modifier(HomeCapsule(shape: shape, interactive: interactive)) }
    /// Escape closes a sheet whose only button is Done (Return, .defaultAction): one button holds one shortcut, so an unseen one holds Escape (.cancelAction).
    /// Kept out of VoiceOver, which already has Done and its own escape gesture
    func escapeCloses(_ close: @escaping () -> Void) -> some View {
        background {
            Button("Close", action: close).keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
/// One button the hints bar names: one of the pad's face buttons (drawn as that pad's own glyph), −, or the D-pad's directions
enum BeamHintKey: Hashable {
    case pad(NXButton), minus, leftRight, upDown
}
struct BeamHint: Hashable {
    let key: BeamHintKey
    let label: String
    init(_ key: BeamHintKey, _ label: String) { self.key = key; self.label = label }
}

/// The bar of controller hints along the foot of Beam Home's screens: only the buttons that do something on the screen showing, each as the connected pad's own glyph
/// (an Xbox pad's B for Switch A, as NX 18's games draw them; NXPadGlyphs), the Switch's glyph with no pad (the letter keys do the same then). A glass capsule over what
/// scrolls under it. The glyphs are read again only when a controller comes, goes or becomes the current one: no polling
struct BeamHintsBar: View {
    let hints: [BeamHint]
    @State private var glyphs = NXPadGlyphs.current()
    var body: some View {
        HStack(spacing: 22) {
            ForEach(hints, id: \.self) { h in item(h) }
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .homeSurface(Capsule(), interactive: false)
        .animation(nil, value: hints)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Controller buttons")
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in glyphs = NXPadGlyphs.current() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in glyphs = NXPadGlyphs.current() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidBecomeCurrent)) { _ in glyphs = NXPadGlyphs.current() }
    }
    private func item(_ h: BeamHint) -> some View {
        HStack(spacing: 8) {
            switch h.key {
            case .pad(let b): NXPadGlyphView(glyphs.glyph(b), size: 22, relativeTo: .body).foregroundStyle(NX18Palette.text)
            case .minus: key("−")
            case .leftRight: key("◀ ▶")
            case .upDown: key("▲ ▼")
            }
            Text(h.label).font(.body.weight(.medium)).foregroundStyle(NX18Palette.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spoken(h.key)): \(h.label)")
    }
    private func key(_ s: String) -> some View {
        Text(s).font(.caption.weight(.bold)).foregroundStyle(NX18Palette.charcoal)
            .padding(.horizontal, s.count > 1 ? 6 : 0).frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(NX18Palette.text))
    }
    private func spoken(_ k: BeamHintKey) -> String {
        switch k {
        case .pad(let b): glyphs.name(b)
        case .minus: "Minus"
        case .leftRight: "Left and right"
        case .upDown: "Up and down"
        }
    }
}
