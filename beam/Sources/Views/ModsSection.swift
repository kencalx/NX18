// The game page's Mods and Manual (beam-design §3.6, §3.9): kept mods with their credit, the sources' mods for this build, a mod file of the player's own,
// and the game's manual. Mods apply at the next build; the launcher's High frame rate and Ultrawide switches turn them on and off as today
import SwiftUI
import UniformTypeIdentifiers

struct ModsSection: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    @State private var kept: [ModStore.Kept] = []
    @State private var busy: String?
    @State private var addingFile: URL?
    @State private var pickFile = false
    @State private var pickManual = false

    var body: some View {
        if let g = library.games.first(where: { $0.id == gameID }), let ident = g.identity {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Mods").font(.headline)
                        Text("Frame rate and Ultrawide only").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if busy != nil { ProgressView().controlSize(.small) }
                        if !library.sources.isEmpty { Button("Check for Mod Updates") { Task { busy = "sources"; await library.refreshSources(); busy = nil } } }
                        Button("Add a Mod File…") { pickFile = true }
                    }
                    if kept.isEmpty && library.offers(for: g).isEmpty {
                        Text(library.sources.isEmpty ? "No mods. Add a mod source in Settings, or a mod file you got yourself." : "No mods for this game in your sources.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !library.beamKeepsMods(ident.titleId), let own = GameFolderMods.read(g.source), !own.isEmpty { gameFolderRows(own) }
                    ForEach(kept) { k in keptRow(k, g) }
                    if g.modsChanged == true { Text("Rebuild to apply the change.").font(.callout).foregroundStyle(NX18Palette.coral) }
                    ForEach(library.offers(for: g).filter { o in !kept.contains { $0.credit?.sha256 == o.entry.sha256.lowercased() } }) { o in offerRow(o, g) }
                    Divider()
                    manualRow(g)
                }
                .padding(6)
            }
            .task(id: g.modsChanged) { reload(ident.titleId) }
            .task { if library.sourceLists.isEmpty && !library.sources.isEmpty { await library.refreshSources() } }
            .fileImporter(isPresented: $pickFile, allowedContentTypes: [.zip, .data]) { r in if case .success(let u) = r { addingFile = u } }
            .fileImporter(isPresented: $pickManual, allowedContentTypes: [.pdf]) { r in if case .success(let u) = r { library.setManual(u, for: gameID) } }
            .sheet(isPresented: Binding(get: { addingFile != nil }, set: { if !$0 { addingFile = nil } })) {
                if let f = addingFile { AddModFileSheet(file: f) { kind, variant, author in
                    Task { busy = "file"; await library.addModFile(f, kind: kind, variant: variant, author: author, for: g); reload(ident.titleId); busy = nil }
                } }
            }
        }
    }

    private func reload(_ tid: String) { kept = ModStore.kept(titleID: tid) }

    /// The mods beside the game's files, which builds use while Beam keeps none of its own; Beam brings them in by itself before its first mod or cheat
    private func gameFolderRows(_ own: GameFolderMods) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("From the game's mods folder").font(.callout.weight(.semibold))
                Spacer()
                Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([own.folder]) }.font(.callout)
            }
            ForEach(own.mods) { m in
                HStack(spacing: 10) {
                    Image(systemName: m.kind == .ultrawide ? "rectangle.landscape.rotate" : m.kind == .framerate ? "speedometer" : "minus.circle")
                        .foregroundStyle(m.kind == nil ? NX18Palette.muted : m.kind == .ultrawide ? NX18Palette.coral : NX18Palette.cyan).frame(width: 20)
                    Text(m.name)
                    Spacer()
                    Text(m.kind?.label ?? "Left out: only frame-rate and Ultrawide mods are packed").font(.caption).foregroundStyle(.secondary)
                }
            }
            if own.cheatFiles > 0 { Text("\(own.cheatFiles) cheat file\(own.cheatFiles == 1 ? "" : "s"), packed with the build").font(.caption).foregroundStyle(.secondary) }
            Text("Builds use this folder as it is. When you add a mod or cheat in Beam, Beam brings these in too, so they stay in the build.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keptRow(_ k: ModStore.Kept, _ g: LibraryGame) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let kind = k.credit?.kind ?? GameFolderMods.kind(of: k.folder.lastPathComponent)
            Image(systemName: kind == .ultrawide ? "rectangle.landscape.rotate" : kind == .framerate ? "speedometer" : "minus.circle")
                .foregroundStyle(kind == nil ? NX18Palette.muted : kind == .ultrawide ? NX18Palette.coral : NX18Palette.cyan).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(k.folder.lastPathComponent)
                if let c = k.credit {
                    Text("\(c.source == nil ? "Added by you" : "By \(c.author)") · \(c.license ?? "License not stated")\(c.version.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    if c.kind == .framerate { Text("A higher frame rate uses more battery and heat on iPhone; the launcher's High frame rate switch turns it off.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("From the game's mods folder").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let h = k.credit?.homepage, let u = URL(string: h) { Link("Author's Page", destination: u).font(.callout) }
            Button("Remove") { library.removeMod(k, for: g); reload(g.identity?.titleId ?? "") }
        }
    }

    private func offerRow(_ o: Library.Offer, _ g: LibraryGame) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: o.entry.role == .ultrawide ? "rectangle.landscape.rotate" : "speedometer").foregroundStyle(o.fits ? NX18Palette.muted : NX18Palette.separator).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(o.entry.role?.label ?? "")\(o.entry.variant.map { ": \($0)" } ?? "") by \(o.entry.author)")
                Text("\(o.entry.license ?? "License not stated")\(o.entry.size.map { " · \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" } ?? "") · from \(o.source.name)")
                    .font(.caption).foregroundStyle(.secondary)
                if !o.fits { Text("For another version of the game").font(.caption).foregroundStyle(NX18Palette.coral) }
            }
            Spacer()
            if let h = o.entry.homepage, let u = URL(string: h) { Link("Author's Page", destination: u).font(.callout) }
            Button("Get") { Task { busy = o.id; await library.getMod(o, for: g); reload(g.identity?.titleId ?? ""); busy = nil } }
                .disabled(!o.fits || busy != nil)
        }
        .opacity(o.fits ? 1 : 0.6)
    }

    private func manualRow(_ g: LibraryGame) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed").foregroundStyle(NX18Palette.coral).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.manual.map { "Manual: \($0.lastPathComponent)" } ?? "Manual")
                Text(g.manual == nil ? "The game's manual (PDF), in the app's guide window." : "Goes into the app at the next build. Keep the app to your own devices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if g.manual != nil { Button("Remove") { library.setManual(nil, for: g.id) } }
            Button(g.manual == nil ? "Add Manual…" : "Replace…") { pickManual = true }
        }
    }
}

