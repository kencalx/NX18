// The game page's Cheats, Art and My files (beam-design §3.7-§3.9), and Settings' SteamGridDB key
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CheatsSection: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    @State private var pick = false
    @State private var tick = 0   // re-reads the files after a change

    var body: some View {
        if let g = library.games.first(where: { $0.id == gameID }), let c = library.cheats(g) {
            let names = c.names, on = c.enabled
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cheats").font(.headline)
                        Text("for build \(c.build)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !names.isEmpty { Button("Remove") { library.removeCheats(for: g); tick += 1 } }
                        Button(names.isEmpty ? "Import Cheat File…" : "Replace…") { pick = true }
                    }
                    if names.isEmpty {
                        Text("Your own cheat file, named after the game's build (\(c.build).txt). Beam does not download cheats.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Toggle("Cheats on", isOn: Binding(get: { !c.allOff }, set: { library.setCheatsOff(!$0, for: g); tick += 1 }))
                        ForEach(names, id: \.self) { n in
                            Toggle(n, isOn: Binding(get: { on.contains(n) }, set: { library.setCheat(n, on: $0, for: g); tick += 1 }))
                                .disabled(c.allOff)
                        }
                        Text("These switches are for the Mac app, read when it starts. An iPhone build packs the file; turn cheats on in the game's in-game menu there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .id(tick)
            }
            .fileImporter(isPresented: $pick, allowedContentTypes: [.plainText, .data]) { r in if case .success(let u) = r { library.addCheats(u, for: g); tick += 1 } }
        }
    }
}

struct ArtSection: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    @State private var picking: ArtKind?

    var body: some View {
        if let g = library.games.first(where: { $0.id == gameID }), let ident = g.identity {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Art").font(.headline)
                        Spacer()
                        if !SteamGridKey.isSet { Text("Add a SteamGridDB key in Settings to choose art.").font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(ArtKind.allCases, id: \.self) { k in
                            let u: URL? = k == .keyArt ? g.art : k == .logo ? g.logo : g.icon
                            VStack(spacing: 6) {
                                Group {
                                    if let u, let img = NSImage(contentsOf: u) { Image(nsImage: img).resizable().scaledToFit() }
                                    else { Text("The build's own").font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(width: k == .keyArt ? 200 : 90, height: 90)
                                .background(RoundedRectangle(cornerRadius: 10).fill(NX18Palette.charcoal))
                                Text(k.label).font(.caption)
                                HStack(spacing: 6) {
                                    Button("Choose…") { picking = k }.disabled(!SteamGridKey.isSet)
                                    if u != nil { Button("Reset") { library.setArt(nil, k, for: g.id) } }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    Text("Without a pick, the build finds the game's banner in the public title list. Picks apply at the next build.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .sheet(item: $picking) { k in ArtPicker(kind: k, name: g.title, titleID: ident.titleId) { url in library.setArt(url, k, for: g.id) } }
        }
    }
}
extension ArtKind: Identifiable { var id: String { rawValue } }

private struct ArtPicker: View {
    let kind: ArtKind, name: String, titleID: String
    let chose: (URL) -> Void
    @State private var query = ""
    @State private var games: [GridGame] = []
    @State private var game: GridGame?
    @State private var images: [GridImage] = []
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var problem: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose \(kind.label.lowercased())").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            HStack {
                TextField("Game name", text: $query).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(busy)
            }
            if !games.isEmpty {
                Picker("Match", selection: Binding(get: { game?.id ?? -1 }, set: { id in game = games.first { $0.id == id }; Task { await load() } })) {
                    ForEach(games) { Text($0.name).tag($0.id) }
                }
            }
            if let problem { Text(problem).foregroundStyle(NX18Palette.coral).font(.callout) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == .keyArt ? 220 : 110), spacing: 10)], spacing: 10) {
                    ForEach(images) { img in
                        Button { Task { await pick(img) } } label: {
                            VStack(spacing: 2) {
                                Group { if let t = thumbs[img.id] { Image(nsImage: t).resizable().scaledToFit() } else { ProgressView() } }
                                    .frame(height: kind == .keyArt ? 80 : 100)
                                if let a = img.author?.name { Text("by \(a)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        .buttonStyle(.plain)
                        .task { await thumb(img) }
                    }
                }
            }
            Text("From SteamGridDB, made by its community. Your key is read from the Keychain for each request and never given to the build.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 720, height: 520)
        .task { query = name; await search() }
    }

    private func search() async {
        busy = true; problem = nil
        do { games = try await SteamGrid.search(query); game = games.first; await load() } catch { problem = error.localizedDescription }
        busy = false
    }
    private func load() async {
        guard let g = game else { return }
        do { images = try await SteamGrid.images(kind, game: g.id); thumbs = [:] } catch { images = []; problem = error.localizedDescription }
    }
    private func thumb(_ img: GridImage) async {
        guard thumbs[img.id] == nil, let u = URL(string: img.thumb), let d = try? await ModFetch.get(u), let i = NSImage(data: d) else { return }
        thumbs[img.id] = i
    }
    private func pick(_ img: GridImage) async {
        do { chose(try await SteamGrid.save(img, kind: kind, titleID: titleID)); dismiss() } catch { problem = error.localizedDescription }
    }
}

/// Settings: the SteamGridDB key, saved in the Keychain for this Mac only
struct ArtKeySection: View {
    @State private var key = ""
    @State private var set = SteamGridKey.isSet
    @State private var problem: String?
    var body: some View {
        Section {
            if set {
                HStack { Text("Key saved in the Keychain"); Spacer(); Button("Remove") { SteamGridKey.remove(); set = false } }
            } else {
                HStack {
                    SecureField("SteamGridDB key", text: $key)
                    Button("Save") { do { try SteamGridKey.save(key); key = ""; set = true; problem = nil } catch { problem = error.localizedDescription } }.disabled(key.isEmpty)
                }
            }
            if let problem { Text(problem).foregroundStyle(NX18Palette.coral) }
        } header: { Text("Art") } footer: {
            Text("Optional, for choosing key art, logos and icons from SteamGridDB (steamgriddb.com, Preferences, API). Kept in the Keychain on this Mac only and never given to the build.")
        }
    }
}
