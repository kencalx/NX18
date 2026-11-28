// The in-game menu as NX 18's own panel (the default; DM_GAME_MENU=system keeps the UIMenu, DmGamepad.m). The same rows as the UIMenu (GameMenu.swift gameMenuSections), drawn so
// they keep out of the game's way: a wide, low panel of see-through charcoal over a light dim (no blur), the rows in columns side by side (the settings screen's sections, More),
// cyan for switches, ticks and the controller's focus, coral only for Close and Exit to Gate, the text in NX 18's UI font (NXFont.swift). Landscape: below the menu button at the top centre, as
// wide as the screen allows; portrait: across the bottom, fewer columns, scrolling when it is taller than the room it has. A choice, Cheats, Touch controls and Exit and return to Gate's
// confirmation open as a page of the panel (‹ back; a choice on the Touch controls page opens a page over it, and B goes back one page at a time). The game keeps running, as under the UIMenu; the touch
// controls and the controllers' input to the game wait while it is open (DmGamepad.m), and nothing pressed to close it reaches the game.
//   Touch: a tap on a row picks it, on the dim (the menu button too) closes. A controller (LauncherController.swift's polling, while the panel is open only): the D-pad or the left
//   stick moves the cyan ring, A picks, B goes back a page or closes, + closes; Home opens and closes it (DmGamepad.m). VoiceOver: a modal of buttons with their values and notes,
//   the escape gesture goes back or closes. Dynamic Type: the system's text size (the window keeps the UIMenu's one small size, front_ios.m), up to accessibility 3: fewer,
//   wider columns. Share log closes the panel first: the share sheet and its alert are the system's
// The Mac's game app draws the same panel over its game view (dm/mac/GameMenuMac.swift: an NSHostingView, scaled to the window): its controller events come from the host's
// own pad reading (front_mac.m), its keyboard's too, and the mouse clicks as touch taps
import GameController
import SwiftUI
#if os(iOS)
import UIKit
typealias GameMenuPad = LauncherGamepad   // LauncherController.swift: polled only while the panel is up
#else
import AppKit
typealias GameMenuPad = GameMenuMacPad    // dm/mac/GameMenuMac.swift: fed by front_mac.m, no polling
#endif

// One column of a page: blocks of rows, each under its heading (none where a section goes on from the column before)
struct GameMenuColumn: Identifiable {
    struct Block: Identifiable {
        let id: String; var heading: String?; var items: [GameMenuItem]
        var continues: String? = nil   // the heading of the section this block goes on with from the column before: the column keeps that heading's room, so its rows line up
    }
    let id: String
    var blocks: [Block]
    var ids: [String] { blocks.flatMap { $0.items.map(\.id) } }
}

enum GameMenuLayout {
    // The sections in at most n columns. Fewer sections than columns: each its own column, and the tallest split over more, while it has more than split rows per column (the
    // first page keeps a short section whole; a page of options or cheats spreads out). More sections than columns: in order, cut where the columns come out even
    // The preset chips' columns: 2 × 2 for four (or two), one row of three for three, so the grid never shows an empty slot
    static func presetColumns(_ count: Int) -> Int { count == 3 ? 3 : 2 }

    static func columns(_ sections: [GameMenuSection], fit n: Int, split: Int) -> [GameMenuColumn] {
        var merged: [GameMenuSection] = []   // neighbours under one heading (More: Cheats, then Take Screenshot, Exit and return to Gate and Share log) are one block
        for s in sections where !s.items.isEmpty {
            if let last = merged.last, let h = s.heading, last.heading == h, s.title.isEmpty, last.title.isEmpty { merged[merged.count - 1].items += s.items } else { merged.append(s) }
        }
        let n = max(1, n)
        if merged.isEmpty { return [] }
        if merged.count <= n {
            var count = Array(repeating: 1, count: merged.count)
            var spare = n - merged.count
            while spare > 0 {
                let perColumn = merged.indices.map { (merged[$0].items.count + count[$0] - 1) / count[$0] }
                guard let i = perColumn.indices.max(by: { perColumn[$0] < perColumn[$1] }), perColumn[i] > split, count[i] < merged[i].items.count else { break }
                count[i] += 1; spare -= 1
            }
            var out: [GameMenuColumn] = []
            for (i, s) in merged.enumerated() {
                let per = (s.items.count + count[i] - 1) / count[i]
                for c in 0..<count[i] {
                    let part = Array(s.items.dropFirst(c * per).prefix(per))
                    if part.isEmpty { continue }
                    out.append(GameMenuColumn(id: "\(s.id)#\(c)", blocks: [.init(id: "\(s.id)#\(c)", heading: c == 0 ? s.label : nil, items: part, continues: c == 0 ? nil : s.label)]))
                }
            }
            return out
        }
        let total = merged.reduce(0) { $0 + $1.items.count + ($1.label == nil ? 0 : 1) }
        let per = (total + n - 1) / n
        var out: [GameMenuColumn] = [], blocks: [GameMenuColumn.Block] = [], used = 0
        func cut() { if !blocks.isEmpty { out.append(GameMenuColumn(id: blocks[0].id, blocks: blocks)) }; blocks = []; used = 0 }
        for s in merged {
            var rest = s.items[...], first = true
            while !rest.isEmpty {
                let head = first && s.label != nil ? 1 : 0
                if used > 0 && out.count < n - 1 && (used + head >= per || per - used - head < min(2, rest.count)) { cut() }   // no heading left alone at a column's foot
                let room = out.count == n - 1 ? rest.count : max(1, per - used - head)
                let part = Array(rest.prefix(room)); rest = rest.dropFirst(part.count)
                blocks.append(.init(id: "\(s.id)@\(part[0].id)", heading: first ? s.label : nil, items: part, continues: first ? nil : s.label))
                used += head + part.count; first = false
                if used >= per && out.count < n - 1 { cut() }
            }
        }
        cut()
        return out
    }

