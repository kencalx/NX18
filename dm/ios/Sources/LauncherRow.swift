// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled, and so is a row a rule makes inactive (LauncherModel.reason), with the reason as
// its note; an option a rule makes inactive is shown but cannot be picked, with the reason beside it. Below the row: the NX 18 look both launchers share (the palette, the mark, the
// preset chips, the rails line, the status line, the game's logo), which the Mac app's build compiles from this file too (dm/mac/pack_app.py lists it).
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.shown(s) }, set: { self.pick(s, $0) }) }   // the value the row shows (shown); a greyed row or option is refused (pick)
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fixed.contains(s.env) }
    private var inactive: Bool { m.inactiveWhy(s) != nil }
    private var current: String { m.shown(s) }   // the player's choice, or the value a greyed row shows (Picture's Stretch under Ultrawide)
    // The setting's note, the reason a rule gives (in its place when the row does nothing: what the setting costs no longer matters then), and the lock. Each line is decided
    // as the values change, as is the row's disabled state
    private var note: String {
        var parts: [String] = []
        let reason = m.reason(s)
        if let r = reason, r.inactive { parts.append(r.why) } else {
            if !s.note.isEmpty { parts.append(s.note) }
            if let r = reason, !r.why.isEmpty { parts.append(r.why) }
        }
        if locked { parts.append(m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file") }
        return parts.joined(separator: " · ")
    }
    // An option's label in the menu: with its reason beside it while a rule greys it or gives it a hint. The chosen option keeps its plain label, as the menu's button shows it,
    // and its reason is the row's note
    private func optionLabel(_ o: [String]) -> String {
        guard o[0] != current, let why = m.optionInactive(s, o[0]) ?? m.optionHint(s, o[0]), !why.isEmpty else { return o[1] }
        return "\(o[1]) (\(why))"
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.shown(s)) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label).foregroundStyle(NX18Palette.text)
            if !note.isEmpty { Text(note).nxFont(.footnote).foregroundStyle(NX18Palette.muted) }
        }
    }

    private var options: some View {
        ForEach(s.options ?? [], id: \.[0]) { o in
            Text(optionLabel(o)).tag(o[0]).selectionDisabled(m.optionInactive(s, o[0]) != nil)
        }
    }
    private var currentLabel: String { s.options?.first { $0[0] == current }?[1] ?? current }
    // A choice with the UI font (NXFont.swift): the menu picker draws its value itself, in the system font on iOS (a UIKit button) and on the Mac in an NSPopUpButton whose
    // title sits below the row's name (AppKit lays the font out with its line gap). So the value is NX 18's own text in a Menu, and only the option list is the system's menu
    // (the same Picker, inline in it: checkmark, greyed options). Name and value side by side, the value under the name at the accessibility text sizes, as the menu picker does
    @ViewBuilder private var fontChoice: some View {
        let value = Menu {
            Picker(selection: m.binding(s)) { options } label: { Text(s.label) }
                .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel).nxFont(.body)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .foregroundStyle(enabled && !locked && !inactive ? NX18Palette.cyan : NX18Palette.muted)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).fixedSize()
        .accessibilityLabel(Text(s.label)).accessibilityValue(Text(currentLabel))
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) { settingLabel.accessibilityHidden(true); value.accessibilityHint(Text(note)) }
        } else {
            HStack(alignment: .firstTextBaseline) { settingLabel.accessibilityHidden(true); Spacer(minLength: 12); value.accessibilityHint(Text(note)) }
        }
    }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.legibilityWeight) private var legibility
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                if NXFont.name != nil && legibility != .bold { fontChoice } else {
                    Picker(selection: m.binding(s)) { options } label: { settingLabel }
                        .pickerStyle(.menu)
                }
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(NX18Palette.muted)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { current == s.onValue }, set: { m.pick(s, $0 ? s.onValue : s.offValue) })) {
                    settingLabel
                }
                .disabled(m.optionInactive(s, current == s.onValue ? s.offValue : s.onValue) != nil)   // the value it would switch to is greyed
            }
        }
        .disabled(locked || inactive)
        .tint(NX18Palette.cyan)   // switches on, the slider, the menu's value: the logo's cyan
    }
}

