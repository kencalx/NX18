// The in-game menu as NX 18's own panel (the default; DM_GAME_MENU=system keeps the UIMenu, DmGamepad.m). The same rows as the UIMenu (GameMenu.swift gameMenuSections), drawn so
// they keep out of the game's way: a wide, low panel of see-through charcoal over a light dim (no blur), the rows in columns side by side (the settings screen's sections, More),
// cyan for switches, ticks and the controller's focus, coral only for Close, the text in NX 18's UI font (NXFont.swift). Landscape: below the menu button at the top centre, as
// wide as the screen allows; portrait: across the bottom, fewer columns, scrolling when it is taller than the room it has. A choice and Cheats open as a page of the panel
// (‹ back). The game keeps running, as under the UIMenu; the touch controls and the controllers' input to the game wait while it is open (DmGamepad.m), and nothing pressed to
// close it reaches the game.
//   Touch: a tap on a row picks it, on the dim (the menu button too) closes. A controller (LauncherController.swift's polling, while the panel is open only): the D-pad or the left
//   stick moves the cyan ring, A picks, B goes back a page or closes, + closes; Home opens and closes it (DmGamepad.m). VoiceOver: a modal of buttons with their values and notes,
//   the escape gesture goes back or closes. Dynamic Type: the system's text size (the window keeps the UIMenu's one small size, front_ios.m), up to accessibility 3: fewer,
//   wider columns. Share log closes the panel first: the share sheet and its alert are the system's
import GameController
import SwiftUI
import UIKit

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
    static func columns(_ sections: [GameMenuSection], fit n: Int, split: Int) -> [GameMenuColumn] {
        var merged: [GameMenuSection] = []   // neighbours under one heading (More: Cheats, then Settings screen at start and Share log) are one block
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
    @Published private(set) var stack: [String] = []   // the ids of the choice or submenu open, outermost first
    @Published var focus: String?
    @Published var anchorBottom: CGFloat = 0            // the menu button's lower edge in the panel's view: the landscape panel starts below it (GameMenuPanelHost keeps it, rotation too)
    let title = gameMenuTitle()
    weak var anchor: UIView?                            // the menu button
    var closed = false                                  // closing: the controller's presses during the fade do nothing
    var columnsShown: [GameMenuColumn] = []            // the page as last laid out: the controller's steps go by it
    var close: () -> Void = {}

    init(anchor: UIView?) {
        self.anchor = anchor
        refresh()
        focus = root.first?.items.first?.id   // where the controller's ring starts (drawn only while a controller is connected)
    }

    func refresh() {
        root = gameMenuSections()
        while let last = stack.last, find(last) == nil { stack.removeLast() }   // a submenu gone (the cheats reloaded to none)
    }
    private func find(_ id: String, in sections: [GameMenuSection]? = nil) -> GameMenuItem? {
        for s in sections ?? root { for i in s.items {
            if i.id == id { return i }
            if case .submenu(let inner) = i.kind, let f = find(id, in: inner) { return f }
        } }
        return nil
    }
    var page: Page {
        guard let id = stack.last, let item = find(id) else { return Page(id: nil, title: title, subtitle: nil, sections: root, options: false) }
        switch item.kind {
        case .choice(let o): return Page(id: id, title: item.title, subtitle: item.subtitle, sections: [GameMenuSection(id: id + ".options", items: o)], options: true)
        case .submenu(let s): return Page(id: id, title: item.title, subtitle: item.subtitle, sections: s, options: false)
        default: return Page(id: nil, title: title, subtitle: nil, sections: root, options: false)
        }
    }

    func activate(_ item: GameMenuItem) {
        guard !item.disabled else { return }
        switch item.kind {
        case .choice(let o):
            stack.append(item.id); focus = (o.first(where: \.isOn) ?? o.first)?.id
        case .submenu(let s):
            stack.append(item.id); focus = s.first?.items.first?.id
        case .action, .toggle:
            if item.closesMenu { close(); item.perform?(anchor); return }
            let option = page.options
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
        guard let last = stack.popLast() else { close(); return }
        focus = last
    }
    func handle(_ e: LauncherPadEvent) {
        if closed { return }
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
        case .y, .l, .r: break
        }
    }
}

struct GameMenuPanelView: View {
    @ObservedObject var model: GameMenuPanelModel
    @StateObject private var pad = LauncherGamepad()
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var columnWidth: CGFloat = 180
    @ScaledMetric(relativeTo: .footnote) private var optionWidth: CGFloat = 140

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
                panel(width: width, maxHeight: maxHeight, landscape: landscape)
                    .padding(.top, landscape ? top : 0)
                    .padding(.bottom, landscape ? 0 : 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .nxTextRoot()
        .task { await pad.run { model.handle($0) } }   // only while the panel is up: the task ends with it
    }

