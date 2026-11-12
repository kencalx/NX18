// The button glyphs of NX 18's controller hints: the settings screen's "Press A to play", the guide's Y and the sheets' B close (Launcher.swift, GuideViewer.swift), and the
// in-game menu's A Select / B Back or Close (GameMenuPanel.swift). The Switch's buttons are drawn from "Switch Button Icons and Controls" by Zacksly (CC BY 3.0 Licensed |
// zacksly.itch.io), modified: recoloured: the pack's Full Solid glyphs (a disc with the label cut out), vendored as SVG in dm/ios/Resources/ButtonIcons with the licence, and
// turned into outlines by dm/ios/tools/button_glyphs.py (NXButtonGlyphData.swift). A glyph is a shape filled with the foreground style, so it takes the tint of where it is,
// as a template image does (NX 18's coral for Play, cyan elsewhere), and stays sharp at every size; its size follows Dynamic Type with the text beside it.
// Which glyph a hint shows is the button the player presses, as the game maps the pad (dm/host/pad_apple.h, LauncherGamepad.labelled): a Nintendo pad by its printed labels
// (Switch A is its A), any other pad by position (Switch A is the right button: B on an Xbox pad, drawn as that pad's B; a pad whose buttons are not lettered, such as a
// PlayStation pad's shapes, keeps its own SF Symbol). Without a controller (or before one is read) the Switch's own glyph.
import GameController
import SwiftUI

// The credit the pack's licence (CC BY 3.0) asks for, in its short form, with the change made: shown under the settings and in About this game (Launcher.swift, GuideViewer.swift),
// and in the README's Acknowledgements
enum NX18Credits {
    static let buttonIcons = "Button Icons and Controls by Zacksly (CC BY 3.0 Licensed | zacksly.itch.io), modified: recoloured"
    // CC BY 3.0 asks for the licence's address with every copy: the app carries no LICENSE.txt, so About this game names it
    static let buttonIconsLicence = "CC BY 3.0: creativecommons.org/licenses/by/3.0"
}

// A Switch button with a glyph
enum NXButton: String, CaseIterable, Sendable {
    case a, b, x, y, plus
    var outline: NXButtonGlyphOutline {
        switch self {
        case .a: return NXButtonGlyphData.a
        case .b: return NXButtonGlyphData.b
        case .x: return NXButtonGlyphData.x
        case .y: return NXButtonGlyphData.y
        case .plus: return NXButtonGlyphData.plus
        }
    }
    var spoken: String {   // VoiceOver's name for it where the pad gives none
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .plus: return "plus"
        }
    }
}

// A shoulder button the hints name in words only (no glyph): the save question's L and R. The launcher gets the pad's shoulders as L and R and its triggers as ZL and ZR
// (LauncherGamepad.keys), so the words are the pad's own: LB on an Xbox pad, L1 on a PlayStation pad, whose triggers (LT, L2) are not these buttons
enum NXShoulder: String, CaseIterable, Sendable {
    case l, r
    var spoken: String { self == .l ? "L" : "R" }   // the name where the pad gives none
}

// One glyph's outline fitted into the rect (centred, aspect kept), filled with the non-zero rule as the SVG is
struct NXButtonGlyphShape: Shape {
    let button: NXButton
    func path(in rect: CGRect) -> Path {
        let o = button.outline
        guard o.box.width > 0, o.box.height > 0 else { return Path() }
        let s = Swift.min(rect.width / o.box.width, rect.height / o.box.height)
        let ox = rect.midX - o.box.midX * s, oy = rect.midY - o.box.midY * s
        var p = Path()
        var i = 0
        func next() -> CGPoint {
            defer { i += 2 }
            return i + 1 < o.pts.count ? CGPoint(x: ox + o.pts[i] * s, y: oy + o.pts[i + 1] * s) : CGPoint(x: ox, y: oy)
        }
        for op in o.ops {
            switch op {
            case "M": p.move(to: next())
            case "L": p.addLine(to: next())
            case "C": let c1 = next(), c2 = next(), e = next(); p.addCurve(to: e, control1: c1, control2: c2)
            case "Z": p.closeSubpath()
            default: break
            }
        }
        return p
    }
}