// MARK: - The NX 18 look (docs/images/nx18/make_logo.py): charcoal surfaces, cyan accents, coral for Play, Reset and the 18. The accents, the rails and the mark keep these
// colours on every game; only the background may take a little of the art's colour (background(tint:))
public enum NX18Palette {
    public static let charcoal = Color(nx18: 0x2A2A2D)     // cards; the 18's digits; text on a cyan or coral fill
    public static let background = Color(nx18: 0x1E1E21)   // the screen
    public static let row = Color(nx18: 0x333337)          // a settings row
    public static let separator = Color(nx18: 0x3E3E44)
    public static let text = Color(nx18: 0xEDEDF0)         // a setting's name and other plain text: near white, set outright so a light-mode trait cannot turn it black
    public static let muted = Color(nx18: 0xB4B4BC)        // notes, values, chevrons: light enough to read on the cards (#9A9AA2 was too dim)
    public static let onArt = Color(nx18: 0xC4C4CA)        // the muted grey a little lighter, for small text over the art (the status line), always on a scrim
    public static let cyan = Color(nx18: cyanHex)          // section headings, switches, the slider, the focus ring, the N
    public static let coral = Color(nx18: coralHex)        // the Play pill, Reset, the 18 pill
    static let cyanHex: UInt32 = 0x00C8F5, coralHex: UInt32 = 0xFF6B5A   // also the rails' Core Animation layer (NX18RailsFlowView)

    // The art's average colour, for the tint: the image drawn into an 8 x 8 sRGB bitmap with Core Graphics, on the CPU (no Metal device or Core Image context: Launcher.swift's
    // metalDeviceMade). nil for an image Core Graphics cannot draw or one that is all transparent
    public static func average(of image: CGImage) -> NX18RGB? {
        let side = 8
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for i in 0..<(side * side) {   // premultiplied: the sums over the alpha sum are the colour of what is opaque
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2]); a += Double(px[i * 4 + 3])
        }
        guard a > 0 else { return nil }
        return NX18RGB(r: r / a, g: g / a, b: b / a)
    }
    // A surface with the art's colour mixed in, at most 12 % (the screen behind the settings, the art's fade); without a tint, the surface as it is
    public static func background(tint: NX18RGB?, amount: Double = 0.12) -> Color { mix(0x1E1E21, tint, amount) }
    public static func card(tint: NX18RGB?, amount: Double = 0.12) -> Color { mix(0x2A2A2D, tint, amount) }
    static func mix(_ base: UInt32, _ tint: NX18RGB?, _ amount: Double) -> Color {
        guard let t = tint else { return Color(nx18: base) }
        let k = Swift.min(Swift.max(amount, 0), 0.12)
        let c = NX18RGB(hex: base)
        return Color(.sRGB, red: c.r + (t.r - c.r) * k, green: c.g + (t.g - c.g) * k, blue: c.b + (t.b - c.b) * k, opacity: 1)
    }
}
// An sRGB colour as 0...1 components (the art's average)
public struct NX18RGB: Equatable, Sendable {
    public var r, g, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) { self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255) }
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}
extension Color {
    init(nx18 hex: UInt32) { let c = NX18RGB(hex: hex); self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1) }
}

