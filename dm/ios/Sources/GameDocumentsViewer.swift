// Manual & documents while the game runs (docs/frontends.md, Documents in the game): the in-game menu's row of that name (GameMenu.swift; a door on the panel's first page) opens a
// page of the documents GameDocuments.swift lists (the manual, the game's guide, then the player's own guides and maps from Documents/Companion and the NX 18 folder), and a pick
// opens it in a viewer over the game, drawn by the panel's host (GameMenuPanel.swift on the iPhone and iPad, dm/mac/GameMenuMac.swift on the Mac, unscaled there so the pages
// stay sharp). The game keeps running behind it and its input stays held, as under the menu: the viewer is part of the panel, so Home closes both and nothing pressed to close
// it reaches the game.
//   The manual and PDFs: PDFKit (pages drawn as they come into view). Pictures: decoded off the main thread at most 4096 px on a side, with pinch, drag and a double tap to zoom.
//   Text and Markdown: a lazy list of paragraphs, the first 4 MB. HTML pages and the guide: offline, through LauncherGuideFiles (its scheme, Content-Security-Policy and block
//   list), the guide at the console's 1280x720 as before play.
//   The controller: the D-pad and stick scroll (a picture: move it), left / right and L / R turn a PDF's pages, X / Y zoom in and out, A fits again, ZL / ZR go to the previous or
//   next document (as the guide viewer switches the guide and the manual), B goes back to the list, + closes the menu; on the guide every other button is the page's, as before
//   play (LauncherGuidePageModel), and its B goes back a page, then to the list. Touch on the iPhone; the mouse, trackpad and the panel's keys on the Mac.
// Nothing is read until the menu opens (the listing, once every few seconds at most) and nothing of a document until it is picked; an iCloud placeholder is downloaded then
// (GameDocuments.fetch). Logs say what kind was opened and from where, never a name or a path
import Combine
import ImageIO
import PDFKit
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Where this game's documents are: the app's manual and guide, the folder Beam's Send My Files fills (the iPhone and iPad only), the NX 18 folder and the title ID
struct GameDocumentPlaces: Sendable {
    var manual: URL?, guide: URL?, guideRoot: URL?, companion: URL?, nx18: URL?
    var titleID: String?

