// The gallery's state, shared by a game page's Album and Beam Home's all-games Album (AlbumGallery.swift): the groups, the item in focus, the one open in the viewer,
// and what the viewer is doing (looking, its action bar, the Trash question, a trim). A controller, the arrow keys and the mouse all go through press(_:)
import AVFoundation
import AppKit
import SwiftUI

/// A press as the Album reads it (Home maps its controller's presses to these; the game page's keys too)
enum AlbumPress: Sendable { case left, right, up, down, a, b, y }

@MainActor @Observable final class AlbumBrowser {
    struct Group: Identifiable, Equatable, Sendable { let id: String; let title: String; let items: [AlbumItem] }
    enum Mode: Equatable { case grid, look, actions(Int), confirmDelete, trim }
    enum Action: Equatable { case share, finder, trim, delete }
    struct Trim: Equatable { var start = 0.0, end = 0.0, duration = 0.0, editingEnd = false }

    private(set) var groups: [Group] = []
    private(set) var items: [AlbumItem] = []
    private(set) var loaded = false
    var focus = 0
    var viewing: Int?
    var mode: Mode = .grid
    var trim = Trim()
    var working: String?            // "Saving the trimmed copy…"
    var message: String?            // what went wrong, or where the copy went
    var playRequests = 0            // A on a recording: the viewer plays or pauses
    var columns = 5                 // the grid's columns, for up and down (Home's fixed grid)
    @ObservationIgnored weak var shareAnchor: NSView?
    @ObservationIgnored private let load: @Sendable () -> [Group]

    /// `load` reads the folders; it runs off the main thread
    init(load: @escaping @Sendable () -> [Group]) { self.load = load }

    var current: AlbumItem? { viewing.flatMap { items.indices.contains($0) ? items[$0] : nil } }

    func reload() async {
        let load = self.load
        let g = await Task.detached(priority: .userInitiated) { load() }.value
        apply(g)
    }
    /// New groups, keeping the focus and the open item on the same files where they are still there
    func apply(_ g: [Group]) {
        let focusURL = items.indices.contains(focus) ? items[focus].url : nil, viewURL = current?.url
        loaded = true
        guard g != groups else { return }
        groups = g; items = g.flatMap(\.items)
        if let u = focusURL, let i = items.firstIndex(where: { $0.url == u }) { focus = i } else { focus = min(focus, max(items.count - 1, 0)) }
        if viewing != nil {
            if let u = viewURL, let i = items.firstIndex(where: { $0.url == u }) { viewing = i }
            else if items.isEmpty { close() } else { viewing = min(viewing!, items.count - 1); mode = .look }
        }
    }
    func index(of item: AlbumItem) -> Int? { items.firstIndex(of: item) }

    func open(_ i: Int) {
        guard items.indices.contains(i) else { return }
        focus = i; viewing = i; mode = .look; message = nil
        if items[i].downloading { Album.fetch(items[i].url) }   // only now: the player asked to see it
    }
    func close() { viewing = nil; mode = .grid; message = nil }
    func step(_ d: Int) {
        guard let v = viewing, !items.isEmpty else { return }
        open(min(max(v + d, 0), items.count - 1))
    }
    func actions(for item: AlbumItem) -> [Action] { item.kind == .recording ? [.share, .finder, .trim, .delete] : [.share, .finder, .delete] }

    /// One press. False only for B in the grid: the caller closes the Album
    @discardableResult func press(_ p: AlbumPress) -> Bool {
        guard working == nil else { return true }   // a trim being saved: wait
        switch mode {
        case .grid:
            switch p {
            case .left, .right, .up, .down:
                let d: AlbumGridMove.Direction = switch p { case .left: .left; case .right: .right; case .up: .up; default: .down }
                focus = AlbumGridMove.move(focus, d, groups: groups.map(\.items.count), columns: columns)
            case .a: open(focus)
            case .b: return false
            case .y: break
            }
        case .look:
            switch p {
            case .left: step(-1)
            case .right: step(1)
            case .a: if current?.kind == .recording { playRequests += 1 }
            case .y: if current.map({ !$0.downloading }) == true { mode = .actions(0) }
            case .b: close()
            case .up, .down: break
            }
        case .actions(let i):
            guard let item = current else { mode = .look; return true }
            let acts = actions(for: item)
            switch p {
            case .left: mode = .actions(max(i - 1, 0))
            case .right: mode = .actions(min(i + 1, acts.count - 1))
            case .a: perform(acts[min(i, acts.count - 1)])
            case .b, .y: mode = .look
            case .up, .down: break
            }
        case .confirmDelete:
            if p == .a { trash() } else if p == .b { mode = .look }
        case .trim:
            switch p {
            case .left: nudge(-0.5)
            case .right: nudge(0.5)
            case .up, .down: trim.editingEnd.toggle()
            case .a: Task { await saveTrim() }
            case .b: mode = .look
            case .y: break
            }
        }
        return true
    }

    func perform(_ a: Action) {
        guard let item = current, !item.downloading else { return }
        switch a {
        case .share:
            if let v = shareAnchor { NSSharingServicePicker(items: [item.url]).show(relativeTo: v.bounds, of: v, preferredEdge: .minY) }
        case .finder: NSWorkspace.shared.activateFileViewerSelecting([item.url])
        case .trim: Task { await beginTrim() }
        case .delete: mode = .confirmDelete
        }
    }

