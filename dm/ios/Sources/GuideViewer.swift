// The settings screen's viewers (Launcher.swift): the game guide, full screen, which shows the game's own guide (its offline HTML pages in a WKWebView, read from the app's files
// only) and the player's manual (manual.pdf in a PDFView), the guide first, with a switch between them when the app has both; and the About this game sheet (about.json's text
// under the art), and Acknowledgements (the app's third-party notices, LauncherNoticesSheet). They close with their close button or the controller's B (LauncherController.swift)
// when nothing is left to go back to.
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
    case guide, manual, mine   // mine: the player's own documents (My files), as the in-game menu's Manual & documents lists them (GameDocumentsViewer.swift)
    var id: String { rawValue }
    var title: String { self == .guide ? "Game guide" : self == .manual ? "Manual" : "My files" }
}

// LauncherGuidePageModel (the guide page shown, its footer buttons and the controller on it) is in LauncherGuideFiles.swift: the in-game viewer on the Mac uses it too

struct LauncherGuideSheet: View {
    let content: LauncherContent
    let scroller: LauncherScroller
    var closeGlyph: NXPadGlyph? = nil   // the controller's B (NXButtonGlyph.swift) while a controller is connected: beside Back while the guide has a page to go back to (B goes back there), else beside the close button
    var turnNames: (l: String, r: String)? = nil   // the connected pad's own names for its shoulders (LB / RB, L1 / R1: NXPadGlyphs.name), on the page-turn buttons; nil: L and R
    let close: () -> Void
    var mine: [GameDocument] = []   // the player's own documents (Launcher.swift playerDocuments): a third chip, My files, a list whose pick opens in the in-game viewer's views
    @State private var page: LauncherGuidePage
    @StateObject private var model = LauncherGuidePageModel()
    @StateObject private var docControl = GameDocumentControl()   // the picked document's controller moves, as in game
    @State private var picked: GameDocumentOpen?
    @State private var listFocus = 0

    init(content: LauncherContent, scroller: LauncherScroller, mine: [GameDocument] = [], closeGlyph: NXPadGlyph? = nil, turnNames: (l: String, r: String)? = nil, close: @escaping () -> Void) {
        self.content = content; self.scroller = scroller; self.mine = mine; self.closeGlyph = closeGlyph; self.turnNames = turnNames; self.close = close
        _page = State(initialValue: content.guide != nil ? .guide : content.manual != nil ? .manual : .mine)
    }
    private var pages: [LauncherGuidePage] {
        LauncherGuidePage.allCases.filter { switch $0 { case .guide: content.guide != nil; case .manual: content.manual != nil; case .mine: !mine.isEmpty } }
    }
    private var onGuide: Bool { page == .guide && content.guide != nil }
    private var inDocument: Bool { page == .mine && picked != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if inDocument {
                    circleButton("chevron.backward", label: "Back", glyph: closeGlyph) { unpick() }   // to My files' list
                } else if onGuide && model.hasBack {
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
                circleButton("xmark", label: "Close", glyph: (onGuide && model.hasBack) || inDocument ? nil : closeGlyph, action: close)
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
                case .mine:
                    myFiles
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
            // The controller: ZL / ZR switch documents; on the guide every other button is the page's (the manual keeps Launcher.swift's: B closes, up / down scroll, L / R switch);
            // on My files up / down and A pick from the list, and a document open takes the in-game viewer's moves (GameDocumentControl), B back to the list
            scroller.pad = { e in
                if e == .zl || e == .zr { scroller.page?(e == .zr ? 1 : -1); return true }
                if page == .mine { return myFilesPad(e) }
                return onGuide ? model.handle(e) : false
            }
        }
        .onDisappear { scroller.page = nil; scroller.scroll = nil; scroller.pad = nil }
    }

