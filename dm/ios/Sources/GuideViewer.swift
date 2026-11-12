// The settings screen's viewers (Launcher.swift): the game guide, full screen, which shows the game's own guide (its offline HTML pages in a WKWebView, read from the app's files
// only) and the player's manual (manual.pdf in a PDFView), the guide first, with a switch between them when the app has both; and the About this game sheet (about.json's text
// under the art). Both close with their close button or the controller's B (LauncherController.swift) when nothing is left to go back to.
// The guide's pages were written for the Switch's web applet at 1280x720: they are laid out at that size and scaled to fit under the header, whole (LauncherGuideBox), and a script
// at document start gives them window.nx and what the console's browser does for them (LauncherGuideFiles.swift shim). The header's Back, a swipe from the left edge and the
// controller's B go back: the page's own Back when it assigned one (nx.footer B), else the previous page, else the viewer closes. The page's L / R page turning shows as two buttons
// in the header, a swipe across the page and the controller's L / R; the D-pad and stick are its arrow keys and A presses; ZL / ZR switch between the guide and the manual.
// The calls that end the applet (nx.endApplet, window.close) and the console's end URL (http://localhost/) close the viewer.
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

// The guide page shown: the footer buttons it assigned and whether there is a page to go back to, and what the header, the edge swipe and the controller do to it
@MainActor final class LauncherGuidePageModel: ObservableObject {
    @Published var footer: Set<String> = []   // the page's nx.footer buttons ("B", "L", "R", ...)
    @Published var canGoBack = false           // the web view has a previous page
    weak var web: WKWebView?
    var close: () -> Void = {}

    var hasBack: Bool { canGoBack || footer.contains("B") }
    // A footer button on the page: the page's own when it assigned it; B left to the viewer goes to the previous page, else closes the viewer
    func press(_ button: String) {
        guard let web else { if button == "B" { close() }; return }
        web.evaluateJavaScript(LauncherGuideFiles.footerScript(button)) { [weak self, weak web] r, _ in
            MainActor.assumeIsolated {
                guard let self, button == "B", (r as? String) ?? "back" == "back" else { return }
                if let web, web.canGoBack { web.goBack() } else { self.close() }
            }
        }
    }
    func back() { press("B") }
    // An arrow key (37 left, 38 up, 39 right, 40 down) and A, as the console's controller gives them to the page
    func key(_ code: Int) { web?.evaluateJavaScript("window.__nx18 && __nx18.key && __nx18.key(\(code))", completionHandler: nil) }
    func pressA() { web?.evaluateJavaScript("window.__nx18 && __nx18.a && __nx18.a()", completionHandler: nil) }

    // A controller event while the guide's page is shown (Launcher.swift handle): every button goes to the page
    func handle(_ e: LauncherPadEvent) -> Bool {
        switch e {
        case .left: key(37)
        case .up: key(38)
        case .right: key(39)
        case .down: key(40)
        case .a: pressA()
        case .b: back()
        case .l: press("L")
        case .r: press("R")
        case .x: press("X")
        case .y: press("Y")
        case .plus: press("Plus")
        case .minus: press("Minus")
        case .zl, .zr: return false
        }
        return true
    }
}

struct LauncherGuideSheet: View {
    let content: LauncherContent
    let scroller: LauncherScroller
    var closeGlyph: NXPadGlyph? = nil   // the controller's B (NXButtonGlyph.swift) while a controller is connected: beside Back while the guide has a page to go back to (B goes back there), else beside the close button
    let close: () -> Void
    @State private var page: LauncherGuidePage
    @StateObject private var model = LauncherGuidePageModel()