    // Reads the app's folders (the guide's language folders): off the main thread. lang: the game language (DM_LANG), for the guide's language
    static func find(lang: String?) -> GameDocumentPlaces {
        var p = GameDocumentPlaces()
        p.titleID = Bundle.main.object(forInfoDictionaryKey: "DMTitleID") as? String
        #if os(iOS)
        let dir = ProcessInfo.processInfo.environment["DM_APP_DM"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        let c = LauncherContent.find(dir: dir, lang: lang)
        p.manual = c.manual; p.guide = c.guide; p.guideRoot = c.guideRoot
        p.companion = GameDocuments.companionFolder()
        p.nx18 = NX18Profile.folderURL()
        #else
        if let res = Bundle.main.resourceURL {
            let pdf = res.appendingPathComponent("dm/manual.pdf")
            if FileManager.default.isReadableFile(atPath: pdf.path) { p.manual = pdf }
            if let g = macGuide(res.appendingPathComponent("html"), lang: lang ?? (Bundle.main.object(forInfoDictionaryKey: "DMLanguage") as? String)) { p.guide = g.index; p.guideRoot = g.root }
        }
        p.nx18 = GameDocuments.macNX18Folder()
        #endif
        return p
    }

    #if os(macOS)
    // The Mac app's guide (dm/mac/pack_app.py: Resources/html/html<n>/html-document/htmlcontents.htdocs/html/<language>/index.html), as the settings window finds it
    // (dm/mac/Launcher.swift LauncherExtras.guidePage, which the host does not build): the game language's folder, else USen, EUen, else the first with an index.html
    static func macGuide(_ html: URL, lang: String?) -> (index: URL, root: URL)? {
        let fm = FileManager.default
        let docs = ((try? fm.contentsOfDirectory(atPath: html.path)) ?? []).compactMap { n -> (Int, String)? in
            guard n.hasPrefix("html"), let i = Int(n.dropFirst(4)) else { return nil }
            return (i, n)
        }.sorted { $0.0 < $1.0 }
        let map = ["en-US": "USen", "en-GB": "EUen", "ja": "JPja", "fr": "EUfr", "fr-CA": "USfr", "de": "EUde", "es": "EUes", "es-419": "USes", "it": "EUit", "nl": "EUnl",
                   "pt": "EUpt", "pt-BR": "USpt", "ru": "EUru", "ko": "KRko", "zh-Hans": "CNzh", "zh-Hant": "TWzh"]
        var wanted: [String] = []
        for w in [lang.flatMap { map[$0] ?? map[String($0.prefix { $0 != "-" })] }, "USen", "EUen"] { if let w, !wanted.contains(w) { wanted.append(w) } }
        for (_, n) in docs {
            let htdocs = html.appendingPathComponent(n).appendingPathComponent("html-document/htmlcontents.htdocs")
            let langs = htdocs.appendingPathComponent("html")
            let all = ((try? fm.contentsOfDirectory(atPath: langs.path)) ?? []).sorted()
            for l in wanted + all {
                let index = langs.appendingPathComponent(l).appendingPathComponent("index.html")
                if fm.isReadableFile(atPath: index.path) { return (index, htdocs) }
            }
        }
        return nil
    }
    #endif
}

// The documents as the menu last listed them. The listing runs when the menu opens (GameMenu.swift gameDocumentsRow asks; at most once every 3 s, one at a time), off the main
// thread; the menu's rows are built again when it changes (changed: the open panel's refresh)
@MainActor final class GameDocumentsStore {
    static let shared = GameDocumentsStore()
    private(set) var docs: [GameDocument] = []
    private(set) var listed = false
    private var task: Task<Void, Never>?
    private var last: ContinuousClock.Instant?
    var changed: (() -> Void)?       // the panel's refresh (GameMenuPanel.swift)
    var menuChanged: (() -> Void)?   // DM_GAME_MENU=system: the open UIMenu's (GameMenu.swift refreshVisibleSystemMenu)

    func refresh() {
        if task != nil { return }
        if let last, ContinuousClock.now - last < .seconds(3) { return }
        last = .now
        let lang = gameMenuModel?.values["DM_LANG"] ?? ProcessInfo.processInfo.environment["DM_LANG"]
        task = Task { [weak self] in
            let p = await Task.detached(priority: .userInitiated) { GameDocumentPlaces.find(lang: lang) }.value
            let found = await GameDocuments.load(manual: p.manual, guide: p.guide, guideRoot: p.guideRoot, companion: p.companion, nx18: p.nx18, titleID: p.titleID)
            guard let self else { return }
            self.task = nil
            let first = !self.listed
            self.listed = true
            guard first || found != self.docs else { return }
            self.docs = found
            fputs(GameDocuments.summary(found) + "\n", stderr)
            self.changed?()
            self.menuChanged?()
        }
    }
}

// MARK: The menu's row

// Manual & documents: a page of every document, each row opening it in the viewer. nil while there is none (no manual, guide or document of the player's), and until the first
// listing has come back (a moment after the menu opens: the row then appears)
@MainActor func gameDocumentsRow() -> GameMenuItem? {
    let store = GameDocumentsStore.shared
    store.refresh()
    let docs = store.docs
    guard GameDocuments.offered(docs) else { return nil }
    let rows = docs.map { d in
        GameMenuItem(id: "doc:" + d.id, title: d.title, subtitle: GameDocuments.note(d), symbol: GameDocuments.symbol(d)) { _ in gameDocumentOpen(d) }
    }
    return GameMenuItem(id: "docs", title: "Manual & documents", subtitle: GameDocuments.menuNote(docs), symbol: "book.closed",
                        kind: .submenu([GameMenuSection(id: "docs.all", inline: false, items: rows)]))
}

// A document's row picked: its viewer over the panel. From the UIMenu (DM_GAME_MENU=system, no panel up) the panel opens for it first, once the UIMenu has gone, and B then closes both
@MainActor func gameDocumentOpen(_ d: GameDocument) {
    if let m = GameMenuPanelModel.current, !m.closed { m.openDocument(d); return }
    #if os(iOS)
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(350))   // the UIMenu's close (DmGamepad.m menuClosed) before the panel's open
        if dm_gamepad_panel_open_now(), let m = GameMenuPanelModel.current, !m.closed { m.openDocument(d, direct: true) }
    }
    #endif
}

