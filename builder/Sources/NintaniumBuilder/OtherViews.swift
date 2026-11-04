import AppKit
import SwiftUI

struct AddGameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var name = ""
    @State private var titleID = ""
    @State private var device: TargetDevice = .iphone
    @State private var picking = false

    private var valid: Bool { folder != nil && !name.isEmpty && titleID.wholeMatch(of: #/[0-9A-Fa-f]{16}/#) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Game").font(.title2.bold())
            Text("Choose the folder holding the game's NSPs (the base game, and its update and DLC if you have them).").foregroundStyle(.secondary)
            HStack {
                Text(folder?.path ?? "No folder").lineLimit(1).truncationMode(.middle).foregroundStyle(folder == nil ? .secondary : .primary)
                Spacer()
                Button("Choose…") { picking = true }
            }
            Form {
                TextField("Name", text: $name)
                TextField("Title ID", text: $titleID, prompt: Text("0100…000"))
                Picker("Device", selection: $device) { ForEach(TargetDevice.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let folder { model.addGame(folder: folder, name: name, titleID: titleID, device: device) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20).frame(width: 520)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            guard case .success(let u) = r else { return }
            folder = u
            if let d = GameFolder.detect(u) { name = d.name; titleID = d.titleID } else if name.isEmpty { name = u.lastPathComponent }
        }
    }
}

struct RepositoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let repo = model.repo
        Form {
            Section("Nintanium") {
                LabeledContent("Checkout") { Text(model.settings.repoPath).textSelection(.enabled) }
                if repo.exists {
                    LabeledContent("At") { Text(repo.head).textSelection(.enabled) }
                    if repo.localChanges { Label("The checkout has changes of its own: automatic updates wait; Pull still works when the new commits don't touch the same files.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                } else {
                    Text("No checkout there yet.").foregroundStyle(.secondary)
                    Button("Clone \(model.settings.repoURL)") { Task { await repo.clone(from: model.settings.repoURL) } }.disabled(repo.busy)
                }
                if !repo.message.isEmpty { Text(repo.message).foregroundStyle(repo.message.hasPrefix("Could not") ? .red : .secondary) }
            }
            if repo.exists {
                Section {
                    Toggle("Pull new commits automatically", isOn: $model.settings.autoPull)
                    Stepper("Check every \(model.settings.autoPullMinutes) minutes", value: $model.settings.autoPullMinutes, in: 5...240, step: 5)
                    Text("New commits are pulled as they are added, while no build runs. Only fast-forwards: nothing in the checkout is overwritten. The next build of each game uses them.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check Now") { Task { await repo.check() } }
                        Button("Pull \(repo.incoming.count) Commit\(repo.incoming.count == 1 ? "" : "s")") { Task { await repo.pull() } }
                            .disabled(repo.incoming.isEmpty || model.phase.isRunning)
                        if repo.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        if let d = repo.lastChecked { Text("Checked \(d.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }
                } header: { Text("Updates") }
                if !repo.incoming.isEmpty {
                    Section("New on \(model.settings.branch)") {
                        ForEach(repo.incoming) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.subject)
                                Text("\(c.hash) · \(c.author) · \(c.when)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !repo.notes.isEmpty {
                    Section("Notes from the last update") {
                        ForEach(repo.notes, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Repository")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tools: [(String, Bool, String)] = []
    @State private var checking = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Repository") {
                TextField("Checkout folder", text: $model.settings.repoPath)
                TextField("Remote", text: $model.settings.repoURL)
                TextField("Branch", text: $model.settings.branch)
            }
            Section("Building") {
                HStack {
                    TextField("prod.keys", text: $model.settings.keysPath)
                    Button("Choose…") { choose(file: true) { model.settings.keysPath = $0 } }
                }
                HStack {
                    TextField("IPA folder", text: $model.settings.outputFolder, prompt: Text("beside the game's NSPs"))
                    Button("Choose…") { choose(file: false) { model.settings.outputFolder = $0 } }
                }
                TextField("Python", text: $model.settings.python)
            }
            Section {
                HStack {
                    TextField("Team ID", text: $model.settings.teamID, prompt: Text("from Xcode › Settings › Apple Accounts"))
                    Button("Detect") { Task { if let t = await Devices.teamID() { model.settings.teamID = t } } }
                }
                Toggle("Apple Developer Program account", isOn: $model.settings.paidAccount)
                Toggle("Increased Memory Limit", isOn: $model.settings.increasedMemoryLimit)
            } header: { Text("Signing (Xcode install)") } footer: {
                Text(model.settings.paidAccount
                     ? "Signed builds also ask for Extended Virtual Addressing (more address space for games that reserve a large block), and the chosen device is registered on your account as it is installed on. Apps stay installable for a year."
                     : "A free Personal Team: Increased Memory Limit only, apps expire after 7 days, and a device must already be in a profile. The bigger games need Increased Memory Limit; turn it off only if signing fails over it.").font(.caption)
            }
            Section("Tools") {
                ForEach(tools, id: \.0) { t in
                    LabeledContent { Text(t.2).foregroundStyle(t.1 ? Color.secondary : Color.red).lineLimit(1) } label: {
                        Label(t.0, systemImage: t.1 ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(t.1 ? .green : .red)
                    }
                }
                HStack {
                    Button("Check Tools") { checking = true; Task { tools = await model.checkTools(); checking = false } }
                    if checking { ProgressView().controlSize(.small) }
                }
                Text("The build needs what README step 1 installs: Xcode 27.2, xcodegen, zstd, glslang, the .NET SDK and the Python packages.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.settingsChanged() }
        .onSubmit { model.settingsChanged() }
    }

    private func choose(file: Bool, _ set: (String) -> Void) {
        let p = NSOpenPanel()
        p.canChooseFiles = file; p.canChooseDirectories = !file; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { set(u.path) }
    }
}
