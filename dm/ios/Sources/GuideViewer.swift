// The settings screen's viewers (Launcher.swift): the game guide, full screen, which shows the game's own guide (its offline HTML pages in a WKWebView, read from the app's files
// only) and the player's manual (manual.pdf in a PDFView), the guide first, with a switch between them when the app has both; and the About this game sheet (about.json's text
// under the art). Both close with their close button or the controller's B (LauncherController.swift). The guide's pages were written for the Switch's web applet: a script at
// document start gives them a harmless window.nx (every call does nothing, nothing throws), and the calls that end the applet (nx.endApplet, window.close) close the viewer.
// The pages are served from the guide's .htdocs through a scheme of their own (nx18guide://guide/<path>), as the host's in-game viewer serves them (dm/host/web_apple.m dmweb://):
// their scripts may then read the guide's other files with XMLHttpRequest or fetch, which WebKit refuses between file: URLs, and the button icons in their text come from the
// host's stand-in for the Nintendo extension font (DM_SHARED_FONT_EXT, else DM_FONT_DIR's nintendo_ext.ttf, at U+E000-E1FF).
// Nothing here goes to the network: every response carries a Content-Security-Policy that allows the guide's own scheme only (images, scripts, styles, fetch, media), a content
// rule list blocks http(s), ws(s), ftp and file: loads besides (attached before the first page loads), and a navigation outside the guide is refused
import PDFKit
import SwiftUI
import UIKit
import WebKit

enum LauncherGuidePage: String, Identifiable, CaseIterable, Sendable {
    case guide, manual
    var id: String { rawValue }
    var title: String { self == .guide ? "Game guide" : "Manual" }
}

struct LauncherGuideSheet: View {
    let content: LauncherContent
    let scroller: LauncherScroller
    let close: () -> Void
    @State private var page: LauncherGuidePage