// The game's logo (dm/logo.png: its title wordmark with transparency, from SteamGridDB or the player's --logo, scripts/game_art.py), shown in place of the name over the art by both launchers
enum NX18Logo {
    // The logo decoded on the CPU with ImageIO (no Metal device or Core Image context: Launcher.swift's metalDeviceMade) and trimmed to its visible pixels (trimmed), so a wordmark
    // centred in a padded canvas is fitted and leading-aligned by the wordmark itself. A file of at most 1200 pixels on its longest side, as the build makes it, is decoded as it is;
    // a larger one (or one with an EXIF orientation) as a 1200-pixel thumbnail, so an oversized file costs no more memory than that. nil for a missing or empty file, one ImageIO
    // cannot decode, or one with no visible pixels: the launcher then shows the name as text
    static let maxPixels = 1200
    static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0, h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let oriented = ((props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) != 1
        let img: CGImage?
        if w > 0, h > 0, Swift.max(w, h) <= maxPixels, !oriented {
            img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }
        guard let img, img.width > 0, img.height > 0 else { return nil }
        return trimmed(img)
    }
    // The image cropped to the box of its visible pixels (alpha above about 3 %), with 2 pixels to spare for their soft edges: one pass over an alpha-only bitmap on the CPU. The
    // image itself when nothing is transparent around it; nil when no pixel is visible (an empty export, a conversion that lost the picture)
    static func trimmed(_ image: CGImage, threshold: UInt8 = 8, pad: Int = 2) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return image }
        let stride = ctx.bytesPerRow, px = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var minX = w, minY = h, maxX = -1, maxY = -1   // rows from the top, as cropping(to:) counts them
        for y in 0..<h {
            let row = px + y * stride
            var first = -1, last = -1
            for x in 0..<w where row[x] > threshold { if first < 0 { first = x }; last = x }
            if first >= 0 { minX = Swift.min(minX, first); maxX = Swift.max(maxX, last); if minY == h { minY = y }; maxY = y }
        }
        guard maxX >= 0 else { return nil }
        let x0 = Swift.max(minX - pad, 0), y0 = Swift.max(minY - pad, 0), x1 = Swift.min(maxX + pad, w - 1), y1 = Swift.min(maxY + pad, h - 1)
        if x0 == 0, y0 == 0, x1 == w - 1, y1 == h - 1 { return image }
        return image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)) ?? image
    }
    // Whether a logo is a black wordmark (SteamGridDB's black style): the average colour of its opaque pixels (NX18Palette.average) is near black, every component under 0.25. A
    // saturated red or blue logo is not, though its luminance is low: it keeps the dark shadow. A black one gets a light glow instead, as the dark shadow would sink it into the scrim
    static func isDark(_ image: CGImage) -> Bool {
        guard let c = NX18Palette.average(of: image) else { return false }
        return Swift.max(c.r, c.g, c.b) < 0.25
    }
    // The size to draw a logo of size natural at: as large as fits in maxWidth x maxHeight, keeping its shape (a wide wordmark is held by the width, a tall one by the height)
    static func fitted(_ natural: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0, maxWidth > 0, maxHeight > 0 else { return .zero }
        let k = Swift.min(maxWidth / natural.width, maxHeight / natural.height)
        return CGSize(width: (natural.width * k).rounded(), height: (natural.height * k).rounded())
    }
}

// The logo where the name was: leading-aligned at its fitted size, with a soft dark shadow so a white or coloured wordmark reads over bright art and the scrim alike (a black one, a
// soft light glow: NX18Logo.isDark). VoiceOver reads the game's name as the screen's heading, as it read the text before
struct NX18GameLogo: View {
    let image: Image
    let natural: CGSize   // the image's size, for its shape
    let name: String
    let dark: Bool        // NX18Logo.isDark
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        let s = NX18Logo.fitted(natural, maxWidth: maxWidth, maxHeight: maxHeight)
        image.resizable().interpolation(.high).antialiased(true)
            .frame(width: s.width, height: s.height)
            .shadow(color: dark ? .white.opacity(0.55) : .black.opacity(0.5), radius: 8, y: dark ? 0 : 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isHeader)
            .accessibilityRemoveTraits(.isImage)
    }
}

