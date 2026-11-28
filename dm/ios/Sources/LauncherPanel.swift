// The Gate's system menu (NX18-X2.0 gate-ui.md, A9a-2b step 1): the settings side of the iOS launcher (Launcher.swift) as NX 18's own panel in place of the Settings-app list.
// A solid slab with a hairline edge holds pages: the main page (the preset chips, the preset line or the Custom bar, the quick tiles in two rows split by the two doors,
// Customize and Cloud saves, then the mod tiles), Customize (Picture and performance, Other choices, Troubleshooting, Reset all settings), Cloud saves, Touch controls, and a
// tick list for a choice of three or more options. A hint strip at the foot shows the focused or last-touched item's note in one line, and the pad's buttons while a controller
// is connected. Touch and controller are equals (gate-ui §10): a tap does what A does, a horizontal swipe on a quick tile steps it, every target is at least 44 pt.
// The controller's focus is the launcher's own state (LauncherFocus, LauncherController.swift); this file draws it and reports touches back (last input wins). iOS only for
// now: the Mac window keeps its Form until the Mac step (gate-ui §16 step 3)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Pages

enum GatePage: Hashable, Sendable {
    case main, customize, cloud, touch, options(String)   // options: the tick list of the row whose env is given
}

// The rows each page draws, from the model's visible rows (LauncherModel.rows), in the order gate-ui G10 sets for the main page
extension LauncherModel {
#if os(macOS)
    // The Mac's swaps (gate-ui §13): Display mode in place of Picture, Switch 2 controllers in place of Touch controls; no Vitals tile until the Mac's Vitals (F8)
    static let gateQuickFirst = ["DM_OPMODE", "DM_LANG", "DM_FULLSCREEN"]        // Console mode · Game language · Display mode
    static let gateQuickSecond = ["DM_SHOW_FPS", "DM_RUMBLE", "DM_SW2"]          // Game rumble · Switch 2 controllers (Vitals only where the Mac offers the row)
#else
    static let gateQuickFirst = ["DM_OPMODE", "DM_LANG", "DM_PICTURE_FIT"]       // Console mode · Game language · Picture
    static let gateQuickSecond = ["DM_SHOW_FPS", "DM_RUMBLE"]                    // Vitals · Game rumble, then the Touch controls door
#endif
    static let gateMods = ["DM_MOD_FPS", "DM_MOD_ULTRAWIDE"]                      // shown only when the app was packed with the mod, or for Ultrawide a build whose own camera widens (settings.tsv shown column)
    static let gateTouch = ["DM_TOUCH_SIZE", "DM_TOUCH_OPACITY", "DM_TOUCH_HAPTICS"]

