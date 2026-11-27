// The NX 18 Profile in Beam (ProfileSetup.swift): the welcome page's Profile step, console style (create a profile, or use the one in the NX 18 folder, or later), and the
// Profile section of Settings (the picture, the name, the NX 18 folder). Both say what a Profile and the NX 18 folder are in the same words (ProfileSetup.explanation)
import SwiftUI
import UniformTypeIdentifiers

/// The picture: the player's, else the default one, with a button to choose a picture file (its centre square is used)
struct ProfilePictureButton: View {
    var model: ProfileModel
    var side: CGFloat = 72
    @State private var picking = false
    var body: some View {
        Button { picking = true } label: {
            NX18ProfilePictureView(version: model.pictureVersion, has: model.hasPicture, url: model.pictureURL).frame(width: side, height: side)
        }
        .buttonStyle(NX18PressStyle())
        .help("Choose a picture")
        .accessibilityLabel(model.hasPicture ? "Picture: chosen. Choose another" : "Picture: the default. Choose a picture")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { r in if case .success(let u) = r { model.setPicture(from: u) } }
    }
}

/// The name: 1-10 letters, digits, spaces and - ' . _ (NX18ProfileName); the rule shows under it while the text breaks it
struct ProfileNameField: View {
    @Binding var text: String
    var submit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Name", text: $text, prompt: Text("Player"))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                .onSubmit { if NX18ProfileName.clean(text) != nil { submit() } }
            if NX18ProfileName.clean(text) == nil {
                Text(NX18ProfileName.refusal).font(.caption).foregroundStyle(NX18Palette.coral)
            }
        }
    }
}

/// The NX 18 folder in a line: its name, or not connected
private func folderLine(_ u: URL?) -> String { u.map { "NX 18 folder: \($0.lastPathComponent)" } ?? "NX 18 folder: not connected" }

// ---- the welcome page's step ----

struct ProfileWelcomePanel: View {
    @State private var model = ProfileModel.shared
    @State private var step: Step = ProfileModel.shared.exists ? .have : .choose
    @State private var name = ""
    @State private var proposed: URL?
    @State private var choosing = false

    enum Step { case choose, have, create, connect, done, later }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Profile").font(.headline)
                    Spacer()
                    if model.connecting { ProgressView().controlSize(.small) }
                }
                if step != .later { Text(ProfileSetup.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                switch step {
                case .choose: choose
                case .have: have
                case .create: create
                case .connect: connect
                case .done: done
                case .later: later
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { proposed = await Task.detached(priority: .utility) { ProfileSetup.proposedFolder() }.value }   // it may list iCloud Drive
    }

    // A console's first start: make a user, or bring the one you have
    private var choose: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                tile("Create a Profile", "A name and a picture for your games", "person.crop.circle.badge.plus") { name = ""; step = .create }
                tile("Use My Profile from the NX 18 Folder", "The one your iPhone, iPad or other Mac made", "icloud") { step = .connect }
            }
            HStack { Spacer(); Button("Later") { step = .later } }
        }
    }
    private var have: some View {
        VStack(alignment: .leading, spacing: 10) {
            card(title: "This Mac has a profile")
            HStack {
                Button("Keep It") { step = .done }.buttonStyle(.glassProminent)
                Button("Change It") { name = model.name == "Player" ? "" : model.name; step = .create }
                if model.folder == nil { Button("Use My Profile from the NX 18 Folder") { step = .connect } }
            }
        }
    }
    private var create: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    ProfilePictureButton(model: model)
                    Text(model.hasPicture ? "Change picture" : "Choose a picture").font(.caption).foregroundStyle(.secondary)
                }
                ProfileNameField(text: $name) { finishCreate() }
            }
            HStack {
                Button("Back") { step = model.exists ? .have : .choose }
                Spacer()
                Button("Done") { finishCreate() }.buttonStyle(.glassProminent).disabled(NX18ProfileName.clean(name) == nil)
            }
        }
    }
    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = proposed {
                Text("Beam found an NX 18 folder in iCloud Drive: \(p.lastPathComponent)").font(.callout)
            } else {
                Text("Beam found no NX 18 folder in iCloud Drive. Choose yours, or create a folder named NX 18 there.").font(.callout)
            }
            HStack {
                Button("Back") { step = model.exists ? .have : .choose }
                Spacer()
                Button("Choose…") { choosing = true }
                if let p = proposed { Button("Use This Folder") { Task { await model.connect(p); step = .done } }.buttonStyle(.glassProminent) }
            }
            .disabled(model.connecting)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { r in   // here, apart from the picture's (one importer per branch of the view)
            if case .success(let u) = r { Task { await model.connect(u); step = .done } }
        }
    }
    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            card(title: nil)
            if let n = model.note { Text(n).font(.callout) }
            HStack {
                Text("Change it any time in Beam's Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.folder == nil { Button("Connect the NX 18 Folder") { step = .connect } }
            }
        }
    }
    private var later: some View {
        HStack {
            Text("Create or connect a profile any time in Beam's Settings.").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Set Up Now") { step = model.exists ? .have : .choose }
        }
    }

    private func finishCreate() {
        guard model.setName(name) else { return }
        step = .done
    }
    private func card(title: String?) -> some View {
        HStack(spacing: 14) {
            NX18ProfilePictureView(version: model.pictureVersion, has: model.hasPicture, url: model.pictureURL).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
                Text(model.name).font(.title3.weight(.semibold))
                Text(folderLine(model.folder)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func tile(_ title: String, _ brief: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.title2).foregroundStyle(NX18Palette.cyan)
                Text(title).font(.headline).multilineTextAlignment(.leading)
                Text(brief).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.glass)
        .accessibilityLabel(title).accessibilityHint(brief)
    }
}