    private func panel(width: CGFloat, maxHeight: CGFloat, landscape: Bool) -> some View {
        let page = model.page
        let inner = width - 24
        let n = max(1, Int((inner + 8) / ((page.options ? optionWidth : columnWidth) + 8)))
        let columns = GameMenuLayout.columns(page.sections, fit: n, split: page.options || page.id != nil ? 1 : 2)
        let colWidth = (inner - CGFloat(max(columns.count - 1, 0)) * 8) / CGFloat(max(columns.count, 1))
        return VStack(alignment: .leading, spacing: 0) {
            header(page, width: width)
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(Double(columns.count + 1))   // VoiceOver: the header first, then the columns left to right (grid)
            ScrollViewReader { proxy in
                ViewThatFits(in: .vertical) {
                    grid(columns, page: page, colWidth: colWidth)
                    ScrollView(.vertical) { grid(columns, page: page, colWidth: colWidth) }.scrollIndicators(.automatic)
                }
                .onChange(of: model.focus) { _, f in
                    guard let f, pad.connected else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(f) }
                }
            }
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(NX18Palette.background.opacity(0.84)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(maxHeight: maxHeight, alignment: landscape ? .top : .bottom)   // the most it may take: a page that fits is as tall as its rows (ViewThatFits), a taller one scrolls
        .onAppear { model.columnsShown = columns }
        .onChange(of: columns.map(\.ids)) { _, _ in model.columnsShown = columns }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { model.back() }
    }

    @ViewBuilder private func header(_ page: GameMenuPanelModel.Page, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            if page.id != nil {
                Button { model.back() } label: {
                    Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)).foregroundStyle(NX18Palette.cyan)   // system: symbol
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: NXFont.name == nil ? 1 : 3) {
                    Text(page.title).nxFont(.footnote, weight: .semibold).foregroundStyle(NX18Palette.text).lineLimit(1)
                    if let s = page.subtitle { Text(s).nxFont(.caption2).foregroundStyle(NX18Palette.muted).lineLimit(1) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } else {
                Text(page.title.isEmpty ? "Menu" : page.title).nxFont(.caption).foregroundStyle(NX18Palette.muted).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            if pad.connected && !(typeSize.isAccessibilitySize && width < 600) { hints(page) }   // an accessibility text size in a narrow panel: no room for them beside the title
            Button { model.close() } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11, weight: .bold))   // system: symbol
                    .foregroundStyle(NX18Palette.charcoal)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(NX18Palette.coral))
                    .frame(width: 36, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.leading, page.id != nil ? 6 : 14)
        .padding(.trailing, 6)
        .padding(.top, 2)
    }

    // The controller's A and B as the pack's glyphs (NXButtonGlyph.swift: the first pad's buttons, a Nintendo pad by its labels, any other by position as the game maps them),
    // each in the colour of what it does: A selects (cyan), B closes (Close's coral) or goes back a page (cyan)
    private func hints(_ page: GameMenuPanelModel.Page) -> some View {
        let g = pad.glyphs
        return HStack(spacing: 10) {
            hint(g.glyph(.a), "Select", NX18Palette.cyan)
            hint(g.glyph(.b), page.id != nil ? "Back" : "Close", page.id != nil ? NX18Palette.cyan : NX18Palette.coral)
        }
        .nxFont(.caption2).foregroundStyle(NX18Palette.muted)
        .accessibilityHidden(true)   // VoiceOver has its own gestures; the controller's are said by the buttons themselves
    }
    private func hint(_ glyph: NXPadGlyph, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) { NXPadGlyphView(glyph, size: 15, relativeTo: .caption2).foregroundStyle(tint); Text(text) }.fixedSize()
    }

    private func grid(_ columns: [GameMenuColumn], page: GameMenuPanelModel.Page, colWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, col in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(col.blocks) { block in
                        if let h = block.heading, !h.isEmpty {
                            NX18SectionHeader(h).padding(.horizontal, 10).padding(.bottom, 2)
                        } else if block.id == col.blocks.first?.id, let h = block.continues, !h.isEmpty {
                            NX18SectionHeader(h).padding(.horizontal, 10).padding(.bottom, 2).hidden().accessibilityHidden(true)   // its room only: the rows line up with the column before
                        }
                        ForEach(block.items) { item in
                            GameMenuRowView(item: item, option: page.options, overview: page.id == nil, focused: pad.connected && model.focus == item.id) { model.activate(item) }
                                .id(item.id)
                        }
                    }
                }
                .frame(width: max(colWidth, 0), alignment: .topLeading)
                .accessibilityElement(children: .contain)   // VoiceOver reads a column through before the next, not across the columns row by row,
                .accessibilitySortPriority(Double(columns.count - index))   // and the columns in their order (a column whose heading is the one before's starts lower)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// One row: its name and note, and at the end a switch, a tick, the choice made with ›, or › alone. On the first page a choice or a submenu shows its name alone: a choice's note
