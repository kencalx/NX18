// "Bring your NX Play library" (beam-design §3.1) and the guides for other sideloading tools (§3.4 Route B)
import SwiftUI

struct NXPlayImportSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    let lib: NXPlayLibrary
    @State private var running = false
    @State private var result: (added: Int, read: Int, failed: [String])?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bring your NX Play library").font(.title2.weight(.semibold))
            if let r = result {
                Text(r.added == 0 ? "Every game in NX Play's folder is already in Beam." : "\(r.added) game\(r.added == 1 ? "" : "s") added; NX 18 read \(r.read).")
                if !r.failed.isEmpty {
                    Text("Not read yet: \(r.failed.joined(separator: ", ")). Open each one and press Read Again, or check its files.").foregroundStyle(.secondary)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent) }
            } else {
                Text("NX Play's games folder holds \(lib.games.count) game\(lib.games.count == 1 ? "" : "s"):")
                Text(lib.gamesRoot.path).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Beam adds each game where it is. Nothing is moved, copied or deleted, and NX Play keeps working.", systemImage: "folder")
                    if lib.keys != nil && library.settings.keys == nil { Label("Beam uses the keys file NX Play uses.", systemImage: "key") }
                    if !lib.installedTitles.isEmpty {
                        Label("Games NX Play installed on your devices keep their identity: installing one from Beam replaces it and keeps its save.", systemImage: "iphone")
                    }
                }
                .font(.callout)
                if running { ProgressView("Asking NX 18 about each game…").progressViewStyle(.linear) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button("Bring Them In") { running = true; Task { result = await library.importNXPlay(lib); running = false } }
                        .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).disabled(running || lib.games.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Step-by-step for installing the IPA with another tool. The steps follow NX 18's own docs (docs/getting-started.md, README "Increased Memory Limit");
/// each tool's own guide is linked for the parts it owns. LiveContainer is not offered until NX 18's LiveContainer check passes (beam-design D6)
struct SideloadGuide: View {
    enum Tool: String, CaseIterable, Identifiable {
        case sideStore = "SideStore", altStore = "AltStore Classic", sideloadly = "Sideloadly"
        var id: String { rawValue }
        var guide: URL {
            switch self {
            case .sideStore: URL(string: "https://docs.sidestore.io/docs/installation/install")!
            case .altStore: URL(string: "https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos")!
            case .sideloadly: URL(string: "https://sideloadly.io/faq")!
            }
        }
    }
    struct Step: Identifiable { let id: Int; let symbol: String; let text: String }

    let ipa: URL
    @State private var tool: Tool = .sideStore
    @Environment(\.dismiss) private var dismiss

    static func steps(_ t: Tool) -> [Step] {
        var s: [(String, String)] = [
            ("iphone.gen3", "On your iPhone, turn on Developer Mode in Settings > Privacy & Security, then restart and tap Enable. It appears after the iPhone has been connected to a computer once."),
        ]
        switch t {
        case .sideStore:
            s += [("arrow.down.app", "Install SideStore on the iPhone with its own guide, once (linked below)."),
                  ("square.and.arrow.up", "Send the IPA to the iPhone: AirDrop it from Beam, or put it in the Files app."),
                  ("plus.app", "In SideStore, open My Apps, tap +, and choose the IPA. Keep the app's entitlements if asked."),
                  ("memorychip", "Add the Increased Memory Limit with GetMoreRam: sign in with the same Apple ID, open App IDs, tap Refresh, pick the game's App ID and tap Add Increased Memory Limit. Then reinstall the game from SideStore once.")]
        case .altStore:
            s += [("arrow.down.app", "Install AltStore Classic (not AltStore PAL: PAL installs only notarized apps) with its own guide, once."),
                  ("square.and.arrow.up", "Send the IPA to the iPhone: AirDrop it from Beam, or put it in the Files app."),
                  ("plus.app", "In AltStore, open My Apps, tap +, and choose the IPA. Keep the entitlements when AltStore offers the choice."),
                  ("memorychip", "If the game has clearly less room than it should (the README's check), add the Increased Memory Limit with GetMoreRam, as for SideStore.")]
        case .sideloadly:
            s += [("arrow.down.app", "Install Sideloadly on this Mac with its own guide, and connect the iPhone with a cable."),
                  ("plus.app", "Drag the IPA (Show IPA in Beam) into Sideloadly, pick your Apple ID, and start. Keep the app's entitlements in the advanced options."),
                  ("checkmark.shield", "On the iPhone, trust the developer profile in Settings > General > VPN & Device Management."),
                  ("memorychip", "With a free Apple ID, add the Increased Memory Limit with GetMoreRam, as for SideStore.")]
        }
        s += [("clock.arrow.circlepath", "On a free Apple ID, refresh the game every 7 days in your tool, before it stops opening."),
              ("exclamationmark.triangle", "To update the game, install the new IPA over it. Never delete the game first: deleting it deletes its saves.")]
        return s.enumerated().map { Step(id: $0.offset + 1, symbol: $0.element.0, text: $0.element.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install with another tool").font(.title2.weight(.semibold))
            Picker("Tool", selection: $tool) { ForEach(Tool.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.steps(tool)) { st in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle().fill(NX18Palette.charcoal).frame(width: 40, height: 40)
                                Image(systemName: st.symbol).foregroundStyle(NX18Palette.accent(at: st.id - 1))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Step \(st.id)").font(.caption).foregroundStyle(.secondary)
                                Text(st.text)
                            }
                        }
                    }
                }
            }
            HStack {
                Link("\(tool.rawValue)'s own guide", destination: tool.guide)
                Link("Increased Memory Limit steps", destination: URL(string: "https://github.com/kencalx/NX18#increased-memory-limit")!)
                Spacer()
                Button("Show IPA", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([ipa]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)   // a sheet's buttons at its bottom trailing edge (macOS 27 dialogs)
            }
            .font(.callout)
        }
        .padding(24)
        .frame(width: 600, height: 560)
    }
}