    var gateRows: [Setting] { sections.flatMap { rows(in: $0) } }
    func gateRow(_ env: String) -> Setting? { gateRows.first { $0.env == env } }
    var gateTouchRows: [Setting] { Self.gateTouch.compactMap(gateRow) }
    var gateFirstTiles: [String] { Self.gateQuickFirst.filter { gateRow($0) != nil } }
    var gateSecondTiles: [String] { Self.gateQuickSecond.filter { gateRow($0) != nil } + (gateTouchRows.isEmpty ? [] : ["touch"]) }
    var gateModTiles: [String] { Self.gateMods.filter { gateRow($0) != nil } }
    // Customize's groups: the rows a preset sets, the other choices, and the Troubleshooting section's rows, drawn only while one of them differs from its default so a saved
    // workaround stays visible (presets-first P6; "Performance" is the section's name in an older list). Rows on the main page or the Touch page are not repeated
    static func isTrouble(_ s: Setting) -> Bool { s.sectionTitle == "Troubleshooting" || s.sectionTitle == "Performance" }
    var gateCustomizeGroups: [(title: String, note: String, rows: [Setting])] {
        let onMain = Set(Self.gateQuickFirst + Self.gateQuickSecond + Self.gateMods + Self.gateTouch)
        let rest = gateRows.filter { !onMain.contains($0.env) }
        let preset = rest.filter { $0.preset != nil }
        let troubleAll = rest.filter { $0.preset == nil && Self.isTrouble($0) }
        let trouble = troubleAll.contains { !$0.isDefault(values[$0.env] ?? $0.def) } ? troubleAll : []
        let other = rest.filter { $0.preset == nil && !Self.isTrouble($0) }
        return [("Picture and performance", "Set by the presets", preset), ("Other choices", "Additional settings", other),
                ("Troubleshooting", "You changed one of these. Choose it to go back", trouble)].filter { !$0.rows.isEmpty }
    }
    func optionLabel(_ s: Setting, _ v: String) -> String { s.options?.first { $0[0] == v }?[1] ?? v }
    // A row's value as the panel writes it: an option's label, a range's percentage, On or Off
    func gateValue(_ s: Setting) -> String {
        let v = shown(s)
        switch s.kind {
        case "choice": return optionLabel(s, v)
        case "range": return "\(Int(((Double(v) ?? s.max ?? 1) * 100).rounded())) %"
        default: return v == s.onValue ? "On" : "Off"
        }
    }
    // The strip's line: the row's reason while a rule greys it or the env file or launch fixed it, else its note, else a line from its name; at most 60 characters (gate-ui GW2)
    func gateBrief(_ s: Setting) -> String {
        if fixed.contains(s.env) { return fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file" }
        if let r = reason(s), !r.why.isEmpty { return GateText.brief(r.why) }
        return GateText.brief(s.note.isEmpty ? GateText.defaultNote(s) : s.note)
    }
}

enum GateText {
    // The first sentence of a note, cut to 60 characters at a word (gate-ui GW2: the strip never wraps)
    static func brief(_ note: String, max: Int = 60) -> String {
        var s = note
        if let dot = s.range(of: ". ") { s = String(s[..<dot.lowerBound]) + "." }
        guard s.count > max else { return s }
        let cut = s.prefix(max - 1)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
    static func defaultNote(_ s: Setting) -> String {
        switch s.env {
        case "DM_OPMODE": return "Docked or handheld, as the game sees the console."
        case "DM_LANG": return "The language the game's text and voices use."
        case "DM_SHOW_FPS": return "Frame rate, CPU power, heat, battery and time at the top."
        case "DM_RUMBLE": return "The game's rumble on your controller or phone."
        case "DM_FPS_TARGET": return "The frame rate the game aims for."
        case "DM_RENDER_SCALE": return "The 3D picture's size before it is scaled to the screen."
        default: return s.label
        }
    }
    static func shoulder(_ name: String) -> String { name.replacingOccurrences(of: " Button", with: "") }   // "L1 Button" in the strip reads "L1"
    static let presetLine: [LauncherPreset: String] = [   // a preset's note when the list names no rows it moves (an older list)
        .battery: "Less power and heat: lower frame rate and resolution.",
        .balanced: "The settings this game was tested with.",
        .quality: "Sharper picture: full resolution and smoothing.",
        .performance: "Higher frame rate where the game offers it.",
    ]
    // A preset's note, built from the rows it moves in this game (presets-first W12): fixed text would be wrong in most games. Cost words where a preset costs more
    @MainActor static func presetNote(_ m: LauncherModel, _ p: LauncherPreset) -> String {
        if p == .balanced { return presetLine[.balanced]! }
        var parts: [String] = []
        for s in m.moves(p) {
            guard let t0 = s.target(p) else { continue }
            let t = m.presetValue(s, t0)
            switch s.env {
            case "DM_FPS_TARGET": parts.append("\(t) fps")
            case "DM_PRESENT_INTERVAL": parts.append(t == "display" ? "60 fps" : "30 fps")
            case "DM_RENDER_SCALE": parts.append((Double(t) ?? 1) < (Double(s.def) ?? 1) ? "lower resolution" : "full resolution")
            case "DM_DYNAMIC_RESOLUTION": parts.append(t == "1" ? "dynamic resolution" : "full resolution")
            case "DM_PRESENT_UPSCALE": if t == "metalfx" { parts.append("MetalFX upscaling") }
            case "DM_POST_AA": if t != "off" { parts.append("smoother edges") }
            case "DM_UPSCALER": if t == "metalfx" { parts.append("MetalFX for the game's upscaler") }
            default: break
            }
        }
        if m.presetEnv[p.rawValue]?["DM_FPS_CTL"] == "hold30" { parts.insert("steady 30 fps", at: 0) }   // a switch no row sets (preset_env): the game's own controller held at 30
        if m.presetEnv[p.rawValue]?["DM_DRS_LOWEST"] == "1" {   // a switch no row sets: Battery Saver's floor held at the game's lowest dynamic-resolution level (nvn_drs_gpu.h hold)
            parts.removeAll { $0 == "dynamic resolution" || $0 == "lower resolution" }; parts.append("lowest resolution")
        }
        if m.presetEnv[p.rawValue]?["DM_NVN_PASS_ALT"] == "0" { parts.append("full detail") }   // a switch no row sets: the profile's pass_alternate view drawn every frame (Donkey Kong Bananza's Quality)
        if m.presetEnv[p.rawValue]?["DM_NVN_CUBE_ALT"] == "0" { parts.append("full detail") }   // the profile's cube passes drawn every frame (Donkey Kong Bananza's environment cube)
        if m.presetEnv[p.rawValue]?["DM_NVN_UP_BILINEAR"] == "0" { parts.append("full detail") }   // the game's upscaler by MetalFX, not a bilinear stretch (Donkey Kong Bananza's Quality; the same words, listed once)
        var uniq: [String] = []
        for x in parts where !uniq.contains(x) { uniq.append(x) }
        guard var line = uniq.isEmpty ? nil : uniq.joined(separator: ", ") else { return presetLine[p] ?? "" }
        line = line.prefix(1).uppercased() + line.dropFirst()
        switch p {
        case .battery: line += ": less power and heat"
        case .quality: line += m.facts.kind == .mac ? "" : "; warmer, uses more battery"
        case .performance: line += "; uses more power"
        default: break
        }
        return line + "."
    }
}

extension LauncherPreset {
    var gateName: String { title }   // the player-facing name (NX18-X2.0 names: Battery Saver)
}

// MARK: - Palette (gate-ui GW14, §11a.3: the Soft tone; dark as it was, light the light set; NX18Look.swift)

enum GateColor {
    static let slab = Color(dark: 0x2A2A2D, light: 0xECECF0)
    static let tile = Color(dark: 0x333337, light: 0xFAFAFB)
    static let lit = Color(dark: 0x23434D, light: 0xF8E7E4)       // a focused tile: the teal wash, the pale wash in light
    static let chosen = Color(dark: 0x9CD1E2, light: 0xF3C7BE)    // the chosen preset chip: powder cyan with charcoal text; blush with a rosewood bar in light
    static let ring = Color(dark: 0x86CADF, light: 0x95534A)      // the focus ring: ice blue; rosewood in light
    static let peach = Color(dark: 0xF4B7A6, light: 0x3E6B7A)     // the second accent's small text: soft peach; slate teal in light
    static let disabled = Color(dark: 0x8A8A92, light: 0x7E7E86)  // a greyed name; the marks colour (GW18)
    static let well = Color(dark: 0x141415, light: 0xC8C8CE)
    static let hairline = Color(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.08, lightAlpha: 0.08)
    static let wine = Color(dark: 0xD9837B, light: 0x713A5D)      // a destructive action's text: the muted wine in light
    static let text = Color(dark: 0xEDEDF0, light: 0x1C1C1F)      // names and plain text
    static let muted = Color(dark: 0xB4B4BC, light: 0x55555E)     // notes, values, hint text
    static let line = Color(dark: NX18Palette.cyanHex, light: 0x95534A)   // section labels, icons, values, lamps, pips: the logo cyan in dark, rosewood in light
    static let coral = Color(dark: NX18Palette.coralHex, light: 0x95534A) // the + glyph: the set's coral-family tone
    static let ink = Color(dark: 0x2A2A2D, light: 0x1C1C1F)       // a name on the chosen fill
    static let chosenIcon = Color(dark: 0x2A2A2D, light: 0x95534A) // an icon on the chosen fill
    static let separator = Color(dark: 0x3E3E44, light: 0xC4C4CC)
    static let page = Color(dark: 0x1E1E21, light: 0xDCDCE1)      // behind the slab (the art tint goes on top: LauncherView)
}

// MARK: - Icons: monoline shapes in the logo's stroke (gate-ui §8 NX18Icon), round caps and joins

struct NX18Icon: View {
    enum Kind { case battery, balanced, quality, performance, console, language, picture, vitals, rumble, touch, sliders, cloud, rocket, wide }
    let kind: Kind
    var size: CGFloat = 20
    var body: some View {
        Canvas { ctx, sz in
            let w = sz.width, h = sz.height
            var p = Path()
            func r(_ x: CGFloat, _ y: CGFloat, _ ww: CGFloat, _ hh: CGFloat, _ c: CGFloat) { p.addRoundedRect(in: CGRect(x: x * w, y: y * h, width: ww * w, height: hh * h), cornerSize: CGSize(width: c * w, height: c * w)) }
            func l(_ pts: [(CGFloat, CGFloat)]) { guard let f = pts.first else { return }; p.move(to: CGPoint(x: f.0 * w, y: f.1 * h)); for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0 * w, y: q.1 * h)) } }
            switch kind {
            case .battery: r(0.08, 0.3, 0.74, 0.42, 0.08); l([(0.9, 0.42), (0.9, 0.6)]); l([(0.22, 0.42), (0.22, 0.6)])
            case .balanced: l([(0.5, 0.15), (0.5, 0.85)]); l([(0.15, 0.32), (0.85, 0.32)]); l([(0.15, 0.32), (0.08, 0.6), (0.3, 0.6), (0.15, 0.32)]); l([(0.85, 0.32), (0.7, 0.6), (0.92, 0.6), (0.85, 0.32)])
            case .quality: l([(0.5, 0.1), (0.62, 0.38), (0.9, 0.5), (0.62, 0.62), (0.5, 0.9), (0.38, 0.62), (0.1, 0.5), (0.38, 0.38), (0.5, 0.1)])
            case .performance: l([(0.58, 0.08), (0.24, 0.55), (0.5, 0.55), (0.42, 0.92), (0.78, 0.42), (0.52, 0.42), (0.58, 0.08)])
            case .console: r(0.06, 0.28, 0.88, 0.44, 0.1); l([(0.24, 0.5), (0.36, 0.5)]); l([(0.3, 0.44), (0.3, 0.56)]); p.addEllipse(in: CGRect(x: 0.66 * w, y: 0.44 * h, width: 0.1 * w, height: 0.1 * h))
            case .language: p.addEllipse(in: CGRect(x: 0.12 * w, y: 0.12 * h, width: 0.76 * w, height: 0.76 * h)); l([(0.12, 0.5), (0.88, 0.5)]); p.addEllipse(in: CGRect(x: 0.34 * w, y: 0.12 * h, width: 0.32 * w, height: 0.76 * h))
            case .picture: r(0.08, 0.2, 0.84, 0.6, 0.08); l([(0.16, 0.7), (0.4, 0.45), (0.58, 0.62), (0.7, 0.5), (0.84, 0.7)])
            case .vitals: l([(0.06, 0.55), (0.3, 0.55), (0.4, 0.25), (0.55, 0.8), (0.65, 0.45), (0.94, 0.45)])
            case .rumble: r(0.3, 0.2, 0.4, 0.6, 0.12); l([(0.14, 0.35), (0.14, 0.65)]); l([(0.86, 0.35), (0.86, 0.65)])
            case .touch: p.addEllipse(in: CGRect(x: 0.36 * w, y: 0.36 * h, width: 0.28 * w, height: 0.28 * h)); p.addEllipse(in: CGRect(x: 0.12 * w, y: 0.12 * h, width: 0.76 * w, height: 0.76 * h))
            case .sliders: l([(0.15, 0.3), (0.85, 0.3)]); l([(0.15, 0.7), (0.85, 0.7)]); l([(0.35, 0.2), (0.35, 0.4)]); l([(0.65, 0.6), (0.65, 0.8)])
            case .cloud: l([(0.25, 0.75), (0.78, 0.75)]); p.addArc(center: CGPoint(x: 0.25 * w, y: 0.6 * h), radius: 0.15 * w, startAngle: .degrees(90), endAngle: .degrees(250), clockwise: false); p.addArc(center: CGPoint(x: 0.5 * w, y: 0.45 * h), radius: 0.22 * w, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false); p.addArc(center: CGPoint(x: 0.76 * w, y: 0.6 * h), radius: 0.15 * w, startAngle: .degrees(290), endAngle: .degrees(90), clockwise: false)
            case .rocket: l([(0.5, 0.08), (0.7, 0.4), (0.7, 0.72), (0.3, 0.72), (0.3, 0.4), (0.5, 0.08)]); l([(0.4, 0.86), (0.5, 0.95), (0.6, 0.86)])
            case .wide: r(0.04, 0.3, 0.92, 0.4, 0.06); l([(0.2, 0.5), (0.8, 0.5)])
            }
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: Swift.max(1.5, h * 0.09), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
    static func forPreset(_ p: LauncherPreset) -> Kind { switch p { case .battery: .battery; case .balanced: .balanced; case .quality: .quality; case .performance: .performance } }
    static func forTile(_ id: String) -> Kind {
        switch id {
        case "DM_OPMODE": .console
        case "DM_LANG": .language
        case "DM_PICTURE_FIT": .picture
        case "DM_SHOW_FPS": .vitals
        case "DM_RUMBLE": .rumble
        case "touch": .touch
        case "DM_MOD_FPS": .rocket
        case "DM_MOD_ULTRAWIDE": .wide
        default: .sliders
        }
    }
}

// MARK: - The tile surface: one shape for every tile, chip and row (gate-ui GateTile)

// One focus ring for the whole panel (gate-ui §8, the shared ring): each tile, chip and row draws it through GateRing, matched by one id in the panel's namespace, so it
// slides from the old item to the new instead of blinking off and on. Without the namespace (another view using the style) it is drawn in place
private struct GateRingKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
// A focusable item's scroll id, with the ring's room around it: the pad's scroll-into-view (proxy.scrollTo) brings in the item and the 6 pt where its focus ring
// is drawn, so the ring is never cut at the slab's top or bottom edge (owner, 2026-11-17: Ultrawide's ring cut at the bottom). Layout is unchanged (the padding is given back)
extension View { func gateScrollID<ID: Hashable>(_ id: ID) -> some View { padding(6).id(id).padding(-6) } }
extension EnvironmentValues { var gateRing: Namespace.ID? { get { self[GateRingKey.self] } set { self[GateRingKey.self] = newValue } } }
struct GateRing: View {
    var radius: CGFloat
    @Environment(\.gateRing) private var ns
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius + 3, style: .continuous).strokeBorder(GateColor.ring, lineWidth: 2).padding(-3).allowsHitTesting(false)
        if let ns { shape.matchedGeometryEffect(id: "gate.ring", in: ns) } else { shape }
    }
}

