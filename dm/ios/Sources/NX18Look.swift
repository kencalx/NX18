// The light look and the Appearance choice (NX18-X2.0 gate-ui.md §11a, G8, G19-G21; the choice §20.5b, G20). One choice, on the NX 18 card: Match device (the default),
// Light or Dark. It covers the Gate (its page, slab and pages), About this game, Acknowledgements, the NX 18 card, the acknowledgement panel and the in-game menu (its dim
// light set). The art side (the hero: art, scrim, title, status line, Play, Guide, About and the mark on it), Vitals, the touch controls and the game stay dark.
// The tokens are dynamic colours: they follow the trait collection's style, which the choice sets on the hosting controller (overrideUserInterfaceStyle), so a change applies live
// with no view rebuilt (tokens are never part of a view's identity: focus, the open card and the page stack stay where they are). A subtree that must stay dark sets
// .environment(\.colorScheme, .dark), which SwiftUI resolves these colours against. Dark values are the Gate's as they were (LauncherPanel.swift GateColor), light the Soft
// tone's light set (§11a.3), in-game light the dimmer set (§11a.5)
import SwiftUI
#if os(macOS)
import AppKit
typealias NX18PlatformColor = NSColor
#else
import UIKit
typealias NX18PlatformColor = UIColor
#endif

// The choice: nx18.appearance in the app's defaults ("device", "light" or "dark"), which always holds the value in use, so a start never waits on iCloud and the in-game menu
// reads it with no file access. Not a launcher.* key, so Reset all settings keeps it (GW23). With the Profile on and an NX 18 folder chosen it also goes with the Profile
// (appearance.txt and the stamp, NX18Profile.swift), so every game app using the folder follows; a look that finds a newer Profile there sets it here without writing back
enum NX18Appearance: String, CaseIterable, Sendable {
    case device, light, dark
    static let key = "nx18.appearance"
    // NX18Profile.swift: writes appearance.txt when the Profile uses the NX 18 folder; true when it did. nil (a target without the Profile): per app only
    nonisolated(unsafe) static var share: ((NX18Appearance) -> Bool)? = nil
    static var current: NX18Appearance {
        get { UserDefaults.standard.string(forKey: key).flatMap(NX18Appearance.init(rawValue:)) ?? .device }
        set { store(newValue, fromFolder: false) }
    }
    // fromFolder: the NX 18 folder's Profile brought this value (nothing is written back)
    static func store(_ value: NX18Appearance, fromFolder: Bool) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        let folder = fromFolder || (share?(value) ?? false)
        fputs("launcher: appearance \(value.rawValue) (\(folder ? "NX 18 folder" : "this app"))\n", stderr)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static let changed = Notification.Name("nx18.appearance.changed")
    var title: String { switch self { case .device: "Match device"; case .light: "Light"; case .dark: "Dark" } }
#if os(macOS)
    var appearance: NSAppearance? { switch self { case .device: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) } }
#else
    var style: UIUserInterfaceStyle { switch self { case .device: .unspecified; case .light: .light; case .dark: .dark } }
#endif
    // For a SwiftUI presentation (a sheet, a cover), which does not take its presenter's style: nil follows the device
    var scheme: ColorScheme? { switch self { case .device: nil; case .light: .light; case .dark: .dark } }
    // The next value a step of the row gives (‹ and ›), in the row's order
    func stepped(_ by: Int) -> NX18Appearance {
        let all = Self.allCases, i = all.firstIndex(of: self)!
        return all[(i + (by >= 0 ? 1 : all.count - 1)) % all.count]
    }
}

extension NX18PlatformColor {
    convenience init(nx18 hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
extension Color {
    // A token: dark in the dark look (and wherever a subtree is held dark), light in the light look
    init(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) {
        self.init(nx18Dynamic: NX18PlatformColor(nx18: dark, alpha: darkAlpha), light: NX18PlatformColor(nx18: light, alpha: lightAlpha))
    }
    // A colour that resolves against the look: the trait collection's style on iOS, the effective appearance on the Mac (an NSColor made from a static SwiftUI colour does not follow it)
    init(nx18Dynamic d: NX18PlatformColor, light l: NX18PlatformColor) {
#if os(macOS)
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? l : d })
#else
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .light ? l : d })
#endif
    }
}