// MARK: The viewer

// The document the viewer shows: url once it is ready to read (a placeholder brought down), failed when it could not be
struct GameDocumentOpen: Equatable {
    let doc: GameDocument
    var direct = false   // opened from the UIMenu: B closes the panel too
    var url: URL? = nil
    var failed = false
}

// What the controller does to the document shown: each kind of view sets what it takes as it is made (the panel model clears them as another document opens)
@MainActor final class GameDocumentControl: ObservableObject {
    @Published var status: String?               // "Page 3 of 40"
    var move: ((CGFloat, CGFloat) -> Void)?      // the D-pad and stick: -1 / 1 on one axis
    var page: ((Int) -> Void)?                   // L / R
    var zoom: ((Int) -> Void)?                   // X in, Y out
    var fit: (() -> Void)?                       // A
    var guide: LauncherGuidePageModel?           // the guide shown: its page takes the buttons

    func take() { status = nil; move = nil; page = nil; zoom = nil; fit = nil; guide = nil }

    // true when the document took it; B, +, ZL and ZR are the viewer's (the guide's B goes back a page first: its model closes the viewer when there is none)
    func handle(_ e: LauncherPadEvent) -> Bool {
        switch e {
        case .plus, .zl, .zr: return false
        default: break
        }
        if let guide { return guide.handle(e) }
        switch e {
        case .up: move?(0, -1)
        case .down: move?(0, 1)
        case .left: move?(-1, 0)
        case .right: move?(1, 0)
        case .l: page?(-1)
        case .r: page?(1)
        case .x: zoom?(1)
        case .y: zoom?(-1)
        case .a: fit?()
        case .b: return false
        case .minus, .plus, .zl, .zr: break
        }
        return true
    }
}

