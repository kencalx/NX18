// The key art's framing (dm/ios/Sources/ArtFocus.swift): the crop for an image, a view shape, a focus and a zoom; clamping so no edge is empty; the stored forms; and which
// framing is drawn (the player's saved one, else the build's packed one, else the centre). test_art_focus.py compiles it with ArtFocus.swift and runs it
import CoreFoundation
import CoreGraphics
import Foundation

@main struct ArtFocusCheck {
    nonisolated(unsafe) static var failed = 0
    static func expect(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FAIL: \(what)") } }
    static func near(_ a: CGFloat, _ b: CGFloat, _ what: String) { expect(abs(a - b) < 0.01, "\(what): \(a) is not \(b)") }
    static func near(_ a: Double, _ b: Double, _ what: String) { expect(abs(a - b) < 0.0005, "\(what): \(a) is not \(b)") }

    static func main() {
        let hero = CGSize(width: 1920, height: 620)       // a SteamGridDB hero
        let phone = CGSize(width: 526, height: 440)       // an iPhone's landscape art side

        // the centre at 1 is the old centre crop: aspect fill, the middle of the image
        var c = ArtFocus.crop(image: hero, view: phone, focus: .centre)
        near(c.height, 620, "fills the height"); near(c.width, 620 * 526 / 440, "the view's shape")
        near(c.midX, 960, "centred across"); near(c.minY, 0, "no room up or down")
        var r = ArtFocus.frame(image: hero, view: phone, focus: .centre)
        near(r.height, 440, "drawn as tall as the view"); near(r.minX, -(r.width - 526) / 2, "drawn centred")

        // a focus to the left: the crop moves left and stops at the edge
        c = ArtFocus.crop(image: hero, view: phone, focus: ArtFocus(x: 0.25, y: 0.5)); near(c.midX, 480, "centred on the focus")
        c = ArtFocus.crop(image: hero, view: phone, focus: ArtFocus(x: 0, y: 0.5)); near(c.minX, 0, "clamped at the left edge")
        r = ArtFocus.frame(image: hero, view: phone, focus: ArtFocus(x: 0, y: 0.5)); near(r.minX, 0, "no gap at the left")
        c = ArtFocus.crop(image: hero, view: phone, focus: ArtFocus(x: 1, y: 1)); near(c.maxX, 1920, "clamped at the right"); near(c.maxY, 620, "and the bottom")
        r = ArtFocus.frame(image: hero, view: phone, focus: ArtFocus(x: 1, y: 1)); near(r.maxX, 526, "no gap at the right"); near(r.maxY, 440, "nor the bottom")

        // zoom: a smaller crop, still inside the image, about the focus
        c = ArtFocus.crop(image: hero, view: phone, focus: ArtFocus(x: 0.5, y: 0.5, zoom: 2)); near(c.height, 310, "half as tall at 2"); near(c.midY, 310, "centred up and down")
        c = ArtFocus.crop(image: hero, view: phone, focus: ArtFocus(x: 0.5, y: 0, zoom: 2)); near(c.minY, 0, "zoomed: clamped at the top")
        expect(ArtFocus(zoom: 9).zoom == ArtFocus.maxZoom && ArtFocus(zoom: 0.2).zoom == 1, "zoom kept in 1...max")
        expect(ArtFocus(x: -1, y: 4) == ArtFocus(x: 0, y: 1) && ArtFocus(x: .nan, y: .infinity).isCentre, "x and y kept in 0...1, not-a-number centred")

        // a portrait image in a wide view (the Mac's banner): it fills the width, the crop moves up and down
        let tall = CGSize(width: 1000, height: 1500), banner = CGSize(width: 600, height: 248)
        c = ArtFocus.crop(image: tall, view: banner, focus: ArtFocus(x: 0.1, y: 0.2)); near(c.width, 1000, "the whole width"); near(c.midY, 300, "the focus up and down")
        // every shape keeps the same point in view where it can (the focus is a point, not an offset)
        for v in [phone, CGSize(width: 440, height: 382), CGSize(width: 757, height: 1032), banner] {
            let f = ArtFocus(x: 0.4, y: 0.5)
            let s = ArtFocus.crop(image: CGSize(width: 1920, height: 1080), view: v, focus: f)
            expect(s.minX >= 0 && s.minY >= 0 && s.maxX <= 1920.01 && s.maxY <= 1080.01, "inside the image in \(v)")
            expect(s.contains(CGPoint(x: 0.4 * 1920, y: 540)), "the focus point in view in \(v)")
        }
        // empty sizes draw nothing odd
        expect(ArtFocus.crop(image: .zero, view: phone, focus: .centre) == .zero, "an empty image")
        expect(ArtFocus.frame(image: hero, view: .zero, focus: .centre).size == .zero, "an empty view")

        // shown: the stored focus as this shape can show it
        let shown = ArtFocus.shown(image: hero, view: phone, focus: ArtFocus(x: 0, y: 0))
        near(shown.x, 620.0 * 526 / 440 / 2 / 1920, "shown: moved in from the left"); near(shown.y, 0.5, "shown: the middle, as the height has no room")

        // a drag: the picture follows the finger (a drag right shows more of the left), from where it was shown
        let s = ArtFocus.scale(image: hero, view: phone)
        var d = ArtFocus.dragged(.centre, by: CGSize(width: 100, height: 0), image: hero, view: phone)
        near(d.x, 0.5 - Double(100 / s / 1920), "dragged right: the focus moves left")
        d = ArtFocus.dragged(ArtFocus(x: 0, y: 0.5), by: CGSize(width: -100, height: 0), image: hero, view: phone)
        expect(d.x > shown.x, "a drag starts from the shown focus, not the stored one past the edge")
        d = ArtFocus.dragged(.centre, by: CGSize(width: 100_000, height: 0), image: hero, view: phone); near(d.x, shown.x, "dragged far: stops at the edge")
        // a pad's step: right moves the window right
        let n = ArtFocus.nudged(.centre, dx: 1, dy: 0, image: hero, view: phone); expect(n.x > 0.5, "nudged right: more of the right")
        let z = ArtFocus.zoomed(.centre, to: 1.5, image: hero, view: phone); near(z.zoom, 1.5, "zoomed"); near(z.x, 0.5, "about the shown point")

        // the stored forms
        expect(ArtFocus(text: "0.25,0.75,1.5") == ArtFocus(x: 0.25, y: 0.75, zoom: 1.5), "x,y,zoom")
        expect(ArtFocus(text: " 0.3 , 0.6 ") == ArtFocus(x: 0.3, y: 0.6), "x,y (zoom 1)")
        for bad in ["", "0.5", "a,b", "0.5,0.5,", "0.5,0.5,1,2", "nan,0.5", "0.5,inf"] { expect(ArtFocus(text: bad) == nil, "not a framing: '\(bad)'") }
        expect(ArtFocus(x: 0.25, y: 0.5, zoom: 1.25).text == "0.25,0.5,1.25", "the text form")
        expect(ArtFocus(text: ArtFocus(x: 0.1234, y: 0.9, zoom: 2).text)!.x == 0.123, "the text form keeps 3 places")
        expect(ArtFocus(json: Data(#"{"x": 0.2, "y": 0.8, "zoom": 1.5}"#.utf8)) == ArtFocus(x: 0.2, y: 0.8, zoom: 1.5), "the packed file")
        expect(ArtFocus(json: Data(#"{"x": 0.2}"#.utf8)) == ArtFocus(x: 0.2), "a packed file with x only")
        expect(ArtFocus(json: Data(#"{"x": "left", "zoom": 7}"#.utf8)) == ArtFocus(zoom: ArtFocus.maxZoom), "a field of another type: its default")
        expect(ArtFocus(json: Data("[0.2, 0.8]".utf8)) == nil && ArtFocus(json: Data("not json".utf8)) == nil, "not a packed framing")

        // which framing is drawn: saved > packed > centre; a saved one that cannot be read is no choice
        let packed = ArtFocus(x: 0.2, y: 0.5)
        expect(ArtFocus.resolve(saved: "0.8,0.5,1", packed: packed) == ArtFocus(x: 0.8, y: 0.5), "the player's own first")
        expect(ArtFocus.resolve(saved: nil, packed: packed) == packed, "then the build's")
        expect(ArtFocus.resolve(saved: "garbage", packed: packed) == packed, "an unreadable saved one: the build's")
        expect(ArtFocus.resolve(saved: nil, packed: nil) == .centre, "else the centre")
        // the preferences round trip (a scratch suite, never the app's own)
        let suite = "org.nx18.test.artfocus.\(ProcessInfo.processInfo.processIdentifier)"
        if let d = UserDefaults(suiteName: suite) {
            ArtFocus.store(ArtFocus(x: 0.3, y: 0.4, zoom: 2), in: d)
            expect(d.string(forKey: ArtFocus.key) == "0.3,0.4,2", "stored as text under launcher.artFocus")
            expect(ArtFocus.resolve(saved: ArtFocus.saved(d), packed: packed) == ArtFocus(x: 0.3, y: 0.4, zoom: 2), "read back")
            ArtFocus.store(nil, in: d); expect(ArtFocus.saved(d) == nil, "forgotten")
            d.removePersistentDomain(forName: suite)
            CFPreferencesAppSynchronize(suite as CFString)   // so cfprefsd writes no file back, and the file it may have written is removed
            try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        } else { expect(false, "a scratch preferences suite") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("art_focus_check.\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(ArtFocus.file)
        try? Data(#"{"x": 0.7, "y": 0.5, "zoom": 1}"#.utf8).write(to: file)
        expect(ArtFocus.packed(at: file) == ArtFocus(x: 0.7, y: 0.5), "the packed file read"); expect(ArtFocus.packed(at: dir.appendingPathComponent("none.json")) == nil && ArtFocus.packed(at: nil) == nil, "no packed file")
        try? FileManager.default.removeItem(at: dir)
        expect(ArtFocus.centre.spoken == "Centred" && ArtFocus(x: 0.1, y: 0.5).spoken == "Towards the left" && ArtFocus(x: 0.9, y: 0.1, zoom: 2).spoken == "Towards the top right, zoomed 2.0 times", "VoiceOver's words")

        print("art focus: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
