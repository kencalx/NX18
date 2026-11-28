// The game page's Album (Album.swift, AlbumGallery.swift): the game's screenshots and recordings as a console's Album shows them, in days, newest first, then the
// player's own documents (My files). A capture opens in the Album's viewer (left and right, Share, Show in Finder, Trim, Move to Trash); a document in Quick Look.
// The folders are read when the page opens and when Beam comes back to the front: nothing watches them in between
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct AlbumSection: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    @State private var browser: AlbumBrowser?
    @State private var docs: [AlbumItem] = []
    @State private var preview: URL?
    @State private var adding = false
    @State private var sending = false
    @State private var leftInNX18 = 0   // with the switch off: files in the NX 18 folder's Documents for this game that Beam did not put there (they stay, MyFilesPlace.swift)

    var body: some View {
        if let g = library.games.first(where: { $0.id == gameID }), let tid = g.identity?.titleId {
            let mine = library.myFilesFolder(g), installs = library.installs(of: g.id), inNX18 = library.myFilesNX18 != nil
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Album").font(.headline)
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Files…", systemImage: "plus") { adding = true }
                        Menu("Show Folder") {
                            if let nx = nx18 { Button("Captures in iCloud Drive") { open(Album.capturesFolders(titleID: tid, nx18: nx)[0].0) } }
                            Button("Captures on this Mac") { open(Album.capturesFolders(titleID: tid, nx18: nil)[0].0) }
                            if let mine { Button(inNX18 ? "My files in the NX 18 folder" : "My files") { open(mine) } }
                        }
                        .fixedSize()
                    }
                    if let browser, !browser.items.isEmpty { AlbumGrid(browser: browser) }
                    if (browser?.items.isEmpty ?? true) && docs.isEmpty {
                        Text("No captures yet. Screenshots and recordings you take in the game show here, with your own guides and maps. On iPhone or iPad, set This game's captures to NX 18 folder on the NX 18 card (tap the NX 18 mark on the Gate).")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !docs.isEmpty || library.settings.myFilesInNX18 || leftInNX18 > 0 {
                        HStack(alignment: .firstTextBaseline) {
                            Text("My files").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            Text(whereNote(tid: tid)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !docs.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(docs) { item in
                                DocumentTile(item: item)
                                    .onTapGesture { if !item.downloading { preview = item.url } else { Album.fetch(item.url) } }
                                    .contextMenu { menu(item) }
                            }
                        }
                        ForEach(installs) { r in
                            Button("Send My Files to \(r.deviceName)", systemImage: "iphone.and.arrow.forward") { Task { sending = true; await library.sendMyFiles(g, to: r); sending = false } }.disabled(sending)
                                .help(inNX18 ? "Not needed when the game on \(r.deviceName) has the same NX 18 folder connected: it shows these already. This copies them into the game itself." : "Copies these into the game on \(r.deviceName), which shows them while you play.")
                        }
                    }
                }
                .padding(6)
            }
            .quickLookPreview($preview, in: docs.filter { !$0.downloading }.map(\.url))
            .sheet(isPresented: Binding(get: { browser?.viewing != nil }, set: { if !$0 { browser?.close() } })) {
                if let browser { AlbumViewerSheet(browser: browser) }
            }
            .fileImporter(isPresented: $adding, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard let mine, case .success(let urls) = r else { return }
                let library = library.folder, into = self.library.myFilesNX18   // the NX 18 folder My files are in now (nil: Beam's), which the ledger notes the name under
                Task {
                    await Task.detached(priority: .userInitiated) {   // never over a file already there: a name taken gets " 2" (MyFilesPlace.add); coordinated, as the NX 18 folder is in iCloud Drive
                        for u in urls {
                            let ok = u.startAccessingSecurityScopedResource()
                            if let name = MyFilesPlace.add(u, into: mine), let into { MyFilesPlace.noteAdded(name, titleID: tid, library: library, nx18: into) }
                            if ok { u.stopAccessingSecurityScopedResource() }
                        }
                    }.value
                    await reload(mine)
                }
            }
            .task(id: gameID) {   // the page opened (or another game's): a fresh Album, read once
                browser = AlbumBrowser { Self.captures(titleID: tid) }
                await library.settleMyFiles(titleIDs: [tid])   // an NX 18 folder connected since the switch, or files still in iCloud then: brought where the switch says
                await reload(library.myFilesFolder(g))
                Task.detached(priority: .background) { AlbumThumbnails.prune() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await reload(mine) } }
            .onChange(of: library.myFilesSettled) { Task { await reload(library.myFilesFolder(g)) } }   // the switch moved them (Settings): read where they are now
            .onChange(of: mine) { Task { await reload(mine) } }
        }
    }

    /// The game's captures in days, read off the main thread (AlbumBrowser.reload)
    nonisolated static func captures(titleID: String) -> [AlbumBrowser.Group] {
        let items = Album.items(titleID: titleID, nx18: Album.nx18Folder(chosen: nil), myFiles: nil).filter { $0.kind != .document }
        let now = Date.now
        return AlbumGrouping.days(items).map { AlbumBrowser.Group(id: $0.day.ISO8601Format(), title: AlbumGrouping.title(of: $0.day, now: now), items: $0.items) }
    }

    private var nx18: URL? { Album.nx18Folder(chosen: nil) }
    private var summary: String {
        let items = browser?.items ?? []
        let shots = items.filter { $0.kind == .screenshot }.count, vids = items.filter { $0.kind == .recording }.count, d = docs.count
        let parts = [shots > 0 ? "\(shots) screenshot\(shots == 1 ? "" : "s")" : nil, vids > 0 ? "\(vids) recording\(vids == 1 ? "" : "s")" : nil, d > 0 ? "\(d) document\(d == 1 ? "" : "s")" : nil].compactMap { $0 }
        return parts.isEmpty ? "captures and your own files" : parts.joined(separator: ", ")
    }
    private func reload(_ mine: URL?) async {
        await browser?.reload()
        guard let g = library.games.first(where: { $0.id == gameID }), let tid = g.identity?.titleId else { return }
        let place: AlbumItem.Place = library.myFilesNX18 != nil ? .nx18 : .myFiles
        // with the switch off and a folder connected: what Beam leaves in the NX 18 folder's Documents (another device's, or the player's), counted for the note
        let other = library.settings.myFilesInNX18 ? nil : ProfileSetup.connectedFolder().map { GameDocuments.nx18Folder(titleID: tid, nx18: $0) }
        let (new, left) = await Task.detached(priority: .userInitiated) {
            (mine.map { Album.read($0, place: place, captures: false, download: false).sorted { $0.date > $1.date } } ?? [],
             other.map { Album.read($0, place: .nx18, captures: false, download: false).count } ?? 0)
        }.value
        if new != docs { docs = new }
        if left != leftInNX18 { leftInNX18 = left }
    }
    /// Where this game's My files are, in a line beside the heading
    private func whereNote(tid: String) -> String {
        if let nx = library.myFilesNX18 { return "In the NX 18 folder (\(nx.lastPathComponent) › \(tid.uppercased()) › \(GameDocuments.folderName)): your games on every device connected to it show them while you play." }
        if library.settings.myFilesInNX18 { return "In Beam on this Mac until you connect an NX 18 folder in Settings › Profile." }
        let left = leftInNX18 > 0 ? " \(leftInNX18) more in the NX 18 folder (\(tid.uppercased()) › \(GameDocuments.folderName)) stay there for your other devices." : ""
        return "In Beam on this Mac." + left
    }
    private func open(_ dir: URL) { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); NSWorkspace.shared.open(dir) }

    @ViewBuilder private func menu(_ item: AlbumItem) -> some View {
        Button("Open") { NSWorkspace.shared.open(item.url) }.disabled(item.downloading)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        ShareLink(item: item.url).disabled(item.downloading)
        Divider()
        Button("Move to Trash", role: .destructive) {   // the Finder's own Move to Trash: put back from the Trash
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            docs.removeAll { $0.id == item.id }
        }
    }
}