    init(content: LauncherContent, scroller: LauncherScroller, closeGlyph: NXPadGlyph? = nil, close: @escaping () -> Void) {
        self.content = content; self.scroller = scroller; self.closeGlyph = closeGlyph; self.close = close
        _page = State(initialValue: content.guide != nil ? .guide : .manual)
    }
    private var pages: [LauncherGuidePage] { LauncherGuidePage.allCases.filter { $0 == .guide ? content.guide != nil : content.manual != nil } }
    private var onGuide: Bool { page == .guide && content.guide != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if onGuide && model.hasBack {
                    circleButton("chevron.backward", label: "Back", glyph: closeGlyph) { model.back() }
                } else {
                    NX18Mark(height: 16).accessibilityHidden(true)
                }
                if pages.count > 1 && NXFont.name != nil {
                    LauncherGuideChips(pages: pages, page: $page)   // a segmented control draws its titles in the system font: the UI font's chips instead
                } else if pages.count > 1 {
                    Picker("Document", selection: $page) {
                        ForEach(pages) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                } else {
                    Text(page.title).nxFont(.headline).foregroundStyle(.white).lineLimit(1)
                }
                Spacer(minLength: 0)
                if onGuide && (model.footer.contains("L") || model.footer.contains("R")) {
                    HStack(spacing: 8) {
                        turnButton("L", icon: "chevron.left", label: "Previous page", on: model.footer.contains("L"))
                        turnButton("R", icon: "chevron.right", label: "Next page", on: model.footer.contains("R"))
                    }
                }
                circleButton("xmark", label: "Close", glyph: (onGuide && model.hasBack) ? nil : closeGlyph, action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            NX18Rails(axis: .horizontal, thickness: 2)
            Group {
                switch page {
                case .guide:
                    if let g = content.guide, let root = content.guideRoot {
                        // The page is fitted into the safe area's width; the box reaches the screen's edges, so the swipe back starts at the left edge
                        GeometryReader { geo in
                            LauncherGuideWebView(index: g, root: root, model: model, close: close,
                                                 insets: UIEdgeInsets(top: 0, left: geo.safeAreaInsets.leading, bottom: 0, right: geo.safeAreaInsets.trailing))
                        }
                        .ignoresSafeArea(edges: [.horizontal, .bottom])
                    }
                case .manual:
                    if let m = content.manual { LauncherManualView(url: m, scroller: scroller) }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(NX18Palette.background.ignoresSafeArea())
        .nxTextRoot()
        .tint(NX18Palette.cyan)
        .onAppear {
            model.close = close
            scroller.page = { step in
                let p = pages
                guard p.count > 1, let i = p.firstIndex(of: page) else { return }
                page = p[(i + step + p.count) % p.count]
            }
            // The controller: ZL / ZR switch documents; on the guide every other button is the page's (the manual keeps Launcher.swift's: B closes, up / down scroll, L / R switch)
            scroller.pad = { e in
                if e == .zl || e == .zr { scroller.page?(e == .zr ? 1 : -1); return true }
                return onGuide ? model.handle(e) : false
            }
        }
        .onDisappear { scroller.page = nil; scroller.scroll = nil; scroller.pad = nil }
    }

    // glyph: the controller's button that does the same (B, on Back or the close button, while a controller is connected), beside it
    private func circleButton(_ icon: String, label: String, glyph: NXPadGlyph? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let g = glyph { NXPadGlyphView(g, size: 20, relativeTo: .body).foregroundStyle(NX18Palette.cyan) }
                Image(systemName: icon).font(.body.weight(.semibold)).foregroundStyle(.white)   // system: symbol
                    .frame(width: 36, height: 36).background(Circle().fill(NX18Palette.row))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    // The page's L or R (its page turning), drawn as the console's shoulder buttons
    private func turnButton(_ button: String, icon: String, label: String, on: Bool) -> some View {
        Button { model.press(button) } label: {
            HStack(spacing: 4) {
                if button == "L" { Image(systemName: icon) }
                Text(button)
                if button == "R" { Image(systemName: icon) }
            }
            .nxFont(.subheadline, weight: .semibold).foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 36).background(Capsule().fill(NX18Palette.row))
        }
        .buttonStyle(.plain)
        .disabled(!on).opacity(on ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

// The page's area: the web view laid out at the console's 1280x720 and scaled to fit the area inside insets, whole and centred (the rest is the letterbox, in the viewer's
// background), as the in-game viewer does (dm/host/web_apple.m -place). The page's own scrolling stays for a page taller than the screen, without bounce. A swipe from the
// left edge goes back; a swipe across the page turns its pages when it assigned L / R (to the left: R, the next)
final class LauncherGuideBox: UIView, UIGestureRecognizerDelegate {
    let web: WKWebView
    var insets: UIEdgeInsets = .zero { didSet { if insets != oldValue { setNeedsLayout() } } }
    var back: (() -> Void)?
    var turn: ((String) -> Void)?   // a swipe across the page: "R" (to the left) or "L" (to the right), the page's own page turning
    private let cue = UIImageView(image: UIImage(systemName: "chevron.backward.circle.fill"))

    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        clipsToBounds = true
        let sv = web.scrollView
        sv.bounces = false; sv.alwaysBounceVertical = false; sv.alwaysBounceHorizontal = false
        sv.contentInsetAdjustmentBehavior = .never
        sv.minimumZoomScale = 1; sv.maximumZoomScale = 1
        addSubview(web)
        cue.tintColor = .white; cue.alpha = 0; cue.frame = CGRect(x: 0, y: 0, width: 44, height: 44); cue.contentMode = .scaleAspectFit
        addSubview(cue)
        let edge = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        edge.edges = .left
        edge.delegate = self
        addGestureRecognizer(edge)
        for d in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(turned(_:)))
            swipe.direction = d
            swipe.delegate = self
            swipe.require(toFail: edge)   // a swipe from the left edge is the back swipe only
            addGestureRecognizer(swipe)
        }
    }
    required init?(coder: NSCoder) { nil }

    // The page's rect in the box
    var pageFrame: CGRect { LauncherGuideFiles.fit(in: bounds.inset(by: insets)) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = pageFrame
        guard r.width > 0 else { return }
        let size = LauncherGuideFiles.pageSize
        web.transform = .identity
        web.bounds = CGRect(origin: .zero, size: size)   // laid out at the console's size, so the page's viewport is 1280x720
        web.center = CGPoint(x: r.midX, y: r.midY)
        web.transform = CGAffineTransform(scaleX: r.width / size.width, y: r.height / size.height)
    }

    @objc private func swiped(_ g: UIScreenEdgePanGestureRecognizer) {
        let x = g.translation(in: self).x, go = x > 72
        switch g.state {
        case .began, .changed:
            cue.center = CGPoint(x: Swift.min(x, 72) - 8 + insets.left, y: bounds.midY)
            cue.alpha = Swift.min(1, x / 72) * (go ? 1 : 0.6)
        case .ended:
            fade()
            if go { back?() }
        default: fade()
        }
    }
    @objc private func turned(_ g: UISwipeGestureRecognizer) { turn?(g.direction == .left ? "R" : "L") }
    private func fade() { UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) { self.cue.alpha = 0 } }
    // The swipe and the page's touches together: the page sees its touches, the swipe still goes back
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// The guide's pages: the index.html under its .htdocs folder, served by LauncherGuideFiles, the shim for the Switch's applet API, links outside the guide refused, the end URL closing
struct LauncherGuideWebView: UIViewRepresentable {
    let index: URL
    let root: URL
    let model: LauncherGuidePageModel
    let close: () -> Void
    var insets: UIEdgeInsets = .zero

    func makeCoordinator() -> Coordinator { Coordinator(root: root, model: model, close: close) }

    func makeUIView(context: Context) -> LauncherGuideBox {
        let web = WKWebView(frame: CGRect(origin: .zero, size: LauncherGuideFiles.pageSize), configuration: LauncherGuideFiles.configuration(files: context.coordinator.files, handler: context.coordinator))
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = context.coordinator
        web.accessibilityLabel = "Game guide"
        let box = LauncherGuideBox(web: web)
        box.backgroundColor = UIColor(NX18Palette.background)
        box.insets = insets
        box.back = { [weak model] in model?.back() }
        box.turn = { [weak model] b in if model?.footer.contains(b) == true { model?.press(b) } }
        model.web = web
        context.coordinator.watch(web)
        guard let start = context.coordinator.files.url(for: index) else {
            fputs("[RED] launcher: the guide's index.html is not inside its folder\n", stderr)
            return box
        }
        LauncherGuideFiles.load(web, start: start)
        return box
    }
    func updateUIView(_ box: LauncherGuideBox, context: Context) {
        context.coordinator.close = close
        box.insets = insets
    }
    static func dismantleUIView(_ box: LauncherGuideBox, coordinator: Coordinator) {
        LauncherGuideFiles.detach(box.web)   // the controller keeps its handler: let it go with the view
        box.web.navigationDelegate = nil
        coordinator.history = nil
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let files: LauncherGuideFiles
        let model: LauncherGuidePageModel
        var close: () -> Void
        var history: NSKeyValueObservation?
        init(root: URL, model: LauncherGuidePageModel, close: @escaping () -> Void) { files = LauncherGuideFiles(root: root); self.model = model; self.close = close }

        // The new web view's history and footer buttons in the model (the guide shown again after the manual starts with none of the old page's). The model changes after the
        // view update that made the web view (makeUIView; .initial calls at once), never during it: SwiftUI warns of a change published during an update and may drop it
        func watch(_ web: WKWebView) {
            let model = model
            Task { @MainActor in if !model.footer.isEmpty { model.footer = [] } }
            history = web.observe(\.canGoBack, options: [.initial, .new]) { w, _ in
                Task { @MainActor [weak w] in
                    let back = w?.canGoBack ?? false
                    if model.canGoBack != back { model.canGoBack = back }
                }
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "nx18State" {
                let f = LauncherGuideFiles.footer(of: message.body)
                if message.frameInfo.isMainFrame, model.footer != f { model.footer = f }
                return
            }
            close()   // nx.endApplet, window.close
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            switch LauncherGuideFiles.navigation(action.request.url) {
            case .allow: return .allow
            case .refuse: return .cancel
            case .end: close(); return .cancel
            }
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if !model.footer.isEmpty { model.footer = [] } }   // a new page: it assigns its own
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

// The switch between the guide and the manual as two chips in the preset chips' look (LauncherRow.swift PresetChips), for the UI font: a segmented control draws its titles in the
// system font whatever the view's font. The page shown is filled cyan; L and R switch them as with the segmented control (LauncherController.swift, scroller.page)
struct LauncherGuideChips: View {
    let pages: [LauncherGuidePage]
    @Binding var page: LauncherGuidePage
    var body: some View {
        HStack(spacing: 8) {
            ForEach(pages) { p in
                Button { page = p } label: {
                    Text(p.title).nxFont(.subheadline, weight: .semibold).lineLimit(1)
                        .foregroundStyle(page == p ? NX18Palette.charcoal : Color.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(page == p ? NX18Palette.cyan : NX18Palette.row))
                        .overlay(Capsule().strokeBorder(page == p ? Color.clear : NX18Palette.separator, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == p ? .isSelected : [])
            }
        }
    }
}

// About this game: the art (or the icon) as a header, the name, the intro and description, the publisher and release date, where the text came from, and the app's version
struct LauncherAboutSheet: View {
    let about: LauncherAbout
    let artwork: LauncherArtwork
    let name: String
    let version: String?
    let scroller: LauncherScroller
    var closeGlyph: NXPadGlyph? = nil   // the controller's B, beside the close button while a controller is connected
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
                    Text(about.name ?? name).nxFont(.title2, weight: .bold).foregroundStyle(.white)
                    if let intro = about.intro { Text(intro).nxFont(.headline).foregroundStyle(.white.opacity(0.92)) }
                    if let d = about.description { Text(d).nxFont(.body).foregroundStyle(.white.opacity(0.85)) }
                    facts
                    if let s = about.sourceLine { Text(s).nxFont(.footnote).foregroundStyle(NX18Palette.muted) }
                    if let v = version { Text("Version \(v)").nxFont(.footnote).foregroundStyle(NX18Palette.muted) }
                    VStack(alignment: .leading, spacing: 2) {   // the controller hints' glyphs (NXButtonGlyph.swift): the credit and the licence's address
                        Text(NX18Credits.buttonIcons)
                        Text(NX18Credits.buttonIconsLicence)
                    }
                    .nxFont(.caption).foregroundStyle(NX18Palette.muted)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 32)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset = y }
        .background(background.ignoresSafeArea())
        .nxTextRoot()
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                HStack(spacing: 8) {
                    if let g = closeGlyph {
                        NXPadGlyphView(g, size: 20, relativeTo: .body).foregroundStyle(NX18Palette.cyan)
                            .padding(4).background(Circle().fill(NX18Palette.charcoal.opacity(0.85)))   // over the art: a dark disc behind it
                    }
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)   // system: symbol
                        .frame(width: 36, height: 36).background(Circle().fill(NX18Palette.charcoal.opacity(0.85)))
                }
                .contentShape(Rectangle())
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
