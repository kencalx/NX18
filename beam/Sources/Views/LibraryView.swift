// The library window: the games in a sidebar, the chosen one's page beside it (beam-design §3.2), the welcome until the player has seen it (§3.1)
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(BeamSettings.self) private var settings
    @State private var selection: UUID?
    @State private var picking = false
    @State private var dropping = false
    @State private var importLib: NXPlayLibrary?

    var body: some View {
        Group {
            if settings.welcomed {
                NavigationSplitView {
                    List(selection: $selection) {
                        Section("Games") {
                            ForEach(library.games) { g in GameRow(game: g).tag(g.id) }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .overlay { if library.games.isEmpty { Text("No games yet").foregroundStyle(.secondary) } }
                    .toolbar { ToolbarItem { Button("Add a Game", systemImage: "plus") { picking = true } } }
                } detail: {
                    if let id = selection, library.games.contains(where: { $0.id == id }) {
                        GameDetailView(gameID: id)
                    } else {
                        AddGameTile(dropping: dropping) { picking = true }
                    }
                }
            } else {
                WelcomeView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in selection = library.add(url); settings.welcomed = true }
                }
            }
            return !providers.isEmpty
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { for u in urls { selection = library.add(u) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .beamAddGame)) { _ in picking = true }
        .onChange(of: library.lastAdded) { _, id in if let id { selection = id } }
        .onReceive(NotificationCenter.default.publisher(for: .beamImportNXPlay)) { _ in importLib = NXPlayLibrary.find() }
        .sheet(isPresented: Binding(get: { importLib != nil }, set: { if !$0 { importLib = nil } })) { if let l = importLib { NXPlayImportSheet(lib: l) } }
        .alert("Make room on \(library.swapQuestion?.device.name ?? "the device")?", isPresented: Binding(get: { library.swapQuestion != nil }, set: { if !$0 { library.swapQuestion = nil } })) {
            Button("Swap Games") { if let q = library.swapQuestion { library.install(q.gameID, on: q.device, swap: true) }; library.swapQuestion = nil }
            Button("Cancel", role: .cancel) { library.swapQuestion = nil }
        } message: {
            Text("A free Apple account can have 3 apps on a device. Beam can remove \(library.swapQuestion?.victimTitle ?? "the game played least recently") after copying its save to this Mac, and puts the save back when you install it again.")
        }
        .alert("This Mac is on battery", isPresented: Binding(get: { library.batteryQuestion != nil }, set: { if !$0 { library.batteryQuestion = nil } })) {
            Button("Build Now") { if let q = library.batteryQuestion { library.build(q.id, target: q.target, package: q.package, now: true) }; library.batteryQuestion = nil }
            Button("When Plugged In") { if let q = library.batteryQuestion { library.build(q.id, target: q.target, package: q.package, whenCharging: true) }; library.batteryQuestion = nil }
            Button("Cancel", role: .cancel) { library.batteryQuestion = nil }
        } message: {
            Text("A first build takes 30 to 60 minutes and uses a lot of power. Build now, or when this Mac is plugged in?")
        }
        .alert("Beam", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK") { library.lastError = nil }
        } message: { Text(library.lastError ?? "") }
        .tint(NX18Palette.cyan)
    }
}

private struct GameRow: View {
    @Environment(Library.self) private var library
    let game: LibraryGame
    var body: some View {
        HStack(spacing: 10) {
            GameIcon(game: game, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).lineLimit(1)
                Group {
                    if library.identifying.contains(game.id) { Text("Reading…") }
                    else if library.playing == game.id { Text("Playing") }
                    else if let job = library.jobs[game.id], job.isActive { Text(job.state == .waitingForPower ? "Build when charging" : "Building · \(job.stageName)") }
                    else if let i = game.identity { Text(i.isSwitch2 ? "Switch 2" : "Switch") }
                    else { Text("Not read yet") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GameIcon: View {
    let game: LibraryGame
    let size: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Group {
            if let path = game.lastBuild?.icon, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    NX18Palette.charcoal
                    Text(String(game.title.prefix(1))).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(NX18Palette.cyan)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
    }
}

private struct AddGameTile: View {
    var dropping: Bool
    var add: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.rectangle.on.folder").font(.system(size: 44, weight: .light)).foregroundStyle(NX18Palette.cyan)
            Text("Add a game").font(.title2.weight(.semibold))
            Text("Drop a folder of your game's files, a .nup or an .nx here, or choose one.\nYour legally owned and acquired game files stay where they are.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Choose…", action: add).buttonStyle(.glassProminent).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropping ? NX18Palette.cyan.opacity(0.08) : .clear)
    }
}
