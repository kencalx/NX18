import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all   // the library shows from the first launch on

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $model.selection) {
                Section {
                    Label {
                        HStack {
                            Text("Repository")
                            Spacer()
                            if !model.repo.incoming.isEmpty { Text("\(model.repo.incoming.count)").font(.caption.bold()).padding(.horizontal, 6).background(.tint, in: Capsule()).foregroundStyle(.white) }
                        }
                    } icon: { Image(systemName: "arrow.triangle.branch") }
                    .tag(AppModel.Selection.repository)
                }
                Section("Games") {
                    ForEach(model.games) { g in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.name).lineLimit(1)
                                Text("\(g.device.label) · \(g.titleID)").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: g.device.symbol) }
                        .tag(AppModel.Selection.game(g.id))
                        .contextMenu {
                            Button("Show NSP Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: g.nspFolder)) }
                            Button("Show Patches & Cheats Folder") { NSWorkspace.shared.open(Paths.mods(g.titleID)) }
                            Divider()
                            Button("Remove from Library", role: .destructive) { model.removeGame(g.id) }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                Button { model.showAddGame = true } label: { Label("Add Game", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            switch model.selection {
            case .game(let id)? where model.binding(id) != nil: GameView(gameID: id).id(id)
            default: RepositoryView()
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    if model.devices.isEmpty { Text(model.deviceError ?? "No iPhone or iPad found") }
                    Picker("Device", selection: $model.deviceID) {
                        ForEach(model.devices) { d in
                            Text("\(d.name) (\(d.model))\(d.connected ? "" : " – not connected")").tag(Optional(d.id))
                        }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("Refresh Devices") { Task { await model.refreshDevices() } }
                } label: {
                    Label(model.selectedDevice?.name ?? "No Device", systemImage: model.selectedDevice?.type == "iPad" ? "ipad.landscape" : "iphone")
                }
                .help("The device to install on")
            }
        }
        .sheet(isPresented: $model.showAddGame) { AddGameSheet() }
    }
}

/// Progress and log of the job that runs, for the game it runs for.
struct JobView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .idle: EmptyView()
            case .running(let what):
                HStack {
                    Text(what).font(.headline)
                    Spacer()
                    Button("Stop", role: .cancel) { model.cancel() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.stageN > 0 ? "Stage \(model.stageK) of \(model.stageN): \(model.stage)" : model.stage).font(.subheadline)
                    if let f = model.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                    HStack {
                        Text(model.step).lineLimit(1)
                        Spacer()
                        if let eta = model.eta { Text("about \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))) left") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            case .succeeded(let m): Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            case .cancelled: Label("Stopped. The next build reuses what was finished.", systemImage: "stop.circle").foregroundStyle(.secondary)
            }
            if !model.log.isEmpty {
                DisclosureGroup("Log (\(model.log.count) lines)", isExpanded: $showLog) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(model.log) { l in
                                    Text(l.text).font(.system(.caption, design: .monospaced)).foregroundStyle(l.red ? .red : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                                }
                            }.textSelection(.enabled).padding(6)
                        }
                        .frame(minHeight: 160, maxHeight: 320)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
                    }
                    HStack {
                        Spacer()
                        Button("Copy Log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.log.map(\.text).joined(separator: "\n"), forType: .string)
                        }.controlSize(.small)
                    }
                }
            }
        }
    }
}
