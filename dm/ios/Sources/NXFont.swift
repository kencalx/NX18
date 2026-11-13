// NX 18's UI font in SwiftUI: every text style the iOS launcher (Launcher.swift, LauncherRow.swift, GuideViewer.swift) and the Mac app's settings window (dm/mac/Launcher.swift) draw
// goes through here. The font is the player's own (the NSP script's --ui-font / UI_FONT), which dm/host/ui_font.h registers at the app's start (main.m; the Mac's launcher.c) and
// publishes as DM_UI_FONT_NAME; without it, or with iOS's Bold Text on, every style is the system font exactly as before (the font has one weight and would ignore Bold Text).
// With it: one face for every weight (Apple's text stacks do not make it bold; headings keep their place by size and colour), sizes times DM_UI_FONT_SCALE (default 0.9: its letters
// are larger than the system font's at one size), Dynamic Type kept (Font.custom relativeTo:), and a little space between wrapped lines, which its metrics leave out
// (nxTextRoot). Characters it lacks (a thin space, Hangul, symbols) come from the system's fallback fonts. The Mac app compiles this file too (dm/mac/pack_app.py swift_sources)
import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum NXFont {
    /// The registered UI font's PostScript name, nil for the system font. DM_UI_FONT_NAME, taken only when a font of that name is there (a stale name gives the system font)
    static let name: String? = {
        guard let n = ProcessInfo.processInfo.environment["DM_UI_FONT_NAME"], !n.isEmpty else { return nil }
        return CTFontCopyPostScriptName(CTFontCreateWithName(n as CFString, 12, nil)) as String == n ? n : nil
    }()
    /// DM_UI_FONT_SCALE (0.5 to 1.5), else 0.9, as ui_font.h
    static let scale: CGFloat = {
        guard let s = ProcessInfo.processInfo.environment["DM_UI_FONT_SCALE"], let v = Double(s), (0.5...1.5).contains(v) else { return 0.9 }
        return CGFloat(v)
    }()
    /// Space between wrapped lines with the UI font, in ems (ui_font.h DM_UI_LINE_SPACING, which says why 0.3): the system font's lines are about 1.2 ems, this font's 1.0 in SwiftUI
    static let lineSpacingEm: CGFloat = 0.3

    /// A text style's size at the default text size, which Font.custom scales from (the platform's own table)
    static func base(_ s: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch s {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        default: return 13
        }
        #else
        switch s {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
        #endif
    }

    /// A text style: the UI font, scaled with Dynamic Type relative to the style, else the system font at the style and weight. boldText: iOS's Bold Text, which takes the system font
    static func style(_ s: Font.TextStyle, weight: Font.Weight = .regular, boldText: Bool = false) -> Font {
        if let n = name, !boldText { return .custom(n, size: base(s) * scale, relativeTo: s) }
        return weight == .regular ? .system(s) : .system(s).weight(weight)
    }

    /// The license texts of Acknowledgements (GuideViewer.swift LauncherNoticesSheet), laid out in fixed-width columns as their authors wrote them: the system's monospaced font
    /// at the style, whatever the UI font
    static func mono(_ s: Font.TextStyle) -> Font { .system(s, design: .monospaced) }
    #if os(macOS)
    /// The same for the Mac window's text view (dm/mac/Launcher.swift MacNoticesWindow)
    static func monoNS(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    #endif

    /// A fixed size (the Mac banner's name and pills): the UI font at size times the scale, else the system font at size and weight
    static func fixed(_ size: CGFloat, weight: Font.Weight = .regular, boldText: Bool = false) -> Font {
        if let n = name, !boldText { return .custom(n, fixedSize: size * scale) }
        return .system(size: size, weight: weight)
    }
}

// The modifiers the views use, so iOS's Bold Text is read in one place
private struct NXFontModifier: ViewModifier {
    enum Kind { case style(Font.TextStyle), fixed(CGFloat) }
    let kind: Kind
    let weight: Font.Weight
    let onlyCustom: Bool
    @Environment(\.legibilityWeight) private var legibility

    func body(content: Content) -> some View {
        let bold = legibility == .bold
        if onlyCustom && (NXFont.name == nil || bold) {
            content   // the container's own styling (a List footer, a Form row), as before
        } else {
            switch kind {
            case .style(let s): content.font(NXFont.style(s, weight: weight, boldText: bold))
            case .fixed(let size): content.font(NXFont.fixed(size, weight: weight, boldText: bold))
            }
        }
    }
}

private struct NXTextRoot: ViewModifier {
    @Environment(\.legibilityWeight) private var legibility
    func body(content: Content) -> some View {
        if NXFont.name != nil && legibility != .bold {
            content.font(NXFont.style(.body)).lineSpacing(NXFont.base(.body) * NXFont.scale * NXFont.lineSpacingEm)
        } else {
            content
        }
    }
}

extension View {
    /// The text style in the UI font (else the system font at the style and weight, as before)
    func nxFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(NXFontModifier(kind: .style(style), weight: weight, onlyCustom: false))
    }
    /// A fixed size in the UI font (else the system font at that size and weight)
    func nxFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(NXFontModifier(kind: .fixed(size), weight: weight, onlyCustom: false))
    }
    /// The text style in the UI font, only with the UI font: text that takes its container's font today (a List or Form footer, an AppKit-backed control's title) keeps it without one
    func nxFontIfCustom(_ style: Font.TextStyle) -> some View {
        modifier(NXFontModifier(kind: .style(style), weight: .regular, onlyCustom: true))
    }
    /// Fixed-width text (a license's text, NXFont.mono): the system's monospaced font at the style, with or without the UI font
    func nxMono(_ style: Font.TextStyle) -> some View { font(NXFont.mono(style)) }
    /// A screen's or sheet's root: body text in the UI font and its wrapped lines spaced; nothing without the UI font
    func nxTextRoot() -> some View { modifier(NXTextRoot()) }
}