/// A mod file of the player's own: its kind (the packer takes frame-rate and Ultrawide mods only), the frame rate it is for, and whose it is
private struct AddModFileSheet: View {
    let file: URL
    let add: (ModKind, String?, String) -> Void
    @State private var kind: ModKind = .framerate
    @State private var variant = "60 fps"
    @State private var author = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Text(file.lastPathComponent).font(.headline)
            Picker("Kind", selection: $kind) { ForEach(ModKind.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            if kind == .framerate { TextField("Frame rate", text: $variant) }
            TextField("Author (for the credit)", text: $author)
            Text("Beam checks that the file holds only patches for this game's build. Only frame-rate and Ultrawide mods are taken.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { add(kind, kind == .framerate ? variant : nil, author); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

/// Settings' mod sources: added by URL, shown (name, maintainer, homepage) with the trust warning before they are saved
struct SourcesSection: View {
    @Environment(Library.self) private var library
    @State private var url = ""
    @State private var read: ModSource?
    @State private var reading = false
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(library.sources) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.name)
                        Text(s.maintainer.map { "By \($0)" } ?? s.url).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { library.removeSource(s) }
                }
            }
            HStack {
                TextField("Source address (https://…)", text: $url).onSubmit(readIt)
                Button("Read") { readIt() }.disabled(url.isEmpty || reading)
            }
            if let p = problem { Text(p).font(.callout).foregroundStyle(NX18Palette.coral) }
            if let s = read {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.name).font(.headline)
                    if let m = s.maintainer { Text("Maintained by \(m)") }
                    if let h = s.homepage, let u = URL(string: h) { Link(h, destination: u) }
                    Text("\(s.mods.filter { $0.role != nil }.count) frame-rate and Ultrawide mods").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { read = nil }
                        Button("Add Source") { library.addSource(url.trimmingCharacters(in: .whitespacesAndNewlines), s); read = nil; url = "" }.buttonStyle(.glassProminent)
                    }
                }
            }
        } header: { Text("Mod sources") } footer: {
            Text("Sources are run by mod authors, not by NX 18. Add only sources you trust. Beam reads a source only when you open a game's Mods or check for updates, and takes only frame-rate and Ultrawide code patches.")
        }
    }
    private func readIt() {
        problem = nil; read = nil; reading = true
        Task {
            do { read = try await library.readSource(url) } catch { problem = error.localizedDescription }
            reading = false
        }
    }
}
