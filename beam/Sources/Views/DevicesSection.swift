// The game page's iPhone and iPad section (beam-design §3.4): install on a paired device with the player's Apple account in Xcode, the installs with their days left,
// Renew and Open, the free account's Slots strip, the Increased Memory Limit walkthrough, and the IPA for another tool (Route B)
import SwiftUI

struct DevicesSection: View {
    @Environment(Library.self) private var library
    @Environment(BeamSettings.self) private var settings
    let gameID: UUID
    @State private var deviceID: String?
    @State private var guideFor: URL?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("iPhone and iPad").font(.headline)
                    Spacer()
                    if library.refreshingDevices { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refreshDevices() } }.labelStyle(.iconOnly)
                }
                installRow
                ForEach(library.installs(of: gameID)) { r in installed(r) }
                if let d = chosen, library.certificateSigner() == nil, let team = settings.team, team.free { SlotsStrip(device: d) }
                if let ipa = library.ipa(gameID) { routeB(ipa) }
            }
            .padding(6)
        }
        .task { if library.devices.isEmpty { await library.refreshDevices() }; await library.loadSigning() }
        .sheet(isPresented: Binding(get: { guideFor != nil }, set: { if !$0 { guideFor = nil } })) { if let u = guideFor { SideloadGuide(ipa: u) } }
    }

    private var chosen: DeviceInfo? { library.devices.first { $0.id == deviceID } ?? library.devices.first }

    @ViewBuilder private var installRow: some View {
        let teams = XcodeTeam.inXcode()
        let cert = library.certificateSigner()
        if teams.isEmpty && cert == nil {
            Label("Add your Apple account in Xcode > Settings > Apple Accounts to install from Beam. Beam never asks for your password.", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        } else if library.devices.isEmpty {
            Label("No paired iPhone or iPad. Connect one with a cable and trust this Mac, then Refresh.", systemImage: "iphone.slash").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                Picker("Device", selection: Binding(get: { chosen?.id }, set: { deviceID = $0 })) {
                    ForEach(library.devices) { d in Text("\(d.name)\(d.connected ? "" : " (not connected)")").tag(Optional(d.id)) }
                }
                .frame(maxWidth: 260)
                if let c = cert {
                    Text("\(c.identity.shownName) · \(c.profile.name)").foregroundStyle(.secondary).lineLimit(1)
                } else if teams.count > 1 {
                    Picker("Account", selection: Binding(get: { settings.team?.id }, set: { settings.teamID = $0 })) {
                        ForEach(teams) { t in Text(t.label).tag(Optional(t.id)) }
                    }
                    .frame(maxWidth: 240)
                } else if let t = teams.first {
                    Text(t.label).foregroundStyle(.secondary)
                }
                Button("Install", systemImage: "arrow.down.app") { if let d = chosen { library.install(gameID, on: d) } }
                    .buttonStyle(.glassProminent)
                    .disabled(chosen == nil || (library.jobs[gameID]?.isActive ?? false) || (cert == nil && settings.team?.free == true))
            }
            if cert == nil && settings.team?.free == true {
                Label(MemoryEntitlements.freeTeamText, systemImage: "memorychip").font(.callout).foregroundStyle(NX18Palette.coral)
            }
            if chosen?.developerMode == false {
                Text("Developer Mode is off on this device: Settings > Privacy & Security > Developer Mode.").font(.callout).foregroundStyle(NX18Palette.coral)
            }
        }
    }

    private func installed(_ r: InstallRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.expired() ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(r.expired() ? NX18Palette.coral : NX18Palette.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("On \(r.deviceName)")
                Text(daysText(r)).font(.callout).foregroundStyle(r.renewDue() ? NX18Palette.coral : .secondary)
            }
            Spacer()
            if r.renewDue() { Button("Renew") { library.renew(r) }.buttonStyle(.glassProminent).disabled(library.jobs[gameID]?.isActive ?? false) }
            Button("Open on Device") { library.launch(r) }.buttonStyle(.glass)
        }
    }
    private func daysText(_ r: InstallRecord) -> String {
        guard let d = r.daysLeft() else { return "Installed \(r.installed.formatted(date: .abbreviated, time: .omitted))" }
        if r.expired() { return "Expired. Renew to play it again; its save stays on the device." }
        return d >= 60 ? "Good until \(r.expires!.formatted(date: .abbreviated, time: .omitted))" : d == 0 ? "Expires today" : "\(d) day\(d == 1 ? "" : "s") left"
    }

    private func routeB(_ ipa: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Using another sideloading tool?").foregroundStyle(.secondary)
                Spacer()
                Button("Show IPA", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([ipa]) }
                Button("AirDrop", systemImage: "airplayaudio") { library.airDrop(ipa) }
                Button("Step by Step") { guideFor = ipa }
            }
            HStack(spacing: 4) {   // the IPA asks for both memory entitlements; the tool must keep them
                Text("Keep the app's entitlements when your tool asks. With a free Apple ID, add the Increased Memory Limit with GetMoreRam.").foregroundStyle(.secondary)
                Link("Steps", destination: URL(string: "https://github.com/kencalx/NX18#increased-memory-limit")!)
            }
        }
        .font(.callout)
    }
}

/// A free account's 3 slots on one device: the sideloaded apps on it with their days left, and the free ones
private struct SlotsStrip: View {
    @Environment(Library.self) private var library
    let device: DeviceInfo
    var body: some View {
        let used = Slots.used(onDevice: library.deviceApps[device.id] ?? [])
        HStack(spacing: 8) {
            Text("Slots on \(device.name)").font(.callout).foregroundStyle(.secondary)
            ForEach(used, id: \.bundleID) { a in
                let rec = library.installs.first { $0.bundleID == a.bundleID && $0.deviceID == device.id }
                let title = rec.flatMap { r in library.games.first { $0.id == r.gameID }?.title } ?? a.name ?? a.bundleID
                VStack(spacing: 1) {
                    Text(title).lineLimit(1).font(.caption.weight(.medium))
                    Text(rec?.daysLeft().map { "\($0) d" } ?? "other tool").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(NX18Palette.charcoal))
                .frame(maxWidth: 150)
            }
            ForEach(0..<max(Slots.freeLimit - used.count, 0), id: \.self) { _ in
                Text("Free").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(NX18Palette.separator, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
    }
}