    // My files: the player's documents, one row each (the name, what it is and where it is kept); a pick opens it here with the in-game viewer's views
    @ViewBuilder private var myFiles: some View {
        if let open = picked {
            if open.failed {
                Text("This document could not be opened. If it is in iCloud, check the connection and pick it again.")
                    .nxFont(.body).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = open.url {
                GameDocumentContent(doc: open.doc, url: url, control: docControl, close: { unpick() }).id(open.doc.id)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(NX18Palette.cyan)
                    if open.doc.downloading { Text("Downloading from iCloud…").nxFont(.footnote).foregroundStyle(.white.opacity(0.7)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(mine.enumerated()), id: \.element.id) { i, d in
                        Button { listFocus = i; pick(d) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: GameDocuments.symbol(d)).font(.body.weight(.medium)).foregroundStyle(NX18Palette.cyan).frame(width: 28)   // system: symbol
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.title).nxFont(.body, weight: .semibold).foregroundStyle(.white).lineLimit(1)
                                    Text(GameDocuments.note(d)).nxFont(.footnote).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.5))   // system: symbol
                            }
                            .padding(.horizontal, 14).frame(minHeight: 56)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NX18Palette.row))
                            .overlay { if closeGlyph != nil && listFocus == i { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NX18Palette.cyan, lineWidth: 2) } }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(d.title).accessibilityHint(GameDocuments.note(d))
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }
    private func pick(_ d: GameDocument) {
        docControl.take()
        picked = GameDocumentOpen(doc: d)
        Task { @MainActor in
            let url = await GameDocuments.fetch(d)
            guard picked?.doc.id == d.id else { return }
            picked?.url = url; picked?.failed = url == nil
        }
    }
    private func unpick() { docControl.take(); picked = nil }
    private func myFilesPad(_ e: LauncherPadEvent) -> Bool {
        if picked != nil {
            if e == .b { unpick(); return true }
            _ = docControl.handle(e)
            return e != .plus
        }
        switch e {
        case .up: listFocus = Swift.max(0, listFocus - 1)
        case .down: listFocus = Swift.min(mine.count - 1, listFocus + 1)
        case .a: if mine.indices.contains(listFocus) { pick(mine[listFocus]) }
        default: return false   // B closes, L / R switch, as on the manual
        }
        return true
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
    // The page's L or R (its page turning), drawn as the console's shoulder buttons and named as the connected pad names them (turnNames); the page gets "L" / "R" whatever the name.
    // A pad's name goes without the chevron: "LB" takes the chevron's room, so the header keeps its width (in portrait it already squeezes the Game guide / Manual switch)
    private func turnButton(_ button: String, icon: String, label: String, on: Bool) -> some View {
        Button { model.press(button) } label: {
            HStack(spacing: 4) {
                if button == "L" && turnNames == nil { Image(systemName: icon) }
                Text(turnNames.map { button == "L" ? $0.l : $0.r } ?? button).lineLimit(1).fixedSize()
                if button == "R" && turnNames == nil { Image(systemName: icon) }
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

// The switch between the guide and the manual as two chips in the preset chips' look (the Gate's preset chips, LauncherPanel.swift), for the UI font: a segmented control draws its titles in the
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

// About this game (NX18-X2.0 gate-ui.md §18, O5): one sheet from the hero's About button, always shown. Three short sections, About · On NX 18 · Your play, then a footer card.
// Everything comes from the app and this device; nothing is fetched. The sheet follows the look (NX18Look.swift); the art header stays dark and ends in the rail, and no text sits on
// the art or the glass: the title, the section bar, the cards and the footer are on solid surfaces of the look (§18.4). A tap on a section chip jumps there, L / R with a controller
// (scroller.page), up / down scroll, B or ✕ (44 pt) or a swipe down closes.
// Later (F9): the age rating and NX 18's device report and known issue (dm/facts.json), mod credits, the play record (play time, sessions, the battery estimate) and Clear play history
struct LauncherAboutSheet: View {
    let about: LauncherAbout
    let artwork: LauncherArtwork
    let name: String
    let version: String?
    let scroller: LauncherScroller
    var closeGlyph: NXPadGlyph? = nil   // the controller's B, beside the close button while a controller is connected
    var languages: [String] = []        // the game's languages by name (the Game language row's options); hidden with one
    var badges: [String] = []           // what this app offers (60 fps, MetalFX, Auto scaling ...), derived from its rows
    var lastPlayed: Date? = nil         // the save folder's newest file: the fallback for the play record's last session
    var cloudOn = false
    var facts = LauncherFacts()         // dm/facts.json: the age rating, tested line, known issue and mod credits (§18.1)
    var preset: (key: String, title: String)? = nil   // the preset now (the battery estimate is for it only)
    var playRecordURL = PlayRecord.defaultURL
    let close: () -> Void
    @State private var record = PlayRecordData()
    @State private var clearAsk = false
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @State private var sectionY: [String: CGFloat] = [:]   // each section's top in the page's content, measured: the chips and L / R scroll there by offset (position.scrollTo(y:), as the D-pad does)
    @State private var storage: String?
    @State private var notices = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sections = ["About", "On NX 18", "Your play"]
    static var headerWidth: CGFloat = 0   // the art header's width as last laid out (DuoAboutTests: the window's whole width, side safe areas included)
    private var background: Color { NX18PageColor.page(tint: artwork.tint) }

    // The art header, its rail and the title-and-chips band run edge to edge (under the side safe areas, the backgrounds only); text, chips and the close button keep to the
    // safe area, so nothing sits under the camera housing or the rounded corners (owner, 2026-11-16)
    @State private var side = EdgeInsets()
    var body: some View {
        GeometryReader { geo in
            content.onChange(of: geo.safeAreaInsets, initial: true) { side = geo.safeAreaInsets }
        }
    }
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.environment(\.colorScheme, .dark)   // the art header stays dark in every look (§11a.2)
                    // the close button on the art: it scrolls away with the header, so the wide content below never runs under it (owner, 2026-11-17); B, Escape and the
                    // sheet's swipe down close it from anywhere
                    .overlay(alignment: .topTrailing) { closeButton }
                NX18Rails(axis: .horizontal)               // ends in the rail, static (the seam rule)
                sectionBar
                VStack(alignment: .leading, spacing: 18) {
                    aboutSection.id(Self.sections[0]).modifier(SectionTop(name: Self.sections[0], tops: $sectionY))
                    nx18Section.id(Self.sections[1]).modifier(SectionTop(name: Self.sections[1], tops: $sectionY))
                    playSection.id(Self.sections[2]).modifier(SectionTop(name: Self.sections[2], tops: $sectionY))
                    footer
                }
                .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 32)
                .frame(maxWidth: 1200, alignment: .leading)   // out toward the edges (owner, 2026-11-17); a cap only for a very wide window
                .padding(.leading, side.leading).padding(.trailing, side.trailing)
            }
            .coordinateSpace(.named(SectionTop.space))   // the content's own space: a section's top here does not move as the page scrolls
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset = y }
        // the same soft colour field from the art as the Gate's settings side (LauncherBackdrop), under the dark art header it meets at the top
        .background { LauncherBackdrop(wash: artwork.wash, page: background, edge: NX18Palette.background(tint: artwork.tint), blend: .top).ignoresSafeArea() }
        .nxTextRoot()
        .sheet(isPresented: $notices) {
            LauncherNoticesSheet(tint: artwork.tint, scroller: LauncherScroller()) { notices = false }
                .presentationBackground(background)
                .preferredColorScheme(NX18Appearance.current.scheme)
        }
        .onAppear {
            scroller.scroll = { dy in
                if reduceMotion { position.scrollTo(y: Swift.max(0, offset + dy)) } else { withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: Swift.max(0, offset + dy)) } }
            }
            scroller.page = { step in jump(step) }
        }
        .onDisappear { scroller.scroll = nil; scroller.page = nil }
        .task { storage = await Self.storageLine() }
        .task { let u = playRecordURL; record = await Task.detached(priority: .utility) { PlayRecord.read(u) }.value }
        .alert("Clear play history?", isPresented: $clearAsk) {
            Button("Clear", role: .destructive) { PlayRecord.shared.url = playRecordURL; PlayRecord.shared.clear(); record = PlayRecordData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Play time, sessions and the battery estimate start again. Your saves are not touched.")
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            NX18Palette.background(tint: artwork.tint).frame(height: 200)   // the dark base: a light sheet never shows through the art (§11a.2)
            Color.clear.frame(height: 200).overlay {
                if let art = artwork.art { Image(uiImage: art).resizable().scaledToFill() }
                else if let icon = artwork.icon { Image(uiImage: icon).resizable().scaledToFill().blur(radius: 40).opacity(0.6) }
            }
            .clipped()
            let dark = NX18Palette.background(tint: artwork.tint)
            LinearGradient(stops: [.init(color: dark.opacity(0), location: 0.35), .init(color: dark, location: 1)], startPoint: .top, endPoint: .bottom)
            HStack(spacing: 14) {
                if artwork.art == nil, let icon = artwork.icon {
                    Image(uiImage: icon).resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                NX18Mark(height: 18)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            .padding(.leading, side.leading).padding(.trailing, side.trailing)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { Self.headerWidth = $0 }   // for the Duo check that it runs edge to edge
    }

    private var closeButton: some View {
        Button(action: close) {
            HStack(spacing: 8) {
                if let g = closeGlyph {
                    NXPadGlyphView(g, size: 20, relativeTo: .body).foregroundStyle(NX18Palette.cyan)
                        .padding(4).background(Circle().fill(NX18Palette.charcoal.opacity(0.85)))   // over the art: a dark disc behind it
                }
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)   // system: symbol
                    .frame(width: 44, height: 44).background(Circle().fill(NX18Palette.charcoal.opacity(0.85)))   // 44 pt (§18.4); the disc over the art stays dark
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .keyboardShortcut(.cancelAction)
        .padding(12).padding(.trailing, side.trailing)
    }

    // The title and the three section chips on a solid strip of the look's slab (§18.4)
    private var sectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(about.name ?? name).nxFont(.title2, weight: .bold).foregroundStyle(GateColor.text).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chips }
                VStack(alignment: .leading, spacing: 8) { chips }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .padding(.leading, side.leading).padding(.trailing, side.trailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GateColor.slab)
    }
    @ViewBuilder private var chips: some View {
        ForEach(Self.sections, id: \.self) { t in
            Button { go(t) } label: {
                Text(t).nxFont(.subheadline, weight: .semibold).foregroundStyle(GateColor.text)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(Capsule().fill(GateColor.tile))
                    .contentShape(Capsule())
            }
            .buttonStyle(NX18PressStyle())
            .accessibilityLabel(t).accessibilityHint("Goes to this section")
        }
    }
    // To a section's measured top. position.scrollTo(id:) did nothing here on the iPhone, with or without a scroll target layout (owner, 2026-11-18); scrolling to the measured
    // offset is what the D-pad's scroll already does, and works
    private func go(_ t: String) {
        guard let y = sectionY[t] else { return }
        let to = Swift.max(0, y - 8)
        if reduceMotion { position.scrollTo(y: to) } else { withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(y: to) } }
    }
    // L / R: the next or previous section, from the one nearest the top
    private func jump(_ step: Int) {
        let here = Self.sections.lastIndex { (sectionY[$0] ?? .infinity) <= offset + 40 } ?? 0   // the section whose top has passed the top of the page
        let i = Swift.max(0, Swift.min(Self.sections.count - 1, here + step.signum()))
        go(Self.sections[i])
    }

    // MARK: Sections

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("About")
            if let intro = about.intro { Text(intro).nxFont(.headline).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true) }
            if let d = about.description { Text(d).nxFont(.body).foregroundStyle(GateColor.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true) }
            let released = about.released.map { $0.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current)) }
            let dlc = Self.addOnCount()
            card([("Publisher", about.publisher), ("Released", released), ("Version", version),
                  ("Age rating", facts.ratingLine()),
                  ("Add-ons", dlc == 0 ? "No add-ons" : dlc == 1 ? "1 add-on installed" : "\(dlc) add-ons installed"),
                  ("Languages", languages.count > 1 ? languages.joined(separator: ", ") : nil)])
            if let s = about.sourceLine { Text(s).nxFont(.footnote).foregroundStyle(GateColor.muted) }
        }
    }
    private var nx18Section: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("On NX 18")
            if badges.isEmpty { Text("No features to list").nxFont(.footnote).foregroundStyle(GateColor.muted) }
            else {
                FlowRow(spacing: 8) {
                    ForEach(badges, id: \.self) { b in
                        Text(b).nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.text)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(GateColor.tile))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Features: " + badges.joined(separator: ", "))
            }
            card([("Tested", facts.tested ?? "No device report yet"), ("Known issue", facts.knownIssue)])
            if !facts.mods.isEmpty { modsCard }
        }
    }
    // Each packed mod by role, with its author and license; its link opens in the browser only when tapped (nothing loads before)
    private var modsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(facts.mods.enumerated()), id: \.element.id) { i, mod in
                if i > 0 { Rectangle().fill(GateColor.separator).frame(height: 0.5).padding(.leading, 14) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(mod.role).foregroundStyle(GateColor.text)
                        Spacer(minLength: 12)
                        Text(mod.name).foregroundStyle(GateColor.muted).multilineTextAlignment(.trailing)
                    }
                    .nxFont(.subheadline)
                    let by = [mod.author.map { "By \($0)" }, mod.license].compactMap { $0 }
                    Text(by.isEmpty ? "No credit given in the mod's folder" : by.joined(separator: " · ")).nxFont(.footnote).foregroundStyle(GateColor.muted)
                    if let u = mod.url {
                        Link(destination: u) {
                            HStack(spacing: 4) { Text(u.host() ?? u.absoluteString); Image(systemName: "arrow.up.right").font(.caption2.weight(.semibold)) }   // system: symbol
                                .nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.line).frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                        .accessibilityHint("Opens the mod's page in the browser")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .accessibilityElement(children: .combine)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GateColor.tile))
    }
    private var playSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Your play")
            let last = [record.lastPlayed, lastPlayed].compactMap { $0 }.max()
            let estimate = preset.flatMap { p in record.batteryEstimate(preset: p.key).map { PlayRecordText.battery(minutes: $0, preset: p.title) } }
            card([("Play time", record.totalSessions > 0 ? PlayRecordText.duration(minutes: record.totalMinutes) : nil),
                  ("Last played", last.map { PlayRecordText.day($0) } ?? "Not yet"),
                  ("Sessions", record.totalSessions > 0 ? PlayRecordText.sessions(record.totalSessions) : nil),
                  ("Battery", estimate),
                  ("Cloud saves", cloudOn ? "On" : "Off"), ("Storage", storage ?? "…")])
            if record.totalSessions > 0 {
                Button { clearAsk = true } label: {
                    HStack { Text("Clear play history").nxFont(.subheadline, weight: .semibold); Spacer() }
                        .foregroundStyle(GateColor.line).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(NX18PressStyle())
                .accessibilityHint("Play time, sessions and the battery estimate start again; saves are kept")
            }
            Text("Kept on this device only. Nothing is sent anywhere.").nxFont(.caption).foregroundStyle(GateColor.muted)
        }
    }

    // The footer card (§18.1): the personal-build line, NX 18's release and build, the button-icon credit and Acknowledgements
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Personal build: made from your own legally owned and acquired game and keys. Please don't share it.")
                .nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.text).fixedSize(horizontal: false, vertical: true)
            if let l = nx18FooterLine { Text(verbatim: l).nxFont(.footnote).foregroundStyle(GateColor.muted) }
            VStack(alignment: .leading, spacing: 2) {   // the controller hints' glyphs (NXButtonGlyph.swift): the credit and the licence's address
                Text(NX18Credits.buttonIcons)
                Text(NX18Credits.buttonIconsLicence)
            }
            .nxFont(.caption).foregroundStyle(GateColor.muted)
            if LauncherNotices.available {
                Button { notices = true } label: {
                    HStack { Text("Acknowledgements").nxFont(.subheadline, weight: .semibold); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }   // system: symbol
                        .foregroundStyle(GateColor.line).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(NX18PressStyle())
                .accessibilityHint("The third-party notices")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(GateColor.tile))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).nxFont(.footnote, weight: .semibold).foregroundStyle(GateColor.text).textCase(.uppercase).accessibilityAddTraits(.isHeader)   // text primary: no accent text on the bare page (§11a.4)
    }
    @ViewBuilder private func card(_ rows: [(String, String?)]) -> some View {
        let shown = rows.compactMap { r in r.1.map { (r.0, $0) } }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(GateColor.separator).frame(height: 0.5).padding(.leading, 14) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.0).foregroundStyle(GateColor.text)
                        Spacer(minLength: 12)
                        Text(r.1).foregroundStyle(GateColor.muted).multilineTextAlignment(.trailing)
                    }
                    .nxFont(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GateColor.tile))
        }
    }

    // The add-ons the build packed: <App>/aoc/<index>/ (build_ipa.sh AOC), counted as the sheet opens
    static func addOnCount(bundle: Bundle = .main) -> Int {
        guard let root = bundle.resourceURL?.appendingPathComponent("aoc"),
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
    }
    // "Game 14.2 GB · Saves 3 MB · Caches 410 MB", read off the main actor once per open
    static func storageLine() async -> String {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            func size(_ u: URL?) -> Int64 {
                guard let u, let e = fm.enumerator(at: u, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
                var n: Int64 = 0
                for case let f as URL in e { n += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
                return n
            }
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            let saves = size(docs?.appendingPathComponent("save")) + size(docs?.appendingPathComponent("save-backups"))
            let caches = size(docs?.appendingPathComponent("pso_archive")) + size(fm.urls(for: .cachesDirectory, in: .userDomainMask).first)
            let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false   // "0 bytes", never "Zero KB"
            return "Game \(f.string(fromByteCount: size(Bundle.main.bundleURL))) · Saves \(f.string(fromByteCount: saves)) · Caches \(f.string(fromByteCount: caches))"
        }.value
    }
}

