// Where Beam's builds take space (beam-design B2, storage view): per game, its files, its build folder and the app it made. A build folder can go to the Trash
// (the next build of that game starts over and takes longer); the game's own files are never touched, and NX Play's <title ID>_build folders are not Beam's
import AppKit
import SwiftUI

struct StorageRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    var game: Int64, build: Int64?, output: Int64?
    let buildFolder: URL?, outputPath: URL?
}

enum Storage {
    /// Bytes a folder or file takes on disk (allocated size: APFS clones count where they were made, so a Mac app made of clones shows its own size)
    static func bytes(_ u: URL) -> Int64? {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func size(_ f: URL) -> Int64 {
            let v = try? f.resourceValues(forKeys: Set(keys))
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        if !dir.boolValue { return size(u) }
        var total: Int64 = 0
        let e = fm.enumerator(at: u, includingPropertiesForKeys: keys, options: []) { _, _ in true }
        while let f = e?.nextObject() as? URL { if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { total += size(f) } }
        return total
    }

    static func rows(_ games: [LibraryGame], buildSpace: URL?) -> [StorageRow] {
        games.map { g in
            let work = g.identity.map { BuildRequest.defaultWorkDir(source: g.source, titleId: $0.titleId, buildSpace: buildSpace) }
            let out = g.lastBuild?.output.map { URL(fileURLWithPath: $0) }
            return StorageRow(id: g.id, title: g.title, game: Preflight.gameBytes(g.source), build: work.flatMap(bytes), output: out.flatMap(bytes),
                              buildFolder: work, outputPath: out)
        }
    }
}

struct StorageView: View {
    @Environment(Library.self) private var library
    @Environment(BeamSettings.self) private var settings
    @State private var rows: [StorageRow] = []
    @State private var loading = false
    @State private var trashing: StorageRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Storage").font(.title2.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading)
            }
            Table(rows) {
                TableColumn("Game", value: \.title)
                TableColumn("Game files") { r in Text(size(r.game)).monospacedDigit() }.width(100)
                TableColumn("Build folder") { r in Text(r.build.map(size) ?? "None").monospacedDigit() }.width(100)
                TableColumn("App") { r in Text(r.output.map(size) ?? "None").monospacedDigit() }.width(100)
                TableColumn("") { r in
                    HStack {
                        if let b = r.buildFolder, r.build != nil {
                            Button("Show", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([b]) }.labelStyle(.iconOnly)
                            Button("Move to Trash", systemImage: "trash") { trashing = r }.labelStyle(.iconOnly)
                                .disabled(library.jobs[r.id]?.isActive ?? false)
                        }
                    }
                }.width(70)
            }
            HStack {
                Text("Build folders: \(size(rows.compactMap(\.build).reduce(0, +))) · Apps: \(size(rows.compactMap(\.output).reduce(0, +)))")
                Spacer()
                if let free = Preflight.freeBytes(at: settings.buildSpace ?? URL.homeDirectory) { Text("\(size(free)) free") }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 360)
        .task { await load() }
        .confirmationDialog("Move \(trashing?.title ?? "this game")'s build folder to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let b = trashing?.buildFolder { NSWorkspace.shared.recycle([b]) { _, _ in Task { await load() } } }
                trashing = nil
            }
        } message: {
            Text("The game's own files and its app stay. Its next build starts over and takes longer.")
        }
    }

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    private func load() async {
        loading = true
        let games = library.games, space = settings.buildSpace
        rows = await Task.detached { Storage.rows(games, buildSpace: space) }.value
        loading = false
    }
}
