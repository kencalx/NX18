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
    @Environment(\.dismiss) private var dismiss

    init(title: String, source: GameSettingsSource) {
        self.title = title; self.source = source
        _m = StateObject(wrappedValue: source.model())
    }

    private var cloud: LauncherStatus.Cloud { (source.defaults.string(forKey: "cloudSaves.folder") ?? "").isEmpty ? .off : .on }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            GatePanel(m: m, pages: $pages, focus: nil, padShown: false, quiet: false, glyphs: NXPadGlyphs(), status: cloud,
                      gateAtStartLocked: false, footer: AnyView(footer), acknowledgements: false, touched: { _ in }, act: act)
        }
        .frame(width: 620, height: 640)
        .background { ZStack { NX18Palette.background; NX18Glow() } }
        .environment(\.colorScheme, .dark)
        .onAppear { MacCloud.defaults = source.defaults }
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
            if p.runModal() == .OK, let u = p.url { source.defaults.set(u.path, forKey: "cloudSaves.folder") }
        case .confirmCloudOff:
            if confirm("Turn off cloud saves?", "This Mac keeps its own save.", "Turn Off") { source.defaults.removeObject(forKey: "cloudSaves.folder") }
        case .confirmReset:
            if confirm("Reset all settings?", "Brings back the settings this game was tested with.", "Reset") { m.reset(); m.save() }
        case .acknowledgements: break   // the game's own window shows them (Beam's About has Beam's)
        }
    }
    private func confirm(_ title: String, _ text: String, _ button: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
