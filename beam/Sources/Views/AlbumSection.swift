// The game page's Album (Album.swift): screenshots and recordings from the game apps, and the player's own documents (My files), newest first. Click opens Quick Look (space
// steps through them); right-click: Open, Show in Finder, Share, Move to Trash. The folders are read again every 10 s while the page shows, so a capture iCloud brings in appears
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct AlbumSection: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    @State private var items: [AlbumItem] = []
    @State private var preview: URL?
    @State private var adding = false
    @State private var sending = false

    var body: some View {
        if let g = library.games.first(where: { $0.id == gameID }), let tid = g.identity?.titleId {
            let mine = library.myFilesFolder(g), installs = library.installs(of: g.id)
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
                            if let mine { Button("My files") { open(mine) } }
                        }
                        .fixedSize()
                    }
                    if items.isEmpty {
                        Text("Screenshots you take in the game show here, with your own guides and maps. On iPhone or iPad, set This game's captures to NX 18 folder on the NX 18 card (tap the NX 18 mark on the Gate).")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(items) { item in
                                AlbumTile(item: item)
                                    .onTapGesture { if !item.downloading { preview = item.url } }
                                    .contextMenu { menu(item) }
                            }
                        }
                    }
                    let docs = items.filter { $0.place == .myFiles }
                    if !docs.isEmpty {
                        ForEach(installs) { r in
                            Button("Send My Files to \(r.deviceName)", systemImage: "iphone.and.arrow.forward") { Task { sending = true; await library.sendMyFiles(g, to: r); sending = false } }.disabled(sending)
                        }
                    }
                }
                .padding(6)
            }
            .quickLookPreview($preview, in: items.filter { !$0.downloading }.map(\.url))
            .fileImporter(isPresented: $adding, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard let mine, case .success(let urls) = r else { return }
                try? FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
                for u in urls { let ok = u.startAccessingSecurityScopedResource(); try? FileManager.default.copyItem(at: u, to: mine.appending(path: u.lastPathComponent)); if ok { u.stopAccessingSecurityScopedResource() } }
                reload(tid, mine)
            }
            .task(id: gameID) { while !Task.isCancelled { reload(tid, mine); try? await Task.sleep(for: .seconds(10)) } }
        }
    }

    private var nx18: URL? { Album.nx18Folder(chosen: library.settings.icloudNX18Folder) }
    private var summary: String {
        let shots = items.filter { $0.kind == .screenshot }.count, vids = items.filter { $0.kind == .recording }.count, docs = items.filter { $0.kind == .document }.count
        let parts = [shots > 0 ? "\(shots) screenshot\(shots == 1 ? "" : "s")" : nil, vids > 0 ? "\(vids) recording\(vids == 1 ? "" : "s")" : nil, docs > 0 ? "\(docs) document\(docs == 1 ? "" : "s")" : nil].compactMap { $0 }
        return parts.isEmpty ? "captures and your own files" : parts.joined(separator: ", ")
    }
    private func reload(_ tid: String, _ mine: URL?) {
        let nx = nx18
        let new = Album.items(titleID: tid, nx18: nx, myFiles: mine)
        if new != items { items = new }
    }
    private func open(_ dir: URL) { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); NSWorkspace.shared.open(dir) }

    @ViewBuilder private func menu(_ item: AlbumItem) -> some View {
        Button("Open") { NSWorkspace.shared.open(item.url) }.disabled(item.downloading)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        ShareLink(item: item.url).disabled(item.downloading)
        Divider()
        Button("Move to Trash", role: .destructive) {   // the Finder's own Move to Trash: put back from the Trash; a capture in iCloud Drive leaves it on every device
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            items.removeAll { $0.id == item.id }
        }
    }
}

/// One picture, recording or document: Quick Look's thumbnail, a play badge on a recording, and where it lives
private struct AlbumTile: View {
    let item: AlbumItem
    @State private var thumb: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.06))
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else { Image(systemName: item.downloading ? "icloud.and.arrow.down" : item.kind == .document ? "doc" : "photo").font(.title).foregroundStyle(.secondary) }
                if item.kind == .recording { Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white, NX18Palette.coral) }
            }
            .frame(height: 96).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.downloading { ProgressView().controlSize(.small).padding(6) }
            }
            Text(item.kind == .document ? item.url.lastPathComponent : item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.place.rawValue).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.kind == .document ? item.url.lastPathComponent : "\(item.kind == .recording ? "Recording" : "Screenshot"), \(item.date.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityValue(item.downloading ? "Downloading from iCloud" : item.place.rawValue)
        .accessibilityAddTraits(.isButton)
        .task(id: "\(item.url.path)\(item.downloading)") { if !item.downloading { thumb = await Self.thumbnail(item.url) } }
    }
    static func thumbnail(_ url: URL) async -> NSImage? {
        let r = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 130), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: r).nsImage
    }
}