// The in-game menu's set (§11a.5): the dark set as the panel had it, and the dimmer light set, so opening it over a dark game is never a flash of white
enum MenuColor {
    static let slab = Color(dark: 0x2A2A2D, light: 0xBDBDC3)
    static let tile = Color(dark: 0x333337, light: 0xCACACF)
    static let lit = Color(dark: 0x23434D, light: 0xD9BFBB)
    static let text = Color(dark: 0xEDEDF0, light: 0x121214)
    static let muted = Color(dark: 0xB4B4BC, light: 0x38383E)
    static let line = Color(dark: NX18Palette.cyanHex, light: 0x743C35)       // section labels, values, icons, the A glyph
    static let second = Color(dark: NX18Palette.coralHex, light: 0x1E5261)    // the Close disc and the + glyph take the second accent in game
    static let separator = Color(dark: 0x3E3E44, light: 0x9C9CA4)
    static let hairline = Color(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.08, lightAlpha: 0.12)
    static let ink = Color(dark: 0x2A2A2D, light: 0xFFFFFF)                    // on a filled disc
    static let well = Color(dark: 0x141415, light: 0xB2B2B8)
    static let chosen = Color(dark: 0x9CD1E2, light: 0xC29A91)                  // the chosen preset chip: powder cyan; the dim chosen fill in light (§11a.5)
    static let chosenIcon = Color(dark: 0x2A2A2D, light: 0x743C35)              // an icon on the chosen fill
    static let bar = Color(dark: 0x2A2A2D, light: 0x743C35)                     // light: the 3 pt bar under the chosen chip's name
}

// The page behind the Gate's slab with the art's average mixed in: 12 % over the dark page, 6 % over the light one (a tint shows more on a light surface, §11a.4)
enum NX18PageColor {
    static func page(tint: NX18RGB?) -> Color {
        func mixed(_ base: UInt32, _ k: Double) -> NX18PlatformColor {
            let c = NX18RGB(hex: base)
            guard let t = tint else { return NX18PlatformColor(red: c.r, green: c.g, blue: c.b, alpha: 1) }
            return NX18PlatformColor(red: c.r + (t.r - c.r) * k, green: c.g + (t.g - c.g) * k, blue: c.b + (t.b - c.b) * k, alpha: 1)
        }
        return Color(nx18Dynamic: mixed(0x1E1E21, 0.12), light: mixed(0xDCDCE1, 0.06))
    }
}

// NX 18's own release and build, under the game's version: "NX 18 X2.0 · build 18be2887" (DMRelease from dm/RELEASE and DMCommit, both stamped by the packer; nil when neither is there)
var nx18Line: String? {
    let rel = (Bundle.main.object(forInfoDictionaryKey: "DMRelease") as? String).flatMap { $0.isEmpty ? nil : $0 }
    let commit = (Bundle.main.object(forInfoDictionaryKey: "DMCommit") as? String).flatMap { $0.isEmpty ? nil : $0 }
    guard rel != nil || commit != nil else { return nil }
    var s = "NX 18" + (rel.map { " \($0)" } ?? "")
    if let c = commit { s += " · build " + String(c.prefix(8)) + (c.hasSuffix("+dirty") ? "+" : "") }
    return s
}

// G17 (gate-ui §20.5a): who built this app, fixed at build: "Built by Player 1 · build 482b7210", or "Build ID 7K4Q-92XD · build 482b7210" without a name at build.
// DMBuiltBy and DMBuildID come from the packer (the NSP script's build_stamp); nil when the app has neither. It never follows the live Profile
var nx18StampLine: String? {
    func key(_ k: String) -> String? { (Bundle.main.object(forInfoDictionaryKey: k) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    let commit = key("DMCommit").map { " · build " + String($0.prefix(8)) + ($0.hasSuffix("+dirty") ? "+" : "") } ?? ""
    if let by = key("DMBuiltBy") { return "Built by \(by)" + commit }
    if let id = key("DMBuildID") { return "Build ID \(id)" + commit }
    return nil
}

// About's footer (§18.1): "NX 18 X2.0 · Built by Player 1 · build 482b7210", or "NX 18 X2.0 · Build ID 7K4Q-92XD · build 482b7210"
var nx18FooterLine: String? {
    guard let line = nx18Line else { return nx18StampLine }
    guard let who = nx18StampLine?.components(separatedBy: " · build ").first else { return line }
    guard let r = line.range(of: " · build ") else { return line + " · " + who }
    return String(line[..<r.lowerBound]) + " · " + who + String(line[r.lowerBound...])
}

// The coral Play pill's and the small buttons' press: a little dimmer and smaller while held
struct NX18PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1).scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
