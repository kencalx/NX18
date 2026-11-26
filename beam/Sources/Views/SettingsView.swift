// Beam's Settings window: the NX 18 folder, the keys file (its path only) and where builds go
import SwiftUI

struct SettingsView: View {
    @Environment(BeamSettings.self) private var settings
    @Environment(Library.self) private var library
    @State private var pickP12 = false
    @State private var pickProfile = false
    @State private var pickKeys = false
    @State private var pickSpace = false
    @State private var pickNX18 = false
    var body: some View {
        Form {
            Section("NX 18") { CheckoutStatus(); SetupPanel() }
            Section {
                LabeledContent("Keys") {
                    HStack {
                        Text(settings.keys?.path ?? "Not chosen").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { pickKeys = true }
                        if settings.keys != nil { Button("Clear") { settings.keys = nil } }
                    }
                }
            } footer: {
                Text("Only needed for Switch games in NSP or XCI form. Use the keys dumped from your own console. Beam keeps the file's location only.")
            }
            Section {
                LabeledContent("Build space") {
                    HStack {
                        Text(settings.buildSpace?.path ?? "Beside each game's files").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { pickSpace = true }
                        if settings.buildSpace != nil { Button("Reset") { settings.buildSpace = nil } }
                    }
                }
            } footer: {
                Text("Builds take several gigabytes per game. By default each game's build folder is a \"build\" folder beside its files.")
            }
            Section {
                LabeledContent("iCloud NX 18 folder") {
                    HStack {
                        Text(Album.nx18Folder(chosen: settings.icloudNX18Folder)?.path ?? "Not found").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { pickNX18 = true }
                        if settings.icloudNX18Folder != nil { Button("Reset") { settings.icloudNX18Folder = nil } }
                    }
                }
            } footer: {
                Text("The folder your iPhone and iPad games use for the Profile, cloud saves and captures. Beam shows each game's captures from it in the game's Album. By default Beam uses the folder your Mac game apps use, or iCloud Drive › NX 18.")
            }
            .fileImporter(isPresented: $pickNX18, allowedContentTypes: [.folder]) { r in if case .success(let u) = r { settings.icloudNX18Folder = u } }
            Section("Beam") {
                Toggle("Check for Beam updates once a day", isOn: Binding(get: { settings.updateChecks }, set: { settings.updateChecks = $0 }))
                Toggle("Menu sounds in Beam Home", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "homeSounds") }, set: { UserDefaults.standard.set($0, forKey: "homeSounds") }))
            }
            SourcesSection()
            ArtKeySection()
            DeveloperSection()
            Section {
                Picker("Sign with", selection: Binding(get: { settings.signWith ?? "" }, set: { settings.signWith = $0.isEmpty ? nil : $0 })) {
                    Text("The Apple account in Xcode").tag("")
                    ForEach(library.identities) { i in
                        ForEach(library.profiles.filter { $0.certificates.contains(i.id) }) { p in
                            Text("\(i.shownName) · \(p.name)\(p.memory ? "" : " (no memory entitlements)")").tag("cert:\(i.id)|\(p.id)")
                        }
                    }
                }
                LabeledContent("Certificates") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(library.identities) { i in Text(i.shownName).foregroundStyle(.secondary) }
                        Button("Add Certificate…") { pickP12 = true }
                    }
                }
                LabeledContent("Profiles") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(library.profiles) { p in
                            Text("\(p.name)\(p.expires.map { ", until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")").foregroundStyle(p.memory ? .secondary : NX18Palette.coral)
                        }
                        Button("Add Profile…") { pickProfile = true }
                    }
                }
            } header: { Text("Signing for iPhone and iPad") } footer: {
                Text("Use the Apple account in Xcode, or your own Apple Developer certificate (.p12) with a provisioning profile made for it. macOS asks for the certificate's password in its own window; Beam never sees it and keeps the certificate in its own keychain. The profile must grant the Increased Memory Limit and Extended Virtual Addressing.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { NX18Glow() }   // over the window's own background, light or dark
        .task { await library.loadSigning() }
        .fileImporter(isPresented: $pickP12, allowedContentTypes: [.pkcs12]) { r in if case .success(let u) = r { Task { await library.addCertificate(u) } } }
        .fileImporter(isPresented: $pickProfile, allowedContentTypes: [.data]) { r in if case .success(let u) = r { Task { await library.addProfile(u) } } }
        .fileImporter(isPresented: $pickKeys, allowedContentTypes: [.data]) { r in if case .success(let u) = r { settings.keys = u } }
        .fileImporter(isPresented: $pickSpace, allowedContentTypes: [.folder]) { r in if case .success(let u) = r { settings.buildSpace = u } }
    }
}

/// The owner's developer switch (dm/tools/nx18_dev.py, docs/development.md "The developer switch"): the file ~/NX18-work/NX18_DEV turns NX18_DEV on for every
/// build started from the Dock, Beam's and NX Play's alike. Shown only on a Mac with ~/NX18-work (the owner's work folder), so players never see the row
struct DeveloperSection: View {
    static let work = FileManager.default.homeDirectoryForCurrentUser.appending(path: "NX18-work", directoryHint: .isDirectory)
    static var file: URL { work.appending(path: "NX18_DEV") }
    @State private var on = FileManager.default.fileExists(atPath: DeveloperSection.file.path)
    var body: some View {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: Self.work.path, isDirectory: &isDir), isDir.boolValue {
            Section {
                Toggle("Developer builds (NX18_DEV)", isOn: Binding(get: { on }, set: { Self.set($0); on = FileManager.default.fileExists(atPath: Self.file.path) }))
            } header: { Text("Developer") } footer: {
                Text("Builds untested games and Switch 2 programs as developer builds, not for players. Applies to NX Play's builds too.")
            }
        }
    }
    static func set(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: file.path, contents: Data("on\n".utf8)) } else { try? FileManager.default.removeItem(at: file) }
    }
}
