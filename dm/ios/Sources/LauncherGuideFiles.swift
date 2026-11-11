// The guide's pages, for the iPhone and iPad (GuideViewer.swift) and the Mac app's guide window (dm/mac/Launcher.swift MacGuideWindow): a WKWebView configuration that serves
// the guide's .htdocs through a scheme of its own (nx18guide://guide/<path>), as the host's in-game viewer serves them (dm/host/web_apple.m dmweb://). Their scripts may then read the
// guide's other files with XMLHttpRequest or fetch, which WebKit refuses between file: URLs, and the button icons in their text come from the host's stand-in for the Nintendo
// extension font (DM_SHARED_FONT_EXT, else DM_FONT_DIR's nintendo_ext.ttf, at U+E000-E1FF). The pages were written for the Switch's web applet at 1280x720: a script at document
// start gives them the applet's window.nx, its footer buttons, its first-paint event, taps they cancel as clicks and the controller as keys (shim), and the viewers lay them out at
// 1280x720 and scale them to fit (fit). A page ends by going to http://localhost/ (isEnd): the viewer closes.
// Nothing here goes to the network: every response carries a Content-Security-Policy that allows the guide's own scheme only (images, scripts, styles, fetch, media), a content
// rule list blocks http(s), ws(s), ftp and file: loads besides (attached before the first page loads), and a navigation outside the guide is refused (the end is cancelled too,
// never loaded). No UIKit or AppKit
import Foundation
import WebKit

