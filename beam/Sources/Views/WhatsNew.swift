// "What's new", once per Beam version (beam-design §3.5, a console touch): shown after the welcome, never again for the same version
import SwiftUI

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    static let items: [(String, String, String)] = [
        ("square.stack.3d.up", "Your library", "Add your legally owned and acquired games, or bring your NX Play library in place. NX 18 tells you what each one is."),
        ("hammer", "Build and play", "Build for iPhone, iPad and Mac with live progress. Play on this Mac at once, or from Beam Home with a controller."),
        ("iphone", "Install on your devices", "With your Apple account in Xcode or your own certificate. The Increased Memory Limit comes with every install."),
        ("slider.horizontal.3", "Mods, cheats and art", "Frame-rate and Ultrawide mods from sources you trust, your own cheat files, and art from SteamGridDB."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("What's new in Beam").font(.title.weight(.bold))
                Spacer()
                Text("System X2.0 · Beam \(BeamUpdate.currentVersion)").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(Self.items.enumerated()), id: \.element.1) { n, item in
                let (icon, title, text) = item
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon).font(.title2).foregroundStyle(NX18Palette.accent(at: n)).frame(width: 34).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary) }
                }
            }
            HStack { Spacer(); Button("Continue") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).controlSize(.large) }
        }
        .padding(28)
        .frame(width: 540)
    }
}