// A soft dark halo right behind the small NX 18 mark over key art (both launchers; the iOS one adds it to its top shade, the Mac one to its banner's): over a white sky the
// shade alone leaves the cyan N on a light grey. An ellipse much wider than tall fading from the middle to clear at its edge, so it reads as the mark's shadow, not a patch;
// a gradient fill, no blur. strong: Reduce Transparency, a little darker
struct NX18MarkShade: View {
    var strong = false
    var body: some View {
        let mid = strong ? 0.45 : 0.36
        EllipticalGradient(stops: [.init(color: .black.opacity(mid), location: 0), .init(color: .black.opacity(mid * 0.8), location: 0.25),
                                   .init(color: .black.opacity(mid * 0.45), location: 0.55), .init(color: .black.opacity(mid * 0.12), location: 0.8),
                                   .init(color: .black.opacity(0), location: 1)])
            .frame(width: 230, height: 100)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// The NX 18 mark (make_logo.py's mark() with the lockup's pill, colour version): a monoline cyan N, an X whose coral stroke passes under the cyan one with a gap, and 18 in a coral
// pill as an exponent. Drawn as paths, no image or font; height is the whole mark's (the pill rises above the letters), the width follows (NX18MarkShape.aspect)
struct NX18Mark: View {
    var height: CGFloat = 24
    var body: some View {
        ZStack {
            NX18MarkShape(part: .cyan).fill(NX18Palette.cyan)
            NX18MarkShape(part: .coral).fill(NX18Palette.coral)
            NX18MarkShape(part: .pill).fill(NX18Palette.coral)
            NX18MarkShape(part: .digits).fill(NX18Palette.charcoal)
        }
        .frame(width: height * NX18MarkShape.aspect, height: height)
        .accessibilityElement()
        .accessibilityLabel("NX 18")
    }
}
// One colour of the mark, as a filled outline fitted (centred, aspect kept) into the rect. Units are make_logo.py's: the letters 104 high, strokes 18 wide with round ends
struct NX18MarkShape: Shape {
    enum Part: Sendable { case cyan, coral, pill, digits }   // the N and the X's top stroke; the X's under stroke; the 18's pill; its digits
    let part: Part

    private static let w: CGFloat = 18, top: CGFloat = 9, bottom: CGFloat = 95, gap: CGFloat = 6
    private static let s2: CGFloat = 0.38, padX: CGFloat = 20, padY: CGFloat = 13   // the lockup's 18: digit scale and the pill's padding
    private static let pillX: CGFloat = 186 + 20, pillY: CGFloat = -26             // NXW + PGAP, -RISE
    private static let pillW = (36 + 18 + 66) * s2 + 2 * padX, pillH = 104 * s2 + 2 * padY
    private static let box = CGRect(x: 0, y: pillY, width: pillX + pillW, height: 104 - pillY)   // the mark's extent (make_logo.py's bbox)
    static let aspect = box.width / box.height
    // The under stroke's gap around the crossing: t along the over stroke's direction from its centre (41, 52), as make_logo.py computes it
    private static let gapEnds: (CGPoint, CGPoint) = {
        let dx: CGFloat = 64, dy: CGFloat = -86, len = (dx * dx + dy * dy).squareRoot()
        let ux = dx / len, uy = dy / len, t = (w + gap) / abs((64 * 86 * 2) / (len * len))
        return (CGPoint(x: 41 - ux * t, y: 52 - uy * t), CGPoint(x: 41 + ux * t, y: 52 + uy * t))
    }()

    func path(in rect: CGRect) -> Path {
        let b = Self.box, scale = Swift.min(rect.width / b.width, rect.height / b.height)
        let fit = CGAffineTransform(translationX: rect.minX + (rect.width - b.width * scale) / 2 - b.minX * scale,
                                    y: rect.minY + (rect.height - b.height * scale) / 2 - b.minY * scale).scaledBy(x: scale, y: scale)
        let stroke = StrokeStyle(lineWidth: Self.w, lineCap: .round, lineJoin: .round)
        var p = Path()
        switch part {
        case .cyan:
            var n = Path()   // N: M9 95 V9 L73 95 V9
            n.move(to: CGPoint(x: 9, y: Self.bottom)); n.addLine(to: CGPoint(x: 9, y: Self.top))
            n.addLine(to: CGPoint(x: 73, y: Self.bottom)); n.addLine(to: CGPoint(x: 73, y: Self.top))
            var x = Path()   // the X's over stroke: M9 9 L73 95, 104 to the right
            x.move(to: CGPoint(x: 9, y: Self.top)); x.addLine(to: CGPoint(x: 73, y: Self.bottom))
            p.addPath(n.strokedPath(stroke))
            p.addPath(x.strokedPath(stroke), transform: CGAffineTransform(translationX: 104, y: 0))
        case .coral:
            var u = Path()   // the under stroke in two halves around the gap: M9 95 L p1 M p2 L73 9
            u.move(to: CGPoint(x: 9, y: Self.bottom)); u.addLine(to: Self.gapEnds.0)
            u.move(to: Self.gapEnds.1); u.addLine(to: CGPoint(x: 73, y: Self.top))
            p.addPath(u.strokedPath(stroke), transform: CGAffineTransform(translationX: 104, y: 0))
        case .pill:
            p.addPath(Path(roundedRect: CGRect(x: Self.pillX, y: Self.pillY, width: Self.pillW, height: Self.pillH), cornerRadius: Self.pillH / 2))
        case .digits:
            var d = Path()   // 1: M9 30 L27 9 V95; 8: circles at (33, 28) r 19 and (33, 71) r 24, 54 to the right
            d.move(to: CGPoint(x: 9, y: 30)); d.addLine(to: CGPoint(x: 27, y: 9)); d.addLine(to: CGPoint(x: 27, y: 95))
            d.addEllipse(in: CGRect(x: 54 + 33 - 19, y: 28 - 19, width: 38, height: 38))
            d.addEllipse(in: CGRect(x: 54 + 33 - 24, y: 71 - 24, width: 48, height: 48))
            p.addPath(d.strokedPath(stroke), transform: CGAffineTransform(translationX: Self.pillX + Self.padX, y: Self.pillY + Self.padY).scaledBy(x: Self.s2, y: Self.s2))
        }
        return p.applying(fit)
    }
}

// The rails: the logo's cyan running into its coral, the thin line between the art and the settings (iOS, vertical) or under the banner (the Mac, horizontal), on every game.
// flowing (the launchers' rails): the two colours drift slowly along the line, a cycle every NX18RailsFlowView.period seconds, drawn by Core Animation (no redraw of the view);
// still, as it was, under Reduce Motion. The guide's and About's rails stay still
struct NX18Rails: View {
    var axis: Axis = .vertical
    var thickness: CGFloat = 2.5
    var flowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if flowing {
                NX18RailsFlow(axis: axis, moving: !reduceMotion)
            } else {
                LinearGradient(colors: [NX18Palette.cyan, NX18Palette.coral],
                               startPoint: axis == .vertical ? .top : .leading, endPoint: axis == .vertical ? .bottom : .trailing)
            }
        }
        .frame(width: axis == .vertical ? thickness : nil, height: axis == .horizontal ? thickness : nil)
        .accessibilityHidden(true)
    }
}