    // The first page's step (gate-ui §19.2): zones side by side (the preset chooser, then the tiles and doors), each a list of lines. Up / down stay in the zone, keeping the
    // column where the next line has it; left / right go along the line and past its end into the next zone, at the same line or its last
    static func homeStep(_ id: String?, _ dx: Int, _ dy: Int, in zones: [[[String]]]) -> String? {
        let zs = zones.map { $0.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
        func place(_ id: String) -> (z: Int, l: Int, c: Int)? {
            for (z, zone) in zs.enumerated() { for (l, line) in zone.enumerated() { if let c = line.firstIndex(of: id) { return (z, l, c) } } }
            return nil
        }
        guard let id, let p = place(id) else { return zs.first?.first?.first }
        let zone = zs[p.z]
        if dy != 0 {
            let l = Swift.min(Swift.max(p.l + dy.signum(), 0), zone.count - 1)
            return zone[l][Swift.min(p.c, zone[l].count - 1)]
        }
        let c = p.c + dx.signum()
        if zone[p.l].indices.contains(c) { return zone[p.l][c] }
        let z = p.z + dx.signum()
        guard zs.indices.contains(z) else { return id }
        let line = zs[z][Swift.min(p.l, zs[z].count - 1)]
        return dx > 0 ? line.first : line.last
    }

    // The first page's doors in lines (gate-ui §19.2): up to three on one line; four (Customize, Cheats, Manual & documents, More) two by two, so each keeps a readable width
    static func doorLines<T>(_ doors: [T]) -> [[T]] {
        guard doors.count > 3 else { return doors.isEmpty ? [] : [doors] }
        let lines = (doors.count + 2) / 3, per = (doors.count + lines - 1) / lines
        return stride(from: 0, to: doors.count, by: per).map { Array(doors[$0..<Swift.min($0 + per, doors.count)]) }
    }

    // The controller's step from id in columns: up / down in its column (no wrap), left / right to the next column at the same row, or the column's last row
    static func step(_ id: String?, _ dx: Int, _ dy: Int, in columns: [GameMenuColumn]) -> String? {
        let grid = columns.map(\.ids).filter { !$0.isEmpty }
        guard let id, let c = grid.firstIndex(where: { $0.contains(id) }), let r = grid[c].firstIndex(of: id) else { return grid.first?.first }
        if dy != 0 { return grid[c][min(max(r + dy, 0), grid[c].count - 1)] }
        let nc = c + dx
        guard grid.indices.contains(nc) else { return id }
        return grid[nc][min(r, grid[nc].count - 1)]
    }
}

// What the panel shows: the rows, the page open, the controller's focus
@MainActor final class GameMenuPanelModel: ObservableObject {
    struct Page { let id: String?; let title: String; let subtitle: String?; let sections: [GameMenuSection]; let options: Bool }
    @Published private(set) var root: [GameMenuSection] = []
    @Published private(set) var home = GameMenuHome()   // the first page: tiles and doors (GameMenu.swift gameMenuHome); the chips come from the launcher's model
    @Published private(set) var toast: String?          // a preset change's toast (gate-ui §19.3, W9), with Undo while the change can be undone; about 5 s
    @Published private(set) var pending: [String] = []  // the preset rows that wait for the next start: "At next start: 30 fps"
    let launcher = gameMenuModel                         // the Gate's model: the presets, Custom and Back (nil in an app without a launcher: no chooser)
    var homeZones: [[[String]]] = []                     // the first page as last laid out: the controller's steps go by it
    private var toastTask: Task<Void, Never>?
    @Published private(set) var stack: [String] = []   // the ids of the choice or submenu open, outermost first
    @Published var focus: String?
    @Published var anchorBottom: CGFloat = 0            // the menu button's lower edge in the panel's view: the landscape panel starts below it (GameMenuPanelHost keeps it, rotation too)
    let title = gameMenuTitle()
    weak var anchor: GameMenuAnchor?                    // the menu button; the game's view on the Mac
    var closed = false                                  // closing: the controller's presses during the fade do nothing
    @Published var leaving = false                      // closing: the panel leaves (its rim dematerializes, the content fades), then the host goes
    var columnsShown: [GameMenuColumn] = []            // the page as last laid out: the controller's steps go by it
    var close: () -> Void = {}
    // Manual & documents (GameDocumentsViewer.swift): the document open in the viewer over the panel, and what the controller does to it. The pad's state for the viewer's hints
    @Published private(set) var document: GameDocumentOpen?
    let documentControl = GameDocumentControl()
    @Published var padConnected = false
    @Published var padGlyphs = NXPadGlyphs()
    static weak var current: GameMenuPanelModel?   // the panel up: a document's row opens its viewer here (gameDocumentOpen); the documents' listing refreshes its rows

    init(anchor: GameMenuAnchor?) {
        self.anchor = anchor
        Self.current = self
        GameDocumentsStore.shared.changed = { GameMenuPanelModel.current?.refresh() }
        refresh()
        // where the controller's ring starts (drawn only while a controller is connected): the chosen preset's chip, else the first tile
        if let m = launcher, m.hasPresets { focus = "preset:" + (m.activePreset ?? m.basePreset).rawValue } else { focus = home.tiles.first?.id ?? root.first?.items.first?.id }
    }

    func refresh() {
        root = gameMenuSections()
        home = gameMenuHome()
        pending = launcher.map(gameMenuPending) ?? []
        if let gone = stack.firstIndex(where: { find($0) == nil }) { stack.removeSubrange(gone...) }   // a page gone (the cheats reloaded to none), and every page opened from it
    }
    private func find(_ id: String, in sections: [GameMenuSection]? = nil) -> GameMenuItem? {
        for s in sections ?? (root + [GameMenuSection(id: "home", items: home.tiles + home.doors)]) { for i in s.items {
            if i.id == id { return i }
            if case .submenu(let inner) = i.kind, let f = find(id, in: inner) { return f }
        } }
        return nil
    }
    var page: Page {
        guard let id = stack.last, let item = find(id) else { return Page(id: nil, title: title, subtitle: nil, sections: root, options: false) }
        switch item.kind {
        case .choice(let o): return Page(id: id, title: item.title, subtitle: item.subtitle, sections: [GameMenuSection(id: id + ".options", items: o)], options: true)
        case .submenu(let s) where id == GameMenuExit.rowID: return Page(id: id, title: GameMenuExit.question, subtitle: GameMenuExit.warning, sections: s, options: false)   // the confirmation
        case .submenu(let s): return Page(id: id, title: item.title, subtitle: item.subtitle, sections: s, options: false)
        default: return Page(id: nil, title: title, subtitle: nil, sections: root, options: false)
        }
    }