// Chips that wrap onto the next line when the width runs out
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing; line = Swift.max(line, s.height); widest = Swift.max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = Swift.max(line, s.height)
        }
    }
}

// Acknowledgements: the third-party notices every app carries, dm/ThirdPartyNotices.txt in the bundle (dm/tools/third_party_notices.py makes it from the repository's license files;
// build_ipa.sh copies it in). Each piece of others' work in the app with its author, what NX 18 uses it for and its license text, which keeps its authors' fixed-width layout
enum LauncherNotices {
    // <App>/dm/ThirdPartyNotices.txt; at the bundle's top only in the Duo harness (dm/ios/tests/duo/project.yml), which has no dm folder
    static var url: URL? {
        Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt", subdirectory: "dm") ?? Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")
    }
    static var available: Bool { url != nil }

    enum Kind: Sendable { case title, heading, meta, prose, license }
    struct Block: Identifiable, Sendable { let id: Int; let kind: Kind; let text: String }

    /// The file as blocks to draw, one per paragraph: the title, then each entry's number and name, its author and license, what NX 18 uses it for, and its license text.
    /// The file's rule lines ("====" before an entry, "----" after its use) mark where each kind starts
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var inLicense = false
        func add(_ k: Kind, _ s: String) { if !s.isEmpty { out.append(Block(id: out.count, kind: k, text: s)) } }
        for para in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            var lines = para.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.first?.isEmpty == true { lines.removeFirst() }
            while lines.last?.isEmpty == true { lines.removeLast() }
            guard let first = lines.first else { continue }
            if out.isEmpty { add(.title, lines.joined(separator: "\n")); continue }
            if first.hasPrefix("====") {   // an entry: "<n>. <name>", then its author, license and address; or the closing line
                inLicense = false
                lines.removeFirst()
                guard let head = lines.first else { continue }
                if head.first?.isNumber == true { add(.heading, head); add(.meta, lines.dropFirst().joined(separator: "\n")) }
                else { add(.meta, lines.joined(separator: "\n")) }
            } else if lines.last?.hasPrefix("----") == true {   // what NX 18 uses it for; its license text follows
                add(.prose, lines.dropLast().joined(separator: "\n"))
                inLicense = true
            } else {
                add(inLicense ? .license : .prose, lines.joined(separator: "\n"))
            }
        }
        return out
    }
}