    /// The Finder's Move to Trash (Put Back works); the next item takes its place
    func trash() {
        guard let item = current else { return }
        do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
        catch { message = "Could not move it to the Trash: \(error.localizedDescription)"; mode = .look; return }
        let at = viewing ?? 0
        groups = groups.compactMap { g in let rest = g.items.filter { $0 != item }; return rest.isEmpty ? nil : Group(id: g.id, title: g.title, items: rest) }
        items = groups.flatMap(\.items)
        if items.isEmpty { close() } else { viewing = min(at, items.count - 1); focus = viewing!; mode = .look }
    }

    func beginTrim() async {
        guard let item = current, item.kind == .recording, !item.downloading else { return }
        let url = item.url
        let seconds = await Task.detached { (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0 }.value
        guard seconds.isFinite, seconds > AlbumTrim.minimumLength, current?.url == url else { message = "This recording could not be trimmed."; return }
        trim = Trim(start: 0, end: seconds, duration: seconds, editingEnd: false)
        mode = .trim; message = nil
    }
    func nudge(_ by: Double) {
        let gap = AlbumTrim.minimumLength
        if trim.editingEnd { trim.end = min(max(trim.end + by, trim.start + gap), trim.duration) }
        else { trim.start = max(min(trim.start + by, trim.end - gap), 0) }
    }
    func saveTrim() async {
        guard let item = current, mode == .trim else { return }
        working = "Saving the trimmed copy…"
        defer { working = nil }
        do {
            let out = try await AlbumTrim.export(item.url, start: trim.start, end: trim.end)
            await reload()
            if let i = items.firstIndex(where: { $0.url.standardizedFileURL == out.standardizedFileURL }) { open(i) } else { mode = .look }
            message = "Saved as a new recording. The original is unchanged."
        } catch {
            mode = .look
            message = (error as? LocalizedError)?.errorDescription ?? "The trimmed copy could not be saved."
        }
    }
}

/// The gallery's grid: each group's header, then its thumbnails. Home draws a focus ring on the focused tile; on the game page the mouse is enough
struct AlbumGrid: View {
    let browser: AlbumBrowser
    var fixedColumns: Int?          // Home: a fixed count, so up and down match what the player sees
    var tileHeight: CGFloat = 96
    var showFocus = false
    var showPlace = true

    var body: some View {
        let starts = Self.starts(browser.groups)
        let cols = fixedColumns.map { Array(repeating: GridItem(.flexible(), spacing: 16), count: $0) } ?? [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(Array(browser.groups.enumerated()), id: \.element.id) { gi, g in
                Text(g.title).font(showFocus ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(showFocus ? NX18Palette.text : .primary)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: cols, alignment: .leading, spacing: showFocus ? 20 : 12) {
                    ForEach(Array(g.items.enumerated()), id: \.element.id) { ii, item in
                        let i = starts[gi] + ii
                        AlbumThumb(item: item, height: tileHeight, focused: showFocus && browser.focus == i, showPlace: showPlace)
                            .id(item.url)
                            .onTapGesture(count: 2) { browser.open(i) }
                            .onTapGesture { if showFocus { browser.focus = i } else { browser.open(i) } }
                            .accessibilityAction { browser.open(i) }   // VoiceOver's activate opens it, as A or a click does
                    }
                }
            }
        }
    }
    /// Each group's first index in the browser's flat list
    static func starts(_ groups: [AlbumBrowser.Group]) -> [Int] {
        var out: [Int] = [], n = 0
        for g in groups { out.append(n); n += g.items.count }
        return out
    }
}

/// One capture's tile: its thumbnail (made when the tile first shows, AlbumThumbnails), a play badge on a recording, a cloud while iCloud has not brought it down
struct AlbumThumb: View {
    let item: AlbumItem
    var height: CGFloat = 96
    var focused = false
    var showPlace = true
    @State private var thumb: CGImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06))
                if let thumb { Image(decorative: thumb, scale: 2).resizable().scaledToFill() }
                else { Image(systemName: item.downloading ? "icloud.and.arrow.down" : "photo").font(.title).foregroundStyle(.secondary) }
                if item.kind == .recording { Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white, NX18Palette.coral) }
            }
            .frame(height: height).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(NX18Palette.brand, lineWidth: 4).padding(-5).opacity(focused ? 1 : 0))
            Text(item.date.formatted(date: .omitted, time: .shortened)).font(.caption).lineLimit(1)
                .foregroundStyle(focused ? NX18Palette.text : .secondary)
            if showPlace { Text(item.downloading ? "In iCloud" : item.place.rawValue).font(.caption2).foregroundStyle(.secondary) }
        }
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: focused ? 10 : 0, y: focused ? 6 : 0)   // lifts with the focus, as Home's tiles do
        .scaleEffect(focused && !reduceMotion ? 1.04 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: focused)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind == .recording ? "Recording" : "Screenshot"), \(item.date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityValue(item.downloading ? "In iCloud, downloads when opened" : item.place.rawValue)
        .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
        .task(id: "\(item.url.path)|\(item.downloading)") {   // a lazy grid: only tiles on screen get here, and leaving the screen cancels it
            thumb = nil
            if !item.downloading { thumb = await AlbumThumbnails.thumbnail(for: item.url, kind: item.kind) }
        }
    }
}
