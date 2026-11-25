// A game's page: what NX 18 says it is (--identify), its build buttons and the running build's progress (beam-design §3.2, §3.3)
import SwiftUI

struct GameDetailView: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    @State private var version: String?
    @State private var settingsSource: GameSettingsSource?

    var body: some View {
        if let game = library.games.first(where: { $0.id == gameID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(game)
                    if let job = library.jobs[gameID] { BuildProgressView(job: job) }
                    if let i = game.identity { facts(i) } else if library.identifying.contains(gameID) { ProgressView("Asking NX 18 what this game is…") }
                    if game.identity != nil { DevicesSection(gameID: gameID) }
                    if game.identity != nil { ModsSection(gameID: gameID) }
                    if game.identity != nil { CheatsSection(gameID: gameID); ArtSection(gameID: gameID); MyFilesSection(gameID: gameID) }
                    if let b = game.lastBuild { lastBuild(b) }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)   // the page fills the window, edge to edge with the padding
            }
            .background { HomeBackdrop(game: game, subtle: true) }   // the game's art, faintly, behind its page
            .navigationTitle(game.title)
            .sheet(isPresented: Binding(get: { settingsSource != nil }, set: { if !$0 { settingsSource = nil } })) {
                if let s = settingsSource { GameSettingsView(title: game.title, source: s) }
            }
            .toolbar {
                ToolbarItem {
                    Button("Read Again", systemImage: "arrow.clockwise") { library.identify(gameID) }.disabled(library.identifying.contains(gameID))
                }
                ToolbarItem {
                    Button("Remove from Library", systemImage: "minus.circle") { library.remove(gameID) }
                        .help("Removes the game from Beam's list. Its files are not touched.")
                }
            }
        }
    }

    private func header(_ game: LibraryGame) -> some View {
        HStack(alignment: .center, spacing: 18) {
            GameIcon(game: game, size: 88)
            VStack(alignment: .leading, spacing: 6) {
                GameTitle(title: game.title, logo: game.logo)
                Text(game.source.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let i = game.identity {
                    GlassEffectContainer(spacing: 8) { HStack(spacing: 8) {   // the floating buttons as one glass group (beam-design §4.5)
                        if library.macApp(gameID) != nil {
                            Button(library.playing == gameID ? "Playing" : "Play", systemImage: "play.fill") { library.play(gameID) }
                                .buttonStyle(.glassProminent).tint(NX18Palette.coral)
                                .disabled(library.playing != nil)
                            Button("Settings", systemImage: "slider.horizontal.3") { settingsSource = library.macApp(gameID).flatMap(GameSettingsSource.init(app:)) }
                                .buttonStyle(.glass)
                        }
                        Group {
                            Button("Build for iPhone and iPad", systemImage: "iphone") { library.build(gameID, target: .iPhone, package: chosen(i)) }
                            Button("Build for Mac", systemImage: "macbook") { library.build(gameID, target: .mac, package: chosen(i)) }
                        }
                        .buttonStyle(.glass)
                        .disabled(library.jobs[gameID]?.isActive ?? false)
                    } }
                    .padding(.top, 6)
                }
                if let end = library.lastEnd, end.game == gameID {
                    Label(end.message, systemImage: "exclamationmark.triangle").foregroundStyle(NX18Palette.coral).font(.callout)
                }
            }
        }
    }

    private func chosen(_ i: IdentifyEvent) -> String? { version == nil || version == i.packs ? nil : version }

    @ViewBuilder private func facts(_ i: IdentifyEvent) -> some View {
        if i.profile == nil {
            Label("NX 18 has not been tested with this game. It may not start. You can still build it.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(NX18Palette.coral)
        }
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("Title ID").foregroundStyle(.secondary); Text(i.titleId).monospaced().textSelection(.enabled) }
                GridRow { Text("System").foregroundStyle(.secondary); Text(i.isSwitch2 ? "Nintendo Switch 2" : "Nintendo Switch") }
                GridRow { Text("Files").foregroundStyle(.secondary); Text(kindName(i.kind)) }
                GridRow { Text("Profile").foregroundStyle(.secondary); Text(i.profile.map { $0 + (i.alias == true ? " (a regional release)" : "") } ?? "None (untested)") }
                if !i.dlc.isEmpty { GridRow { Text("DLC").foregroundStyle(.secondary); Text("\(i.dlc.count)") } }
                if i.programs.count > 1 { GridRow { Text("Programs").foregroundStyle(.secondary); Text(i.programs.joined(separator: ", ")).monospaced() } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        GroupBox("Versions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(i.versions.sorted { $0.number > $1.number }, id: \.version) { v in
                    HStack {
                        Image(systemName: (version ?? i.packs) == v.version ? "largecircle.fill.circle" : "circle").foregroundStyle(NX18Palette.coral)   // the one chosen: coral
                        Text(v.display ?? v.version).frame(minWidth: 80, alignment: .leading)
                        Text(v.build.map { "build \($0)" } ?? (v.note ?? "no code of its own")).monospaced().font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if v.registered == true { Text("Tested").font(.caption).foregroundStyle(NX18Palette.cyan) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { version = v.version }
                }
            }
            .padding(6)
        }
    }

    private func lastBuild(_ b: LibraryGame.BuildRecord) -> some View {
        GroupBox("Last build") {
            VStack(alignment: .leading, spacing: 6) {
                Label(b.ok ? "Built for \(b.target == .mac ? "Mac" : "iPhone and iPad")" : "Stopped", systemImage: b.ok ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(b.ok ? NX18Palette.cyan : NX18Palette.coral)
                Text(b.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                if let m = b.message { Text(m).textSelection(.enabled) }
                if let out = b.output {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: out)]) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func kindName(_ k: String) -> String {
        switch k { case "nsp": "NSP or XCI files"; case "nup": "NUP"; case "nx": "NX archive"; case "folder": "A folder of the game's files"; default: k }
    }
}

struct BuildProgressView: View {
    let job: BuildJob
    @State private var showLog = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let w = job.workDir, FileManager.default.fileExists(atPath: w.path) {
                        Button("Show Details") {   // the build folder's logs/, where every tool's full output is
                            let logs = w.appending(path: "logs")
                            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logs.path) ? logs : w)
                        }
                    }
                    if job.isActive { Button("Stop", role: .cancel) { job.cancel() } }
                }
                if job.state == .waitingForPower { Text("Waiting for the power adapter. The build starts when this Mac is plugged in.").font(.callout).foregroundStyle(.secondary) }
                if job.state == .checking { NX18Bar(); Text("Checking the space for the build…").font(.callout).foregroundStyle(.secondary) }
                if job.state == .running {
                    NX18Bar(value: job.overall)
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if case .failed(let why) = job.state { Text(why).foregroundStyle(NX18Palette.coral).textSelection(.enabled) }
                if job.warned { Text("Built without part of what it makes (see the messages).").font(.callout).foregroundStyle(.secondary) }
                if let m = job.mods, !m.leftOut.isEmpty || !m.offered.isEmpty {
                    Text("Mods: \(m.offered.map(\.mod).joined(separator: ", ").ifEmpty("none offered")); \(m.leftOut.count) left out").font(.callout).foregroundStyle(.secondary)
                }
                DisclosureGroup("Messages", isExpanded: $showLog) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(job.messages.enumerated()), id: \.offset) { _, s in
                                Text(s.text).font(.system(.caption, design: .monospaced)).foregroundStyle(s.isError ? NX18Palette.coral : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(6)
        }
    }
    private var title: String {
        switch job.state {
        case .running, .checking: "Building for \(job.target == .mac ? "Mac" : "iPhone and iPad")"
        case .waitingForPower: "Build when charging"
        case .done: "Built"
        case .failed: "The build stopped"
        case .cancelled: "Stopped"
        }
    }
    private var detail: String {
        var s = job.stageCount > 0 ? "Step \(job.stageIndex) of \(job.stageCount): \(job.stageName)" : job.stageName
        if let st = job.step, !st.isEmpty { s += " · \(st)" }
        if let eta = job.eta, eta > 1 { s += " · about \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))) left" }
        return s
    }
}

private extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }

/// The game page's title: the logo the player chose in Art (SteamGridDB) in its place, else the name. The logo keeps its shape in a band as tall as the title's two lines;
/// VoiceOver and the tooltip still read the name. A logo that is gone or unreadable falls back to the name
struct GameTitle: View {
    let title: String
    let logo: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: 440, maxHeight: 72, alignment: .leading)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .accessibilityLabel(title).help(title)
            } else {
                Text(title).font(.largeTitle.weight(.semibold)).lineLimit(2)
            }
        }
        .task(id: logo) { image = await Self.load(logo) }
    }

    nonisolated static func load(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
    }
}