    func activate(_ item: GameMenuItem) {
        guard !item.disabled else { return }
        if item.id == "customize.back" { backToBase(); if stack.last == "door.customize" { focus = page.sections.last?.items.last?.id }; return }   // through the chooser: the toast and the live rows
        switch item.kind {
        case .choice(let o):
            stack.append(item.id); focus = (o.first(where: \.isOn) ?? o.first)?.id
        case .submenu(let s):
            stack.append(item.id); focus = s.first?.items.first?.id
            if item.id == GameMenuExit.rowID {   // Exit and return to Gate asks first: the ring on Keep Playing, so A pressed on through does not exit
                focus = GameMenuExit.noID
                AccessibilityNotification.Announcement("\(GameMenuExit.question) \(GameMenuExit.warning)").post()
            }
        case .action, .toggle:
            if item.id == GameMenuExit.noID { back(); return }   // Keep Playing: back to the row, nothing done
            if item.closesMenu { close(); item.perform?(anchor); return }
            let option = page.options
            if item.id.hasPrefix("row:"), toast != nil { toastTask?.cancel(); toast = nil; launcher?.dropUndo() }   // a hand change ends the preset step's Undo: X then goes back to the base
            item.perform?(anchor)
            refresh()
            if option { back() }   // a choice picked: back to its row, which shows it
            Task { @MainActor [weak self] in   // what the pick changes a moment later (the cheats reloaded, a row's note)
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
    }
    func back() {
        if document != nil { closeDocument(); return }
        guard let last = stack.popLast() else { close(); return }
        focus = last
    }
    // The preset chooser (gate-ui §19.3): a chip, L / R, X, Back to X and Undo move the values as on the Gate; the live rows apply now, the rest at the next start
    func choosePreset(_ p: LauncherPreset) { change { $0.applyPreset(p) } }
    func stepPreset(_ d: Int) { change { $0.stepPreset(d) } }
    func backToBase() { change { $0.backToBase() } }
    func undo() {
        guard let m = launcher, m.undoState != nil else { return }
        _ = gameMenuApplyPreset(m) { m.undo() }
        toastTask?.cancel(); toast = nil
        refresh()
        AccessibilityNotification.Announcement("Undone: \(m.presetLabel)").post()
    }
    private func change(_ f: (LauncherModel) -> Void) {
        guard let m = launcher, m.hasPresets else { return }
        let r = gameMenuApplyPreset(m) { f(m) }
        refresh()
        if let p = m.activePreset { focus = focus?.hasPrefix("preset:") == true ? "preset:" + p.rawValue : focus }
        let words = r.now.isEmpty ? (r.next.isEmpty ? nil : "at next start") : r.now.joined(separator: ", ")
        toast = m.presetLabel + (words.map { " · " + $0 } ?? "")
        AccessibilityNotification.Announcement(toast! + (r.next.isEmpty || r.now.isEmpty ? "" : ". At next start: " + r.next.joined(separator: ", "))).post()
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.toast = nil; self?.launcher?.dropUndo()
        }
    }
    var canUndo: Bool { toast != nil && launcher?.undoState != nil }

    // A document in the viewer over the panel (the game runs on, its input still held): fetched first when iCloud holds it (GameDocuments.fetch), then shown. direct: from the UIMenu
    func openDocument(_ d: GameDocument, direct: Bool = false) {
        guard !closed else { return }
        documentControl.take()
        document = GameDocumentOpen(doc: d, direct: direct || (document?.direct ?? false))
        fputs("documents: open \(d.kind.rawValue) (\(d.source.rawValue)\(d.downloading ? ", from iCloud" : ""))\n", stderr)
        Task { @MainActor [weak self] in
            let url = await GameDocuments.fetch(d)
            guard let self, self.document?.doc.id == d.id else { return }
            self.document?.url = url
            self.document?.failed = url == nil
            if url == nil { fputs("[RED] documents: it could not be read\n", stderr) }
            else if d.downloading { GameDocumentsStore.shared.refresh() }   // it is on the device now: its row says so at the next listing
        }
    }
    // B: back to the list, its row ringed; from the UIMenu the panel closes as well
    func closeDocument() {
        guard let open = document else { return }
        documentControl.take()
        document = nil
        if open.direct { close(); return }
        focus = "doc:" + open.doc.id
    }
    // ZL / ZR and the header's arrows: the document before or after in the list
    func stepDocument(_ step: Int) {
        guard let open = document, let next = GameDocuments.step(from: open.doc.id, by: step, in: GameDocumentsStore.shared.docs) else { return }
        openDocument(next)
    }

    func handle(_ e: LauncherPadEvent) {
        if closed { return }
        if document != nil {   // the viewer has the controller: the document's own moves, then B back to the list, + closes, ZL / ZR the other documents
            if documentControl.handle(e) { return }
            switch e {
            case .b: closeDocument()
            case .plus: close()
            case .zl: stepDocument(-1)
            case .zr: stepDocument(1)
            default: break
            }
            return
        }
        switch e {   // the chooser's buttons act on every page (L / R only inside the menu: the game has no controllers while it is open)
        case .l: stepPreset(-1); return
        case .r: stepPreset(1); return
        case .x: if canUndo { undo() } else if launcher?.isCustom == true { backToBase() }; return
        default: break
        }
        if page.id == nil { handleHome(e); return }
        let cols = columnsShown
        let ids = Set(cols.flatMap(\.ids))
        // no ring on a row shown (the rows changed under it): the first row gets it, and only B and + act at once; A picks nothing the player has not seen ringed
        if focus == nil || !ids.contains(focus!) { focus = GameMenuLayout.step(nil, 0, 0, in: cols); if e != .b && e != .plus { return } }
        switch e {
        case .up: focus = GameMenuLayout.step(focus, 0, -1, in: cols)
        case .down: focus = GameMenuLayout.step(focus, 0, 1, in: cols)
        case .left: focus = GameMenuLayout.step(focus, -1, 0, in: cols)
        case .right: focus = GameMenuLayout.step(focus, 1, 0, in: cols)
        case .a: if let f = focus, let item = page.sections.lazy.flatMap(\.items).first(where: { $0.id == f }) { activate(item) }
        case .b: back()
        case .plus: close()
        case .x, .y, .minus, .l, .r, .zl, .zr: break   // -, ZL and ZR: nothing here (L, R and X above)
        }
    }
    private func handleHome(_ e: LauncherPadEvent) {
        let zones = homeZones
        let ids = Set(zones.flatMap { $0.flatMap { $0 } })
        if focus == nil || !ids.contains(focus!) { focus = GameMenuLayout.homeStep(nil, 0, 0, in: zones); if e != .b && e != .plus { return } }
        switch e {
        case .up: focus = GameMenuLayout.homeStep(focus, 0, -1, in: zones)
        case .down: focus = GameMenuLayout.homeStep(focus, 0, 1, in: zones)
        case .left: focus = GameMenuLayout.homeStep(focus, -1, 0, in: zones)
        case .right: focus = GameMenuLayout.homeStep(focus, 1, 0, in: zones)
        case .a:
            guard let f = focus else { return }
            if f.hasPrefix("preset:"), let p = LauncherPreset(rawValue: String(f.dropFirst(7))) { choosePreset(p) }
            else if f == "back" { backToBase() }
            else if let item = (home.tiles + home.doors).first(where: { $0.id == f }) { activate(item) }
        case .b, .plus: close()
        default: break
        }
    }
}

struct GameMenuPanelView: View {
    @ObservedObject var model: GameMenuPanelModel
    @StateObject private var pad = GameMenuPad()
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var columnWidth: CGFloat = 200
    @ScaledMetric(relativeTo: .footnote) private var optionWidth: CGFloat = 150
    @State private var vitalsTick = 0   // DmVitals.m posts after each 1 s tick while the menu is open: the header's line and the save minute follow it
    @State private var shown = false   // the inner content's fade and slide (the glass rim materializes on its own: no opacity on glass, gate-ui §19.4)
    @Namespace private var ringSpace   // the shared focus ring (LauncherPanel.swift GateRing): it slides from tile to tile

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + safe.leading + safe.trailing, height: geo.size.height + safe.top + safe.bottom)
            let landscape = full.width > full.height
            let width = min(geo.size.width - (landscape ? 12 : 20), 1000)
            let top = landscape ? max(model.anchorBottom + 6 - safe.top, 6) : 0
            let maxHeight = landscape ? geo.size.height - top - 8 : min(geo.size.height * 0.72, geo.size.height - 12)
            ZStack(alignment: landscape ? .top : .bottom) {
                Color.black.opacity(0.22)   // a light dim: the game stays readable around the panel
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                    .accessibilityHidden(true)
                if !model.leaving && model.document == nil {
                    panel(width: width, maxHeight: maxHeight, landscape: landscape)
                        .padding(.top, landscape ? top : 0)
                        .padding(.bottom, landscape ? 0 : 10)
                        .glassEffectTransition(.materialize)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        #if os(iOS)
        .overlay { if let open = model.document, !model.leaving { GameDocumentViewer(model: model, control: model.documentControl, open: open).transition(.opacity) } }   // the Mac's is unscaled (GameMenuMac.swift)
        #endif
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.document?.doc.id)
        .onChange(of: pad.connected, initial: true) { _, c in if model.padConnected != c { model.padConnected = c } }   // the viewer's hints
        .onChange(of: pad.glyphs, initial: true) { _, g in if model.padGlyphs != g { model.padGlyphs = g } }
        .environment(\.gateRing, ringSpace)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .nxTextRoot()
        .task { await pad.run { model.handle($0) } }   // only while the panel is up: the task ends with it
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .DmVitalsTick)) { _ in vitalsTick &+= 1 }
        #else
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in vitalsTick &+= 1 }   // the save minute only (no Vitals on the Mac yet); while the panel is up
        #endif
        .onAppear {   // the content's 160 ms fade and 6 pt slide; under Reduce Motion a jump in dark, a fade with no slide in light (a grey slab never pops on over a dark game)
            if reduceMotion && scheme == .dark { shown = true } else { withAnimation(.easeOut(duration: 0.16)) { shown = true } }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.18), value: pad.connected ? model.focus : nil)   // the ring slides with the controller's focus
    }

    private func panel(width: CGFloat, maxHeight: CGFloat, landscape: Bool) -> some View {
        let page = model.page
        let inner = width - 36
        let n = max(1, Int((inner + 8) / ((page.options ? optionWidth : columnWidth) + 8)))
        let columns = GameMenuLayout.columns(page.sections, fit: n, split: page.options || page.id != nil ? 1 : 2)
        let colWidth = (inner - CGFloat(max(columns.count - 1, 0)) * 8) / CGFloat(max(columns.count, 1))
        let zoned = landscape && !typeSize.isAccessibilitySize && width >= 640
        let head = header(page, width: width)
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(Double(columns.count + 2))   // VoiceOver: the header first, then the page, then the strip
        // A page that fits stands between the header and the strip; one that scrolls runs under them as bars (safeAreaBar), with the system's soft scroll edge effect keeping
        // them clear of it (Apple HIG, Scroll views, iOS 27), as the Gate's panel does
        return ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    head
                    pageBody(page, columns: columns, colWidth: colWidth, zoned: zoned, inner: inner)
                    strip(page)
                }
                ScrollView(.vertical) { pageBody(page, columns: columns, colWidth: colWidth, zoned: zoned, inner: inner) }
                    .scrollIndicators(.automatic)
                    .safeAreaBar(edge: .top, spacing: 0) { head }
                    .safeAreaBar(edge: .bottom, spacing: 0) { strip(page) }
                    .scrollEdgeEffectStyle(.automatic, for: .vertical)   // the HIG's preference: the header and strip are text outside glass, for which automatic gives the firmer separation
            }
            .onChange(of: model.focus) { _, f in
                guard let f, pad.connected else { return }
                if reduceMotion { proxy.scrollTo(f) } else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f) } }   // as the Gate scrolls
            }
        }
        .overlay(alignment: .bottom) { if let t = model.toast { toast(t).padding(.bottom, pad.connected ? 52 : 34).transition(.opacity) } }
        .opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : (landscape ? -6 : 6))   // the inner content only: the rim stays glass
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MenuColor.slab).padding(6))   // the solid inner fill, 6 pt inside the rim (gate-ui §19.2)
        .frame(width: width)
        .nx18Surface(RoundedRectangle(cornerRadius: 22, style: .continuous), fill: MenuColor.slab, hairline: MenuColor.hairline, art: true)   // the glass rim over the running game
        .frame(maxHeight: maxHeight, alignment: landscape ? .top : .bottom)   // the most it may take: a page that fits is as tall as its rows (ViewThatFits), a taller one scrolls
        .onAppear { model.columnsShown = columns; model.homeZones = homeZones(zoned: zoned) }
        .onChange(of: columns.map(\.ids)) { _, _ in model.columnsShown = columns }
        .onChange(of: homeZones(zoned: zoned)) { _, z in model.homeZones = z }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { model.back() }
        .gesture(swipeClose(landscape: landscape))
    }

    // A swipe on the panel toward the edge it came from closes it (up in landscape, down in portrait); a right swipe from its leading edge goes back a page
    private func swipeClose(landscape: Bool) -> some Gesture {
        DragGesture(minimumDistance: 24).onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if model.page.id != nil, g.startLocation.x < 34, dx > 60, abs(dy) < 40 { model.back(); return }
            if abs(dy) > 60, abs(dy) > abs(dx) * 1.5, (landscape ? dy < 0 : dy > 0) { model.close() }
        }
    }

    @ViewBuilder private func pageBody(_ page: GameMenuPanelModel.Page, columns: [GameMenuColumn], colWidth: CGFloat, zoned: Bool, inner: CGFloat) -> some View {
        if page.id == nil { home(zoned: zoned, inner: inner) } else { grid(columns, page: page, colWidth: colWidth) }
    }

    @ViewBuilder private func header(_ page: GameMenuPanelModel.Page, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            if page.id != nil {
                Button { model.back() } label: {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)).foregroundStyle(MenuColor.line)   // system: symbol
                        .frame(width: 44, height: 44).contentShape(Rectangle())   // 44 pt (gate-ui §19.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: NXFont.name == nil ? 1 : 3) {
                    Text(page.title).nxFont(.footnote, weight: .semibold).foregroundStyle(MenuColor.text).lineLimit(1)
                    if let s = page.subtitle { Text(s).nxFont(.caption2).foregroundStyle(MenuColor.muted).lineLimit(1).accessibilityLabel(s.replacingOccurrences(of: " · ", with: ", ")) }   // VoiceOver: the summary as the row reads it
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } else {
                GameMenuHeaderLine(tick: vitalsTick)   // "Menu · Game Title · Saved 2 min ago" (gate-ui §19.8)
                    .layoutPriority(0)
            }
            Spacer(minLength: 8)
            #if os(iOS)
            if !typeSize.isAccessibilitySize { VitalsCompactLine(tick: vitalsTick).layoutPriority(1) }   // never cut by the left line; at accessibility sizes it moves to its own line below
            #endif
            Button { model.close() } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11, weight: .bold))   // system: symbol
                    .foregroundStyle(MenuColor.ink)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(MenuColor.second))
                    .frame(width: 44, height: 44).contentShape(Rectangle())   // 44 pt (gate-ui §19.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.leading, page.id != nil ? 6 : 18)
        .padding(.trailing, 6)
        .padding(.top, 6)
        #if os(iOS)
        if typeSize.isAccessibilitySize { VitalsCompactLine(tick: vitalsTick).padding(.horizontal, 18).padding(.bottom, 4) }   // the Vitals line's own line at accessibility sizes (gate-ui §19.2)
        #endif
    }

    // MARK: The first page (gate-ui §19.2): the chooser on the left, the tiles and doors on the right; one column in portrait and at accessibility sizes

    private func homeZones(zoned: Bool) -> [[[String]]] {
        var chooser: [[String]] = []
        if let m = model.launcher, m.hasPresets {
            let ids = m.offeredPresets.map { "preset:" + $0.rawValue }
            let per = GameMenuLayout.presetColumns(ids.count)
            chooser = stride(from: 0, to: ids.count, by: per).map { Array(ids[$0..<min($0 + per, ids.count)]) }
            if m.isCustom { chooser.append(["back"]) }
        }
        let tiles = model.home.tiles.map(\.id)
        var right = stride(from: 0, to: tiles.count, by: 3).map { Array(tiles[$0..<min($0 + 3, tiles.count)]) }
        right += GameMenuLayout.doorLines(model.home.doors.map(\.id))
        return zoned ? [chooser, right] : [chooser + right]
    }

    @ViewBuilder private func home(zoned: Bool, inner: CGFloat) -> some View {
        let m = model.launcher
        Group {
            if zoned, let m, m.hasPresets {
                HStack(alignment: .top, spacing: 12) {
                    chooser(m).frame(width: max((inner - 12) * 0.38, 0))
                    tilesAndDoors
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let m, m.hasPresets { chooser(m) }
                    tilesAndDoors
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 8)
    }

    // The preset chips, 2 × 2 (three: one row of three, so no slot stays empty), then the line: "Frame rate and resolution change at next start" (and what waits, once something does), or the Custom bar with Back (presets-first P7 (b))
    private func chooser(_ m: LauncherModel) -> some View {
        let active = m.activePreset
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: GameMenuLayout.presetColumns(m.offeredPresets.count)), spacing: 8) {
                ForEach(m.offeredPresets) { p in
                    let id = "preset:" + p.rawValue
                    Button { model.focus = id; model.choosePreset(p) } label: {
                        VStack(spacing: 4) {
                            NX18Icon(kind: NX18Icon.forPreset(p), size: 20).foregroundStyle(active == p ? MenuColor.chosenIcon : MenuColor.text)
                            Text(p.gateName).nxFont(.footnote, weight: .semibold).lineLimit(1).minimumScaleFactor(0.75)
                            if scheme == .light { Capsule().fill(active == p ? MenuColor.bar : .clear).frame(width: 28, height: 3).accessibilityHidden(true) }   // chosen: a bar inside; focused: a ring outside
                        }
                        .foregroundStyle(active == p && scheme != .light ? MenuColor.ink : MenuColor.text)   // dark: charcoal on powder cyan; light: the text tone on the dim chosen fill
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(MenuTileStyle(focused: pad.connected && model.focus == id, fill: active == p ? MenuColor.chosen : MenuColor.tile))
                    .accessibilityLabel(p.gateName)
                    .accessibilityHint(GateText.presetNote(m, p))
                    .accessibilityAddTraits(active == p ? .isSelected : [])
                    .id(id)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preset")
            .accessibilityValue(m.isCustom ? "Custom, from \(m.basePreset.title)" : active?.title ?? "")
            .accessibilityActions {
                if m.isCustom { Button("Back to \(m.basePreset.title)") { model.backToBase() } }
                if model.canUndo { Button("Undo") { model.undo() } }
            }
            if active != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frame rate and resolution change at next start").nxFont(.caption2).foregroundStyle(MenuColor.muted).fixedSize(horizontal: false, vertical: true)
                    if !model.pending.isEmpty {
                        Text("At next start: " + model.pending.joined(separator: " · ")).nxFont(.caption2, weight: .semibold).foregroundStyle(MenuColor.line).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 4)
            } else {
                HStack(spacing: 8) {
                    Circle().fill(MenuColor.line).frame(width: 7, height: 7)
                    Text(m.presetLabel).nxFont(.footnote, weight: .semibold).foregroundStyle(MenuColor.text).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button { model.focus = "back"; model.backToBase() } label: {
                        Text("Back to \(m.basePreset.title)").nxFont(.caption, weight: .semibold).foregroundStyle(MenuColor.line).lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.horizontal, 10).frame(minHeight: 44)
                    }
                    .buttonStyle(MenuTileStyle(focused: pad.connected && model.focus == "back", fill: MenuColor.well, radius: 12))
                    .id("back")
                }
                .padding(.leading, 6)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var tilesAndDoors: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.home.tiles) { item in tile(item) }
            }
            ForEach(Array(GameMenuLayout.doorLines(model.home.doors).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 8) { ForEach(line) { item in door(item) } }
            }
        }
    }

    // A live quick tile (gate-ui §19.2): the value or a lamp at the top, the name below. A tap does what A does: a switch flips, a choice opens its options, Touch controls its page
    private func tile(_ item: GameMenuItem) -> some View {
        let greyed = item.disabled
        let key = item.id.hasPrefix("row:") ? String(item.id.dropFirst(4)) : item.id
        let value: String? = { switch item.kind {
            case .choice: return item.currentOption
            case .submenu where item.summary: return dm_setting_why("DM_TOUCH_HAPTICS") != nil ? "Hidden" : item.subtitle?.components(separatedBy: " · ").first   // the reason goes to the strip
            default: return nil } }()
        let lamp: Bool? = { if case .toggle(let on) = item.kind { return on }; return nil }()
        return Button { model.focus = item.id; model.activate(item) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    NX18Icon(kind: key == "layout" ? .console : key == "DM_FULLSCREEN" ? .picture : NX18Icon.forTile(key), size: 16).foregroundStyle(greyed ? MenuColor.muted : MenuColor.line)
                    if let lamp { MenuLamp(on: lamp) }
                    if let value { Text(value).nxFont(.footnote, weight: .semibold).foregroundStyle(greyed ? MenuColor.muted : MenuColor.line).lineLimit(1).minimumScaleFactor(0.6) }
                }
                Text(item.title).nxFont(.caption).foregroundStyle(greyed ? MenuColor.muted : MenuColor.text).lineLimit(2).minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .opacity(greyed ? 0.6 : 1)
        }
        .buttonStyle(MenuTileStyle(focused: pad.connected && model.focus == item.id))
        .disabled(greyed)
        .accessibilityLabel(item.title)
        .accessibilityValue(value ?? (lamp.map { $0 ? "On" : "Off" } ?? ""))
        .accessibilityHint(greyed ? "Dimmed. \(item.subtitle ?? "")" : item.summary ? "" : item.subtitle ?? "")
        .accessibilityAddTraits(lamp != nil ? .isToggle : [])
        .id(item.id)
    }

    private func door(_ item: GameMenuItem) -> some View {
        Button { model.focus = item.id; model.activate(item) } label: {
            HStack(spacing: 8) {
                if let s = item.symbol { Image(systemName: s).font(.footnote.weight(.medium)).foregroundStyle(MenuColor.line) }   // system: symbol
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).nxFont(.footnote, weight: .semibold).foregroundStyle(MenuColor.text).lineLimit(1).minimumScaleFactor(0.8)
                    if let s = item.subtitle { Text(s).nxFont(.caption2).foregroundStyle(MenuColor.muted).lineLimit(1).minimumScaleFactor(0.8) }
                }
                Spacer(minLength: 0)
                Text(verbatim: "›").nxFont(.body).foregroundStyle(MenuColor.muted)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(MenuTileStyle(focused: pad.connected && model.focus == item.id))
        .accessibilityLabel(item.title).accessibilityValue(item.subtitle ?? "")
        .id(item.id)
    }

    // The toast after a preset change: what moved now, and Undo (44 pt; X with a controller while it shows)
    private func toast(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text).nxFont(.footnote, weight: .semibold).foregroundStyle(MenuColor.text).lineLimit(1).minimumScaleFactor(0.8)
            if model.canUndo {
                Button { model.undo() } label: {
                    HStack(spacing: 4) {
                        if pad.connected { NXPadGlyphView(pad.glyphs.glyph(.x), size: 14, relativeTo: .caption2).foregroundStyle(MenuColor.line) }
                        Text("Undo").nxFont(.footnote, weight: .semibold).foregroundStyle(MenuColor.line)
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                }
                .buttonStyle(MenuTileStyle(fill: MenuColor.well, radius: 12))
                .accessibilityHint("Puts back the settings before this preset")
            }
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 2)
        .background(Capsule().fill(MenuColor.tile).shadow(color: .black.opacity(0.25), radius: 8, y: 2))
        .overlay(Capsule().strokeBorder(MenuColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    // The hint strip at the foot (gate-ui §19.2): line 1, the focused item's note; line 2, only with a pad, the buttons
    private func strip(_ page: GameMenuPanelModel.Page) -> some View {
        let note = focusedNote(page)
        let g = pad.glyphs
        return VStack(alignment: .leading, spacing: 3) {
            if let note, !note.isEmpty { Text(GateText.brief(note)).nxFont(.caption2).foregroundStyle(MenuColor.muted).lineLimit(1) }
            if pad.connected {
                HStack(spacing: 10) {
                    hint(g.glyph(.a), "Choose", MenuColor.line)
                    hint(g.glyph(.b), page.id != nil ? "Back" : "Close", page.id != nil ? MenuColor.line : MenuColor.second)
                    if model.launcher?.hasPresets == true {
                        Text("\(GateText.shoulder(g.name(NXShoulder.l))) \(GateText.shoulder(g.name(NXShoulder.r))) Preset").nxFont(.caption2).foregroundStyle(MenuColor.muted).lineLimit(1).fixedSize()
                    }
                    hint(g.glyph(.plus), "Close", MenuColor.second)
                }
                .nxFont(.caption2).foregroundStyle(MenuColor.muted)
                .accessibilityHidden(true)   // VoiceOver has its own gestures
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 12)
        .accessibilityHidden(note == nil && !pad.connected)
    }
    private func focusedNote(_ page: GameMenuPanelModel.Page) -> String? {
        guard pad.connected, let f = model.focus else { return nil }
        if f.hasPrefix("preset:"), let m = model.launcher, let p = LauncherPreset(rawValue: String(f.dropFirst(7))) { return GateText.presetNote(m, p) }
        if f == "back", let m = model.launcher { return "The \(m.basePreset.title) preset's settings again" }
        let items = page.id == nil ? model.home.tiles + model.home.doors : page.sections.flatMap(\.items)
        return items.first { $0.id == f }?.subtitle
    }
    private func hint(_ glyph: NXPadGlyph, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) { NXPadGlyphView(glyph, size: 15, relativeTo: .caption2).foregroundStyle(tint); Text(text) }.fixedSize()
    }

    private func grid(_ columns: [GameMenuColumn], page: GameMenuPanelModel.Page, colWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(col.blocks) { block in
                        if let h = block.heading, !h.isEmpty {
                            NX18SectionHeader(h).padding(.horizontal, 10).padding(.bottom, 2)
                        } else if block.id == col.blocks.first?.id, let h = block.continues, !h.isEmpty {
                            NX18SectionHeader(h).padding(.horizontal, 10).padding(.bottom, 2).hidden().accessibilityHidden(true)   // its room only: the rows line up with the column before
                        }
                        ForEach(block.items) { item in
                            GameMenuRowView(item: item, option: page.options, overview: page.id == nil, focused: pad.connected && model.focus == item.id) { model.focus = item.id; model.activate(item) }
                                .id(item.id)
                        }
                    }
                }
                .frame(width: max(colWidth, 0), alignment: .topLeading)
                .accessibilityElement(children: .contain)   // VoiceOver reads a column through before the next, not across the columns row by row,
                .accessibilitySortPriority(Double(columns.count - index))   // and the columns in their order (a column whose heading is the one before's starts lower)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}

// The in-game tile's press and focus (the Gate's GateTileStyle in the menu's set, gate-ui §11a.5): the lit fill while pressed or focused, the shared ring 3 pt outside
struct MenuTileStyle: ButtonStyle {
    var focused = false
    var fill: Color = MenuColor.tile
    var radius: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(configuration.isPressed || focused ? (fill == MenuColor.tile ? MenuColor.lit : fill) : fill))
            .overlay { if focused { GateRing(radius: radius) } }
            .scaleEffect(focused && !reduceMotion ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// A switch tile's lamp in the menu's set: no glow in light
struct MenuLamp: View {
    let on: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Circle().fill(on ? MenuColor.line : Color.clear)
            .overlay(Circle().strokeBorder(on ? MenuColor.line : MenuColor.muted, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .shadow(color: on && scheme != .light ? MenuColor.line.opacity(0.5) : .clear, radius: 3)
    }
}

// One row: its name and note, and at the end a switch, a tick, the choice made with ›, or › alone. On the first page a choice or a submenu shows its name alone: a choice's note
// heads its page (a dot marks it, and VoiceOver reads it), a submenu's is its value; a summary (Touch controls: its page's values) goes under its name, read as its value. A
// switch or an action has no page, so its note stays under its name
private struct GameMenuRowView: View {
    let item: GameMenuItem
    let option: Bool   // an option of a choice: a tick and a cyan tint when it is the one chosen
    let overview: Bool   // a row of the first page
    let focused: Bool
    let pick: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 6) {
                if let s = item.symbol {
                    Image(systemName: s).font(.footnote.weight(.medium)).foregroundStyle(coral ? MenuColor.second : MenuColor.line).frame(minWidth: 16)   // system: symbol
                }
                if overview, opens, !item.summary {   // the dot takes no room
                    Text(item.title).nxFont(.footnote).foregroundStyle(MenuColor.text).fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topTrailing) {
                            if dot { Circle().fill(MenuColor.muted).frame(width: 5, height: 5).offset(x: 8, y: 2).accessibilityHidden(true) }
                        }
                } else {
                    VStack(alignment: .leading, spacing: NXFont.name == nil ? 1 : 3) {   // the UI font's lines carry no gap of their own (NXFont.swift)
                        Text(item.title).nxFont(.footnote, weight: coral ? .semibold : .regular).foregroundStyle(coral ? MenuColor.second : MenuColor.text).fixedSize(horizontal: false, vertical: true)
                        if let s = item.subtitle, !s.isEmpty {
                            Text(s).nxFont(.caption2).foregroundStyle(MenuColor.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 2)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 46)   // rows 46 pt (gate-ui §19.5)
            .opacity(item.disabled ? 0.45 : 1)
        }
        .buttonStyle(MenuTileStyle(focused: focused, fill: fill))
        .disabled(item.disabled)
        .padding(3)   // room for the focus ring inside the scroll view's clip
        .accessibilityLabel(item.title)
        .accessibilityValue(value)
        .accessibilityHint(item.summary ? "" : item.subtitle ?? "")
        .accessibilityAddTraits(traits)
    }

    private var coral: Bool { item.id == GameMenuExit.yesID }   // Exit to Gate: the second accent (coral in the dark set), as the Gate's Reset all settings
    private var opens: Bool { switch item.kind { case .choice, .submenu: return true; default: return false } }   // a page of its own, where its note is shown
    private var dot: Bool { if case .choice = item.kind { return !(item.subtitle ?? "").isEmpty }; return false }   // a submenu's note is its value

    private var fill: Color {
        if option && item.isOn { return MenuColor.line.opacity(0.18) }
        return MenuColor.tile
    }

    @ViewBuilder private var trailing: some View {
        switch item.kind {
        case .toggle(let on):
            if option {
                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(MenuColor.line).opacity(on ? 1 : 0)   // system: symbol
            } else {
                OnOffCapsule(on: on, enabled: !item.disabled)   // the Gate's capsule (gate-ui §8)
            }
        case .choice:
            HStack(spacing: 4) {
                if let v = item.currentOption { Text(v).nxFont(.footnote).foregroundStyle(MenuColor.line).lineLimit(1) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(MenuColor.muted)   // system: symbol
            }
            .fixedSize()
        case .submenu:
            if overview, !item.summary, let s = item.subtitle, !s.isEmpty { Text(s).nxFont(.footnote).foregroundStyle(MenuColor.line).lineLimit(1).fixedSize() }   // Cheats: "1 on" as its value
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(MenuColor.muted)   // system: symbol
        case .action:
            EmptyView()
        }
    }

    private var value: String {
        switch item.kind {
        case .toggle(let on): return option ? "" : on ? "On" : "Off"
        case .choice: return item.currentOption ?? ""
        case .submenu where item.summary: return (item.subtitle ?? "").replacingOccurrences(of: " · ", with: ", ")   // Touch controls: "Large, Normal, Feedback on"
        default: return ""
        }
    }
    private var traits: AccessibilityTraits {
        switch item.kind {
        case .toggle(let on): return option ? (on ? [.isButton, .isSelected] : .isButton) : [.isButton, .isToggle]
        default: return .isButton
        }
    }
}

#if os(iOS)
// The panel over the game: a child of the game's view controller, its view over the touch controls; opened and closed with a short fade (and a small slide without Reduce Motion)
@MainActor final class GameMenuPanelHost: UIHostingController<GameMenuPanelView> {
    let model: GameMenuPanelModel
    private var closing = false
    init(model: GameMenuPanelModel) {
        self.model = model
        super.init(rootView: GameMenuPanelView(model: model))
        overrideUserInterfaceStyle = NX18Appearance.current.style   // the look the NX 18 card chose, read as the menu opens (it never changes during play, §20.5b)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {   // a hardware keyboard's Escape: back, then close
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
    }
    @objc private func escape() { model.back() }

    // Where the menu button ends, read again at each layout and after a rotation (the button moves with the safe area), so the landscape panel starts just below it
    private func followAnchor() {
        guard let a = model.anchor, let into = view.superview else { return }
        let y = a.convert(a.bounds, to: into).maxY
        if abs(y - model.anchorBottom) > 0.5 { model.anchorBottom = y }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); followAnchor() }
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.followAnchor() }
    }

    // The system's text size, not the window's fixed small one (front_ios.m keeps that for the UIMenu)
    func followTextSize() { traitOverrides.preferredContentSizeCategory = UIApplication.shared.preferredContentSizeCategory }

    func show(in parent: UIViewController) {
        parent.addChild(self)
        view.frame = parent.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        followTextSize()
        NotificationCenter.default.addObserver(self, selector: #selector(textSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(padsChanged), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(padsChanged), name: .GCControllerDidDisconnect, object: nil)
        parent.view.addSubview(view)
        followAnchor()
        didMove(toParent: parent)
        // no fade on the hosting view: opacity on glass leaves a flat grey panel (gate-ui §19.4). The rim materializes and the content fades in (GameMenuPanelView)
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
    @objc private func textSizeChanged() { followTextSize() }
    // A controller connected or gone while the panel is up: the rows again, once DmGamepad.m's padsChanged has shown or hidden the touch controls (its own main-queue block),
    // so Touch controls' summary says whether they are hidden now. Nonisolated: GameController may post from another thread; the panel shown then is the one refreshed
    @objc nonisolated private func padsChanged() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            gameMenuPanel?.model.refresh()   // nil once closed
        }
    }

    func hide() {
        guard !closing else { return }
        closing = true
        view.isUserInteractionEnabled = false
        resignFirstResponder()
        NotificationCenter.default.removeObserver(self)
        withAnimation(.easeIn(duration: 0.12)) { model.leaving = true }   // the panel leaves inside the view: the rim dematerializes, the dim stays until the host goes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            self.willMove(toParent: nil); self.view.removeFromSuperview(); self.removeFromParent()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}

@MainActor private var gameMenuPanel: GameMenuPanelHost?

@MainActor func gameMenuPanelClose() {
    guard let host = gameMenuPanel else { return }
    gameMenuPanel = nil
    host.model.closed = true
    dm_gamepad_panel_closed()   // at once: the game has its controllers back while the panel fades (it takes no touch meanwhile)
    host.hide()
}

// DmGamepad.m: open the panel over the view controller the menu button is in (anchor: the button). False when there is none
@_cdecl("dm_game_panel_open")
public func dmGamePanelOpen(_ anchor: UnsafeMutableRawPointer) -> Bool {
    nonisolated(unsafe) let anchor = anchor
    return MainActor.assumeIsolated {
        if gameMenuPanel != nil { return true }
        let button = Unmanaged<UIView>.fromOpaque(anchor).takeUnretainedValue()
        var r: UIResponder? = button
        while let x = r, !(x is UIViewController) { r = x.next }
        guard let parent = r as? UIViewController else { fputs("[RED] in-game menu: the menu button is in no view controller\n", stderr); return false }
        let model = GameMenuPanelModel(anchor: button)
        let host = GameMenuPanelHost(model: model)
        model.close = { gameMenuPanelClose() }
        gameMenuPanel = host
        host.show(in: parent)
        return true
    }
}

@_cdecl("dm_game_panel_close")
public func dmGamePanelClose() { MainActor.assumeIsolated { gameMenuPanelClose() } }

@_cdecl("dm_game_panel_shown")
public func dmGamePanelShown() -> Bool { MainActor.assumeIsolated { gameMenuPanel != nil } }
#endif

// The in-game menu's header, left (gate-ui §19.8): "Menu · Game Title · Saved 2 min ago". The save part drops first, then the title truncates; the Vitals line beside it never cuts.
// The time is the game's own last save commit (hle_fs.c dm_fs_last_commit_ns), read when the menu opens and again on each 1 s tick the Vitals line already uses
struct GameMenuHeaderLine: View {
    let tick: Int
    private static var title: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Game" }
    static func savedText(now: UInt64 = clock_gettime_nsec_np(CLOCK_MONOTONIC), last: UInt64 = dm_fs_last_commit_ns()) -> String {
        guard last > 0, now >= last else { return "Not saved yet this session" }
        let s = (now - last) / 1_000_000_000
        return s < 60 ? "Saved just now" : s < 3600 ? "Saved \(s / 60) min ago" : "Saved \(s / 3600) h ago"
    }
    var body: some View {
        let saved = Self.savedText(), title = Self.title
        _ = tick
        return ViewThatFits(in: .horizontal) {
            line(title, saved)
            line(title, nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu, \(title), \(saved.prefix(1).lowercased() + saved.dropFirst())")
        .accessibilityAddTraits(.isHeader)
    }
    private func line(_ title: String, _ saved: String?) -> some View {
        HStack(spacing: 0) {
            Text("Menu · ").nxFont(.caption, weight: .semibold).foregroundStyle(MenuColor.text)
            Text(title).nxFont(.caption, weight: .semibold).foregroundStyle(MenuColor.text).lineLimit(1).truncationMode(.tail)
            if let saved { Text(" · " + saved).nxFont(.caption).foregroundStyle(MenuColor.muted).lineLimit(1).fixedSize() }
        }
    }
}

#if os(iOS)
// The compact Vitals line in the header (vitals.md §2, §7): "60 fps · 🌡 Warm · ▮82% · 9:41", shown even with Vitals off. The time drops first, then the heat word; the frame rate and
// the battery stay. 🌡 and ▮ are the thermometer and battery symbols (cyan, coral when hot; yellow battery in Low Power Mode is iOS's own cue and stays for Vitals over the game)
struct VitalsCompactLine: View {
    let tick: Int
    var body: some View {
        _ = tick
        return ViewThatFits(in: .horizontal) {
            line(String(cString: dm_vitals_compact_text(0)))
            line(String(cString: dm_vitals_compact_text(1)))
            line(String(cString: dm_vitals_compact_text(2)))
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(cString: dm_vitals_compact_text(0)).replacingOccurrences(of: "🌡 ", with: "").replacingOccurrences(of: "🌡", with: "").replacingOccurrences(of: "▮", with: "battery ").replacingOccurrences(of: " · ", with: ", "))
    }
    private func line(_ s: String) -> some View {
        var t = Text("")
        var run = ""
        for ch in s {
            if ch == "🌡" || ch == "▮" {
                if !run.isEmpty { t = Text("\(t)\(Text(run))"); run = "" }   // Text interpolation: Text's + is deprecated in iOS 26
                t = Text("\(t)\(Text(Image(systemName: Self.symbol(ch))).foregroundColor(Self.tint(ch)))")   // system: symbol
            } else { run.append(ch) }
        }
        if !run.isEmpty { t = Text("\(t)\(Text(run))") }
        return t.nxFont(.caption).monospacedDigit().foregroundStyle(MenuColor.text).lineLimit(1)
    }
    static func symbol(_ ch: Character) -> String {
        if ch == "🌡" { let h = dm_vitals_thermal(); return h <= 0 ? "thermometer.low" : h == 1 ? "thermometer.medium" : "thermometer.high" }
        let b = dm_vitals_battery()
        return b >= 88 ? "battery.100percent" : b >= 63 ? "battery.75percent" : b >= 38 ? "battery.50percent" : b >= 13 ? "battery.25percent" : "battery.0percent"
    }
    static func tint(_ ch: Character) -> Color { ch == "🌡" ? (dm_vitals_thermal() >= 2 ? MenuColor.second : MenuColor.line) : MenuColor.text }
}
#endif
