// A Mac app's settings in Beam (beam-design §4.3): the app's own dm/launcher.json drawn by NX 18's Gate panel with the same rules as the game's window,
// its choices kept in the app's own preferences (launcher.<VAR>, only what differs from the tested default), so the game starts with them from Beam or from Finder
import AppKit
import SwiftUI

/// A built Mac app's settings list and preferences domain
struct GameSettingsSource {
    let file: SettingsFile
    let bundleID: String
    let defaults: UserDefaults

    init?(app: URL) {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Resources/dm/launcher.json")),
              let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty,
              let id = Bundle(url: app)?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
              let d = UserDefaults(suiteName: id) else { return nil }
        self.file = file; bundleID = id; defaults = d
    }

    @MainActor func model() -> LauncherModel {
        let m = LauncherModel(file.settings, defaults: defaults)
        m.takeList(file)                     // the console, the drawn presets and the stored base preset
        m.follow(beamDeviceFacts, on: [])    // the rules decided on this Mac, where the app runs
        return m
    }
}

struct GameSettingsView: View {
    let title: String
    let source: GameSettingsSource
    @StateObject private var m: LauncherModel
    @State private var pages: [GatePage] = []
    @State private var asking: Ask?
    @Environment(\.dismiss) private var dismiss

    init(title: String, source: GameSettingsSource) {
        self.title = title; self.source = source
        _m = StateObject(wrappedValue: source.model())
    }

    @State private var place: NX18CloudSaves.Place = .off   // the game's cloud saves: its own folder or the NX 18 folder (read from its preferences)
    private var cloud: LauncherStatus.Cloud { place == .off ? .off : .on }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14)
            GatePanel(m: m, pages: $pages, focus: nil, padShown: false, quiet: false, glyphs: NXPadGlyphs(), status: cloud,
                      savesInNX18Folder: place.inNX18, gateAtStartLocked: false, footer: AnyView(footer), acknowledgements: false, touched: { _ in }, act: act)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large) }   // a sheet's buttons at its bottom trailing edge (macOS 27 dialogs)
                .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 620, height: 640)
        .background { ZStack { NX18Palette.background; NX18Glow() } }
        .environment(\.colorScheme, .dark)
        .alert(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { a in
            // the system's alert on the sheet (window modal), Cancel beside the action as macOS 27 draws it; Reset loses choices, so it is marked destructive
            Button(a.button, role: a == .reset ? .destructive : nil) { confirmed(a) }
            Button("Cancel", role: .cancel) {}
        } message: { a in Text(a.text) }
        .onAppear { MacCloud.defaults = source.defaults; readPlace() }
        .onDisappear { m.save(); MacCloud.defaults = .standard }   // stored as the game's window stores them at Play, never set in Beam's own environment
    }

    private var footer: some View {
        Text("These are the settings this game starts with, from Beam or from Finder. Changes are kept with the game's app.")
            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
    }

    private func act(_ a: GateAction) {
        switch a {
        case .chooseCloudFolder:
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.message = "Choose a folder for this game's cloud saves, such as one in iCloud Drive."
            // In the NX 18 folder: the chosen folder becomes the game's own (nx18.cloud = own). Nothing moves here: the game compares the two saves at its next start, and the
            // NX 18 folder's copy stays (the game's own card moves the save first: This game's saves)
            if p.runModal() == .OK, let u = p.url { source.defaults.set(u.path, forKey: NX18CloudSaves.folderKey); if place.inNX18 { source.defaults.set("own", forKey: NX18CloudSaves.choiceKey) } }
        case .confirmCloudOff: asking = .cloudOff
        case .confirmReset: asking = .reset
        case .acknowledgements: break   // the game's own window shows them (Beam's About has Beam's)
        }
        readPlace()
    }
    private func readPlace() { place = NX18CloudSaves.place(source.defaults, nx18: ProfileSetup.connectedFolder()) }
    private func confirmed(_ a: Ask) {
        switch a {
        case .cloudOff:
            source.defaults.set("", forKey: NX18CloudSaves.folderKey)   // "", as the game's window stores it: turned off, so the NX 18 folder's default never starts it again
            if place.inNX18 { source.defaults.set("own", forKey: NX18CloudSaves.choiceKey) }   // the NX 18 folder too: its saves stay there, nothing is deleted
        case .reset: m.reset(); m.save()
        }
        readPlace()   // the alert acts after act() returned: the door's line follows the answer
    }

    /// The two questions the panel asks before it acts
    enum Ask: Equatable {
        case cloudOff, reset
        var title: String { self == .cloudOff ? "Turn off cloud saves?" : "Reset all settings?" }
        var text: String { self == .cloudOff ? "This Mac keeps its own save." : "Brings back the settings this game was tested with." }
        var button: String { self == .cloudOff ? "Turn Off" : "Reset" }
    }
}