// The controller's focus on the panel: a lit fill, an ice-blue 2 pt ring 3 pt outside and a 1.5 % lift; touch shows the lit fill while pressed. Filled means chosen, lit means focused
struct GateTileStyle: ButtonStyle {
    var focused = false
    var fill: Color = GateColor.tile
    var radius: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        GateTileBody(label: configuration.label, pressed: configuration.isPressed, focused: focused, fill: fill, radius: radius, reduceMotion: reduceMotion)
    }
}
// The tile's look; on the Mac a pointer over it lights it as a press does (hover)
private struct GateTileBody<L: View>: View {
    let label: L
    let pressed: Bool, focused: Bool
    let fill: Color
    let radius: CGFloat
    let reduceMotion: Bool
    @State private var hovered = false
    var body: some View {
        label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(pressed || focused || hovered ? (fill == GateColor.tile ? GateColor.lit : fill) : fill))
            .overlay {
                if focused { GateRing(radius: radius) }
            }
            .scaleEffect(focused && !reduceMotion ? 1.015 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.18), value: focused)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
#if os(macOS)
            .onHover { hovered = $0 }
#endif
    }
}

// A refused press: a small shake (gate-ui: a greyed tile refuses; nothing changes)
struct GateShake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 4), y: 0)) }
}

// MARK: - The panel