#if os(macOS)
typealias NX18PlatformView = NSView
#else
typealias NX18PlatformView = UIView
#endif

// The flowing rails: a gradient layer three lines long (cyan, coral, cyan, coral) slid along the line by two lengths and round again, so the line shows cyan to coral (as the
// still rails do) at the start and end of each cycle and coral to cyan halfway. The slide is a CABasicAnimation, run by the render server: no timer, display link or SwiftUI
// update in the app while it moves. It is only on while the view is in a window (and, on the Mac, while the window is visible: not minimised, hidden or covered), and not under
// Reduce Motion (moving false: the still cyan-to-coral line). A change of length starts it again from the still position
final class NX18RailsFlowView: NX18PlatformView {
    static let period: CFTimeInterval = 14   // seconds for a point of the line to go from cyan to coral and back
    static let key = "nx18.flow"
    static let frameRates = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
    let axis: Axis
    private let strip = CAGradientLayer()
    private var length: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    var moving = true { didSet { if moving != oldValue { restart() } } }
    var isFlowing: Bool { strip.animation(forKey: Self.key) != nil }   // the Duo harness's check

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        let c = [NX18Palette.cyanHex, NX18Palette.coralHex].map { h -> CGColor in let v = NX18RGB(hex: h); return CGColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 1) }
        strip.colors = [c[0], c[1], c[0], c[1]]
        strip.startPoint = axis == .vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
        strip.endPoint = axis == .vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
