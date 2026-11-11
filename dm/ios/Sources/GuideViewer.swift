// The settings screen's viewers (Launcher.swift): the game guide, full screen, which shows the game's own guide (its offline HTML pages in a WKWebView, read from the app's files
// only) and the player's manual (manual.pdf in a PDFView), the guide first, with a switch between them when the app has both; and the About this game sheet (about.json's text
// under the art). Both close with their close button or the controller's B (LauncherController.swift). The guide's pages were written for the Switch's web applet: a script at
// document start gives them a harmless window.nx (every call does nothing, nothing throws), and the calls that end the applet (nx.endApplet, window.close) close the viewer.
// The pages are served from the guide's .htdocs through a scheme of their own, with the shim, the Content-Security-Policy and the network block list: LauncherGuideFiles.swift,
// which the Mac app's guide window shares (dm/mac/Launcher.swift MacGuideWindow)
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

    func makeCoordinator() -> Coordinator { Coordinator(root: root, close: close) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: LauncherGuideFiles.configuration(files: context.coordinator.files, close: context.coordinator))
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
        LauncherGuideFiles.load(web, start: start)
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
            LauncherGuideFiles.allows(action.request.url) ? .allow : .cancel
        }
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