// heads its page (a dot marks it, and VoiceOver reads it), a submenu's is its value. A switch or an action has no page, so its note stays under its name
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
                    Image(systemName: s).font(.footnote.weight(.medium)).foregroundStyle(NX18Palette.cyan).frame(minWidth: 16)   // system: symbol
                }
                if overview, opens {   // the dot takes no room
                    Text(item.title).nxFont(.footnote).foregroundStyle(NX18Palette.text).fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .topTrailing) {
                            if dot { Circle().fill(NX18Palette.muted).frame(width: 5, height: 5).offset(x: 8, y: 2).accessibilityHidden(true) }
                        }
                } else {
                    VStack(alignment: .leading, spacing: NXFont.name == nil ? 1 : 3) {   // the UI font's lines carry no gap of their own (NXFont.swift)
                        Text(item.title).nxFont(.footnote).foregroundStyle(NX18Palette.text).fixedSize(horizontal: false, vertical: true)
                        if let s = item.subtitle, !s.isEmpty {
                            Text(s).nxFont(.caption2).foregroundStyle(NX18Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 2)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, overview ? 3 : 4)
            .frame(minHeight: overview ? 30 : 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .opacity(item.disabled ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(GameMenuPressStyle())
        .disabled(item.disabled)
        .nx18Focus(focused, cornerRadius: 12)
        .padding(2)   // room for the focus ring inside the scroll view's clip
        .accessibilityLabel(item.title)
        .accessibilityValue(value)
        .accessibilityHint(item.subtitle ?? "")
        .accessibilityAddTraits(traits)
    }

    private var opens: Bool { switch item.kind { case .choice, .submenu: return true; default: return false } }   // a page of its own, where its note is shown
    private var dot: Bool { if case .choice = item.kind { return !(item.subtitle ?? "").isEmpty }; return false }   // a submenu's note is its value

    private var fill: Color {
        if option && item.isOn { return NX18Palette.cyan.opacity(0.18) }
        return Color.white.opacity(focused ? 0.08 : 0.04)
    }

    @ViewBuilder private var trailing: some View {
        switch item.kind {
        case .toggle(let on):
            if option {
                Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(NX18Palette.cyan).opacity(on ? 1 : 0)   // system: symbol
            } else {
                Capsule().fill(on ? NX18Palette.cyan : Color(nx18: 0x4A4A50))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2) }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: on)
            }
        case .choice:
            HStack(spacing: 4) {
                if let v = item.currentOption { Text(v).nxFont(.footnote).foregroundStyle(NX18Palette.cyan).lineLimit(1) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(NX18Palette.muted)   // system: symbol
            }
            .fixedSize()
        case .submenu:
            if overview, let s = item.subtitle, !s.isEmpty { Text(s).nxFont(.footnote).foregroundStyle(NX18Palette.cyan).lineLimit(1).fixedSize() }   // Cheats: "1 on" as its value
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(NX18Palette.muted)   // system: symbol
        case .action:
            EmptyView()
        }
    }

    private var value: String {
        switch item.kind {
        case .toggle(let on): return option ? "" : on ? "On" : "Off"
        case .choice: return item.currentOption ?? ""
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

private struct GameMenuPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.75 : 1) }
}

// The panel over the game: a child of the game's view controller, its view over the touch controls; opened and closed with a short fade (and a small slide without Reduce Motion)
@MainActor final class GameMenuPanelHost: UIHostingController<GameMenuPanelView> {
    let model: GameMenuPanelModel
    private var closing = false
    init(model: GameMenuPanelModel) {
        self.model = model
        super.init(rootView: GameMenuPanelView(model: model))
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
        parent.view.addSubview(view)
        followAnchor()
        didMove(toParent: parent)
        view.alpha = 0
        if !UIAccessibility.isReduceMotionEnabled { view.transform = CGAffineTransform(translationX: 0, y: -6) }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { self.view.alpha = 1; self.view.transform = .identity }
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
    @objc private func textSizeChanged() { followTextSize() }

    func hide() {
        guard !closing else { return }
        closing = true
        view.isUserInteractionEnabled = false
        resignFirstResponder()
        NotificationCenter.default.removeObserver(self)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseIn]) {
            self.view.alpha = 0
        } completion: { _ in
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
