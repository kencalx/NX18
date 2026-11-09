// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import CoreHaptics
import GameController
import Metal
import MetalFX
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

// Whether front_ios.m startGame has made the process's first Metal device. Until it has, the facts leave MetalFX unknown (no greying): a device made here would come before
// front_hud_env, and the Metal device reads MTL_HUD_ENABLED, the launcher's Performance HUD switch, only when the process makes its first (GitHub issue #840)
@MainActor private var metalDeviceMade = false

// The device facts the rules are decided on (LauncherSettings.swift DeviceFacts), as front_ios.m tests the same things when the game starts: the app scene's screen and window
// (the TV's scene is not the app's), the haptic engine, the controllers, and a TV scene connected
@MainActor private func iosDeviceFacts() -> DeviceFacts {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let app = scenes.first { $0.session.role == .windowApplication }
    func ratio(_ s: CGSize?) -> Double? {
        guard let s, min(s.width, s.height) > 0 else { return nil }
        return Double(max(s.width, s.height) / min(s.width, s.height))
    }
    var f = DeviceFacts()
    f.kind = UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
    f.screen = ratio(app?.screen.bounds.size)
    f.window = ratio(app?.effectiveGeometry.coordinateSpace.bounds.size)
    f.hz = app.map { $0.screen.maximumFramesPerSecond }
    f.haptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    f.controller = !GCController.controllers().isEmpty
    f.tv = scenes.contains { $0.session.role == .windowExternalDisplayNonInteractive }
    if metalDeviceMade, let dev = MTLCreateSystemDefaultDevice() { f.metalFX = dev.supportsFamily(.metal4) && MTLFXSpatialScalerDescriptor.supportsMetal4FX(dev) }
    return f
}


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    ForEach(m.sections, id: \.self) { section in
                        let rows = m.rows(in: section)
                        if !rows.isEmpty {
                            Section(section) {
                                ForEach(rows) { SettingRow(s: $0, m: m) }
                            }
                        }
                    }
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                    CloudSavesSection()
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .frame(width: geometry.size.width * 2 / 3)
            }
            .onChange(of: geometry.size) { m.refreshFacts() }   // the window's shape: rotated, or resized under Stage Manager or Split View
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    var playButton: some View {
        Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large).buttonStyle(.glassProminent)
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    nonisolated(unsafe) let viewController = viewController, done = done   // a raw pointer and a C callback: not Sendable, but front_ios.m hands them over on the main thread, where they stay
    return MainActor.assumeIsolated {   // front_ios.m calls it from its view controller on the main thread (UIKit); gameMenuModel is main-actor state (GameMenu.swift)
        // a game of several programs (main.m): the running program's settings, in its dm/p<N>
        let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
        guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
        let model = LauncherModel(file.settings)
        model.follow(iosDeviceFacts, on: [.GCControllerDidConnect, .GCControllerDidDisconnect, UIScene.willConnectNotification, UIScene.didDisconnectNotification])
        gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
        if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" {
            fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved()
            metalDeviceMade = true   // front_ios.m starts the game as soon as this returns, before any refresh, which waits for a later main-actor turn (LauncherModel.follow)
            Task { @MainActor in model.refreshFacts() }   // that turn: the game's device is made by then, so the facts learn MetalFX (mfx:none) for the in-game menu
            return false
        }
        let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
        var host: UIViewController?
        let view = LauncherView(m: model) {
            guard let h = host else { return }
            host = nil
            model.apply()
            h.dismiss(animated: false) { done(); metalDeviceMade = true; model.refreshFacts() }   // done() started the game, whose device is made: the facts learn MetalFX now
        }
        let h = DmHostingController(rootView: view)
        h.modalPresentationStyle = .fullScreen
        host = h
        parent.present(h, animated: false)
        fputs("launcher: \(file.settings.count) settings shown\n", stderr)
        return true
    }
}
