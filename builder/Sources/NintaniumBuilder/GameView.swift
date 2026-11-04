import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GameView: View {
    @Environment(AppModel.self) private var model
    let gameID: UUID

    private var game: Binding<Game> {
        Binding(get: { model.binding(gameID) ?? Game(name: "", titleID: "", nspFolder: "") }, set: { model.update($0) })
    }

    var body: some View {
        let g = game.wrappedValue
        let busy = model.phase.isRunning
        let mine = model.jobGame == gameID
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        TextField("Name", text: game.name).font(.title2.bold()).textFieldStyle(.plain)
                        Text("\(g.titleID) · \(g.nspFolder)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let d = g.lastBuilt {
                        Text("Last built \(d.formatted(.relative(presentation: .named))) for \(g.lastBuiltDevice?.label ?? "?")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Build") {
                Picker("Device", selection: game.device) {
                    ForEach(TargetDevice.allCases) { d in Label(d.label, systemImage: d.symbol).tag(d) }
                }
                .pickerStyle(.segmented)
                Text("An \(g.device.label)-only app for the \(g.device.model). Pre-compiled GPU shaders, when the build makes them, are made for its GPU (\(g.device.gpu)) alone." + (g.device == .ipad ? " Ultrawide is left out: the iPad's screen is not wider than 16:9." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Game files", selection: game.gameData) { ForEach(GameDataMode.allCases) { Text($0.label).tag($0) } }
                Picker("Install", selection: game.install) { ForEach(InstallMethod.allCases) { Text($0.label).tag($0) } }
                Toggle("Pre-compile GPU shaders for the \(g.device.label)", isOn: game.precompileGPUShaders)
                if g.precompileGPUShaders {
                    Text("The first start skips building them, but the build takes minutes longer and the app grows by about 650 MB. A bundled archive once crashed Metal at boot on an iPhone Air with iOS 27.0 (cause unknown): if the game stops at its first start, build again with this off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Frame-rate counter", isOn: game.showFPS)
                TextField("Bundle ID", text: game.bundleID, prompt: Text("org.nxnative.\(g.titleID.lowercased())"))
                TextField("Language", text: game.language, prompt: Text("English (or ja, fr, de, es, …)"))
            }

            ModsSection(game: game)

            Section("Build & Install") {
                HStack {
                    Button {
                        Task { await model.build(gameID, thenInstall: g.install == .xcode && model.selectedDevice != nil) }
                    } label: { Label(g.install == .xcode ? "Build & Install" : "Build IPA", systemImage: "hammer") }
                    .buttonStyle(.borderedProminent).disabled(busy)
                    Button { Task { await model.install(gameID) } } label: { Label(g.install == .xcode ? "Install" : "Open in Sideloader", systemImage: "arrow.down.app") }
                        .disabled(busy || (g.install == .xcode ? g.lastProject == nil : g.lastIPA == nil))
                    if g.gameData == .separate {
                        Button { Task { await model.copyGameData(gameID) } } label: { Label("Copy Game Data", systemImage: "externaldrive.badge.plus") }
                            .disabled(busy || g.lastGameData == nil)
                            .help("Copies the game's files into the installed app (needed once per game version)")
                    }
                    Button { Task { await model.copyCheats(gameID) } } label: { Label("Copy Cheats", systemImage: "wand.and.stars") }
                        .disabled(busy || ModsStore.enabledCheatFiles(Paths.mods(g.titleID)).isEmpty)
                        .help("Copies the cheat files that are on into the installed app; then Reload cheats in the game's gear menu")
                }
                if let ipa = g.lastIPA, g.install == .sideload {
                    LabeledContent("IPA") { Button(URL(fileURLWithPath: ipa).lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ipa)]) }.buttonStyle(.link) }
                }
                if busy && !mine { Text("Another game is building.").foregroundStyle(.secondary) }
                if mine { JobView() }
            }
        }
        .formStyle(.grouped)
    }
}

/// The game's patches and cheats, which every build of it takes.
struct ModsSection: View {
    @Binding var game: Game
    @State private var entries: [ModEntry] = []
    @State private var importing = false
    @State private var pendingPatch: PendingPatch?
    @State private var patchName = ""
    @State private var error: String?

    private var root: URL { Paths.mods(game.titleID) }

    var body: some View {
        Section {
            Toggle("Use patches and cheats in builds", isOn: $game.useMods)
            if entries.isEmpty {
                Text("None yet. Add .pchtxt or .ips patches, a mod folder or .zip (60FPS, Ultrawide, …), or .txt cheat files, or drop them here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                HStack {
                    Image(systemName: e.kind == .cheat ? "wand.and.stars" : "puzzlepiece.extension")
                        .foregroundStyle(e.enabled ? Color.accentColor : .secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(e.name).strikethrough(!e.enabled)
                            if let t = e.toggle { Text("\(t) toggle").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1).background(.tint.opacity(0.18), in: Capsule()) }
                        }
                        Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { e.enabled }, set: { on in perform { try ModsStore.setEnabled(e, on) } })).labelsHidden().toggleStyle(.switch)
                    Button(role: .destructive) { perform { try ModsStore.remove(e) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button { importing = true } label: { Label("Add Patch or Cheat…", systemImage: "plus") }
                Button("Show in Finder") { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); NSWorkspace.shared.open(root) }
                Button("Refresh") { reload() }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        } header: {
            Text("Patches & Cheats")
        } footer: {
            Text("A mod named for a frame rate (60FPS) or a wide shape (Ultrawide, 21.9) becomes a High frame rate or Ultrawide toggle in the game's launcher; other patches are built in. Cheats are packed into the app and turned on in the game's gear menu › Cheats.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onChange(of: game.titleID) { reload() }
        .dropDestination(for: URL.self) { urls, _ in add(urls); return true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { add(urls) }
        }
        .sheet(item: $pendingPatch) { pending in
            let url = pending.url
            VStack(alignment: .leading, spacing: 12) {
                Text("Name this patch").font(.headline)
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                TextField("Mod name", text: $patchName)
                Text("Include 60FPS, Ultrawide or 21.9 in the name to make it a launcher toggle.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { pendingPatch = nil }
                    Button("Add") { let u = url; pendingPatch = nil; perform { _ = try ModsStore.add(u, to: root, modName: patchName) } }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 380)
        }
    }

    private func add(_ urls: [URL]) {
        for u in urls {
            if ModsStore.patchExtensions.contains(u.pathExtension.lowercased()), urls.count == 1 {
                let parent = u.deletingLastPathComponent()
                patchName = parent.lastPathComponent.lowercased() == "exefs" ? parent.deletingLastPathComponent().lastPathComponent : u.deletingPathExtension().lastPathComponent
                pendingPatch = PendingPatch(url: u)
                return
            }
            perform {
                let ok = u.startAccessingSecurityScopedResource()
                defer { if ok { u.stopAccessingSecurityScopedResource() } }
                _ = try ModsStore.add(u, to: root)
            }
        }
    }

    private func perform(_ f: () throws -> Void) {
        do { try f(); error = nil } catch { self.error = error.localizedDescription }
        reload()
    }

    private func reload() { entries = ModsStore.list(root) }
}

struct PendingPatch: Identifiable {
    let url: URL
    var id: String { url.path }
}
