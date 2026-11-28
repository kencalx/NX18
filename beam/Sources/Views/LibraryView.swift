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
    @State private var whatsNew = false
    @State private var newName = ""

    var body: some View {
        Group {
            if settings.welcomed && library.showingHome {
                HomeView()   // the same window, as the console view (View > Beam Home, ⌃⌘H, or the toolbar's controller button)
            } else if settings.welcomed {
                NavigationSplitView {
                    List(selection: $selection) {
                        Section("Games") {
                            ForEach(library.games) { g in GameRow(game: g).tag(g.id).contextMenu { GameContextMenu(gameID: g.id) } }
                        }
                    }
                    .safeAreaInset(edge: .bottom) { RebuildBar() }   // NX 18 moved on: the games it changed, rebuilt three at a time
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .overlay { if library.games.isEmpty { Text("No games yet").foregroundStyle(.secondary) } }
                    .toolbar {
                        ToolbarItem { Button("Add a Game", systemImage: "plus") { picking = true } }
                        ToolbarItem { Button("Beam Home", systemImage: "gamecontroller") { library.showingHome = true }.help("Beam Home: your games full screen, for a controller (⌃⌘H)") }
                        if library.renewDue() {   // an install on an iPhone or iPad runs out within 2 days, or has
                            ToolbarItem {
                                Button(library.renewingAll ? "Renewing…" : "Renew All", systemImage: "arrow.clockwise") { library.renewAll() }
                                    .disabled(library.renewingAll)
                                    .help("Renew every game that expires within 2 days on a connected iPhone or iPad")
                            }
                        }
                    }
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
        .onChange(of: library.pageRequest) { _, id in if let id { selection = id; library.pageRequest = nil } }
        .task(id: settings.welcomed) {   // after the welcome: What's new once per version, and the daily update check when it is on
            guard settings.welcomed else { return }
            if settings.whatsNewSeen != BeamUpdate.currentVersion { whatsNew = true; settings.whatsNewSeen = BeamUpdate.currentVersion }
            await library.checkForUpdateIfDue()
            await library.checkRebuilds()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in   // the NX 18 checkout may have moved while Beam was away
            if settings.welcomed { Task { await library.checkRebuilds() } }
        }
        .sheet(isPresented: $whatsNew) { WhatsNewSheet() }
        .alert("Rename \(library.games.first { $0.id == library.renameRequest }?.title ?? "the game")",
               isPresented: Binding(get: { library.renameRequest != nil }, set: { if !$0 { library.renameRequest = nil } })) {
            TextField(library.games.first { $0.id == library.renameRequest }?.identity?.name ?? "Name", text: $newName)
            Button("Rename") { if let id = library.renameRequest { library.rename(id, to: newName) }; library.renameRequest = nil }
            Button("Cancel", role: .cancel) { library.renameRequest = nil }
        } message: {
            Text("The new name shows in Beam, and the app gets it at its next build. Leave it empty for the game's own name.")
        }
        .onChange(of: library.renameRequest) { _, id in newName = id.flatMap { i in library.games.first { $0.id == i }?.customName } ?? "" }
        .sheet(isPresented: Binding(get: { library.settingsRequest != nil }, set: { if !$0 { library.settingsRequest = nil } })) {   // one settings sheet for the library and Beam Home
            if let id = library.settingsRequest, let src = library.library_settingsSource(id) {
                GameSettingsView(title: library.games.first { $0.id == id }?.title ?? "Game", source: src)
            }
        }
        .safeAreaInset(edge: .top) {
            if let r = library.updateAvailable, let u = URL(string: r.htmlUrl) {
                HStack {
                    Image(systemName: "arrow.down.circle").foregroundStyle(NX18Palette.coral)
                    switch library.updateStep {
                    case .working(let what)?:
                        Text("\(r.name ?? r.tagName): \(what)"); ProgressView().controlSize(.small)
                    case .failed(let why)?:
                        Text(why)
                        Link("See the release", destination: u)
                    case nil:
                        Text("\(r.name ?? r.tagName) is available.")
                        Link("See the release", destination: u)
                    }
                    Spacer()
                    if library.updateStep?.isWorking != true {
                        Button("Later") { library.updateAvailable = nil; library.updateStep = nil }
                    }
                    if library.canInstallUpdate, library.updateStep == nil {   // the preferred action last, at the trailing edge (macOS 27)
                        Button("Install and Relaunch") { library.installUpdate() }
                            .buttonStyle(.glassProminent)
                            .disabled(library.busyForUpdate)
                            .help(library.busyForUpdate ? "Beam installs its update once the builds and installs finish." : "")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))   // the system's glass, as the toolbar's: it frosts itself under Reduce Transparency and Increase Contrast
                .padding(.horizontal, 12).padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Beam update")
            }
        }
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
        .alert("Renew All", isPresented: Binding(get: { library.renewNote != nil && !library.showingHome }, set: { if !$0 { library.renewNote = nil } })) {   // Home says it in its own top bar
            Button("OK") { library.renewNote = nil }
        } message: { Text(library.renewNote ?? "") }
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
                    else if let e = library.expiryBadge(game.id) { Label(e.text, systemImage: e.expired ? "exclamationmark.circle.fill" : "clock").foregroundStyle(NX18Palette.coral) }
                    else if library.rebuilds[game.id] != nil { Label("Update available: rebuild", systemImage: "arrow.triangle.2.circlepath").labelStyle(.titleAndIcon) }
                    else if let i = game.identity { Text(i.isSwitch2 ? "Switch 2" : "Switch") }
                    else { Text("Not read yet") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Below the games, only while NX 18 changed some built ones: rebuild them (three at a time), or how far a rebuild is, or tonight's
private struct RebuildBar: View {
    @Environment(Library.self) private var library
    var body: some View {
        let n = library.rebuildCandidates.count
        if let p = library.rebuildProgress {
            HStack {
                Text("Rebuilding updated games: \(min(p.done + 1, p.total)) to \(min(p.done + 3, p.total)) of \(p.total)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { library.stopRebuilding() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        } else if let t = library.tonight {
            HStack {
                Text("Rebuilding updated games at \(t.formatted(date: .omitted, time: .shortened))").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { library.cancelTonight() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        } else if n > 0 {
            Button { library.rebuildUpdated() } label: {
                Label(n == 1 ? "Rebuild 1 Updated Game" : "Rebuild \(n) Updated Games", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .help("NX 18 changed since these games were built. Beam rebuilds them three at a time and keeps this Mac awake until they are done.")
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}

struct GameIcon: View {
    let game: LibraryGame
    let size: CGFloat

    /// The game's picture: the player's own pick, else the icon of Beam's latest build, else the icon NX Play cached for the game (read only, as the build
    /// script reads it: NXPLAY_ICONS) or Beam's copy of it, else none (the tile shows the name's first letter)
    static func image(for g: LibraryGame) -> NSImage? {
        for case let p? in [g.icon?.path, g.builtIcon, g.lastBuild?.icon] { if let i = NSImage(contentsOfFile: p) { return i } }
        return g.identity.flatMap { NXPlayPicture.image(.icon, titleID: $0.titleId) }
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Group {
            if let img = GameIcon.image(for: game) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    NX18Palette.charcoal
                    Text(String(game.title.prefix(1))).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(NX18Palette.accent(for: game.title))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
        .accessibilityHidden(true)   // the game's name is read beside it
    }
}

/// A picture NX Play keeps for a game in its cache folder (Banners/icons/<title ID>.jpg, Banners/<title ID>.jpg), read only. A cache is the system's to clear
/// (a disk cleanup emptied it on 2026-11-25 and every game Beam had not built lost its icon), so the first time Beam sees one it keeps a copy in its own Art
/// folder (Art/<title ID>/nxplay-icon.jpg, nxplay-banner.jpg: names the player's picks never take) and falls back to that copy while the cache has none
enum NXPlayPicture: String {
    case icon, banner
    static func image(_ kind: NXPlayPicture, titleID: String, cache: URL = URL.libraryDirectory.appending(path: "Caches/com.varyform.nxplay/Banners"),
                      art: URL = Library.defaultFolder.appending(path: "Art")) -> NSImage? {
        let tid = titleID.uppercased(), fm = FileManager.default
        let src = (kind == .icon ? cache.appending(path: "icons") : cache).appending(path: "\(tid).jpg")
        let kept = art.appending(path: tid, directoryHint: .isDirectory).appending(path: "nxplay-\(kind.rawValue).jpg")
        if let img = NSImage(contentsOfFile: src.path) {
            if !fm.fileExists(atPath: kept.path) {
                try? fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: src, to: kept)
            }
            return img
        }
        return NSImage(contentsOfFile: kept.path)
    }
}

private struct AddGameTile: View {
    var dropping: Bool
    var add: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.rectangle.on.folder").font(.system(size: 44, weight: .light)).foregroundStyle(NX18Palette.brand)
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
