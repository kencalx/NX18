// The key art's framing (owner, 2026-11-27: "the user should be able to select what portion of the game art appears in the Gate"). Key art is mostly wider than the Gate's
// art side, which fills itself with it, so a part of it is cut. The framing says which part: a focus point in the image (x and y, 0...1 of its width and height, the point the
// Gate centres on as far as the image allows) and a zoom (1 = the art just fills the space, up to maxZoom). The default, 0.5 / 0.5 at 1, is the centre crop the Gate always drew.
// One framing for every shape the art is drawn in (iPhone landscape and portrait, iPad, the Mac window's banner, Beam): a point, not an offset, so each shape keeps the same
// part of the picture in view; no shape ever shows an empty edge (crop clamps).
// Where it is kept: the app's preferences, launcher.artFocus, as "x,y,zoom" (the player's own choice, made in the Gate: Adjust art on the NX 18 card, or a long press on the
// art); a build's default beside the art, dm/art_focus.json ({"x": , "y": , "zoom": }, build_ipa.sh from the NSP script's --art-focus, which NX 18 Beam passes); else the
// centre. The saved choice wins, then the packed one (resolve). The tint and the blurred wash behind the settings keep using the whole picture (LauncherArtwork.load).
// The framing mode's bar is ArtFramingBar (LauncherRow.swift). Shared: the iPhone and iPad Gate (Launcher.swift), the Mac app's window (dm/mac/Launcher.swift, pack_app.py swift_sources) and NX 18 Beam (beam/project.yml)
import Foundation
import CoreGraphics
import SwiftUI

struct ArtFocus: Equatable, Sendable, Codable {
    var x = 0.5, y = 0.5, zoom = 1.0

    static let centre = ArtFocus()
    static let key = "launcher.artFocus"     // the app's preferences (UserDefaults): the player's own framing
    static let file = "art_focus.json"       // the build's default, beside dm/art.jpg
    static let maxZoom = 3.0

    init(x: Double = 0.5, y: Double = 0.5, zoom: Double = 1) {
        self.x = Self.unit(x); self.y = Self.unit(y); self.zoom = Self.zoomed(zoom)
    }
    private static func unit(_ v: Double) -> Double { v.isFinite ? Swift.min(Swift.max(v, 0), 1) : 0.5 }
    private static func zoomed(_ v: Double) -> Double { v.isFinite ? Swift.min(Swift.max(v, 1), maxZoom) : 1 }

