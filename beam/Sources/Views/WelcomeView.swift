// The first screen (beam-design §3.1, step 1): what Beam does, with the legal framing first, and where NX 18 is
import SwiftUI

struct WelcomeView: View {
    @Environment(BeamSettings.self) private var settings
    @State private var nxPlay = NXPlayLibrary.find()
    @State private var importing = false
    var body: some View {
        ScrollView { VStack(spacing: 22) {
            Text("NX 18 Beam").font(.system(size: 40, weight: .bold))
            Text("Beam builds your legally owned and acquired games into apps for your iPhone, iPad and Mac.\nIt includes no games, keys or firmware.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
            CheckoutStatus().frame(maxWidth: 560)
            SetupPanel().frame(maxWidth: 560)
            Toggle("Check for Beam updates once a day", isOn: Binding(get: { settings.updateChecks }, set: { settings.updateChecks = $0 }))
                .toggleStyle(.checkbox)
                .help("Beam's only network call you did not start. It reads NX 18's releases on GitHub and sends nothing about you. Settings turns it off.")
            Button("Get Started") { settings.welcomed = true }
                .buttonStyle(.glassProminent).controlSize(.extraLarge)
                .disabled(!settings.checkout.isValid)
            if let lib = nxPlay, !lib.games.isEmpty {
                Button("Bring Your NX Play Library (\(lib.games.count) games)") { importing = true }
                    .buttonStyle(.glass).disabled(!settings.checkout.isValid)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NX18Palette.background.opacity(0.35))
        .sheet(isPresented: $importing) { if let lib = nxPlay { NXPlayImportSheet(lib: lib) } }
    }
}

/// Whether the NX 18 folder is where Beam looks, with a button to choose another
struct CheckoutStatus: View {
    @Environment(BeamSettings.self) private var settings
    @State private var picking = false
    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: settings.checkout.isValid ? "checkmark.circle.fill" : "questionmark.folder")
                    .font(.title2).foregroundStyle(settings.checkout.isValid ? NX18Palette.cyan : NX18Palette.coral)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.checkout.isValid ? "NX 18 found" : "NX 18 will be set up here").font(.headline)
                    Text(settings.nx18Folder.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…") { picking = true }
            }
            .padding(6)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
            if case .success(let u) = r { settings.nx18Folder = u }
        }
    }
}