struct GatePanel: View {
    @ObservedObject var m: LauncherModel
    @Binding var pages: [GatePage]          // the page stack: empty is the main page
    let focus: LauncherFocus?
    let padShown: Bool                      // a controller is connected and no sheet is up: the ring and line 2 of the strip show
    var quiet = false                       // the NX 18 card is open over it: no hint strip (the card shows its own)
    let glyphs: NXPadGlyphs
    let status: LauncherStatus.Cloud
    var savesInNX18Folder = false           // this game's saves go through the NX 18 folder (the NX 18 card's This game's saves): the Cloud saves door says so
    let gateAtStartLocked: Bool             // DM_LAUNCHER from an env file or the launch decides
    let footer: AnyView                     // the end of Customize: the game's and NX 18's versions and the button icons' credit (Launcher.swift; About this game carries them too)
    let acknowledgements: Bool
    let touched: (LauncherFocus) -> Void    // a touch moves the controller's focus there (last input wins)
    let act: (GateAction) -> Void           // what a press asks the launcher for (the folder picker, Acknowledgements, the reset question)
    @State private var shake: [LauncherFocus: CGFloat] = [:]
    @State private var lastTouched: LauncherFocus?
    @State private var toastShown = false
    @Namespace private var ringSpace   // the shared focus ring's (GateRing)
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme   // the look (NX18Look.swift): light marks the chosen chip with a bar as well as its fill

    private var page: GatePage { pages.last ?? .main }
    private var noted: LauncherFocus? { padShown ? focus : (lastTouched ?? focus) }

    var body: some View {
        // The header and the strip are bars over the scrolling page (safeAreaBar), so the page runs under them and the system's soft scroll edge effect keeps them clear of it
        // (Apple HIG, Scroll views, iOS 27: a scroll edge effect where floating elements sit over a scroll view), instead of the page stopping at a hard line under the header
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { pageBody }
                    .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 16)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .safeAreaBar(edge: .bottom, spacing: 0) { strip.opacity(quiet ? 0 : 1).accessibilityHidden(quiet) }   // kept in place, so the slab does not move under the card
            .scrollEdgeEffectStyle(.automatic, for: .vertical)   // the HIG's preference: the header and strip are text outside glass, for which automatic gives the firmer separation
            .onChange(of: focus) { _, f in
                guard padShown, let f, f != .play, f != .guide, f != .about else { return }
                if reduceMotion { proxy.scrollTo(f) } else { withAnimation(.spring(duration: 0.18)) { proxy.scrollTo(f) } }
            }
        }
        .environment(\.gateRing, ringSpace)
#if os(iOS)
        // Back by swiping right from the panel's leading edge, as iOS goes back (Apple HIG, Designing for iOS: let people swipe to go back, so the top corner's ‹ is not the
        // only way). The swipe has a 20 pt strip of its own along that edge, over the rows: on the rows themselves a sideways drag that started on one opened it (a tap)
        // in the Simulator. Mostly sideways and at least 60 pt, else nothing
        .overlay(alignment: .leading) {
            if !pages.isEmpty {
                Color.clear.frame(width: 20).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                        guard v.translation.width > 60, abs(v.translation.height) < v.translation.width * 0.6 else { return }
                        if reduceMotion { pop() } else { withAnimation(.spring(duration: 0.2)) { pop() } }
                    })
                    .accessibilityHidden(true)   // VoiceOver goes back with the scrub (below) or the ‹ button
            }
        }
