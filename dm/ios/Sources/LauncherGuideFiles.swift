// The game guide's pages, for the iPhone and iPad (GuideViewer.swift) and the Mac app's guide window (dm/mac/Launcher.swift MacGuideWindow): a WKWebView configuration that serves
// the guide's .htdocs through a scheme of its own (nx18guide://guide/<path>), as the host's in-game viewer serves them (dm/host/web_apple.m dmweb://). Their scripts may then read the
// guide's other files with XMLHttpRequest or fetch, which WebKit refuses between file: URLs, and the button icons in their text come from the host's stand-in for the Nintendo
// extension font (DM_SHARED_FONT_EXT, else DM_FONT_DIR's nintendo_ext.ttf, at U+E000-E1FF). The pages were written for the Switch's web applet: a script at document start gives
// them a harmless window.nx, which a browser opening them from file: does not have.
// Nothing here goes to the network: every response carries a Content-Security-Policy that allows the guide's own scheme only (images, scripts, styles, fetch, media), a content
// rule list blocks http(s), ws(s), ftp and file: loads besides (attached before the first page loads), and a navigation outside the guide is refused. No UIKit or AppKit
import Foundation
import WebKit

// The guide's files under its own scheme: nx18guide://guide/<path under the guide's .htdocs>, and the Nintendo extension font at /__nx18_font/nintendo_ext.ttf. Anything
// outside the folder is not served. Each response forbids the page every other source (Content-Security-Policy)
@MainActor final class LauncherGuideFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "nx18guide"
    static let policy = "default-src nx18guide: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src nx18guide: data: blob:; form-action 'none'"

    // The page's stand-in for the Switch applet's window.nx, at document start: every call does nothing and nothing throws; nx.endApplet, nx.exit and window.close post nx18Close
    static let shim = """
    (function () {
      if (window.__nx18) return; window.__nx18 = 1;
      var post = function () { try { window.webkit.messageHandlers.nx18Close.postMessage('close'); } catch (e) {} };
      var nothing = function () { return stub(function () {}); };
      var stub = function (o) {
        return new Proxy(o, {get: function (t, p) { return (p in t || typeof p !== 'string' || p === 'then' || p === 'toJSON') ? t[p] : nothing(); }});
      };
      var font = function () {   // the Nintendo extension font's button icons, as the host's viewer gives them
        var s = document.createElement('style');
        s.textContent = '@font-face{font-family:"nx18-nx-ext";src:url("/__nx18_font/nintendo_ext.ttf");unicode-range:U+E000-E1FF}' +
          'html{font-family:"nx18-nx-ext",-apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif}';
        var r = document.head || document.documentElement; if (r) r.insertBefore(s, r.firstChild);
      };
      if (document.documentElement) font(); else document.addEventListener('DOMContentLoaded', font);
      window.nx = stub({
        endApplet: post, exit: post,
        addEventListener: function () {}, removeEventListener: function () {},
        sendMessage: function () { return true; },
        footer: stub({setAssign: function () {}, unsetAssign: function () {}, setFixed: function () {}})
      });
      window.close = post;
    })();
    """

    // The web view's configuration: no website data kept, the guide's scheme served by files, the shim in every frame, and close called for nx18Close (the caller removes the
    // handler when the view goes: the controller keeps it)
    static func configuration(files: LauncherGuideFiles, close: any WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(files, forURLScheme: scheme)
        config.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(close, name: "nx18Close")
        return config
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
