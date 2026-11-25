// The welcome screen's setup (beam-design §3.1 steps 2 and 3): this Mac checked by NX 18's setup script, each missing piece with the script's own question as
// its approval, Fix All, and the script's output as it runs. Xcode is the player's download from Apple: Beam names the version and opens Apple's page
import SwiftUI

struct SetupPanel: View {
    @Environment(BeamSettings.self) private var settings
    @State private var setup = SetupModel()
    @State private var showLog = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("This Mac").font(.headline)
                    Text("NX 18 \(BeamSystem.shown) in \(settings.nx18Folder.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if setup.running != nil { ProgressView().controlSize(.small) }
                    Button("Check Again") { Task { await setup.check(folder: settings.nx18Folder) } }.disabled(setup.running != nil)
                }
                if setup.checked && setup.ready {
                    Label("Ready to build", systemImage: "checkmark.seal.fill").foregroundStyle(NX18Palette.cyan)
                }
                ForEach(setup.items.filter { $0.state != "ok" }) { i in
                    Label(i.text, systemImage: i.state == "missing" ? "xmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(i.state == "missing" ? NX18Palette.coral : .secondary).font(.callout)
                }
                if !setup.items.isEmpty, setup.items.contains(where: { $0.state == "ok" }) {
                    DisclosureGroup("\(setup.items.filter { $0.state == "ok" }.count) checks passed") {
                        ForEach(setup.items.filter { $0.state == "ok" }) { i in Label(i.text, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                    }.font(.callout)
                }
                if setup.xcodeMissing {
                    HStack {
                        Text("Xcode 27.3 is your download from Apple (free with an Apple Account). Install it, open it once, then Check Again.").font(.callout)
                        Link("Apple's downloads", destination: URL(string: "https://developer.apple.com/download/all/?q=Xcode%2027.3")!)
                    }
                }
                ForEach(setup.fixes) { f in
                    HStack(alignment: .top) {
                        Text(f.question).font(.callout)
                        Spacer()
                        Button("Install") { Task { await setup.fix([f.id], folder: settings.nx18Folder) } }.disabled(setup.running != nil)
                    }
                }
                if setup.fixes.count > 1 {
                    HStack { Spacer(); Button("Fix All") { Task { await setup.fix(setup.fixes.map(\.id), folder: settings.nx18Folder) } }.buttonStyle(.glassProminent).disabled(setup.running != nil) }
                }
                if let s = setup.stopped { Text(s).font(.callout).foregroundStyle(NX18Palette.coral).textSelection(.enabled) }
                if !setup.log.isEmpty {
                    DisclosureGroup("What the setup did", isExpanded: $showLog) {
                        ScrollView { Text(setup.log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                            .frame(maxHeight: 160)
                    }.font(.callout)
                }
                Text("Every install is named before it runs and needs your click. Nothing uses an administrator password. The same steps are in NX 18's setup script, for setting up without Beam.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .task(id: settings.nx18Folder) { await setup.check(folder: settings.nx18Folder) }
    }
}