#endif
        .accessibilityAction(.escape) { pop() }   // VoiceOver's two-finger scrub goes back a page too
        .animation(reduceMotion ? nil : .spring(duration: 0.18), value: padShown ? focus : nil)   // the ring slides with the controller's focus
        .overlay(alignment: .bottom) { if toastShown, m.undoState != nil { toast.padding(.bottom, 64).transition(.opacity) } }
        .onChange(of: m.isCustom) { _, custom in   // VoiceOver hears the change to Custom and back (gate-ui §12)
            AccessibilityNotification.Announcement(custom ? "Custom, from \(m.basePreset.title)" : (m.activePreset?.title ?? "")).post()
        }
        .task(id: m.presetChange) {   // a preset change's toast with Undo, about 5 s (presets-first W9); a later change starts it again
            guard m.presetChange > 0 else { return }
            toastShown = true
            AccessibilityNotification.Announcement(toastText).post()   // the preset step, as the toast says it
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            toastShown = false; m.dropUndo()
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(GateColor.slab))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(GateColor.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .gesture(edgeBack)
        .animation(reduceMotion ? nil : .spring(duration: 0.22), value: pages)
        .onChange(of: pages) { if let t = lastTouched, !onPage(t) { lastTouched = nil } }   // the strip's note follows what the page shows
    }

    // A right swipe that starts within 24 pt of the panel's leading edge goes back a page (gate-ui §10)
    private var edgeBack: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { g in
            guard !pages.isEmpty, g.startLocation.x < 34, g.translation.width > 60, abs(g.translation.height) < 40 else { return }
            pop()
        }
    }
    private func pop() { if !pages.isEmpty { pages.removeLast() } }
    private func onPage(_ f: LauncherFocus) -> Bool {
        switch (page, f) {
        case (.main, .preset), (.main, .tile), (.main, .door), (.main, .backToPreset): return true
        case (.customize, .row), (.customize, .action("gate")), (.customize, .reset), (.customize, .acknowledgements), (.touch, .row), (.cloud, .action), (.options, .option): return true
        default: return f == .pageBack && !pages.isEmpty
        }
    }

    // MARK: Header

    private var title: String {
        switch page {
        case .main: "Settings"
        case .customize: "Customize"
        case .cloud: "Cloud saves"
        case .touch: "Touch controls"
        case .options(let env): m.gateRow(env)?.label ?? "Choose"
        }
    }
    private var header: some View {
        HStack(spacing: 6) {
            if !pages.isEmpty {
                Button { pop() } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: "‹").nxFont(.title2, weight: .semibold).foregroundStyle(GateColor.line)
                        Text(title).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 8).frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(GateTileStyle(focused: padShown && focus == .pageBack, fill: .clear, radius: 12))
                .accessibilityLabel("Back")
                .gateScrollID(LauncherFocus.pageBack)
            } else {
                Text(title).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text)
                    .padding(.leading, 6).frame(minHeight: 44).accessibilityAddTraits(.isHeader)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    // MARK: Pages

    @ViewBuilder private var pageBody: some View {
        switch page {
        case .main: mainPage
        case .customize: customizePage
        case .cloud: cloudPage
        case .touch: rowsPage(m.gateTouchRows)
        case .options(let env): if let s = m.gateRow(env) { optionsPage(s) }
        }
    }

    // The preset chips (1 × N, 2 × 2 in a narrow panel or at large text, one column at accessibility sizes), the preset line or the Custom bar, the tiles and the doors
    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.hasPresets { presetChips; presetLine }
            tileRow(m.gateFirstTiles)
            HStack(spacing: 8) {
                door(id: "customize", name: "Customize", sub: "Every setting", icon: .sliders) { pages.append(.customize) }
                door(id: "cloud", name: "Cloud saves", sub: status == .off ? "Off" : savesInNX18Folder ? "NX 18 folder" : "Own folder", icon: .cloud) { pages.append(.cloud) }
            }
            tileRow(m.gateSecondTiles)
            if !m.gateModTiles.isEmpty { tileRow(m.gateModTiles) }
        }
    }

    private var presetChips: some View {
        let active = m.activePreset
        let shown = m.offeredPresets
        let cols = typeSize.isAccessibilitySize ? 1 : typeSize >= .xxLarge ? 2 : shown.count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
            ForEach(shown) { p in
                let f = LauncherFocus.preset(p)
                Button { touch(f); m.applyPreset(p) } label: {
                    VStack(spacing: 4) {
                        NX18Icon(kind: NX18Icon.forPreset(p), size: 20).foregroundStyle(active == p ? GateColor.chosenIcon : GateColor.text)
                        Text(p.gateName).nxFont(.footnote, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8)
                        // light: a 3 pt rosewood bar under the chosen chip's name, so chosen (a bar inside) and focused (a ring outside) differ in shape (§11a.3)
                        if scheme == .light { Capsule().fill(active == p ? GateColor.ring : .clear).frame(width: 28, height: 3).accessibilityHidden(true) }
                    }
                    .foregroundStyle(active == p ? GateColor.ink : GateColor.text)
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(GateTileStyle(focused: padShown && focus == f, fill: active == p ? GateColor.chosen : GateColor.tile))
                .accessibilityLabel(p.gateName)
                .accessibilityHint(GateText.presetNote(m, p))
                .accessibilityAddTraits(active == p ? .isSelected : [])
                .gateScrollID(f)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preset")
        .accessibilityValue(m.isCustom ? "Custom, from \(m.basePreset.title)" : active?.title ?? "")
        .accessibilityActions {   // one-step actions in place of the strip's buttons (gate-ui §12): Back to the base preset while Custom, Undo while the toast's change can be undone
            if m.isCustom { Button("Back to \(m.basePreset.title)") { m.backToBase() } }
            if m.undoState != nil { Button("Undo") { m.undo(); toastShown = false } }
        }
    }

    // The toast after a preset change: what moved, and Undo (44 pt; the only part that takes touches; X with a controller while it shows)
    private var toast: some View {
        HStack(spacing: 10) {
            Text(toastText).nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).minimumScaleFactor(0.85)
            Button { m.undo(); toastShown = false } label: {
                HStack(spacing: 4) {
                    if padShown { Text(verbatim: "X").nxFont(.caption, weight: .bold).foregroundStyle(GateColor.line) }
                    Text("Undo").nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.line)
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
            }
            .buttonStyle(GateTileStyle(fill: GateColor.well, radius: 12))
            .accessibilityHint("Puts back the settings before this preset")
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 2)
        .background(Capsule().fill(GateColor.tile).shadow(color: .black.opacity(0.25), radius: 8, y: 2))
        .overlay(Capsule().strokeBorder(GateColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
    private var toastText: String {
        let p = m.activePreset ?? m.basePreset
        let parts = [p.title] + (p == .balanced ? [] : [presetSummary].filter { !$0.isEmpty })
        return parts.joined(separator: " · ")
    }

    // presets-first W13: while Battery Saver is lit, the first quick tile that costs power, by name
    private var batteryHint: String? {
        func on(_ env: String, _ v: String) -> Bool { m.settings.first { $0.env == env }.map { m.shown($0) == v } ?? false }
        if on("DM_OPMODE", "1") { return "Handheld mode saves more" }
        if on("DM_MOD_FPS", "1") { return "High frame rate is on" }
        if on("DM_MOD_ULTRAWIDE", "1") { return "Ultrawide uses more power" }
        return nil
    }
    // The preset's note and a short summary of what it sets, or while the values match no preset the Custom bar with its way back
    @ViewBuilder private var presetLine: some View {
        if let p = m.activePreset {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(GateText.presetNote(m, p)).nxFont(.caption).foregroundStyle(GateColor.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(presetSummary).nxFont(.caption).monospacedDigit().foregroundStyle(GateColor.line).lineLimit(1)
                }
                if p == .battery, let hint = batteryHint {   // W13: a quick tile that costs power while Battery Saver is lit; the tile is never flipped
                    Text(hint).nxFont(.caption, weight: .semibold).foregroundStyle(GateColor.line).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        } else {
            HStack(spacing: 8) {
                Circle().fill(GateColor.line).frame(width: 7, height: 7)
                Text(m.presetLabel).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
                Button { touch(.backToPreset); m.backToBase() } label: {
                    Text("Back to \(m.basePreset.title)").nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.line)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                }
                .buttonStyle(GateTileStyle(focused: padShown && focus == .backToPreset, fill: GateColor.well, radius: 12))
                .gateScrollID(LauncherFocus.backToPreset)
            }
            .padding(.leading, 8)
            .accessibilityElement(children: .contain)
        }
    }
    private var presetSummary: String {
        var parts: [String] = []
        if let s = m.gateRow("DM_FPS_TARGET") { parts.append(m.gateValue(s)) }
        if let s = m.gateRow("DM_RENDER_SCALE") { parts.append(m.gateValue(s).replacingOccurrences(of: " %", with: "%")) }
        return parts.joined(separator: " · ")
    }

    private func tileRow(_ ids: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(ids, id: \.self) { id in quickTile(id) }
            ForEach(0..<Swift.max(0, 3 - ids.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, minHeight: 1) }   // a short row keeps the three columns
        }
    }

    // A quick tile: the value or a lamp at the top, the name below. A tap does what A does: a two-value tile flips, three or more open the tick list; a swipe steps the value
    @ViewBuilder private func quickTile(_ id: String) -> some View {
        let f = LauncherFocus.tile(id)
        if id == "touch" {
            tileButton(f, name: "Touch controls", value: m.gateTouchRows.first.map(m.gateValue) ?? "", lamp: nil, icon: .touch, greyed: nil) { pages.append(.touch) }
        } else if let s = m.gateRow(id) {
            let greyed = m.fixed.contains(s.env) ? (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file") : m.inactiveWhy(s)
            tileButton(f, name: s.env == "DM_SHOW_FPS" ? s.label : s.label, value: s.kind == "toggle" ? nil : m.gateValue(s),
                       lamp: s.kind == "toggle" ? (m.shown(s) == s.onValue) : nil, icon: NX18Icon.forTile(id), greyed: greyed) { press(s, f) }
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { g in
                    guard abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                    touch(f); step(s, f, g.translation.width > 0 ? 1 : -1)
                })
                .accessibilityAdjustableAction { d in step(s, f, d == .increment ? 1 : -1) }
        }
    }
    private func tileValue(_ value: String, greyed: String?) -> some View {
        Text(value).nxFont(.footnote, weight: .semibold).foregroundStyle(greyed == nil ? GateColor.line : GateColor.disabled)
    }
    private func tileButton(_ f: LauncherFocus, name: String, value: String?, lamp: Bool?, icon: NX18Icon.Kind, greyed: String?, action: @escaping () -> Void) -> some View {
        Button { touch(f); action() } label: {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {   // a long value ("American English" in iPhone landscape) keeps its line and the tile its height: the icon steps aside first, then the text shrinks
                    HStack(spacing: 6) {
                        NX18Icon(kind: icon, size: 16).foregroundStyle(greyed == nil ? GateColor.line : GateColor.disabled)
                        if let lamp { Lamp(on: lamp) }
                        if let value { tileValue(value, greyed: greyed).lineLimit(1).fixedSize() }
                    }
                    if let value { tileValue(value, greyed: greyed).lineLimit(1).fixedSize() }
                    if let value { tileValue(value, greyed: greyed).lineLimit(1).minimumScaleFactor(0.6) }
                }
                Text(name).nxFont(.caption).foregroundStyle(greyed == nil ? GateColor.text : GateColor.disabled).lineLimit(2).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        }
        .buttonStyle(GateTileStyle(focused: padShown && focus == f))
        .modifier(GateShake(amount: shake[f] ?? 0))
        .accessibilityLabel(name)
        .accessibilityValue(value ?? (lamp.map { $0 ? "On" : "Off" } ?? ""))
        .accessibilityHint(greyed.map { "Dimmed. \($0)" } ?? "")
        .gateScrollID(f)
    }

    private func door(id: String, name: String, sub: String, icon: NX18Icon.Kind, open: @escaping () -> Void) -> some View {
        let f = LauncherFocus.door(id)
        return Button { touch(f); open() } label: {
            HStack(spacing: 10) {
                NX18Icon(kind: icon, size: 18).foregroundStyle(GateColor.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).minimumScaleFactor(0.75)
                    Text(sub).nxFont(.caption2).foregroundStyle(GateColor.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Text(verbatim: "›").nxFont(.body).foregroundStyle(GateColor.muted)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(GateTileStyle(focused: padShown && focus == f))
        .accessibilityLabel(name).accessibilityValue(sub).accessibilityAddTraits(.isButton)
        .gateScrollID(f)
    }

    // MARK: Customize, Touch controls and the rows

    private var customizePage: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(m.gateCustomizeGroups, id: \.title) { g in
                groupLabel(g.title, g.note)
                ForEach(g.rows) { s in row(s) }
                if g.title == "Other choices" { otherAppChoices }
            }
            if !m.gateCustomizeGroups.contains(where: { $0.title == "Other choices" }) { groupLabel("Other choices", "Additional settings"); otherAppChoices }
            actionRow(.reset, name: "Reset all settings", sub: "Brings back all settings this game was tested with.", coral: true, enabled: m.changed) { act(.confirmReset) }
            footer.nxFont(.caption2).foregroundStyle(GateColor.muted).padding(.horizontal, 4).padding(.top, 4)
        }
    }
    // The app's own choices at the end of Other choices (gate-ui G9): Gate at start, Acknowledgements until About this game links them (GW3)
    @ViewBuilder private var otherAppChoices: some View {
        let f = LauncherFocus.action("gate")
        Button { touch(f); if !gateAtStartLocked { m.skipAtStart.toggle() } else { refuse(f) } } label: {
            rowLabel(name: "Gate at start", sub: gateAtStartLocked ? "Set by an env file" : nil, greyed: gateAtStartLocked) {
                OnOffCapsule(on: !m.skipAtStart, enabled: !gateAtStartLocked)
            }
        }
        .buttonStyle(GateTileStyle(focused: padShown && focus == f))
        .modifier(GateShake(amount: shake[f] ?? 0))
        .accessibilityLabel("Gate at start").accessibilityValue(m.skipAtStart ? "Off" : "On").accessibilityAddTraits(.isToggle)
        .gateScrollID(f)
        if acknowledgements { actionRow(.acknowledgements, name: "Acknowledgements", sub: nil, coral: false, enabled: true) { act(.acknowledgements) } }
    }

    private func groupLabel(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.line).accessibilityAddTraits(.isHeader)
            Text(note).nxFont(.caption2).foregroundStyle(GateColor.muted).lineLimit(1)
        }
        .padding(.horizontal, 4).padding(.top, 8)
    }

    private func rowsPage(_ rows: [Setting]) -> some View {
        VStack(alignment: .leading, spacing: 8) { ForEach(rows) { s in row(s) } }
    }

    // One row grammar: the name on the left (the reason under it while greyed), the value on the right. A choice reads ‹ value ›: ‹ and › step, a tap on the name or the value
    // opens the tick list (three or more options) or steps (two); a toggle is an On or Off capsule and a tap anywhere flips it; a range is ten pips and a percentage
    // A row's VoiceOver value: its value, and "changed from Balanced" where the dot shows (gate-ui §12)
    private func a11yValue(_ s: Setting, _ differs: Bool) -> String { m.gateValue(s) + (differs ? ", changed from \(m.basePreset.title)" : "") }
    @ViewBuilder private func row(_ s: Setting) -> some View {
        let f = LauncherFocus.row(s.env)
        let greyed = m.fixed.contains(s.env) ? (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file") : m.inactiveWhy(s)
        let differs = m.changedFromBase(s)   // differs from the base preset: the dot, and "changed from Balanced" for VoiceOver
        Group {
            switch s.kind {
            case "range":
                HStack(spacing: 8) {
                    rowName(s, greyed: greyed, differs: differs)
                    Spacer(minLength: 6)
                    PipMeter(value: Double(m.shown(s)) ?? s.max ?? 1, lo: s.min ?? 0, hi: s.max ?? 1, enabled: greyed == nil) { v in
                        touch(f); m.values[s.env] = String(format: "%.2f", v)
                    }
                    .frame(width: 110)
                    Text(m.gateValue(s)).nxFont(.footnote).monospacedDigit().foregroundStyle(greyed == nil ? GateColor.line : GateColor.disabled).frame(minWidth: 44, alignment: .trailing)
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(padShown && focus == f ? GateColor.lit : GateColor.tile))
                .overlay { if padShown && focus == f { GateRing(radius: 14) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.label).accessibilityValue(a11yValue(s, differs)).accessibilityHint(greyed.map { "Dimmed. \($0)" } ?? m.gateBrief(s))
                .accessibilityAdjustableAction { d in step(s, f, d == .increment ? 1 : -1) }
            case "choice":
                HStack(spacing: 0) {
                    Button { touch(f); press(s, f) } label: { rowName(s, greyed: greyed, differs: differs).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                    stepTarget("‹", greyed: greyed) { touch(f); step(s, f, -1) }
                    Button { touch(f); press(s, f) } label: {
                        Text(m.gateValue(s)).nxFont(.footnote, weight: .semibold).foregroundStyle(greyed == nil ? GateColor.line : GateColor.disabled).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(minWidth: 44, minHeight: 46)
                    }
                    .buttonStyle(.plain)
                    stepTarget("›", greyed: greyed) { touch(f); step(s, f, 1) }
                }
                .padding(.leading, 12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(padShown && focus == f ? GateColor.lit : GateColor.tile))
                .overlay { if padShown && focus == f { GateRing(radius: 14) } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.label).accessibilityValue(a11yValue(s, differs)).accessibilityHint(greyed.map { "Dimmed. \($0)" } ?? m.gateBrief(s))
                .accessibilityAdjustableAction { d in step(s, f, d == .increment ? 1 : -1) }
            default:
                Button { touch(f); press(s, f) } label: {
                    rowLabel(name: s.label, sub: greyed, greyed: greyed != nil, differs: differs) {
                        OnOffCapsule(on: m.shown(s) == s.onValue, enabled: greyed == nil)
                    }
                }
                .buttonStyle(GateTileStyle(focused: padShown && focus == f))
                .accessibilityLabel(s.label).accessibilityValue(a11yValue(s, differs)).accessibilityHint(greyed.map { "Dimmed. \($0)" } ?? m.gateBrief(s)).accessibilityAddTraits(.isToggle)
            }
        }
        .modifier(GateShake(amount: shake[f] ?? 0))
        .gateScrollID(f)
    }
    private func rowName(_ s: Setting, greyed: String?, differs: Bool) -> some View {
        HStack(spacing: 6) {
            if differs { Circle().fill(GateColor.line).frame(width: 6, height: 6) }
            VStack(alignment: .leading, spacing: 2) {
                Text(s.label).nxFont(.subheadline).foregroundStyle(greyed == nil ? GateColor.text : GateColor.disabled)
                if let g = greyed { Text(g).nxFont(.caption2).foregroundStyle(GateColor.disabled).lineLimit(2) }
            }
        }
    }
    private func rowLabel<V: View>(name: String, sub: String?, greyed: Bool, differs: Bool = false, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 8) {
            if differs { Circle().fill(GateColor.line).frame(width: 6, height: 6) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).nxFont(.subheadline).foregroundStyle(greyed ? GateColor.disabled : GateColor.text)
                if let sub { Text(sub).nxFont(.caption2).foregroundStyle(GateColor.disabled).lineLimit(2) }
            }
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 46)
    }
    private func stepTarget(_ glyph: String, greyed: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: glyph).nxFont(.title3, weight: .semibold).foregroundStyle(greyed == nil ? GateColor.muted : GateColor.disabled.opacity(0.6))
                .frame(width: 44, height: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
    private func actionRow(_ f: LauncherFocus, name: String, sub: String?, coral: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { touch(f); if enabled { action() } else { refuse(f) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).nxFont(.subheadline, weight: .semibold).foregroundStyle(!enabled ? GateColor.disabled : coral ? GateColor.wine : GateColor.text)
                    if let sub { Text(sub).nxFont(.caption2).foregroundStyle(GateColor.muted).lineLimit(2) }
                }
                Spacer()
                if !coral { Text(verbatim: "›").nxFont(.title3).foregroundStyle(GateColor.muted) }
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(GateTileStyle(focused: padShown && focus == f))
        .modifier(GateShake(amount: shake[f] ?? 0))
        .accessibilityLabel(name)
        .gateScrollID(f)
    }

    // The tick list of a choice with three or more options: the chosen one filled, a greyed one dimmed with its reason; a pick goes back to the page the list opened from
    private func optionsPage(_ s: Setting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(s.options ?? [], id: \.[0]) { o in
                let f = LauncherFocus.option(s.env, o[0])
                let chosen = m.shown(s) == o[0]
                let why = chosen ? nil : (m.optionInactive(s, o[0]) ?? (m.inactiveWhy(s) ?? (m.fixed.contains(s.env) ? "Set by an env file" : nil)))
                Button { touch(f); if m.canPick(s, o[0]) && !m.fixed.contains(s.env) { m.pick(s, o[0]); pop(); touch(pages.isEmpty ? .tile(s.env) : .row(s.env)) } else { refuse(f) } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o[1]).nxFont(.subheadline, weight: chosen ? .semibold : .regular).foregroundStyle(chosen ? GateColor.ink : why == nil ? GateColor.text : GateColor.disabled)
                            if let why { Text(why).nxFont(.caption2).foregroundStyle(GateColor.disabled) }
                        }
                        Spacer()
                        if chosen { Text(verbatim: "✓").nxFont(.subheadline, weight: .bold).foregroundStyle(GateColor.ink) }
                    }
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(GateTileStyle(focused: padShown && focus == f, fill: chosen ? GateColor.chosen : GateColor.tile))
                .modifier(GateShake(amount: shake[f] ?? 0))
                .accessibilityLabel(o[1]).accessibilityAddTraits(chosen ? .isSelected : [])
                .gateScrollID(f)
            }
        }
    }

    // MARK: Cloud saves

    private var cloudPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                NX18Icon(kind: .cloud, size: 20).foregroundStyle(GateColor.line)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").nxFont(.caption).foregroundStyle(GateColor.muted)
                    Text(cloudFolderName ?? "Off").nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(GateColor.well))
            .accessibilityElement(children: .combine)
            actionRow(.action("cloud.choose"), name: cloudFolderName == nil ? "Choose a folder in iCloud Drive" : "Choose a different folder",
                      sub: "Pick the same folder in this game's app on your other devices.", coral: false, enabled: true) { act(.chooseCloudFolder) }
            if cloudFolderName != nil {
                actionRow(.action("cloud.off"), name: "Turn off cloud saves", sub: "This device keeps its own save.", coral: true, enabled: true) { act(.confirmCloudOff) }
            }
        }
    }