// The viewer over the game: a dark card nearly the window's size (the game shows at its edges and keeps running), its header (back, the name, the page, zoom, the other
// documents, close), the document, and the controller's hints. A tap beside the card goes back to the list
struct GameDocumentViewer: View {
    @ObservedObject var model: GameMenuPanelModel
    @ObservedObject var control: GameDocumentControl
    let open: GameDocumentOpen
    var chrome: CGFloat = 1   // the header's size: larger on the Mac, whose panel is scaled up (GameMenuMac.swift) where this is not

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.closeDocument() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                header
                MenuColor.separator.frame(height: 1)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.padConnected { strip }
            }
            .background(MenuColor.slab)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(MenuColor.hairline, lineWidth: 1))
            .padding(8)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { model.closeDocument() }
        }
        .nxTextRoot()
    }

    private var docs: [GameDocument] { GameDocumentsStore.shared.docs }

    private var header: some View {
        HStack(spacing: 10 * chrome) {
            button("chevron.left", "Back", glyph: model.padConnected ? model.padGlyphs.glyph(.b) : nil) { model.closeDocument() }
            VStack(alignment: .leading, spacing: 2) {
                Text(open.doc.title).nxFont(size: 15 * chrome, weight: .semibold).foregroundStyle(MenuColor.text).lineLimit(1)
                Text(control.status ?? GameDocuments.note(open.doc)).nxFont(size: 11 * chrome).foregroundStyle(MenuColor.muted).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            if zooms {
                button("minus.magnifyingglass", "Zoom out") { control.zoom?(-1) }
                button("plus.magnifyingglass", "Zoom in") { control.zoom?(1) }
            }
            if docs.count > 1 {
                button("chevron.up", "Previous document") { model.stepDocument(-1) }
                button("chevron.down", "Next document") { model.stepDocument(1) }
            }
            button("xmark", "Close menu", tint: MenuColor.second) { model.close() }
        }
        .padding(.horizontal, 8 * chrome).padding(.vertical, 4 * chrome)
    }
    private var zooms: Bool {
        guard open.url != nil else { return false }
        switch open.doc.kind { case .guide: return false; default: return true }
    }

    private func button(_ icon: String, _ label: String, glyph: NXPadGlyph? = nil, tint: Color = MenuColor.line, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let glyph { NXPadGlyphView(glyph, size: 15 * chrome, relativeTo: .caption2).foregroundStyle(MenuColor.line) }
                Image(systemName: icon).font(.system(size: 14 * chrome, weight: .semibold)).foregroundStyle(tint)   // system: symbol
            }
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var content: some View {
        if open.failed {
            message("This document could not be opened.", "If it is in iCloud, check the connection and pick it again.")
        } else if let url = open.url {
            GameDocumentContent(doc: open.doc, url: url, control: control, close: { model.closeDocument() })
                .id(open.doc.id)
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(MenuColor.line)
                if open.doc.downloading { Text("Downloading from iCloud…").nxFont(size: 13 * chrome).foregroundStyle(MenuColor.muted) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func message(_ title: String, _ note: String) -> some View {
        VStack(spacing: 6) {
            Text(title).nxFont(size: 15 * chrome, weight: .semibold).foregroundStyle(MenuColor.text)
            Text(note).nxFont(size: 12 * chrome).foregroundStyle(MenuColor.muted).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // The buttons, while a controller is connected
    private var strip: some View {
        let g = model.padGlyphs
        let guide = open.doc.kind == .guide
        return HStack(spacing: 12 * chrome) {
            hint(g.glyph(.b), guide ? "Back a page" : "Back")
            if !guide {
                if open.doc.kind == .manual || open.doc.kind == .pdf { word("\(g.name(NXShoulder.l)) \(g.name(NXShoulder.r)) Page") }
                if zooms { hint(g.glyph(.x), "Zoom in"); hint(g.glyph(.y), "Zoom out"); hint(g.glyph(.a), "Fit") }
            }
            if docs.count > 1 { word("ZL ZR Document") }
            hint(g.glyph(.plus), "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityHidden(true)
    }
    private func hint(_ glyph: NXPadGlyph, _ text: String) -> some View {
        HStack(spacing: 4) { NXPadGlyphView(glyph, size: 14 * chrome, relativeTo: .caption2).foregroundStyle(MenuColor.line); word(text) }.fixedSize()
    }
    private func word(_ s: String) -> some View { Text(s).nxFont(size: 11 * chrome).foregroundStyle(MenuColor.muted).lineLimit(1).fixedSize() }
}

// The document itself, by kind
struct GameDocumentContent: View {
    let doc: GameDocument
    let url: URL
    let control: GameDocumentControl
    let close: () -> Void

    var body: some View {
        switch doc.kind {
        case .manual, .pdf: GameDocPDF(url: url, control: control)
        case .picture: GameDocPicture(url: url, control: control)
        case .text: GameDocText(url: url, control: control)
        case .web: GameDocWeb(url: url, control: control, close: close)
        case .guide: GameDocGuide(index: url, root: doc.root ?? url.deletingLastPathComponent(), control: control, close: close)
        }
    }
}

// MARK: PDF (the manual and the player's PDFs): PDFKit, one page after another, fitted to the width; it draws the pages as they come into view

#if os(iOS)
typealias GameDocRepresentable = UIViewRepresentable
#else
typealias GameDocRepresentable = NSViewRepresentable
#endif

struct GameDocPDF: GameDocRepresentable {
    let url: URL
    let control: GameDocumentControl

    // The page line under the name ("Page 3 of 40"), as PDFKit reports the page shown
    @MainActor final class Coordinator {
        var observer: (any NSObjectProtocol)?
        weak var view: PDFView?
        var control: GameDocumentControl?
        func status() {
            guard let v = view, let d = v.document, let p = v.currentPage else { return }
            control?.status = "Page \(d.index(for: p) + 1) of \(d.pageCount)"
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func make(_ context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        #if os(iOS)
        v.backgroundColor = UIColor(MenuColor.slab)
        #else
        v.backgroundColor = NSColor(MenuColor.slab)
        #endif
        v.document = PDFDocument(url: url)
        if v.document == nil { fputs("[RED] documents: a PDF cannot be read\n", stderr) }
        let c = context.coordinator
        c.view = v; c.control = control
        c.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak c] _ in MainActor.assumeIsolated { c?.status() } }
        Task { @MainActor [weak c] in c?.status() }   // after this update
        control.move = { [weak v] dx, dy in
            guard let v else { return }
            if dx < 0 { v.goToPreviousPage(nil) } else if dx > 0 { v.goToNextPage(nil) } else { Self.scroll(v, by: dy * 140) }
        }
        control.page = { [weak v] s in if s < 0 { v?.goToPreviousPage(nil) } else { v?.goToNextPage(nil) } }
        control.zoom = { [weak v] s in
            guard let v else { return }
            let f = v.scaleFactor * (s > 0 ? 1.25 : 0.8)
            v.autoScales = false
            v.scaleFactor = Swift.min(Swift.max(f, v.minScaleFactor), v.maxScaleFactor)
        }
        control.fit = { [weak v] in v?.autoScales = true }
        return v
    }
    private static func dismantle(_ coordinator: Coordinator) {
        if let o = coordinator.observer { NotificationCenter.default.removeObserver(o) }
        coordinator.observer = nil
    }

    #if os(iOS)
    func makeUIView(context: Context) -> PDFView { make(context) }
    func updateUIView(_ v: PDFView, context: Context) {}
    static func dismantleUIView(_ v: PDFView, coordinator: Coordinator) { dismantle(coordinator) }
    static func scroll(_ v: PDFView, by dy: CGFloat) { scrollView(in: v)?.nudge(by: dy) }
    private static func scrollView(in v: UIView) -> UIScrollView? {
        for s in v.subviews {
            if let sv = s as? UIScrollView { return sv }
            if let sv = scrollView(in: s) { return sv }
        }
        return nil
    }
    #else
    func makeNSView(context: Context) -> PDFView { make(context) }
    func updateNSView(_ v: PDFView, context: Context) {}
    static func dismantleNSView(_ v: PDFView, coordinator: Coordinator) { dismantle(coordinator) }
    static func scroll(_ v: PDFView, by dy: CGFloat) {
        guard let doc = v.documentView, let sv = doc.enclosingScrollView else { return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        let room = Swift.max(0, doc.frame.height - clip.bounds.height)
        o.y = Swift.min(Swift.max(o.y + (doc.isFlipped ? dy : -dy), 0), room)
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
    }
    #endif
}

// MARK: Pictures: decoded off the main thread, at most 4096 px on a side; pinch or X / Y zoom, a drag or the D-pad moves a zoomed picture, a double tap or A fits it again

struct GameDocPicture: View {
    let url: URL
    let control: GameDocumentControl
    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var area: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func decode(_ url: URL, side: Int = 4096) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                  kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(zoom * pinch)
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .accessibilityLabel("Picture")
            } else if failed {
                Text("This picture cannot be shown.").nxFont(.footnote).foregroundStyle(MenuColor.muted)
            } else {
                ProgressView().tint(MenuColor.line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
        .gesture(MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }.onEnded { v in set(zoom * v.magnification) })
        .simultaneousGesture(DragGesture().updating($drag) { v, s, _ in s = v.translation }.onEnded { v in move(v.translation) })
        .onTapGesture(count: 2) { set(zoom > 1.01 ? 1 : 2.5) }
        .task {
            let u = url
            let cg = await Task.detached(priority: .userInitiated) { Self.decode(u) }.value
            if let cg { image = cg } else { failed = true; fputs("[RED] documents: a picture cannot be decoded\n", stderr) }
        }
        .onAppear {
            control.zoom = { s in set(zoom * (s > 0 ? 1.4 : 1 / 1.4)) }
            control.fit = { set(1) }
            control.move = { dx, dy in move(CGSize(width: -dx * area.width * 0.15, height: -dy * area.height * 0.15)) }
        }
    }

    private func animate(_ f: () -> Void) { if reduceMotion { f() } else { withAnimation(.easeOut(duration: 0.15), f) } }
    private func set(_ z: CGFloat) {
        let z = Swift.min(Swift.max(z, 1), 8)
        animate { zoom = z; pan = clamped(pan) }
    }
    private func move(_ by: CGSize) { animate { pan = clamped(CGSize(width: pan.width + by.width, height: pan.height + by.height)) } }
    // A zoomed picture moves as far as its edges; at its size it stays centred
    private func clamped(_ p: CGSize) -> CGSize {
        let mx = Swift.max(0, area.width * (zoom - 1) / 2), my = Swift.max(0, area.height * (zoom - 1) / 2)
        return CGSize(width: Swift.min(Swift.max(p.width, -mx), mx), height: Swift.min(Swift.max(p.height, -my), my))
    }
}

// MARK: Text and Markdown: the first 4 MB, as paragraphs in a lazy list (a long file draws only what shows); Markdown's inline styles and # headings; X / Y size the text

struct GameDocText: View {
    let url: URL
    let control: GameDocumentControl
    @State private var blocks: [String]?
    @State private var size: CGFloat = 16
    @State private var position = ScrollPosition(edge: .top)
    @State private var at = CGPoint.zero    // x: the offset, y: the most it can be
    @State private var height: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func read(_ url: URL, markdown: Bool) -> [String]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let cut = data.prefix(4 << 20)
        let text = String(data: cut, encoding: .utf8) ?? String(decoding: cut, as: UTF8.self)
        return GameDocuments.blocks(text, markdown: markdown)   // a heading line ends its block (GameDocuments.blocks)
    }
    private var markdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: size * 0.7) {
                ForEach(Array((blocks ?? []).enumerated()), id: \.offset) { _, b in paragraph(b) }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self) { CGPoint(x: $0.contentOffset.y, y: Swift.max(0, $0.contentSize.height - $0.containerSize.height)) } action: { _, p in at = p }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .overlay { if blocks == nil { ProgressView().tint(MenuColor.line) } }
        .task {
            let u = url, md = markdown
            blocks = await Task.detached(priority: .userInitiated) { Self.read(u, markdown: md) }.value ?? ["This file cannot be read."]
        }
        .onAppear {
            control.move = { dx, dy in scroll(dy != 0 ? dy * 120 : dx * Swift.max(height - 60, 60)) }
            control.page = { s in scroll(CGFloat(s) * Swift.max(height - 60, 60)) }
            control.zoom = { s in size = Swift.min(Swift.max(size + CGFloat(2 * s), 12), 32) }
            control.fit = { size = 16 }
        }
    }

    private func scroll(_ dy: CGFloat) {
        let y = Swift.min(Swift.max(at.x + dy, 0), at.y)
        if reduceMotion { position.scrollTo(y: y) } else { withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(y: y) } }
    }

    @ViewBuilder private func paragraph(_ b: String) -> some View {
        if markdown, !b.contains("\n"), let h = GameDocuments.heading(Substring(b)) {
            let level = h.level
            Text(h.text)
                .nxFont(size: size * (level <= 1 ? 1.45 : level == 2 ? 1.25 : 1.1), weight: .bold).foregroundStyle(MenuColor.text)
                .accessibilityAddTraits(.isHeader)
        } else if markdown, let a = try? AttributedString(markdown: b, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(a).nxFont(size: size).foregroundStyle(MenuColor.text).textSelection(.enabled)
        } else {
            Text(verbatim: b).nxFont(size: size).foregroundStyle(MenuColor.text).textSelection(.enabled)
        }
    }
}

// MARK: Web pages: the player's HTML, offline (LauncherGuideFiles: served from its own folder through nx18guide://, a Content-Security-Policy and the block list keep it off the
// network, links outside refused); and the guide on the Mac (on the iPhone and iPad it is GuideViewer.swift's LauncherGuideWebView, as before play)

@MainActor final class GameDocWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let files: LauncherGuideFiles
    let model: LauncherGuidePageModel?   // the guide's: its footer buttons and history
    var close: () -> Void
    private var history: NSKeyValueObservation?

    init(root: URL, fontDir: URL?, model: LauncherGuidePageModel?, quiet: Bool, close: @escaping () -> Void) {
        files = LauncherGuideFiles(root: root, fontDir: fontDir)
        files.quiet = quiet
        self.model = model; self.close = close
    }
    func makeWeb(size: CGSize) -> WKWebView {
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: LauncherGuideFiles.configuration(files: files, handler: self))
        web.navigationDelegate = self
        if let model {
            model.web = web
            model.close = close
            Task { @MainActor in if !model.footer.isEmpty { model.footer = [] } }
            history = web.observe(\.canGoBack, options: [.initial, .new]) { w, _ in
                Task { @MainActor [weak w] in
                    let back = w?.canGoBack ?? false
                    if model.canGoBack != back { model.canGoBack = back }
                }
            }
        }
        return web
    }
    func start(_ web: WKWebView, at file: URL) {
        guard let start = files.url(for: file) else { fputs("[RED] documents: a page is not inside its folder\n", stderr); return }
        LauncherGuideFiles.load(web, start: start)
    }
    func release(_ web: WKWebView) {
        LauncherGuideFiles.detach(web)
        web.navigationDelegate = nil
        web.stopLoading()
        history = nil
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nx18State" {
            let f = LauncherGuideFiles.footer(of: message.body)
            if let model, message.frameInfo.isMainFrame, model.footer != f { model.footer = f }
            return
        }
        close()   // nx.endApplet, window.close
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch LauncherGuideFiles.navigation(action.request.url, quiet: files.quiet) {   // a page of the player's: its end logged without the link's path
        case .allow: return .allow
        case .refuse: return .cancel
        case .end: close(); return .cancel
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if let model, !model.footer.isEmpty { model.footer = [] } }   // a new page: it assigns its own
}

// The player's HTML, filling the card; the D-pad scrolls it, L / R a screen, X / Y zoom
struct GameDocWeb: GameDocRepresentable {
    let url: URL
    let control: GameDocumentControl
    let close: () -> Void

    func makeCoordinator() -> GameDocWebCoordinator { GameDocWebCoordinator(root: url.deletingLastPathComponent(), fontDir: nil, model: nil, quiet: true, close: close) }
    private func make(_ context: Context) -> WKWebView {
        let web = context.coordinator.makeWeb(size: CGSize(width: 800, height: 600))
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = UIColor(MenuColor.slab)
        #else
        web.underPageBackgroundColor = NSColor(MenuColor.slab)
        #endif
        #if os(iOS)
        web.accessibilityLabel = "Web page"
        #else
        web.setAccessibilityLabel("Web page")
        #endif
        control.move = { [weak web] dx, dy in web?.evaluateJavaScript("window.scrollBy(\(Int(dx * 90)), \(Int(dy * 120)))", completionHandler: nil) }
        control.page = { [weak web] s in web?.evaluateJavaScript("window.scrollBy(0, \(s) * window.innerHeight * 0.9)", completionHandler: nil) }
        control.zoom = { [weak web] s in guard let web else { return }; web.pageZoom = Swift.min(Swift.max(web.pageZoom * (s > 0 ? 1.15 : 1 / 1.15), 0.5), 3) }
        control.fit = { [weak web] in web?.pageZoom = 1 }
        context.coordinator.start(web, at: url)
        return web
    }
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ web: WKWebView, context: Context) { context.coordinator.close = close }
    static func dismantleUIView(_ web: WKWebView, coordinator: GameDocWebCoordinator) { coordinator.release(web) }
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.close = close }
    static func dismantleNSView(_ web: WKWebView, coordinator: GameDocWebCoordinator) { coordinator.release(web) }
    #endif
}