#if os(macOS)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
#else
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(strip)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }   // the system may drop a running animation while the app is in the background
        })
#endif
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

#if os(macOS)
    override var isFlipped: Bool { true }   // the strip's layer laid out from the top left, as on iOS
    override func layout() { super.layout(); place() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let w = window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            })
        }
        restart()
    }
    private var visible: Bool { window.map { $0.occlusionState.contains(.visible) } ?? false }
#else
    override func layoutSubviews() { super.layoutSubviews(); place() }
    override func didMoveToWindow() { super.didMoveToWindow(); restart() }
    private var visible: Bool { window != nil }
#endif

    // The strip three lines long from the line's start; a new length starts the slide again
    private func place() {
        let l = axis == .vertical ? bounds.height : bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        strip.frame = axis == .vertical ? CGRect(x: 0, y: 0, width: bounds.width, height: l * 3) : CGRect(x: 0, y: 0, width: l * 3, height: bounds.height)
        CATransaction.commit()
        if l != length { length = l; restart() }
    }

    private func restart() {
        strip.removeAnimation(forKey: Self.key)
        guard moving, visible, length > 0 else { return }
        let path = axis == .vertical ? "position.y" : "position.x"
        let from = axis == .vertical ? strip.position.y : strip.position.x
        let a = CABasicAnimation(keyPath: path)
        a.fromValue = from
        a.toValue = from - 2 * length
        a.duration = Self.period
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.isRemovedOnCompletion = false
        // A slow drift (a few points a frame at 30 Hz) needs no ProMotion rate: without a range the render server may compose the screen at 120 Hz for it while the launcher idles
        a.preferredFrameRateRange = Self.frameRates
        strip.add(a, forKey: Self.key)
    }
}

#if os(macOS)
private struct NX18RailsFlow: NSViewRepresentable {
    let axis: Axis
    let moving: Bool
    func makeNSView(context: Context) -> NX18RailsFlowView { NX18RailsFlowView(axis: axis) }
    func updateNSView(_ v: NX18RailsFlowView, context: Context) { v.moving = moving }
}
#else
private struct NX18RailsFlow: UIViewRepresentable {
    let axis: Axis
    let moving: Bool
    func makeUIView(context: Context) -> NX18RailsFlowView { NX18RailsFlowView(axis: axis) }
    func updateUIView(_ v: NX18RailsFlowView, context: Context) { v.moving = moving }
}
#endif

// A section heading in the logo's cyan
struct NX18SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).nxFont(.footnote, weight: .semibold).foregroundStyle(NX18Palette.cyan).textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    // The controller's focus: a cyan 2 pt outline around the item, just outside it (a capsule with a large radius). It takes no touches
    func nx18Focus(_ on: Bool, cornerRadius: CGFloat = 10) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(NX18Palette.cyan, lineWidth: 2).padding(-3).allowsHitTesting(false)
            }
        }
    }
}

