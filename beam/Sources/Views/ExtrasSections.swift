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
    @State private var framing = false          // Adjust Framing's sheet (ArtFramingSheet)
    @State private var pickedKeyArt = false     // a new key art was just picked: its framing opens once the picker has closed

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
                                    // the part of the key art the Gate shows: the pick, else the art the last build used (never a banner only NX Play has: the build may pack another)
                                    if k == .keyArt, HomeBackdrop.packedArt(for: g) != nil { Button("Adjust Framing…") { framing = true } }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    Text("Without a pick, the build finds the game's banner in the public title list. Picks apply at the next build.").font(.caption).foregroundStyle(.secondary)
                    if HomeBackdrop.packedArt(for: g) == nil { Text("To frame the key art, choose one or build the game once: framing is made on the picture the game will show.").font(.caption).foregroundStyle(.secondary) }
                    if g.artFocus != nil { Text("Key art framed: Beam Home shows it now, a Mac app at its next start, an iPhone or iPad from its next build.").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(6)
            }
            .sheet(item: $picking, onDismiss: { if pickedKeyArt { pickedKeyArt = false; framing = true } }) { k in
                ArtPicker(kind: k, name: g.title, titleID: ident.titleId) { url in library.setArt(url, k, for: g.id); if k == .keyArt { pickedKeyArt = true } }
            }
            .sheet(isPresented: $framing) {
                if let img = HomeBackdrop.packedArt(for: g) { ArtFramingSheet(image: img, start: g.artFocus ?? .centre) { library.setArtFocus($0, for: g.id) } }
            }
        }
    }
}
extension ArtKind: Identifiable { var id: String { rawValue } }

/// Adjust Framing: which part of the key art the Gate shows (ArtFocus.swift), framed on the iPhone's shape with the other shapes the Gate draws beside it. Drag the picture, the arrow
/// keys move the window over it, a trackpad's pinch or + and − zoom; Reset centres it. Done keeps it in Beam's library (LibraryGame.artFocus)
struct ArtFramingSheet: View {
    let image: NSImage
    let save: (ArtFocus) -> Void
    @State private var focus: ArtFocus
    @Environment(\.dismiss) private var dismiss
    private let main: CGSize   // the iPhone's landscape art side, at 300 pt tall

    init(image: NSImage, start: ArtFocus, save: @escaping (ArtFocus) -> Void) {
        self.image = image; self.save = save; _focus = State(initialValue: start)
        let s = ArtFocus.gateShapes[0].size; main = CGSize(width: (s.width / s.height * 300).rounded(), height: 300)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjust Framing").font(.headline)
            Text("Choose the part of the key art the Gate shows. Drag the picture or use the arrow keys; pinch on a trackpad or press + and − to zoom.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                shape(ArtFocus.gateShapes[0].name, size: main) {
                    ArtFramingSurface(image: Image(nsImage: image), natural: image.size, focus: $focus)
                }
                VStack(alignment: .leading, spacing: 12) {   // the other shapes, as the framing shows in each
                    ForEach(ArtFocus.gateShapes.dropFirst(), id: \.name) { s in
                        let side: CGFloat = s.size.width >= s.size.height ? 220 : 120
                        let size = s.size.width >= s.size.height ? CGSize(width: side, height: (side * s.size.height / s.size.width).rounded()) : CGSize(width: (side * s.size.width / s.size.height).rounded(), height: side)
                        shape(s.name, size: size) { FramedArt(image: Image(nsImage: image), natural: image.size, focus: focus).accessibilityHidden(true) }
                    }
                }
            }
            Text("Beam Home and this page show it now, a Mac app at its next start, and an iPhone or iPad from its next build. A framing made in the game's own Gate comes first there.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reset") { focus = .centre }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save(focus); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { k in
            let dx = k.key == .leftArrow ? -1 : k.key == .rightArrow ? 1 : 0, dy = k.key == .upArrow ? -1 : k.key == .downArrow ? 1 : 0
            focus = ArtFocus.nudged(focus, dx: dx, dy: dy, image: image.size, view: main)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-−")) { k in
            let up = k.characters == "+" || k.characters == "="
            focus = ArtFocus.zoomed(focus, to: focus.zoom + (up ? 1 : -1) * ArtFocus.zoomStep, image: image.size, view: main)
            return .handled
        }
    }

    private func shape(_ name: String, size: CGSize, @ViewBuilder _ art: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            art().frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)))
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}

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