// What a hint shows for one Switch button
enum NXPadGlyph: Equatable, Sendable {
    case button(NXButton)   // a glyph of the pack (a Nintendo pad's label, or a lettered pad's letter)
    case symbol(String)     // the pad's own SF Symbol (a pad whose buttons are not lettered A B X Y)
}

// The glyphs (and VoiceOver's names) of the Switch buttons the hints name, for the first connected controller
struct NXPadGlyphs: Equatable, Sendable {
    private var glyphs: [NXButton: NXPadGlyph] = [:]
    private var names: [NXButton: String] = [:]
    private var shoulderNames: [NXShoulder: String] = [:]

    func glyph(_ b: NXButton) -> NXPadGlyph { glyphs[b] ?? .button(b) }
    func name(_ b: NXButton) -> String { names[b] ?? b.spoken }
    func name(_ s: NXShoulder) -> String { shoulderNames[s] ?? s.spoken }

    // The Switch button a pad button stands for: one of the pad's lettered face buttons (an SF Symbol "a.circle", "b.circle.fill"...) as its letter; nil for anything else
    // ("xmark.circle", a PlayStation pad's cross, is no X)
    static func letter(ofSymbol s: String) -> NXButton? {
        let parts = s.split(separator: ".")
        guard parts.count >= 2, parts[1] == "circle" else { return nil }
        switch parts[0] { case "a": return .a; case "b": return .b; case "x": return .x; case "y": return .y; default: return nil }
    }
    // The glyph for Switch button b: by its label on a Nintendo pad; on any other pad that button's place's own letter (fallback when the pad names no symbol) or symbol
    static func resolve(_ b: NXButton, labelled: Bool, symbol: String?, fallback: NXButton) -> NXPadGlyph {
        if labelled { return .button(b) }
        guard let symbol else { return .button(fallback) }
        if let l = letter(ofSymbol: symbol) { return .button(l) }
        return .symbol(symbol)
    }

    @MainActor static func of(_ c: GCController?) -> NXPadGlyphs {
        var g = NXPadGlyphs()
        guard let c, let pad = c.extendedGamepad else { return g }
        let labelled = LauncherGamepad.labelled(c)
        // the pad button each Switch button is (pad_apple.h dm_pad_face: by label, else right A, bottom B, top X, left Y), and its letter on a pad lettered by position (Xbox)
        let face: [(NXButton, GCControllerButtonInput?, NXButton)] = [
            (.a, labelled ? pad.buttonA : pad.buttonB, .b),
            (.b, labelled ? pad.buttonB : pad.buttonA, .a),
            (.x, labelled ? pad.buttonX : pad.buttonY, .y),
            (.y, labelled ? pad.buttonY : pad.buttonX, .x),
            (.plus, pad.buttonMenu, .plus),
        ]
        for (b, input, fallback) in face {
            g.glyphs[b] = resolve(b, labelled: labelled, symbol: input?.sfSymbolsName, fallback: fallback)
            if let n = input?.localizedName, !n.isEmpty { g.names[b] = n }
        }
        // the shoulders are in the same place on every pad, but not named the same (L, LB, L1)
        for (s, input) in [(NXShoulder.l, pad.leftShoulder), (.r, pad.rightShoulder)] {
            if let n = input.localizedName, !n.isEmpty { g.shoulderNames[s] = n }
        }
        return g
    }
    @MainActor static func current() -> NXPadGlyphs { of(GCController.controllers().first { $0.extendedGamepad != nil }) }
}

// A glyph in the foreground style, about as tall as the text style's capitals and digits plus a little, scaled with Dynamic Type. Hidden from VoiceOver: the hint says it in words
struct NXPadGlyphView: View {
    let glyph: NXPadGlyph
    @ScaledMetric private var side: CGFloat

    init(_ glyph: NXPadGlyph, size: CGFloat = 16, relativeTo style: Font.TextStyle = .footnote) {
        self.glyph = glyph
        _side = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    var body: some View {
        Group {
            switch glyph {
            case .button(let b): NXButtonGlyphShape(button: b).fill(.foreground)
            case .symbol(let s): Image(systemName: s).resizable().scaledToFit()
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
