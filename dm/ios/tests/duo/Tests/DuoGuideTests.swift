import PDFKit
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import DuoHarness

// The game guide viewer (GuideViewer.swift, LauncherGuideFiles.swift) on the placeholder guide (dm/ios/tests/fixtures/guide: made up, written as the console's guides are). The
// guide is shown in the real LauncherGuideSheet in a window of the iPhone 18 Pro Max's size, in landscape and then portrait. It checks the page is laid out at 1280x720 and
// scaled to fit, whole, under the header; that the console's first-paint event came (the guide sets up only then); the D-pad's first down focusing the first item and the items'
// onfocus running; that a tap on a menu item the page cancels the touches of opens its topic, under an invisible page stacked over it; the page's footer buttons (Back, L / R) as
// the header, a swipe and the controller press them; a link to another page and back, the page loaded again; and the end URL closing the viewer.
// The taps are touch events dispatched in the page at the item's place: what WebKit gives the page for a finger there, except that the page's script cannot tell them apart
// (it cancels both); a tap on the Simulator's screen is in the fixture's README.md
final class DuoGuideTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/guide")
    }

    @MainActor
    private func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(cond(), what)
    }
    // The page's answer to a script (JSON text for anything but a string or number)
    @MainActor
    private func js(_ web: WKWebView, _ script: String) -> Any? {
        var out: Any?, done = false
        web.evaluateJavaScript(script) { r, e in out = r ?? e.map { "error: \($0.localizedDescription)" }; done = true }
        let end = Date().addingTimeInterval(5)
        while !done && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return out
    }
    @MainActor
    private func log(_ web: WKWebView) -> [String] { (js(web, "(window.guideLog || []).join(',')") as? String)?.split(separator: ",").map(String.init) ?? [] }
    // A one-finger tap at an element of the page: touchstart and touchend at its centre, as WebKit sends them
    @MainActor
    private func tap(_ web: WKWebView, _ id: String) {
        let r = js(web, """
        (function () {
          var el = document.getElementById('\(id)'); if (!el) return 'none';
          var b = el.getBoundingClientRect(), x = b.left + b.width / 2, y = b.top + b.height / 2, at = document.elementFromPoint(x, y);
          var t = new Touch({identifier: 1, target: at, clientX: x, clientY: y, pageX: x, pageY: y, screenX: x, screenY: y});
          at.dispatchEvent(new TouchEvent('touchstart', {bubbles: true, cancelable: true, touches: [t], targetTouches: [t], changedTouches: [t]}));
          at.dispatchEvent(new TouchEvent('touchend', {bubbles: true, cancelable: true, touches: [], targetTouches: [], changedTouches: [t]}));
          return 'tapped';
        })()
        """) as? String
        XCTAssertEqual(r, "tapped", "Tap on #\(id)")
    }

    @MainActor
    func testPlaceholderGuideFitsTheScreenAndTapsAndButtonsNavigate() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let found = try XCTUnwrap(LauncherContent.findGuide(in: fixture, lang: "en-US"), "The placeholder guide at \(fixture.path)")
        var content = LauncherContent()
        content.guide = found.index; content.guideRoot = found.root
        var closed = 0
        let scroller = LauncherScroller()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 932, height: 430)   // the iPhone 18 Pro Max in landscape
        window.rootViewController = UIHostingController(rootView: LauncherGuideSheet(content: content, scroller: scroller) { closed += 1 })
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func find<T: UIView>(_ v: UIView, _ t: T.Type) -> T? { (v as? T) ?? v.subviews.lazy.compactMap { find($0, t) }.first }
        var box: LauncherGuideBox?
        waitUntil("The guide's page is up") { box = find(window, LauncherGuideBox.self); return box != nil }
        let web = try XCTUnwrap(box?.web)
        waitUntil("The page set up after the console's first paint (NXFirstPaintEndAfterLoad)", 15) { log(web).contains("ready") }
        waitUntil("Its picture loaded") { js(web, "document.querySelector('.picture').naturalWidth") as? Int == 200 }

        // Fit: the page's viewport is the console's, and the whole page is on the screen, under the header
        func checkFit(_ what: String) throws {
            let b = try XCTUnwrap(box)
            b.layoutIfNeeded()
            XCTAssertEqual(js(web, "innerWidth") as? Int, 1280, "\(what): the page is laid out 1280 wide")
            XCTAssertEqual(js(web, "innerHeight") as? Int, 720, "\(what): and 720 high")
            XCTAssertEqual(js(web, "Math.round(document.getElementById('bottom-edge').getBoundingClientRect().bottom)") as? Int, 720, "\(what): its bottom edge is the viewport's")
            let page = b.convert(web.bounds, from: web), shown = b.bounds.intersection(window.convert(window.bounds, to: b))
            XCTAssertTrue(shown.insetBy(dx: -0.5, dy: -0.5).contains(page), "\(what): the whole page \(page) is in the box \(shown)")
            XCTAssertEqual(page.width / page.height, 16.0 / 9.0, accuracy: 0.01, "\(what): not stretched")
            let area = b.bounds.inset(by: b.insets)
            XCTAssertTrue(page.width >= area.width - 1 || page.height >= area.height - 1, "\(what): as large as the area allows (\(page) in \(area))")
            XCTAssertEqual(web.scrollView.contentOffset, .zero, "\(what): not scrolled")
            let header = window.convert(b.bounds, from: b).minY
            XCTAssertGreaterThan(header, 30, "\(what): the header is above the page")
        }
        try checkFit("Landscape")
        XCTAssertTrue(box?.gestureRecognizers?.contains { ($0 as? UIScreenEdgePanGestureRecognizer)?.edges == .left } ?? false, "A swipe from the left edge goes back")
        for d in [UISwipeGestureRecognizer.Direction.left, .right] {
            XCTAssertTrue(box?.gestureRecognizers?.contains { ($0 as? UISwipeGestureRecognizer)?.direction == d } ?? false, "A swipe across the page turns it (\(d.rawValue))")
        }

        // Nothing is focused when the menu comes up, and the page moves its focus only from a focused item: the first down focuses the first item, whose onfocus shows its
        // preview (WebKit sends no focus events in a view that is not focused; the shim does)
        XCTAssertEqual(js(web, "document.activeElement === document.body") as? Bool, true, "Nothing focused at first")
        XCTAssertEqual(scroller.pad?(.down), true)
        waitUntil("Down: the first item has the focus") { js(web, "document.activeElement.id") as? String == "item1" }
        waitUntil("and its onfocus ran") { js(web, "document.getElementById('preview').textContent") as? String == "Preview of topic 1" }
        _ = scroller.pad?(.down)
        waitUntil("Down again: the second item, its onfocus too") { js(web, "document.getElementById('preview').textContent") as? String == "Preview of topic 2" }

        // A tap on a menu item whose page cancels its touches: the item's onclick runs, though an invisible page (opacity 0) lies over it, as guides stack their pages
        XCTAssertEqual(js(web, "document.querySelector('.menu a').getAttribute('href')") as? String, "javascript:void(0)")
        XCTAssertEqual(js(web, "(function () { var b = document.getElementById('item1').getBoundingClientRect(); return document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2).closest('.later-page') !== null; })()") as? Bool, true, "The invisible page is on top")
        tap(web, "item1")
        waitUntil("The tap opened topic one") { log(web).last == "topic1" }
        XCTAssertNotNil(scroller.pad, "The controller goes to the page")

        // The footer buttons, from the controller (the header's Back, L and R call the same)
        XCTAssertEqual(scroller.pad?(.r), true, "R is the page's")
        waitUntil("R turned to topic three") { log(web).last == "topic3" }
        XCTAssertEqual(scroller.pad?(.l), true)
        waitUntil("L turned back to topic one") { log(web).last == "topic1" }
        box?.turn?("R")
        waitUntil("A swipe to the left: the next topic (R)") { log(web).last == "topic3" }
        box?.turn?("L")
        waitUntil("A swipe to the right: the previous one (L)") { log(web).last == "topic1" }
        XCTAssertEqual(scroller.pad?(.b), true, "B is the page's")
        waitUntil("B went back to the menu") { log(web).last == "menu" }
        XCTAssertEqual(closed, 0, "and did not close the viewer")

        // The D-pad and A: the page's own focus moves, A opens the focused item
        _ = js(web, "document.getElementById('item1').focus()")
        _ = scroller.pad?(.down); _ = scroller.pad?(.down)
        waitUntil("Down twice: the third item has the focus") { js(web, "document.activeElement.id") as? String == "item3" }
        XCTAssertEqual(js(web, "document.getElementById('item3').hasAttribute('data-dm-focus')") as? Bool, true, "and its :focus look")
        _ = scroller.pad?(.a)
        waitUntil("A opened topic three") { log(web).last == "topic3" }
        _ = scroller.pad?(.b)
        waitUntil("B: the menu again") { log(web).last == "menu" }

        // A link to another page, then the page's Back: the previous page
        tap(web, "item2")
        waitUntil("The tap went to topic two's page") { log(web).first == "topic2 page" }
        waitUntil("The viewer can go back") { web.canGoBack }
        _ = scroller.pad?(.b)
        waitUntil("B: back on the menu's page") { (js(web, "location.pathname") as? String)?.hasSuffix("/index.html") == true && log(web).contains("menu") }
        // which faded out as it left: it is loaded again (not shown as it was left, from the back-forward cache) and set up again
        waitUntil("The menu's page loaded again and set up") { log(web) == ["ready", "menu"] }
        XCTAssertEqual(js(web, "getComputedStyle(document.querySelector('.contents')).opacity") as? String, "1", "and shows")
        XCTAssertEqual(closed, 0)

        // Portrait: still whole, as wide as the screen
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        try checkFit("Portrait")

        // The end: Finish goes to the console's end URL, which closes the viewer and loads nothing
        tap(web, "item9")
        waitUntil("The end URL closed the viewer") { closed == 1 }
        XCTAssertEqual((js(web, "location.protocol") as? String), "nx18guide:", "Nothing outside the guide was loaded")
    }

    // The guide and a manual: ZR shows the manual, which lets the guide's page go (here its second page, with a history and its own B): its web view is freed, not kept by a
    // handler, the model or a closure. The manual keeps the launcher's own buttons; ZL shows the guide again, a new page from its first one with no history
    @MainActor
    func testManualSwitchFreesTheGuidePage() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let found = try XCTUnwrap(LauncherContent.findGuide(in: fixture, lang: "en-US"), "The placeholder guide at \(fixture.path)")
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("duo-guide-manual.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: pdf) { c in
            for n in 1...3 { c.beginPage(); ("Placeholder manual page \(n)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)]) }
        }
        defer { try? FileManager.default.removeItem(at: pdf) }
        var content = LauncherContent()
        content.guide = found.index; content.guideRoot = found.root; content.manual = pdf
        var closed = 0
        let scroller = LauncherScroller()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 932, height: 430)
        window.rootViewController = UIHostingController(rootView: LauncherGuideSheet(content: content, scroller: scroller) { closed += 1 })
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        // Views looked up in an autorelease pool of their own: UIKit's subviews arrays are autoreleased, and the test method's own pool would keep the page alive to its end
        func find<T: UIView>(_ v: UIView, _ t: T.Type) -> T? {
            func walk(_ v: UIView) -> T? { (v as? T) ?? v.subviews.lazy.compactMap { walk($0) }.first }
            return autoreleasepool { walk(v) }
        }

        weak var first: WKWebView?, firstBox: LauncherGuideBox?
        try autoreleasepool {
            var box: LauncherGuideBox?
            waitUntil("The guide's page is up") { box = find(window, LauncherGuideBox.self); return box != nil }
            let web = try XCTUnwrap(box?.web)
            first = web; firstBox = box
            waitUntil("The page set up", 15) { log(web).contains("ready") }
            tap(web, "item2")
            waitUntil("A second page, so there is a history, whose B is its own") { web.canGoBack && log(web).first == "topic2 page" }
        }
        XCTAssertEqual(scroller.pad?(.zr), true, "ZR switches to the manual")
        waitUntil("The manual is shown") { find(window, PDFView.self)?.document?.pageCount == 3 && find(window, LauncherGuideBox.self) == nil }
        waitUntil("and the guide's page is freed, its box") { firstBox == nil }
        waitUntil("and its web view") { first == nil }
        XCTAssertEqual(scroller.pad?(.down), false, "On the manual the launcher's buttons stay (B closes, up / down scroll, L / R switch)")
        XCTAssertNotNil(scroller.scroll, "The manual scrolls from the controller")
        XCTAssertEqual(scroller.pad?(.zl), true, "ZL switches back to the guide")
        var box: LauncherGuideBox?
        waitUntil("The guide is shown again") { box = find(window, LauncherGuideBox.self); return box != nil }
        let web = try XCTUnwrap(box?.web)
        waitUntil("from its first page", 15) { log(web) == ["ready", "menu"] }
        XCTAssertFalse(web.canGoBack, "with no history")
        XCTAssertEqual(scroller.pad?(.b), true, "B on the menu, its end (nx.endApplet)")
        waitUntil("closes the viewer") { closed == 1 }
    }

    @MainActor
    func testEndURLAndFit() {
        XCTAssertTrue(LauncherGuideFiles.isEnd(URL(string: "http://localhost/ChangeMode")))
        XCTAssertTrue(LauncherGuideFiles.isEnd(URL(string: "https://LOCALHOST/")))
        XCTAssertFalse(LauncherGuideFiles.isEnd(URL(string: "http://example.com/localhost")))
        XCTAssertFalse(LauncherGuideFiles.isEnd(URL(string: "nx18guide://localhost/index.html")), "Only the web's localhost")
        XCTAssertEqual(LauncherGuideFiles.navigation(URL(string: "http://localhost/")), .end)
        XCTAssertEqual(LauncherGuideFiles.navigation(URL(string: "https://example.com/")), .refuse)
        XCTAssertEqual(LauncherGuideFiles.navigation(URL(string: "file:///etc/hosts")), .refuse)
        XCTAssertEqual(LauncherGuideFiles.navigation(URL(string: "nx18guide://guide/html/USen/index.html")), .allow)
        let wide = LauncherGuideFiles.fit(in: CGRect(x: 0, y: 0, width: 932, height: 372))
        XCTAssertEqual(wide.height, 372, "Landscape: the page's height is the area's")
        XCTAssertEqual(wide.width, 372 * 16 / 9, accuracy: 0.001)
        XCTAssertEqual(wide.minX, 135, "and it is centred")
        XCTAssertEqual(LauncherGuideFiles.fit(in: CGRect(x: 10, y: 0, width: 640, height: 900)).width, 640)
        XCTAssertEqual(LauncherGuideFiles.fit(in: CGRect(x: 10, y: 0, width: 640, height: 900)).height, 360)
        XCTAssertEqual(LauncherGuideFiles.footerScript("B'); alert('x"), "window.__nx18 && window.__nx18.footer ? __nx18.footer('Balertx') : 'back'", "Only letters reach the page")
    }
}