// ---- Settings ----

struct ProfileSettingsSection: View {
    @State private var model = ProfileModel.shared
    @State private var name = ProfileModel.shared.name == "Player" ? "" : ProfileModel.shared.name
    @State private var proposed: URL?
    @State private var choosing = false
    var body: some View {
        Section {
            LabeledContent("Picture") {
                HStack {
                    ProfilePictureButton(model: model, side: 44)
                    if model.hasPicture { Button("Remove") { model.clearPicture() } }
                }
            }
            LabeledContent("Name") {
                HStack(alignment: .firstTextBaseline) {
                    ProfileNameField(text: $name) { if name != (model.name == "Player" ? "" : model.name) { model.setName(name) } }   // Return with no change: no new stamp
                    if name != (model.name == "Player" ? "" : model.name) {
                        Button("Save") { model.setName(name) }.disabled(NX18ProfileName.clean(name) == nil)
                    }
                }
            }
            LabeledContent("NX 18 folder") {
                HStack {
                    Text(model.folder?.path ?? "Not connected").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if model.connecting { ProgressView().controlSize(.small) }
                    if let f = model.folder {
                        Button("Change…") { choosing = true }
                        Button("Disconnect") { model.disconnect() }.help("This Mac's games and Beam stop using \(f.lastPathComponent) for the profile. Nothing in the folder is removed.")
                    } else {
                        if let p = proposed { Button("Connect \(p.lastPathComponent)") { Task { await model.connect(p) } } }
                        Button("Choose…") { choosing = true }
                    }
                }
                .disabled(model.connecting)
            }
            // on one row, not the Section (whose modifiers each row would get)
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { r in if case .success(let u) = r { Task { await model.connect(u) } } }
            .task {
                model.reload(); name = model.name == "Player" ? "" : model.name
                proposed = await Task.detached(priority: .utility) { ProfileSetup.proposedFolder() }.value   // it may list iCloud Drive
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.reload() }   // a Mac game's card may have changed it
            if let n = model.note { Text(n).font(.callout) }
        } header: { Text("Profile") } footer: {
            Text(ProfileSetup.explanation + " Beam's Album shows each game's captures from the folder.")
        }
    }
}