struct LauncherNoticesSheet: View {
    let tint: NX18RGB?
    let scroller: LauncherScroller
    var closeGlyph: NXPadGlyph? = nil   // the controller's B, beside the close button while a controller is connected
    let close: () -> Void
    @State private var blocks: [LauncherNotices.Block] = []
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var background: Color { NX18PageColor.page(tint: tint) }   // the look's page (NX18Look.swift)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {   // lazy: the texts run to about 700 lines
                NX18Mark(height: 18).padding(.bottom, 4).accessibilityHidden(true)
                ForEach(blocks) { b in block(b) }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset = y }
        .background(background.ignoresSafeArea())
        .nxTextRoot()
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                HStack(spacing: 8) {
                    if let g = closeGlyph { NXPadGlyphView(g, size: 20, relativeTo: .body).foregroundStyle(GateColor.line) }
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(GateColor.text)   // system: symbol
                        .frame(width: 44, height: 44).background(Circle().fill(GateColor.tile))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
            .padding(14)
        }
        .task {
            guard blocks.isEmpty, let url = LauncherNotices.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            blocks = LauncherNotices.blocks(text)
        }
        .onAppear { scroller.scroll = { dy in
            if reduceMotion { position.scrollTo(y: Swift.max(0, offset + dy)) } else { withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: Swift.max(0, offset + dy)) } }
        } }
        .onDisappear { scroller.scroll = nil }
    }

    @ViewBuilder private func block(_ b: LauncherNotices.Block) -> some View {
        switch b.kind {
        case .title:
            Text(b.text).nxFont(.title2, weight: .bold).foregroundStyle(GateColor.text).accessibilityAddTraits(.isHeader)
        case .heading:
            VStack(alignment: .leading, spacing: 10) {
                GateColor.separator.frame(height: 1)
                Text(b.text).nxFont(.headline, weight: .semibold).foregroundStyle(GateColor.text).accessibilityAddTraits(.isHeader)
            }
            .padding(.top, 14)
        case .meta:
            Text(b.text).nxFont(.footnote).foregroundStyle(GateColor.muted)
        case .prose:
            Text(b.text).nxFont(.callout).foregroundStyle(GateColor.text.opacity(0.9))
        case .license:
            Text(b.text).nxMono(.caption).foregroundStyle(GateColor.muted).textSelection(.enabled)
        }
    }
}

// A guide section's top in the page's content (GuideViewer.sectionY), for its chip and L / R
private struct SectionTop: ViewModifier {
    nonisolated static let space = "guideContent"   // a constant: read from the geometry closure, which is Sendable
    let name: String
    @Binding var tops: [String: CGFloat]
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { tops[name] = $0 }
    }
}
