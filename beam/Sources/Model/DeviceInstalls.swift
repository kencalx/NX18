// Installing a game on the player's iPhone or iPad from Beam (beam-design §3.4 Route A): the build prepares the game's Xcode project, Xcode signs it with the player's
// own account, devicectl installs it. On a free account Beam keeps within the 3 slots, swapping out the game played least recently after copying its save off,
// and offers Renew within 2 days of the 7-day expiry. Route B (another tool) gets the IPA: Show in Finder or AirDrop
import AppKit
import Foundation

/// Who signs an install: Xcode with the player's Apple account, or Beam with the player's own certificate and profile
enum Signer: Sendable {
    case xcode(XcodeTeam)
    case certificate(SigningIdentity, Profile)
    var team: XcodeTeam {
        switch self {
        case .xcode(let t): t
        case .certificate(_, let p): XcodeTeam(id: p.teamID, name: p.name, free: false)   // its bundle IDs take the profile's team's tag
        }
    }
}

extension Library {
    /// Loads the identities in Beam's keychain and the profiles the player added
    func loadSigning() async {
        identities = await BeamKeychain.identities()
        var found: [Profile] = []
        let dir = BeamKeychain.folder.appending(path: "Profiles")
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "mobileprovision" {
            if let p = await Profile.read(f) { found.append(p) }
        }
        profiles = found.sorted { $0.name < $1.name }
    }
    /// Adds a profile: read, then kept as a copy in Beam's Signing/Profiles (the player's file stays where it was)
    func addProfile(_ file: URL) async {
        guard let p = await Profile.read(file) else { lastError = "That file is not a provisioning profile (.mobileprovision)."; return }
        let dir = BeamKeychain.folder.appending(path: "Profiles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appending(path: "\(p.id).mobileprovision")
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: file, to: dst) } catch { lastError = error.localizedDescription; return }
        if !p.memory { lastError = "Added, but the profile \"\(p.name)\" does not grant the Increased Memory Limit and Extended Virtual Addressing, so Beam will not sign with it. Turn both on for its App ID in your developer account and download it again." }
        await loadSigning()
    }
    func addCertificate(_ p12: URL) async {
        do { try await BeamKeychain.importP12(p12) } catch { lastError = error.localizedDescription }
        await loadSigning()
    }
    /// The certificate and profile chosen in Settings (Sign with), when both are still there
    func certificateSigner() -> (identity: SigningIdentity, profile: Profile)? {
        guard let choice = settings.signWith, choice.hasPrefix("cert:") else { return nil }
        let parts = choice.dropFirst(5).split(separator: "|").map(String.init)
        guard parts.count == 2, let i = identities.first(where: { $0.id == parts[0] }), let p = profiles.first(where: { $0.id == parts[1] }) else { return nil }
        return (i, p)
    }

    func saveInstalls() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: installsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(installs).write(to: installsFile, options: .atomic)
    }

    func refreshDevices() async {
        refreshingDevices = true
        defer { refreshingDevices = false }
        do { devices = try await DeviceCtl.devices() } catch { lastError = error.localizedDescription; return }
        for d in devices where d.connected {
            if let apps = try? await DeviceCtl.apps(on: d.id) { deviceApps[d.id] = apps }
        }
    }

    /// The game's installs that are still on a device
    func installs(of game: UUID) -> [InstallRecord] { installs.filter { $0.gameID == game && !$0.removed } }

    /// Prepare, sign and install a game on a device. `swap`: the player agreed to remove the game Beam suggested (a free account's 4th game)
    func install(_ id: UUID, on device: DeviceInfo, swap: Bool = false) {
        guard !(jobs[id]?.isActive ?? false), let g = games.first(where: { $0.id == id }), let ident = g.identity else { return }
        let signer: Signer
        if let c = certificateSigner() { signer = .certificate(c.identity, c.profile) }
        else {
            guard let team = settings.team else { lastError = DeviceError.noTeam.errorDescription; return }
            if team.free { lastError = MemoryEntitlements.freeTeamText; return }   // the memory entitlements are mandatory, and a Personal Team cannot have them
            signer = .xcode(team)
        }
        let team = signer.team
        if device.developerMode == false { lastError = DeviceError.developerModeOff(device.name).errorDescription; return }
        let checkout = settings.checkout
        guard let py = checkout.python() else { lastError = "No Python with NX 18's build modules. Run NX 18's setup (scripts/release/nx18-setup.sh)."; return }
        if ident.needsKeys && settings.keys == nil { lastError = "This game's NSP files need your console's keys. Choose prod.keys in Settings."; return }
        let job = BuildJob(gameID: id, target: .iPhone)
        job.device = device.name
        jobs[id] = job
        job.task = Task {
            job.state = .checking; job.stageName = "Looking at \(device.name)"
            let apps: [DeviceApp]
            do { apps = try await DeviceCtl.apps(on: device.id); deviceApps[device.id] = apps }
            catch { job.state = .failed(DeviceError.notConnected(device.name).errorDescription! + " (\(error.localizedDescription))"); return }
            let known = installs.first { $0.gameID == id && $0.deviceID == device.id }?.bundleID
            var bundleID = known ?? XcodeSigning.bundleID(titleID: ident.titleId, team: team, onDevice: apps)
            if case .certificate(let identity, let profile) = signer {   // the profile decides: its own App ID, or the game's under a wildcard
                bundleID = profile.bundleID(forGame: bundleID)
                if let why = profile.problem(identity: identity, deviceUDID: device.udid, bundleID: bundleID) { job.state = .failed(why); return }
            }
            var victim: InstallRecord?
            switch Slots.plan(installing: bundleID, freeTeam: team.free, onDevice: apps, records: installs) {
            case .fits: break
            case .full:
                job.state = .failed("This device already has 3 apps from a free account, none of them installed by Beam. Remove one on the device, then install again."); return
            case .replaces(let b):
                guard swap else {
                    let title = installs.first { $0.bundleID == b }.flatMap { r in games.first { $0.id == r.gameID }?.title } ?? b
                    job.state = .cancelled; jobs[id] = nil
                    swapQuestion = SwapQuestion(gameID: id, device: device, victim: b, victimTitle: title); return
                }
                victim = installs.first { $0.bundleID == b && $0.deviceID == device.id && !$0.removed }
            }
            if team.free && known == nil && Slots.appIDsThisWeek(installs) >= Slots.weeklyAppIDs {
                job.state = .failed("This Apple account registered 10 new App IDs this week, the most a free account may. Reinstall a game you already have, or wait a few days."); return
            }
            // 1. the build: the game's Xcode project (Xcode signing) or its IPA (a certificate)
            let work = BuildRequest.defaultWorkDir(source: g.source, titleId: ident.titleId, buildSpace: settings.buildSpace)
            job.workDir = work
            var req = BuildRequest(source: g.source, target: .iPhone, keys: ident.needsKeys ? settings.keys : nil, package: nil, titleId: nil, workDir: work)
            dress(&req, g, ident)
            if case .xcode = signer { req.xcode = .init(bundleID: bundleID, teamID: team.id, workspace: work.appending(path: "Beam.xcworkspace")) }
            await runScript(job, req, py: py, checkout: checkout)
            guard job.state == .done else { return }
            job.state = .running
            do {
                // 2. signed: by Xcode with the player's account, or by Beam with the player's certificate and profile; both memory entitlements or no install
                let app: URL, prov: ProvisioningInfo?
                switch signer {
                case .xcode(let t):
                    job.stageName = "Signing with your Apple account"; job.step = t.label; job.fraction = nil
                    app = try await XcodeSigning.sign(work: work, titleID: ident.titleId, device: device, team: t)
                    prov = await ProvisioningInfo.of(app: app)
                case .certificate(let identity, let profile):
                    guard let ipa = job.game?.out.map(URL.init(fileURLWithPath:)), FileManager.default.fileExists(atPath: ipa.path) else { throw DeviceError.noApp }
                    job.stageName = "Signing with your certificate"; job.step = identity.shownName; job.fraction = nil
                    app = try await Resigner.unpack(ipa: ipa, into: work.appending(path: "resign"))
                    try await Resigner.sign(app: app, identity: identity, profile: profile, bundleID: bundleID)
                    prov = ProvisioningInfo(expires: profile.expires, increasedMemoryLimit: profile.memory, extendedVirtualAddressing: profile.memory)
                }
                guard await MemoryEntitlements.signed(app), prov?.grantsMemory == true else { throw DeviceError.signing(MemoryEntitlements.missingText) }
                // 3. a swap: the save off the device first, then the old game removed
                if let v = victim {
                    job.stageName = "Making room"; job.step = "Copying the save of \(games.first { $0.id == v.gameID }?.title ?? v.bundleID) to this Mac"
                    let copy = Library.defaultFolder.appending(path: "Saves/\(v.bundleID)/\(Int(Date.now.timeIntervalSince1970))")
                    try await DeviceCtl.copySave(of: v.bundleID, on: device.id, to: copy)
                    try await DeviceCtl.uninstall(v.bundleID, on: device.id)
                    if let i = installs.firstIndex(of: v) { installs[i].removed = true; installs[i].savedCopy = copy }
                }
                // 4. installed; a save Beam copied off at an earlier swap goes back
                job.stageName = "Installing on \(device.name)"; job.step = nil
                try await DeviceCtl.install(app, on: device.id)
                let earlier = installs.firstIndex { $0.bundleID == bundleID && $0.deviceID == device.id }
                if let e = earlier, installs[e].removed, let copy = installs[e].savedCopy {
                    job.stageName = "Putting the save back"
                    let inner = copy.appending(path: "save")   // devicectl copies the folder itself into the destination
                    try await DeviceCtl.restoreSave(FileManager.default.fileExists(atPath: inner.path) ? inner : copy, of: bundleID, on: device.id)
                }
                let rec = InstallRecord(deviceID: device.id, deviceName: device.name, gameID: id, bundleID: bundleID, titleID: ident.titleId,
                                        installed: earlier.map { installs[$0].installed } ?? .now, expires: prov?.expires, freeTeam: team.free,
                                        increasedMemoryLimit: prov?.increasedMemoryLimit ?? false, lastPlayed: earlier.flatMap { installs[$0].lastPlayed })
                if let e = earlier { installs[e] = rec } else { installs.append(rec) }
                deviceApps[device.id] = try? await DeviceCtl.apps(on: device.id)
                job.state = .done
                notify(g.title, ok: true, target: .iPhone)
            } catch {
                job.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Renew: the same build signed and installed again (fast: CoreDevice sends only what changed)
    func renew(_ r: InstallRecord) {
        guard let d = devices.first(where: { $0.id == r.deviceID }) else { lastError = DeviceError.notConnected(r.deviceName).errorDescription; return }
        install(r.gameID, on: d)
    }

    func launch(_ r: InstallRecord) {
        Task {
            do {
                try await DeviceCtl.launch(r.bundleID, on: r.deviceID)
                if let i = installs.firstIndex(of: r) { installs[i].lastPlayed = .now }
            } catch { lastError = error.localizedDescription }
        }
    }

    // Route B: the IPA for another sideloading tool
    func ipa(_ id: UUID) -> URL? {
        guard let b = games.first(where: { $0.id == id })?.lastBuild, b.ok, b.target == .iPhone, let out = b.output, out.hasSuffix(".ipa"),
              FileManager.default.fileExists(atPath: out) else { return nil }
        return URL(fileURLWithPath: out)
    }
    func airDrop(_ url: URL) { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url]) }
}