// The game's guide: its page takes the controller (LauncherGuidePageModel: the arrows, A, L / R page turning, X, Y, -), B goes back a page, then to the list
struct GameDocGuide: View {
    let index: URL
    let root: URL
    let control: GameDocumentControl
    let close: () -> Void
    @StateObject private var model = LauncherGuidePageModel()

    var body: some View {
        page
            .background(Color.black)
            .onAppear { model.close = close; control.guide = model }
    }
    #if os(iOS)
    private var page: some View { LauncherGuideWebView(index: index, root: root, model: model, close: close) }
    #else
    private var page: some View { GameDocGuideMac(index: index, root: root, model: model, close: close) }
    #endif
}

#if os(macOS)
// The guide on the Mac, laid out at the console's 1280x720 and zoomed to fit, whole and centred, as its guide window does (dm/mac/Launcher.swift MacGuideBox)
final class GameDocGuideBox: NSView {
    var web: WKWebView? { didSet { oldValue?.removeFromSuperview(); if let web { addSubview(web); place() } } }
    override var isFlipped: Bool { true }
    func place() {
        guard let web else { return }
        let r = LauncherGuideFiles.fit(in: bounds)
        guard r.width >= 1 else { return }
        let w = r.width.rounded(.down), zoom = w / LauncherGuideFiles.pageSize.width, h = (LauncherGuideFiles.pageSize.height * zoom).rounded(.up)
        web.frame = NSRect(x: ((bounds.width - w) / 2).rounded(.down), y: ((bounds.height - h) / 2).rounded(.down), width: w, height: h)
        web.pageZoom = zoom
    }
    override func resizeSubviews(withOldSize s: NSSize) { super.resizeSubviews(withOldSize: s); place() }
    override func layout() { super.layout(); place() }
}

struct GameDocGuideMac: NSViewRepresentable {
    let index: URL
    let root: URL
    let model: LauncherGuidePageModel
    let close: () -> Void

    func makeCoordinator() -> GameDocWebCoordinator {
        GameDocWebCoordinator(root: root, fontDir: Bundle.main.resourceURL?.appendingPathComponent("dm/font"), model: model, quiet: false, close: close)
    }
    func makeNSView(context: Context) -> GameDocGuideBox {
        let web = context.coordinator.makeWeb(size: LauncherGuideFiles.pageSize)
        web.underPageBackgroundColor = .black
        web.setAccessibilityLabel("Game guide")
        let box = GameDocGuideBox()
        box.web = web
        context.coordinator.start(web, at: index)
        return box
    }
    func updateNSView(_ box: GameDocGuideBox, context: Context) { context.coordinator.close = close; model.close = close }
    static func dismantleNSView(_ box: GameDocGuideBox, coordinator: GameDocWebCoordinator) { if let web = box.web { coordinator.release(web) } }
}
#endif