// The presets as chips (Battery · Balanced · Quality): the one the values are is filled cyan, none when they match no preset. A tap applies one (LauncherModel.applyPreset,
// which leaves fixed and greyed rows). Nothing is drawn for a list without presets. focused: the chip the controller's focus is on
struct PresetChips: View {
    @ObservedObject var m: LauncherModel
    var focused: LauncherPreset? = nil
    var body: some View {
        if m.hasPresets {
            let active = m.activePreset
            HStack(spacing: 8) {
                ForEach(LauncherPreset.allCases) { p in
                    Button { m.applyPreset(p) } label: {
                        Text(p.title).nxFont(.subheadline, weight: .semibold).lineLimit(1)
                            .foregroundStyle(active == p ? NX18Palette.charcoal : Color.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(active == p ? NX18Palette.cyan : NX18Palette.row))
                            .overlay(Capsule().strokeBorder(active == p ? Color.clear : NX18Palette.separator, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .nx18Focus(focused == p, cornerRadius: 100)
                    .accessibilityLabel("\(p.title) preset")
                    .accessibilityHint(p == .balanced ? "The settings this game was tested with" : "Sets frame rate, resolution and image quality for \(p.title.lowercased())")
                    .accessibilityAddTraits(active == p ? .isSelected : [])
                }
            }
        }
    }
}

// The line under the game's name: the console the game was built for, when it was last played, cloud saves and free memory, each only when known. The launcher passes what
// it knows (launcher.json's console, Documents/save's newest file, CloudSaves, os_proc_available_memory) and refreshes it
struct LauncherStatus: Equatable {
    enum Cloud: Equatable { case off, on, synced }   // no folder; a folder picked; a folder picked and the save brought from or sent to it
    // launcher.json's console (settings.py console(): the sdk module's build spec): Switch 1 with a cyan dot, Switch 2 with a coral one, the logo's two colours
    enum Console: String, Equatable {
        case switch1, switch2
        var text: String { self == .switch2 ? "Switch 2" : "Switch 1" }
        var dot: Color { self == .switch2 ? NX18Palette.coral : NX18Palette.cyan }
    }
    struct Part: Identifiable, Equatable { let id: String; let text: String; let dot: Color? }

    var lastPlayed: Date? = nil
    var cloud: Cloud = .off
    var memoryFree: UInt64? = nil
    var console: Console? = nil

    func parts(now: Date = Date()) -> [Part] {
        var out: [Part] = []
        if let c = console { out.append(Part(id: "console", text: c.text, dot: c.dot)) }
        if let d = lastPlayed {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            out.append(Part(id: "played", text: "Last played \(f.localizedString(for: Swift.min(d, now), relativeTo: now))", dot: nil))
        }
        switch cloud {
        case .off: break
        case .on: out.append(Part(id: "cloud", text: "Cloud saves on", dot: nil))
        case .synced: out.append(Part(id: "cloud", text: "Save synced", dot: nil))
        }
        if let m = memoryFree, m > 0 { out.append(Part(id: "memory", text: "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: m), countStyle: .memory)) free", dot: nil)) }
        return out
    }
    // What VoiceOver reads for the line
    func spoken(now: Date = Date()) -> String {
        parts(now: now).map(\.text).joined(separator: ", ")
    }
    // The newest modification time of a file under the folder (the save folder, for Last played); nil when it has none. It reads the disk: call it once, off the main actor if large
    nonisolated static func lastModified(under folder: URL) -> Date? {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
        var newest: Date?
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true, let d = v.contentModificationDate else { continue }
            if newest.map({ d > $0 }) ?? true { newest = d }
        }
        return newest
    }
}
// The status line as one wrapping line of muted text with the console's coloured dot, read by VoiceOver as one sentence. Nothing for a status with nothing known
struct LauncherStatusLine: View {
    let status: LauncherStatus
    var color: Color = NX18Palette.muted
    var body: some View {
        let parts = status.parts()
        if !parts.isEmpty {
            parts.enumerated().reduce(Text(verbatim: "")) { t, e in
                let sep = e.offset == 0 ? Text(verbatim: "") : Text(verbatim: "  ·  ")
                let dot = e.element.dot.map { Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle($0) } ?? Text(verbatim: "")   // system: symbol
                let gap = e.element.dot == nil ? "" : "\u{2009}"
                return Text("\(t)\(sep)\(dot)\(gap)\(e.element.text)")
            }
            .nxFont(.footnote)
            .foregroundStyle(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.spoken())
        }
    }
}