    enum CodingKeys: String, CodingKey { case x, y, zoom }
    init(from decoder: Decoder) throws {   // a field missing, of another type or out of range: its default, or the nearest value in range
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ def: Double) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? def }
        self.init(x: d(.x, 0.5), y: d(.y, 0.5), zoom: d(.zoom, 1))
    }

    var isCentre: Bool { abs(x - 0.5) < 0.0005 && abs(y - 0.5) < 0.0005 && abs(zoom - 1) < 0.0005 }

    // "x,y" or "x,y,zoom" (the preferences' form and the build option's): nil for anything else
    init?(text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 || parts.count == 3, let px = parts[0], let py = parts[1], px.isFinite, py.isFinite else { return nil }
        let pz = parts.count == 3 ? parts[2] : 1
        guard let z = pz, z.isFinite else { return nil }
        self.init(x: px, y: py, zoom: z)
    }
    var text: String { [x, y, zoom].map(Self.short).joined(separator: ",") }
    private static func short(_ v: Double) -> String {
        var s = String(format: "%.3f", v)   // not localized: always a point
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // The packed default (dm/art_focus.json); nil when it is not one
    init?(json: Data) {
        guard (try? JSONSerialization.jsonObject(with: json)) is [String: Any], let f = try? JSONDecoder().decode(ArtFocus.self, from: json) else { return nil }
        self = f
    }

    // The framing to draw: the player's saved one, else the build's packed one, else the centre
    static func resolve(saved: String?, packed: ArtFocus?) -> ArtFocus { saved.flatMap(ArtFocus.init(text:)) ?? packed ?? .centre }
    static func saved(_ defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: key) }
    static func packed(at url: URL?) -> ArtFocus? { url.flatMap { try? Data(contentsOf: $0) }.flatMap(ArtFocus.init(json:)) }
    // The player's choice kept, or forgotten (nil): the art then follows the build's default again
    static func store(_ f: ArtFocus?, in defaults: UserDefaults = .standard) {
        if let f { defaults.set(f.text, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    // MARK: The crop

    // The scale the image is drawn at in a view of `view`: just filling it (aspect fill), times the zoom. 0 for an empty image or view
    static func scale(image: CGSize, view: CGSize, zoom: Double = 1) -> CGFloat {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return 0 }
        return Swift.max(view.width / image.width, view.height / image.height) * CGFloat(zoomed(zoom))
    }
    // The part of the image (in the image's own units, its origin top left) a view of `view` shows: the view's shape at the scale, centred on the focus point as far as the
    // image reaches, so the crop always lies inside the image. The whole image for an empty view
    static func crop(image: CGSize, view: CGSize, focus f: ArtFocus) -> CGRect {
        let s = scale(image: image, view: view, zoom: f.zoom)
        guard s > 0 else { return CGRect(origin: .zero, size: image) }
        let w = Swift.min(image.width, view.width / s), h = Swift.min(image.height, view.height / s)
        func place(_ p: Double, _ side: CGFloat, _ len: CGFloat) -> CGFloat { Swift.min(Swift.max(CGFloat(p) * side - len / 2, 0), side - len) }
        return CGRect(x: place(f.x, image.width, w), y: place(f.y, image.height, h), width: w, height: h)
    }
    // Where the whole image is drawn in the view's coordinates for that crop (its frame: may start left of and above the view, never leaves a gap)
    static func frame(image: CGSize, view: CGSize, focus f: ArtFocus) -> CGRect {
        let s = scale(image: image, view: view, zoom: f.zoom)
        guard s > 0 else { return CGRect(origin: .zero, size: view) }
        let c = crop(image: image, view: view, focus: f)
        return CGRect(x: -c.minX * s, y: -c.minY * s, width: image.width * s, height: image.height * s)
    }
    // The focus as a view of this shape shows it: the crop's centre. Equal to the focus where the image lets the crop centre there, else moved in to where it can
    static func shown(image: CGSize, view: CGSize, focus f: ArtFocus) -> ArtFocus {
        guard image.width > 0, image.height > 0 else { return f }
        let c = crop(image: image, view: view, focus: f)
        return ArtFocus(x: Double(c.midX / image.width), y: Double(c.midY / image.height), zoom: f.zoom)
    }

    // MARK: Moving it

    // A drag of `by` view points from `start` (the focus as shown when the drag began): the picture follows the finger, so the window over it moves the other way
    static func dragged(_ start: ArtFocus, by: CGSize, image: CGSize, view: CGSize) -> ArtFocus {
        let s = scale(image: image, view: view, zoom: start.zoom)
        guard s > 0 else { return start }
        let from = shown(image: image, view: view, focus: start)
        let moved = ArtFocus(x: from.x - Double(by.width / s / image.width), y: from.y - Double(by.height / s / image.height), zoom: start.zoom)
        return shown(image: image, view: view, focus: moved)
    }
    // A controller's or an arrow key's step: the window over the picture moves a tenth of the view's width or height that way (right shows more of the right)
    static func nudged(_ f: ArtFocus, dx: Int, dy: Int, image: CGSize, view: CGSize) -> ArtFocus {
        dragged(f, by: CGSize(width: -CGFloat(dx) * view.width * 0.1, height: -CGFloat(dy) * view.height * 0.1), image: image, view: view)
    }
    // Zoomed to `zoom` (kept in 1...maxZoom) about the point the view shows
    static func zoomed(_ f: ArtFocus, to zoom: Double, image: CGSize, view: CGSize) -> ArtFocus {
        let from = shown(image: image, view: view, focus: f)
        return shown(image: image, view: view, focus: ArtFocus(x: from.x, y: from.y, zoom: zoom))
    }
    static let zoomStep = 0.25

    // The shapes the Gate draws the art in, for an editor that shows them all (NX 18 Beam's Adjust Framing): an iPhone's art side in landscape (55 % of a 6.9-inch screen beside the
    // settings) and upright (the hero above them), an iPad's in landscape, and the Mac window's banner at its usual width (Launcher.swift's layouts, dm/mac/Launcher.swift's banner)
    static let gateShapes: [(name: String, size: CGSize)] = [("iPhone", CGSize(width: 526, height: 440)), ("iPhone upright", CGSize(width: 440, height: 382)),
                                                              ("iPad", CGSize(width: 757, height: 1032)), ("Mac window", CGSize(width: 600, height: 248))]

    // VoiceOver's value: where the window is, in words
    var spoken: String {
        if isCentre { return "Centred" }
        func side(_ v: Double, _ low: String, _ high: String) -> String? { v < 0.45 ? low : v > 0.55 ? high : nil }
        let at = [side(y, "top", "bottom"), side(x, "left", "right")].compactMap { $0 }
        var s = at.isEmpty ? "Centred" : "Towards the " + at.joined(separator: " ")
        if zoom > 1.001 { s += String(format: ", zoomed %.1f times", zoom) }
        return s
    }
}

// The art drawn as the framing asks, filling the space it is given (it never sizes it); the caller clips it
struct FramedArt: View {
    let image: Image
    let natural: CGSize   // the image's size, in any unit (its pixels or points)
    let focus: ArtFocus
    var body: some View {
        GeometryReader { g in
            let r = ArtFocus.frame(image: natural, view: g.size, focus: focus)
            image.resizable().interpolation(.high)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
    }
}

// The art while the player frames it: drag to move the picture, pinch (or a trackpad's) to zoom; VoiceOver adjusts it (swipe up / down: left and right; its actions move it up
// and down, zoom and reset). Shows the framing as it will be kept, in the space it is given
struct ArtFramingSurface: View {
    let image: Image
    let natural: CGSize
    @Binding var focus: ArtFocus
    @State private var dragStart: ArtFocus?
    @State private var zoomStart: ArtFocus?
    @State private var size: CGSize = .zero

    var body: some View {
        FramedArt(image: image, natural: natural, focus: focus)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let start = dragStart ?? focus; if dragStart == nil { dragStart = start }
                    // the zoom as it is now: a pinch runs beside the drag (both fingers move), and the drag must not take the zoom back to where it began
                    focus = ArtFocus.dragged(ArtFocus(x: start.x, y: start.y, zoom: focus.zoom), by: g.translation, image: natural, view: size)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { g in
                    let start = zoomStart ?? focus; if zoomStart == nil { zoomStart = start }
                    focus = ArtFocus.zoomed(focus, to: start.zoom * Double(g.magnification), image: natural, view: size)   // about the point shown now: the drag beside it keeps moving it
                }
                .onEnded { _ in zoomStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Key art framing")
            .accessibilityValue(focus.spoken)
            .accessibilityHint("Swipe up or down to move the art left or right. Actions move it up or down and zoom.")
            .accessibilityAdjustableAction { d in nudge(dx: d == .increment ? 1 : -1, dy: 0) }
            .accessibilityAction(named: "Move up") { nudge(dx: 0, dy: -1) }
            .accessibilityAction(named: "Move down") { nudge(dx: 0, dy: 1) }
            .accessibilityAction(named: "Zoom in") { zoom(by: 1) }
            .accessibilityAction(named: "Zoom out") { zoom(by: -1) }
            .accessibilityAction(named: "Reset") { focus = .centre }
    }
    private func nudge(dx: Int, dy: Int) { focus = ArtFocus.nudged(focus, dx: dx, dy: dy, image: natural, view: size) }
    private func zoom(by steps: Int) { focus = ArtFocus.zoomed(focus, to: focus.zoom + Double(steps) * ArtFocus.zoomStep, image: natural, view: size) }
}