#if os(macOS)
    private var cloudFolderName: String? { MacCloud.folderName }   // the Mac's chosen folder (dm/mac/Launcher.swift)
#else
    private var cloudFolderName: String? { dmCloudFolderName() }
#endif

    // MARK: The hint strip

    private var strip: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(note(noted)).nxFont(.caption).foregroundStyle(GateColor.muted).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            if padShown {
                HStack(spacing: 13) {
                    hint(.a, "Choose")
                    hint(.b, pages.isEmpty ? "Play line" : "Back")
                    if m.hasPresets {
                        Text("\(GateText.shoulder(glyphs.name(NXShoulder.l))) \(GateText.shoulder(glyphs.name(NXShoulder.r))) Preset").nxFont(.caption2).foregroundStyle(GateColor.muted).lineLimit(1)
                    }
                    hint(.plus, "Play")
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 7).padding(.bottom, 8)
        .background(GateColor.well.opacity(0.4))
        .overlay(alignment: .top) { Rectangle().fill(GateColor.hairline).frame(height: 1) }
        .accessibilityHidden(true)
    }
    private func hint(_ b: NXButton, _ text: String) -> some View {
        HStack(spacing: 4) {
            NXPadGlyphView(glyphs.glyph(b), size: 15, relativeTo: .caption2).foregroundStyle(b == .plus ? GateColor.coral : GateColor.line)
            Text(text).nxFont(.caption2).foregroundStyle(GateColor.muted)
        }
    }
    // The strip's line for an item: its brief note (gate-ui §14), never more than one line
    private func note(_ f: LauncherFocus?) -> String {
        switch f {
        case .preset(let p)?: return GateText.brief(GateText.presetNote(m, p))
        case .backToPreset?: return "Puts the preset rows back to \(m.basePreset.title). Toggles stay."
        case .tile("touch")?: return "Size, opacity and feedback of the touch controls."
        case .tile(let env)?, .row(let env)?: return m.gateRow(env).map(m.gateBrief) ?? ""
        case .door("customize")?: return "Every setting, grouped. Presets set the first group."
        case .door("cloud")?: return "Keep this game's save in step with your other devices."
        case .action("gate")?: return "Show this screen before the game starts."
        case .action("cloud.choose")?: return "Moves this game's cloud saves to a folder you choose."
        case .action("cloud.off")?: return "Stops cloud saves for this game."
        case .reset?: return "Brings back all settings this game was tested with."
        case .acknowledgements?: return "The licences of the code and art this app is built with."
        case .option(let env, let v)?: return m.gateRow(env).map { m.optionHint($0, v) ?? m.optionInactive($0, v) ?? m.optionLabel($0, v) } ?? ""
        case .pageBack?: return "Back to the page before."
        default: return pages.isEmpty ? "Choose a preset, or change one setting at a time." : ""
        }
    }

    // MARK: Actions

    private func touch(_ f: LauncherFocus) { lastTouched = f; touched(f) }
    // A on a tile or row, or a tap: a two-value choice or a toggle steps, three or more options open the tick list; a greyed one refuses
    private func press(_ s: Setting, _ f: LauncherFocus) {
        guard m.editable(s) else { refuse(f); return }
        if s.kind == "choice", (s.options?.count ?? 0) >= 3 { pages.append(.options(s.env)); return }
        if s.kind == "range" { return }
        m.advance(s, by: 1)
    }
    private func step(_ s: Setting, _ f: LauncherFocus, _ d: Int) { if !m.advance(s, by: d), !m.editable(s) { refuse(f) } }
    private func refuse(_ f: LauncherFocus) {
#if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
#endif
        if reduceMotion { return }
        shake[f] = 0
        withAnimation(.easeOut(duration: 0.3)) { shake[f] = 1 }
    }
}

