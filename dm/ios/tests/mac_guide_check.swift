// The Mac app's guide window (dm/mac/Launcher.swift MacGuideWindow, LauncherGuideFiles.swift), run by test_mac_guide.py on a guide folder it writes: the page's script reads the
// guide's other files with XMLHttpRequest and fetch, calls the Switch applet's window.nx, and is refused a file outside the guide and a file: URL; nx.endApplet closes the guide.
// Then the placeholder guide (dm/ios/tests/fixtures/guide, made up as the console's guides are): its 1280x720 page zoomed to fit the window's content, the first-paint event it waits
// for, its footer buttons in the title bar's Back, L and R, and its end URL (http://localhost/) closing the guide. The web view is loaded without a window, so nothing shows on the
// screen. Arguments: the guide's .htdocs folder (html/USen/index.html in it), then the placeholder guide's .htdocs
import AppKit
import WebKit

@main struct GuideCheck {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: mac_guide_check <htdocs> <placeholder htdocs>"); exit(2) }
        _ = NSApplication.shared
        let failed = MainActor.assumeIsolated { check(htdocs: URL(fileURLWithPath: args[1])) + placeholder(htdocs: URL(fileURLWithPath: args[2])) }
        print("mac guide: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    @MainActor static func check(htdocs: URL) -> Int {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        // Runs the main run loop until done says so or the time is up
        func spin(_ seconds: Double, until done: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return done()
        }
        let g = MacGuideWindow(root: htdocs, fontDir: nil)
        var closed = false
        g.closed = { closed = true }
        expect(!g.open(htdocs.deletingLastPathComponent().appendingPathComponent("outside.html")), "a page outside the guide is not opened")
        expect(g.open(htdocs.appendingPathComponent("html/USen/index.html")), "the guide's index opens")
        var result: String?
        let got = spin(60) {
            if result == nil {
                g.web.evaluateJavaScript("window.__result || ''") { v, _ in if let s = v as? String, !s.isEmpty { result = s } }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return result != nil
        }
        expect(got, "the page's script finished")
        let r = (result.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        print("page: \(result ?? "nothing")")
        expect(r["nx"] as? String == "object", "window.nx is there at document start")
        expect(r["footer"] as? String == "ok", "nx calls the stand-in lacks do nothing and do not throw")
        expect(r["xhr"] as? String == "200:{\"text\":\"sibling\"}", "XMLHttpRequest reads a file elsewhere in the guide")
        expect(r["fetch"] as? String == "ok", "fetch reads a page beside it")
        expect(r["link"] as? Int == 404, "a link that leads outside the guide is not served")
        expect(r["file"] as? String == "refused", "a file: URL is refused")
        g.web.evaluateJavaScript("nx.endApplet()") { _, _ in }
        expect(spin(10) { closed }, "nx.endApplet closes the guide")
        expect(MacGuideWindow.current == nil, "no guide window is left")
        return failed
    }

    // The placeholder guide: fitted, set up after its first paint, its footer buttons pressed from the window, and its end
    @MainActor static func placeholder(htdocs: URL) -> Int {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        func spin(_ seconds: Double, until done: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return done()
        }
        let g = MacGuideWindow(root: htdocs, fontDir: nil)
        var closed = false
        g.closed = { closed = true }
        func js(_ script: String) -> Any? {
            var out: Any?, done = false
            g.web.evaluateJavaScript(script) { r, _ in out = r; done = true }
            _ = spin(5) { done }
            return out
        }
        func log() -> String { js("(window.guideLog || []).join(',')") as? String ?? "" }
        expect(g.open(htdocs.appendingPathComponent("html/USen/index.html")), "the placeholder guide opens")
        expect(spin(20) { log().contains("ready") }, "it set up after the first-paint event (\(log()))")
        g.box.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)   // a window taller than 16:9
        g.box.place()
        expect(g.web.frame == NSRect(x: 0, y: 68, width: 1000, height: 563), "the page is fitted, whole, and centred (\(g.web.frame))")
        expect(abs(g.web.pageZoom - 1000.0 / 1280) < 0.001, "at the window's scale")
        _ = spin(1) { js("innerWidth") as? Int == 1280 }
        expect(js("innerWidth") as? Int == 1280 && js("innerHeight") as? Int == 720, "its viewport is the console's 1280x720 (\(js("innerWidth") ?? "-")x\(js("innerHeight") ?? "-"))")
        _ = js("document.getElementById('item1').click()")
        expect(spin(5) { log().hasSuffix("topic1") && g.footer == ["B", "L", "R"] }, "a click opens topic one, which assigns B, L and R (\(g.footer.sorted()))")
        g.press("R")
        expect(spin(5) { log().hasSuffix("topic3") }, "R turns the page")
        g.press("B")
        expect(spin(5) { log().hasSuffix("menu") }, "Back is the page's own: the menu")
        expect(!closed, "and the guide stays")
        _ = js("document.getElementById('item9').click()")
        expect(spin(10) { closed }, "the end URL (http://localhost/) closes the guide")
        return failed
    }
}