// The guide's files under its own scheme: nx18guide://guide/<path under the guide's .htdocs>, and the Nintendo extension font at /__nx18_font/nintendo_ext.ttf. Anything
// outside the folder is not served. Each response forbids the page every other source (Content-Security-Policy)
@MainActor final class LauncherGuideFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "nx18guide"
    static let policy = "default-src nx18guide: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src nx18guide: data: blob:; form-action 'none'"

    // The page's stand-in for the Switch browser's applet API and controller, at document start (dm/host/web_apple.m SHIM is the in-game viewer's; this one adds what the guides
    // need on a touch screen). Every nx call it lacks does nothing and nothing throws; nx.endApplet, nx.exit and window.close post nx18Close.
    // - The footer's buttons (nx.footer.setAssign: the page's Back on B, its page turning on L / R) are kept, and their names posted to nx18State when they change: the viewer
    //   shows a Back, L and R button for them and sends the controller's buttons there (__nx18.footer). B with nothing assigned is the viewer's own back ('back').
    // - The console's first paint (NXFirstPaintEndAfterLoad on window) once each page has loaded and painted: guides wait for it before loading their pictures and setting up.
    // - A tap the page cancelled: guides written for the console call preventDefault on every touch when window.nx exists, and WebKit then sends no click. A one-finger tap that
    //   did not move, whose touchstart or touchend the page cancelled and that no click followed, clicks what it landed on (its link, button or focusable ancestor), after focusing it.
    // - The controller as keys (__nx18.key: the arrow keys 37-40 with keyCode set, A as 32 that clicks the focused link when the page does not take it), and for a page with no key
    //   handler of its own, the arrows move the focus to the nearest link or button that way (else up / down scroll it).
    // - :focus rules copied for [data-dm-focus], which follows the focus (WebKit matches :focus only in the key window, and on the iPhone the web view never takes the keyboard)
    static let shim = """
    (function () {
      if (window.__nx18) return;
      var post = function (name, m) { try { window.webkit.messageHandlers[name].postMessage(m); } catch (e) {} };
      var close = function () { post('nx18Close', 'close'); };
      var nothing = function () { return stub(function () {}); };
      var stub = function (o) {
        return new Proxy(o, {get: function (t, p) { return (p in t || typeof p !== 'string' || p === 'then' || p === 'toJSON') ? t[p] : nothing(); }});
      };
      // The footer's buttons: true = the viewer's own action (B: back), false = none (unsetAssign), a function = the page's
      var assign = {B: true};
      var report = function () { post('nx18State', {footer: Object.keys(assign).filter(function (k) { return typeof assign[k] === 'function'; })}); };
      window.nx = stub({
        endApplet: close, exit: close,
        addEventListener: function () {}, removeEventListener: function () {},
        sendMessage: function () { return true; },
        setCursorScrollSpeed: function () {},
        footer: stub({
          setAssign: function (b, label, fn) { assign[b] = typeof fn === 'function' ? fn : true; report(); },
          unsetAssign: function (b) { assign[b] = false; report(); },
          setFixed: function () {}
        })
      });
      window.close = close;
      window.addEventListener('pageshow', report);   // a page back from the back-forward cache keeps its buttons

      // The page's look: the Nintendo extension font's button icons (the host's stand-in), no tap highlight or text selection, no focus ring when the page asks for none
      var style = function () {
        var m = document.querySelector('meta[name="focus-ring-visibility"]'), s = document.createElement('style');
        s.textContent = '@font-face{font-family:"nx18-nx-ext";src:url("/__nx18_font/nintendo_ext.ttf");unicode-range:U+E000-E1FF}' +
          'html{font-family:"nx18-nx-ext",-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-tap-highlight-color:transparent;-webkit-user-select:none;-webkit-touch-callout:none}' +
          (m && m.content === 'hidden' ? ':focus,[data-dm-focus]{outline:none!important}' : '');
        var r = document.head || document.documentElement; if (r) r.insertBefore(s, r.firstChild);
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', style); else style();
      var mark = function (el) {
        var o = document.querySelectorAll('[data-dm-focus]');
        for (var i = 0; i < o.length; i++) if (o[i] !== el) o[i].removeAttribute('data-dm-focus');
        if (el && el !== document.body && el !== document.documentElement && el.setAttribute) el.setAttribute('data-dm-focus', '');
      };
      var mirror = function () {
        var out = [];
        var walk = function (rules) {
          for (var i = 0; i < rules.length; i++) {
            var r = rules[i];
            if (r.selectorText && r.selectorText.indexOf(':focus') >= 0) out.push(r.cssText.replace(/:focus(?![-\\w])/g, '[data-dm-focus]'));
            else if (r.cssRules && r.media) { var k = out.length; walk(r.cssRules); if (out.length > k) out.splice(k, 0, '@media ' + r.media.mediaText + '{'), out.push('}'); }
          }
        };
        for (var i = 0; i < document.styleSheets.length; i++) { try { walk(document.styleSheets[i].cssRules); } catch (e) {} }
        var s = document.createElement('style'); s.textContent = out.join('\\n'); (document.head || document.documentElement).appendChild(s);
        mark(document.activeElement);
      };
      // The focus as it changes: a page focused in a view that is not the key one gets no focus events, so the focused element is also looked at once a frame
      var focused = null;
      var follow = function () { if (document.activeElement !== focused) { focused = document.activeElement; mark(focused); } requestAnimationFrame(follow); };
      requestAnimationFrame(follow);
      document.addEventListener('focus', function (e) { mark(e.target); }, true);
      document.addEventListener('blur', function () { setTimeout(function () { mark(document.activeElement); }, 0); }, true);

      // The console's first paint after the load: the page's own load handlers have run, and it has painted once (or 100 ms went by: a view not on the screen paints no frames)
      window.addEventListener('load', function () {
        mirror(); report();
        var sent = false, paint = function () { if (!sent) { sent = true; window.dispatchEvent(new Event('NXFirstPaintEndAfterLoad')); } };
        requestAnimationFrame(function () { setTimeout(paint, 0); });
        setTimeout(paint, 100);
      });

      // A tap the page cancelled becomes a click (decided after the touch's listeners have all run: defaultPrevented stays set on the event)
      var CLICKABLE = 'a[href],button,input,select,textarea,label,summary,[onclick],[tabindex]';
      var tap = null;
      window.addEventListener('touchstart', function (e) {
        var t = e.touches[0];
        tap = e.touches.length === 1 && t ? {x: t.clientX, y: t.clientY, start: e, moved: false, clicked: false} : null;
      }, true);
      window.addEventListener('touchmove', function (e) {
        var t = e.touches[0];
        if (tap && t && Math.abs(t.clientX - tap.x) + Math.abs(t.clientY - tap.y) > 12) tap.moved = true;
      }, true);
      window.addEventListener('touchcancel', function () { tap = null; }, true);
      window.addEventListener('click', function (e) { if (tap && e.isTrusted) tap.clicked = true; }, true);
      window.addEventListener('touchend', function (e) {
        var s = tap;
        if (!s || s.moved || e.touches.length) { tap = null; return; }
        setTimeout(function () {
          if (tap === s) tap = null;
          if (s.clicked || !(s.start.defaultPrevented || e.defaultPrevented)) return;   // WebKit clicked, or will: the page did not cancel the touch
          var el = document.elementFromPoint(s.x, s.y); if (!el) return;
          var c = (el.closest && el.closest(CLICKABLE)) || el;
          if (c.focus) { try { c.focus({preventScroll: true}); } catch (x) {} }
          if (c.click) c.click();
        }, 40);
      }, true);
      document.addEventListener('click', function (e) {   // a click focuses what it lands on, as the console's cursor does (focus-driven pages show its details)
        var c = e.target && e.target.closest && e.target.closest(CLICKABLE);
        if (c && c !== document.activeElement && c.focus) { try { c.focus({preventScroll: true}); } catch (x) {} }
      }, true);

      // Whether the page reads keys itself (then the arrows are only its keys, not a focus move as well)
      var keyed = false;
      var add = EventTarget.prototype.addEventListener;
      EventTarget.prototype.addEventListener = function (t) { if (t === 'keydown' || t === 'keyup' || t === 'keypress') keyed = true; return add.apply(this, arguments); };
      var reads = function () {
        return keyed || !!(document.onkeydown || window.onkeydown || document.onkeyup || window.onkeyup || (document.body && (document.body.onkeydown || document.body.onkeyup)));
      };
      var KEYS = {37: ['ArrowLeft', 'ArrowLeft'], 38: ['ArrowUp', 'ArrowUp'], 39: ['ArrowRight', 'ArrowRight'], 40: ['ArrowDown', 'ArrowDown'], 32: [' ', 'Space']};
      var target = function () { var a = document.activeElement; return a && a !== document.documentElement ? a : document.body || document.documentElement; };
      var key = function (type, code, at) {
        var e = new KeyboardEvent(type, {key: KEYS[code][0], code: KEYS[code][1], bubbles: true, cancelable: true});
        Object.defineProperty(e, 'keyCode', {get: function () { return code; }});
        Object.defineProperty(e, 'which', {get: function () { return code; }});
        return (at || target()).dispatchEvent(e);
      };
      var visible = function (el) {
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < innerWidth && r.top < innerHeight && getComputedStyle(el).visibility !== 'hidden';
      };
      // The nearest focusable element from the focused one in a direction (37-40); the first one when nothing is focused
      var nearest = function (code) {
        var all = Array.prototype.filter.call(document.querySelectorAll('a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])'), visible);
        var a = document.activeElement, from = a && a !== document.body && all.indexOf(a) >= 0 ? a.getBoundingClientRect() : null;
        if (!from) return all[0] || null;
        var fx = from.left + from.width / 2, fy = from.top + from.height / 2, best = null, score = Infinity;
        all.forEach(function (el) {
          if (el === a) return;
          var r = el.getBoundingClientRect(), x = r.left + r.width / 2 - fx, y = r.top + r.height / 2 - fy;
          var along = code === 37 ? -x : code === 39 ? x : code === 38 ? -y : y, across = code === 37 || code === 39 ? Math.abs(y) : Math.abs(x);
          if (along <= 1) return;
          var s = along + 2 * across;
          if (s < score) { score = s; best = el; }
        });
        return best;
      };
      window.__nx18 = {
        // A footer button: 'page' when the page took it, 'back' for B left to the viewer, 'none' otherwise
        footer: function (b) {
          var a = assign[b];
          if (typeof a === 'function') { try { a(); } catch (e) { console.error(e && e.message); } return 'page'; }
          return a === true && b === 'B' ? 'back' : 'none';
        },
        // An arrow key (37-40): the page's, else a focus move (or a scroll up or down)
        key: function (code) {
          var el = target(), go = key('keydown', code, el);
          key('keyup', code, el);
          if (!go || reads()) return;
          var n = nearest(code);
          if (n) { try { n.focus({preventScroll: false}); } catch (x) {} }
          else if (code === 38 || code === 40) window.scrollBy(0, code === 40 ? 160 : -160);
        },
        // A: the page's A when it took the button over, else key 32 at the focused element, which is clicked when the page does not take the key
        a: function () {
          if (typeof assign.A === 'function') { try { assign.A(); } catch (e) {} return; }
          var el = target(), go = key('keydown', 32, el);
          key('keyup', 32, el);
          if (go && el.closest && el.closest(CLICKABLE) && el !== document.body) el.click();
        },
        state: report
      };
    })();
    """

    // The script messages the pages post: nx18Close (nx.endApplet, nx.exit, window.close) and nx18State (the footer buttons the page assigned: {footer: ["B", "L", ...]})
    static let messages = ["nx18Close", "nx18State"]

    // The web view's configuration: no website data kept, the guide's scheme served by files, the shim in every frame, and the page's messages for handler (the caller removes
    // them with detach when the view goes: the controller keeps its handler). Sounds and videos play without a tap, inline, as on the console
    static func configuration(files: LauncherGuideFiles, handler: any WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(files, forURLScheme: scheme)
        config.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for m in messages { config.userContentController.add(handler, name: m) }
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        return config
    }
    // Lets the page's handler go with the view
    static func detach(_ web: WKWebView) {
        for m in messages { web.configuration.userContentController.removeScriptMessageHandler(forName: m) }
    }
    // The footer buttons a page's nx18State message names
    static func footer(of body: Any) -> Set<String> {
        guard let d = body as? [String: Any], let keys = d["footer"] as? [Any] else { return [] }
        return Set(keys.compactMap { $0 as? String })
    }
    // The script that presses a footer button on the page: its result is 'page', 'back' or 'none'
    static func footerScript(_ button: String) -> String {
        let b = button.filter { $0.isLetter }
        return "window.__nx18 && window.__nx18.footer ? __nx18.footer('\(b)') : 'back'"
    }

    // The console page's size: the guides are laid out for the Switch's 1280x720 screen
    static let pageSize = CGSize(width: 1280, height: 720)
    // The page fitted into an area, centred, whole (the rest of the area is a letterbox); its scale is the rect's width / 1280
    static func fit(in area: CGRect) -> CGRect {
        guard area.width > 1, area.height > 1 else { return CGRect(origin: area.origin, size: .zero) }
        var w = area.width, h = area.height
        if w / h > pageSize.width / pageSize.height { w = h * pageSize.width / pageSize.height } else { h = w * pageSize.height / pageSize.width }
        return CGRect(x: area.minX + ((area.width - w) / 2).rounded(.down), y: area.minY + ((area.height - h) / 2).rounded(.down), width: w, height: h)
    }

    // The first page, once the network block list is attached, so no load of the page happens before it
    static func load(_ web: WKWebView, start: URL) {
        let content = web.configuration.userContentController
        Task { @MainActor [weak web] in
            if let rules = await blockRules() { content.add(rules) }
            else { fputs("[RED] launcher: the guide's network block list cannot be made; the pages' Content-Security-Policy still keeps them offline\n", stderr) }
            web?.load(URLRequest(url: start))
        }
    }
    // A navigation the guide may make: its own scheme, about:, data: and blob:; any other (a link to the web, a file: URL) is refused
    static func allows(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        if scheme == Self.scheme || scheme == "about" || scheme == "data" || scheme == "blob" { return true }
        fputs("launcher: guide link \(scheme) outside the guide refused\n", stderr)
        return false
    }
    // The page's end: the console's guides finish by going to http://localhost/ (a mode change, the last page's Back, the end from the first page), the browser applet's callback.
    // Nothing is loaded: the viewer cancels the navigation and closes
    static func isEnd(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host?.trimmingCharacters(in: .whitespaces).lowercased() == "localhost"
    }
    enum Navigation: Equatable { case allow, refuse, end }
    // What the viewer does with a navigation: the guide's own pages load, the end closes the viewer, anything else is refused
    static func navigation(_ url: URL?) -> Navigation {
        if isEnd(url) { fputs("launcher: the guide ended (\(url?.path ?? "/"))\n", stderr); return .end }
        return allows(url) ? .allow : .refuse
    }
    let root: URL
    let fontDir: URL?   // where nintendo_ext.ttf is when the environment names no font (the Mac app's Resources/dm/font: its launcher runs before launcher.c sets DM_FONT_DIR for the host)
    init(root: URL, fontDir: URL? = nil) { self.root = root.standardizedFileURL.resolvingSymlinksInPath(); self.fontDir = fontDir }

    // The scheme's URL of a file under the folder; nil for one outside it
    func url(for file: URL) -> URL? {
        let f = file.standardizedFileURL.resolvingSymlinksInPath().path, r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard f.hasPrefix(r) else { return nil }
        var c = URLComponents()
        c.scheme = Self.scheme; c.host = "guide"; c.path = "/" + String(f.dropFirst(r.count))
        return c.url
    }
    // The file a request names; nil for one outside the folder
    func file(for url: URL) -> URL? {
        let rel = url.path.split(separator: "/").map(String.init)
        if rel == ["__nx18_font", "nintendo_ext.ttf"] {   // the host's stand-in, as the shared font service gives it (dm/host/web_apple.m serve)
            let env = ProcessInfo.processInfo.environment
            if let e = env["DM_SHARED_FONT_EXT"], !e.isEmpty { return URL(fileURLWithPath: e) }
            return (env["DM_FONT_DIR"].map { URL(fileURLWithPath: $0) } ?? fontDir)?.appendingPathComponent("nintendo_ext.ttf")
        }
        guard !rel.isEmpty, !rel.contains("..") else { return nil }
        let f = rel.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.resolvingSymlinksInPath()
        return f.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") ? f : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let u = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let f = file(for: u)
        let data = f.flatMap { try? Data(contentsOf: $0) }
        if data == nil { fputs("launcher: the guide asked for \(u.path), which it does not have\n", stderr) }
        let headers = ["Content-Type": Self.mime(f?.pathExtension ?? ""), "Content-Length": String(data?.count ?? 0), "Content-Security-Policy": Self.policy]
        guard let r = HTTPURLResponse(url: u, statusCode: data != nil ? 200 : 404, httpVersion: "HTTP/1.1", headerFields: headers) else { task.didFailWithError(URLError(.cannotParseResponse)); return }
        task.didReceive(r)
        task.didReceive(data ?? Data())
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}   // answered at once: nothing to stop

    static func mime(_ ext: String) -> String {
        let m = ["html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json", "png": "image/png", "jpg": "image/jpeg",
                 "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "wav": "audio/wav", "mp3": "audio/mpeg", "ogg": "audio/ogg",
                 "m4a": "audio/mp4", "mp4": "video/mp4", "webm": "video/webm", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
                 "txt": "text/plain", "xml": "application/xml"]
        return m[ext.lowercased()] ?? "application/octet-stream"
    }

    // A content rule list that blocks every load by http(s), ws(s), ftp or file: (WebKit's url-filter has no alternation: one rule each). nil when WebKit cannot make it
    static func blockRules() async -> WKContentRuleList? {
        let rules = ["^https?:", "^wss?:", "^ftp:", "^file:"].map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        return try? await WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "nx18-guide-offline", encodedContentRuleList: "[" + rules.joined(separator: ",") + "]")
    }
}