    init(content: LauncherContent, scroller: LauncherScroller, close: @escaping () -> Void) {
        self.content = content; self.scroller = scroller; self.close = close
        _page = State(initialValue: content.guide != nil ? .guide : .manual)
    }
    private var pages: [LauncherGuidePage] { LauncherGuidePage.allCases.filter { $0 == .guide ? content.guide != nil : content.manual != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NX18Mark(height: 16).accessibilityHidden(true)
                if pages.count > 1 {
                    Picker("Document", selection: $page) {
                        ForEach(pages) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                } else {
                    Text(page.title).font(.headline).foregroundStyle(.white)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Circle().fill(NX18Palette.row))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            NX18Rails(axis: .horizontal, thickness: 2)
            Group {
                switch page {
                case .guide:
                    if let g = content.guide, let root = content.guideRoot { LauncherGuideWebView(index: g, root: root, scroller: scroller, close: close) }
                case .manual:
                    if let m = content.manual { LauncherManualView(url: m, scroller: scroller) }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(NX18Palette.background.ignoresSafeArea())
        .tint(NX18Palette.cyan)
        .onAppear {
            scroller.page = { step in
                let p = pages
                guard p.count > 1, let i = p.firstIndex(of: page) else { return }
                page = p[(i + step + p.count) % p.count]
            }
        }
        .onDisappear { scroller.page = nil; scroller.scroll = nil }
    }
}

// The guide's pages: the index.html under its .htdocs folder, served by LauncherGuideFiles, a shim for the Switch's applet API, links outside the guide refused
struct LauncherGuideWebView: UIViewRepresentable {
    let index: URL
    let root: URL
    let scroller: LauncherScroller
    let close: () -> Void

    private static let shim = """
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

    func makeCoordinator() -> Coordinator { Coordinator(root: root, close: close) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: LauncherGuideFiles.scheme)
        config.userContentController.addUserScript(WKUserScript(source: Self.shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: "nx18Close")
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(NX18Palette.background)
        web.scrollView.backgroundColor = UIColor(NX18Palette.background)
        web.navigationDelegate = context.coordinator
        web.accessibilityLabel = "Game guide"
        let sv = web.scrollView
        scroller.scroll = { [weak sv] dy in sv?.nudge(by: dy) }
        guard let start = context.coordinator.files.url(for: index) else {
            fputs("[RED] launcher: the guide's index.html is not inside its folder\n", stderr)
            return web
        }
        // The first page loads once the rule list is attached, so no load of the page happens before it
        let content = config.userContentController
        Task { @MainActor [weak web] in
            if let rules = await LauncherGuideFiles.blockRules() { content.add(rules) }
            else { fputs("[RED] launcher: the guide's network block list cannot be made; the pages' Content-Security-Policy still keeps them offline\n", stderr) }
            web?.load(URLRequest(url: start))
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.close = close }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "nx18Close")   // the controller keeps its handler: let it go with the view
        web.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let files: LauncherGuideFiles
        var close: () -> Void
        init(root: URL, close: @escaping () -> Void) { files = LauncherGuideFiles(root: root); self.close = close }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { close() }   // nx.endApplet, window.close

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let u = action.request.url, let scheme = u.scheme?.lowercased() else { return .cancel }
            if scheme == LauncherGuideFiles.scheme || scheme == "about" || scheme == "data" || scheme == "blob" { return .allow }
            fputs("launcher: guide link \(scheme) outside the guide refused\n", stderr)
            return .cancel
        }
    }
}

// The guide's files under its own scheme: nx18guide://guide/<path under the guide's .htdocs>, and the Nintendo extension font at /__nx18_font/nintendo_ext.ttf. Anything
// outside the folder is not served. Each response forbids the page every other source (Content-Security-Policy)
@MainActor final class LauncherGuideFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "nx18guide"
    static let policy = "default-src nx18guide: data: blob: 'unsafe-inline' 'unsafe-eval'; connect-src nx18guide: data: blob:; form-action 'none'"
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

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
            return env["DM_FONT_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("nintendo_ext.ttf") }
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

// manual.pdf in a PDFView: one page after another, fitted to the width
struct LauncherManualView: UIViewRepresentable {
    let url: URL
    let scroller: LauncherScroller

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(NX18Palette.background)
        v.document = PDFDocument(url: url)
        if v.document == nil { fputs("[RED] launcher: dm/manual.pdf cannot be read\n", stderr) }
        scroller.scroll = { [weak v] dy in
            guard let v else { return }
            Self.scrollView(in: v)?.nudge(by: dy)
        }
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
    private static func scrollView(in v: UIView) -> UIScrollView? {
        for s in v.subviews {
            if let sv = s as? UIScrollView { return sv }
            if let sv = scrollView(in: s) { return sv }
        }
        return nil
    }
}

// About this game: the art (or the icon) as a header, the name, the intro and description, the publisher and release date, where the text came from, and the app's version
struct LauncherAboutSheet: View {
    let about: LauncherAbout
    let artwork: LauncherArtwork
    let name: String
    let version: String?
    let scroller: LauncherScroller
    let close: () -> Void
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var background: Color { NX18Palette.background(tint: artwork.tint) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    Text(about.name ?? name).font(.title2.weight(.bold)).foregroundStyle(.white)
                    if let intro = about.intro { Text(intro).font(.headline).foregroundStyle(.white.opacity(0.92)) }
                    if let d = about.description { Text(d).font(.body).foregroundStyle(.white.opacity(0.85)) }
                    facts
                    if let s = about.sourceLine { Text(s).font(.footnote).foregroundStyle(NX18Palette.muted) }
                    if let v = version { Text("Version \(v)").font(.footnote).foregroundStyle(NX18Palette.muted) }
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset = y }
        .background(background.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Circle().fill(NX18Palette.charcoal.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
            .padding(14)
        }
        .onAppear { scroller.scroll = { dy in
            if reduceMotion { position.scrollTo(y: Swift.max(0, offset + dy)) } else { withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: Swift.max(0, offset + dy)) } }
        } }
        .onDisappear { scroller.scroll = nil }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear.frame(height: 200).overlay {
                if let art = artwork.art { Image(uiImage: art).resizable().scaledToFill() }
                else if let icon = artwork.icon { Image(uiImage: icon).resizable().scaledToFill().blur(radius: 40).opacity(0.6) }
            }
            .clipped()
            LinearGradient(stops: [.init(color: background.opacity(0), location: 0.35), .init(color: background, location: 1)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 14) {
                if artwork.art == nil, let icon = artwork.icon {
                    Image(uiImage: icon).resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                NX18Mark(height: 18)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var facts: some View {
        let released = about.released.map { $0.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current)) }
        if about.publisher != nil || released != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let p = about.publisher { fact("Publisher", p) }
                if about.publisher != nil && released != nil { Rectangle().fill(NX18Palette.separator).frame(height: 0.5).padding(.leading, 14) }
                if let r = released { fact("Released", r) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NX18Palette.row))
        }
    }
    private func fact(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.white)
            Spacer()
            Text(v).foregroundStyle(NX18Palette.muted).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}
