// A game's right-click menu, the same in the library's sidebar and in Beam Home: play, its settings, build, install, its page, its files
import AppKit
import SwiftUI

extension Library {
    /// Asks for the game's settings sheet (LibraryView shows it, over the library or Beam Home). False when the game has no Mac build yet: its settings come from it
    @discardableResult func requestSettings(_ id: UUID) -> Bool {
        guard library_settingsSource(id) != nil else { return false }
        settingsRequest = id; return true
    }
    func library_settingsSource(_ id: UUID) -> GameSettingsSource? { macApp(id).flatMap(GameSettingsSource.init(app:)) }
    /// A new name for the game, or nil / empty for its own name again; the app gets it at the next build
    func rename(_ id: UUID, to name: String?) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        games[i].customName = n.isEmpty || n == games[i].identity?.name ? nil : String(n.prefix(60))
        save()
    }
    /// Shows the game's page in the library (from Beam Home too)
    func openPage(_ id: UUID) { showingHome = false; pageRequest = id }
}

struct GameContextMenu: View {
    @Environment(Library.self) private var library
    let gameID: UUID
    var body: some View {
        if let g = library.games.first(where: { $0.id == gameID }) {
            let mac = library.macApp(g.id) != nil, busy = library.jobs[g.id]?.isActive ?? false
            Button("Play on This Mac", systemImage: "play.fill") { library.play(g.id) }.disabled(!mac || library.playing != nil)
            Button(mac ? "Game Settings…" : "Game Settings… (after a Mac build)", systemImage: "slider.horizontal.3") { library.requestSettings(g.id) }.disabled(!mac)
            Divider()
            Button("Build for Mac", systemImage: "macbook") { library.build(g.id, target: .mac) }.disabled(g.identity == nil || busy)
            Button("Install on iPhone or iPad…", systemImage: "iphone") { library.openPage(g.id) }.disabled(g.identity == nil)
            Button("Open Game Page", systemImage: "rectangle.on.rectangle") { library.openPage(g.id) }
            Button("Rename…", systemImage: "pencil") { library.renameRequest = g.id }
            Divider()
            Button("Show Game Files in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([g.source]) }
            Button("Read Again", systemImage: "arrow.clockwise") { library.identify(g.id) }.disabled(library.identifying.contains(g.id))
            Divider()
            Button("Remove from Library", systemImage: "minus.circle", role: .destructive) { library.remove(g.id) }   // its files are never touched
        }
    }
}