/// The viewer in a sheet on the game page, with the keys: left and right move, Return or Space plays or pauses, Escape goes back, Delete asks to move it to the Trash
struct AlbumViewerSheet: View {
    let browser: AlbumBrowser
    @FocusState private var keys: Bool
    var body: some View {
        AlbumViewer(browser: browser)
            .frame(minWidth: 900, idealWidth: 1120, minHeight: 620, idealHeight: 760)
            .focusable().focused($keys).focusEffectDisabled()
            .onAppear { keys = true }
            .onKeyPress(.leftArrow) { browser.press(.left); return .handled }
            .onKeyPress(.rightArrow) { browser.press(.right); return .handled }
            .onKeyPress(.upArrow) { browser.press(.up); return .handled }
            .onKeyPress(.downArrow) { browser.press(.down); return .handled }
            .onKeyPress(.return) { browser.press(.a); return .handled }
            .onKeyPress(.space) { browser.press(.a); return .handled }
            .onKeyPress(.escape) { browser.press(.b); return .handled }
            .onKeyPress(.delete) { if browser.mode == .look, browser.current?.downloading == false { browser.mode = .confirmDelete }; return .handled }
            .onExitCommand { browser.press(.b) }
    }
}

/// One of the player's own documents: Quick Look's thumbnail and its name
private struct DocumentTile: View {
    let item: AlbumItem
    @State private var thumb: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06))
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else { Image(systemName: item.downloading ? "icloud.and.arrow.down" : "doc").font(.title).foregroundStyle(.secondary) }
            }
            .frame(height: 96).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.place.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.url.lastPathComponent)
        .accessibilityValue(item.downloading ? "Downloading from iCloud" : item.place.rawValue)
        .accessibilityAddTraits(.isButton)
        .task(id: "\(item.url.path)\(item.downloading)") { if !item.downloading { thumb = await Self.thumbnail(item.url) } }
    }
    static func thumbnail(_ url: URL) async -> NSImage? {
        let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 130), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).nsImage
    }
}
