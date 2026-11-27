// NX 18 Beam: builds the player's legally owned and acquired games into iPhone, iPad and Mac apps (NX18-X2.0 beam-design.md)
import SwiftUI

@main
@MainActor struct BeamApp: App {
    @NSApplicationDelegateAdaptor private var delegate: BeamDelegate
    @State private var library = BeamApp.makeLibrary()

    /// Beam's library and settings; when Beam is only the host of its own tests, a throwaway pair, so a test run leaves nothing in the player's preferences or
    /// Application Support (the domain is cleared at each such launch)
    static func makeLibrary() -> Library {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil else {
            let settings = BeamSettings()
            ProfileSetup.unify(settings)   // one NX 18 folder: an earlier Beam's Album choice becomes the Mac's connected folder
            return Library(settings: settings)
        }
        let suite = "org.nx18.beam.testhost"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        // the scratch preferences earlier test runs left (macOS writes a removed domain's file back later): Beam's own test names only, never the player's
        let prefs = URL.libraryDirectory.appending(path: "Preferences")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: prefs.path)) ?? [] where f.hasPrefix("org.nx18.beam.test.") && f.hasSuffix(".plist") {
            UserDefaults.standard.removePersistentDomain(forName: String(f.dropLast(6)))
            try? FileManager.default.removeItem(at: prefs.appending(path: f))
        }
        let d = UserDefaults(suiteName: suite) ?? .standard
        return Library(settings: BeamSettings(defaults: d), folder: FileManager.default.temporaryDirectory.appending(path: "beam-testhost", directoryHint: .isDirectory))
    }
    private var settings: BeamSettings { library.settings }

    var body: some Scene {
        Window("NX 18 Beam", id: "library") {
            LibraryView()
                .environment(library)
                .environment(settings)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { delegate.open = { urls in for u in urls { library.add(u) }; library.settings.welcomed = true } }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add a Game…") { NotificationCenter.default.post(name: .beamAddGame, object: nil) }
                    .keyboardShortcut("o")
                Button("Bring Your NX Play Library…") { NotificationCenter.default.post(name: .beamImportNXPlay, object: nil) }
                    .disabled(NXPlayLibrary.find() == nil)
            }
            CommandGroup(after: .windowArrangement) { OpenWindowButton(title: "Storage", id: "storage") }
            CommandGroup(after: .toolbar) {
                Button(library.showingHome ? "Show Library" : "Beam Home") { library.showingHome.toggle() }   // one window: the library and Beam Home switch in place
                    .keyboardShortcut("h", modifiers: [.command, .control])
            }
        }
        Window("Storage", id: "storage") {
            StorageView().environment(library).environment(settings)
        }
        .defaultSize(width: 760, height: 460)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        Settings {
            SettingsView()
                .environment(settings)
                .environment(library)
                .frame(width: 560)
        }
    }
}

/// Games opened with Beam: dropped on its Dock icon, or `open -a "NX 18 Beam" <game>`. They join the library as if added in the window
@MainActor final class BeamDelegate: NSObject, NSApplicationDelegate {
    var open: (([URL]) -> Void)? { didSet { if let open, !waiting.isEmpty { open(waiting); waiting = [] } } }
    private var waiting: [URL] = []   // opened before the window was there
    func application(_ application: NSApplication, open urls: [URL]) {
        if let open { open(urls) } else { waiting += urls }
    }
}

extension Notification.Name {
    static let beamAddGame = Notification.Name("beam.addGame")
    static let beamImportNXPlay = Notification.Name("beam.importNXPlay")
}

private struct OpenWindowButton: View {
    let title: String, id: String
    var fullScreen = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) {
            openWindow(id: id)
            if fullScreen {   // Beam Home fills the screen, as a console's home does
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    if let w = NSApp.windows.first(where: { $0.title == title }), !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                }
            }
        }
    }
}