// What a press on the panel asks the launcher for
enum GateAction: Equatable, Sendable { case chooseCloudFolder, confirmCloudOff, confirmReset, acknowledgements }

// MARK: - Row controls

// A quick tile's lamp: lit cyan when on, a ring in the marks colour when off (GW18)
struct Lamp: View {
    let on: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Circle().fill(on ? GateColor.line : Color.clear)
            .overlay(Circle().strokeBorder(on ? GateColor.line : GateColor.disabled, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .shadow(color: on && scheme != .light ? GateColor.line.opacity(0.5) : .clear, radius: 3)   // no glow in light: it reads as a smudge there (§11a.4)
    }
}

// On or Off as a small capsule: filled while on, a ring while off
struct OnOffCapsule: View {
    let on: Bool
    var enabled = true
    var body: some View {
        Text(on ? "On" : "Off").nxFont(.caption, weight: .semibold)
            .foregroundStyle(on ? GateColor.ink : (enabled ? GateColor.text : GateColor.disabled))
            .frame(width: 48, height: 26)
            .background(Capsule().fill(on ? (enabled ? GateColor.chosen : GateColor.disabled) : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Color.clear : GateColor.disabled, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

// Ten pips for a range: a tap on a pip sets it, a drag scrubs (horizontal only: a vertical drag scrolls)
struct PipMeter: View {
    let value: Double
    let lo: Double
    let hi: Double
    var enabled = true
    let set: (Double) -> Void
    private var lit: Int { hi > lo ? Int(((value - lo) / (hi - lo) * 10).rounded()) : 10 }
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(i < lit ? (enabled ? GateColor.line : GateColor.disabled) : GateColor.separator).frame(height: 6)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                guard enabled, abs(d.translation.width) >= abs(d.translation.height) else { return }
                let k = Swift.min(Swift.max((d.location.x / Swift.max(g.size.width, 1) * 10).rounded(.up), 0), 10)
                set(lo + (hi - lo) * k / 10)
            })
        }
        .frame(height: 46)
        .accessibilityHidden(true)
    }
}
