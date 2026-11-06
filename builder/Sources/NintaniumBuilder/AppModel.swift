import AppKit
import Foundation
import Observation

struct LogLine: Identifiable, Sendable {
    var id: Int
    var text: String
    var red: Bool
}

/// What the build or install is doing.
enum Phase: Equatable, Sendable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String)
    case cancelled
    var isRunning: Bool { if case .running = self { return true }; return false }
}

@MainActor @Observable
final class AppModel {
    var settings = BuilderSettings() { didSet { save() } }
    var games: [Game] = [] { didSet { save() } }
    var selection: Selection? = .repository
    let repo = Repository()
    var devices: [Device] = []
    var deviceError: String?
    var deviceID: String?
    var showAddGame = false

    // the job that runs (one at a time: a build, then its install)
    var phase: Phase = .idle
    var jobGame: UUID?
    var stage = ""
    var stageK = 0
    var stageN = 0
    var step = ""
    var fraction: Double?
    var eta: Double?
    var log: [LogLine] = []
    private var running: RunningCommand?
    private var building: Game?      // the game being built, with what its build's messages said
    private var lastRed = ""
    private var cancelled = false
    private var laterProgram = false   // the build has moved on to another program of the game ("==== program N"): its cheat lines are that program's, not the application's
    private var loaded = false
    private var started = false

    enum Selection: Hashable { case repository, game(UUID) }

    // MARK: - Start, persistence

    func start() async {
        guard !started else { return }   // each window's task calls it (a window opened from the Dock after the last one closed too): one load and one update loop
        started = true
        load()
        repo.configure(path: settings.repoPath, branch: settings.branch)
        await repo.refresh()
        await refreshDevices()
        if settings.teamID.isEmpty, let t = await Devices.teamID() { settings.teamID = t }   // the signing certificate's team, until one is set
        Task { await self.updateLoop() }
    }

    private var libraryURL: URL { Paths.support.appendingPathComponent("library.json") }
    private var settingsURL: URL { Paths.support.appendingPathComponent("settings.json") }

    private func load() {
        let dec = JSONDecoder()
        var kept = true
        if let d = try? Data(contentsOf: settingsURL) {
            if let s = try? dec.decode(BuilderSettings.self, from: d) { settings = s } else if !keepAside(settingsURL) { kept = false }
        }
        if let d = try? Data(contentsOf: libraryURL) {
            if let g = try? dec.decode([Game].self, from: d) { games = g } else if !keepAside(libraryURL) { kept = false }
        }
        loaded = kept   // a file that could not be moved aside is never overwritten: nothing is saved then
    }

    /// A file this version cannot read moves aside (<name>-unreadable-<time>.json), kept for recovery, so that the next save does not overwrite it with an empty library.
    private func keepAside(_ u: URL) -> Bool {
        let to = u.deletingLastPathComponent().appendingPathComponent("\(u.deletingPathExtension().lastPathComponent)-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        return (try? FileManager.default.moveItem(at: u, to: to)) != nil
    }

    private func save() {
        guard loaded else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(settings).write(to: settingsURL, options: .atomic)
        try? enc.encode(games).write(to: libraryURL, options: .atomic)
    }

    func settingsChanged() {
        repo.configure(path: settings.repoPath, branch: settings.branch)
        Task { await repo.refresh() }
    }

    func binding(_ id: UUID) -> Game? { games.first { $0.id == id } }
    func update(_ g: Game) { if let i = games.firstIndex(where: { $0.id == g.id }) { games[i] = g } }

    /// A build's results into the game, keeping what the player changed in the meantime.
    private func record(_ g: Game) {
        guard let i = games.firstIndex(where: { $0.id == g.id }) else { return }
        games[i].lastIPA = g.lastIPA; games[i].lastProject = g.lastProject; games[i].lastDerivedData = g.lastDerivedData
        games[i].lastBundleID = g.lastBundleID; games[i].lastGameData = g.lastGameData; games[i].lastCheatBuild = g.lastCheatBuild
        games[i].lastBuilt = g.lastBuilt; games[i].lastBuiltDevice = g.lastBuiltDevice
    }

    func addGame(folder: URL, name: String, titleID: String, device: TargetDevice) {
        let g = Game(name: name, titleID: titleID.uppercased(), nspFolder: folder.path, device: device)
        games.append(g)
        try? FileManager.default.createDirectory(at: Paths.mods(g.titleID), withIntermediateDirectories: true)
        selection = .game(g.id)
    }

    func removeGame(_ id: UUID) {
        games.removeAll { $0.id == id }
        if selection == .game(id) { selection = .repository }
    }

    // MARK: - Keeping the checkout up to date

    /// Checks the remote now and then; with automatic updates on, pulls new commits when no build runs (a build reads the checkout).
    private func updateLoop() async {
        while !Task.isCancelled {
            await repo.check()
            if settings.autoPull, !repo.incoming.isEmpty, !phase.isRunning, !repo.localChanges { await repo.pull() }
            try? await Task.sleep(for: .seconds(max(5, settings.autoPullMinutes) * 60))
        }
    }

    // MARK: - Devices

    func refreshDevices() async {
        let r = await Devices.list()
        devices = r.devices; deviceError = r.error
        if deviceID == nil || !devices.contains(where: { $0.id == deviceID }) { deviceID = devices.first(where: \.connected)?.id ?? devices.first?.id }
    }

    var selectedDevice: Device? { devices.first { $0.id == deviceID } }

    // MARK: - Log and progress

    private func say(_ s: String, red: Bool = false) {
        log.append(LogLine(id: log.count, text: s, red: red || s.contains("[RED]")))
        if log.count > 6000 { log.removeFirst(1000); for i in log.indices { log[i].id = i } }
    }

    private func beginJob(_ g: Game, _ what: String) {
        jobGame = g.id; phase = .running(what); cancelled = false
        log = []; stage = what; stageK = 0; stageN = 0; step = ""; fraction = nil; eta = nil
    }

    func cancel() { cancelled = true; running?.interrupt() }

    /// Runs a command for the job, its lines into the log (or through parse).
    private func run(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:], parse: ((String) -> Void)? = nil) async -> CommandResult {
        say("$ " + ([tool] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
        let r = await Shell.run(tool, args, cwd: cwd, env: env, onLine: { [weak self] line in
            guard let self else { return }
            switch line {
            case .out(let s): if let parse { parse(s) } else { self.say(s) }
            case .err(let s): self.say(s, red: s.lowercased().contains("error"))
            }
        }, started: { [weak self] cmd in self?.running = cmd })
        running = nil
        return r
    }

    // MARK: - Build

    /// The NSP script's arguments for a game.
    func buildArguments(_ g: Game) -> [String] {
        var a = ["scripts/build_ipa_from_nsp.py", g.nspFolder, "--progress", "json", "--device", g.device.rawValue, "--romfs", g.gameData.rawValue,
                 "--app-name", g.name, g.showFPS ? "--show-fps" : "--no-show-fps"]
        if FileManager.default.fileExists(atPath: settings.keysPath) { a += ["-k", settings.keysPath] }
        if !g.bundleID.isEmpty { a += ["--bundle-id", g.bundleID] }
        if !g.language.isEmpty { a += ["-l", g.language] }
        a += ["--gpu", g.pipelineArchive ? g.device.gpu : "none"]   // off is no archive at all, also for a game whose profile sets pso_mtl4 on
        // the list under Patches & Cheats is what the build takes: with all of it off, no mods, not the mods folder beside the NSPs, which the script takes (its default)
        // only when the list is empty
        let mods = Paths.mods(g.titleID), entries = ModsStore.list(mods)
        if !g.useMods || (!entries.isEmpty && !entries.contains(where: \.enabled)) { a.append("--no-mods") } else if !entries.isEmpty { a += ["--mods", mods.path] }
        if g.install == .xcode {
            a.append("--prepare-xcode")
            if !settings.teamID.isEmpty { a += ["--team-id", settings.teamID] }
        } else {
            let name = "\(g.name) (\(g.device.label)).ipa".replacingOccurrences(of: "/", with: "_")
            let dir = settings.outputFolder.isEmpty ? g.nspFolder : settings.outputFolder
            a += ["-o", URL(fileURLWithPath: dir).appendingPathComponent(name).path]
        }
        return a
    }

    func build(_ id: UUID, thenInstall: Bool) async {
        guard var g = binding(id), !phase.isRunning else { return }
        guard repo.exists else { phase = .failed("No Nintanium checkout at \(settings.repoPath): clone it under Repository."); return }
        guard !repo.writing else { phase = .failed("The checkout is being updated: build again in a moment."); return }   // a build reads the checkout as it goes
        beginJob(g, "Building \(g.name) for \(g.device.label)")
        var env: [String: String] = [:]
        if let ent = Entitlements.file(paid: settings.paidAccount) { env["DM_ENTITLEMENTS"] = ent }   // both memory entitlements, or Increased Memory Limit alone for a free team
        g.lastCheatBuild = nil   // this build's, if it packs cheats: a stale one would put a cheat file under another version's build ID
        building = g; lastRed = ""; laterProgram = false
        let r = await run(settings.python, buildArguments(g), cwd: URL(fileURLWithPath: settings.repoPath), env: env) { [weak self] line in
            guard let self else { return }
            guard line.hasPrefix("{"), let d = line.data(using: .utf8), let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let kind = ev["ev"] as? String else { self.say(line); return }
            switch kind {
            case "stage":
                self.stageK = ev["k"] as? Int ?? self.stageK; self.stageN = ev["n"] as? Int ?? self.stageN
                self.stage = ev["name"] as? String ?? ""; self.step = ev["step"] as? String ?? ""; self.fraction = nil; self.eta = nil
                self.say("▸ \(self.stage)" + (self.step.isEmpty ? "" : ": \(self.step)"))
            case "step": self.step = ev["step"] as? String ?? ""; self.fraction = nil
            case "progress": self.fraction = ev["frac"] as? Double; self.eta = ev["eta"] as? Double; self.step = ev["step"] as? String ?? self.step
            case "stage_end":
                let ok = ev["ok"] as? Bool ?? true, warn = ev["warn"] as? Bool ?? false
                if let s = ev["summary"] as? String, !s.isEmpty { self.say("  \(ok ? (warn ? "⚠︎" : "✓") : "✗") \(s)", red: !ok) }
            case "shaders_stale": self.say("Shaders will be rebuilt: the translation \(ev["reason"] as? String == "chain" ? "chain" : "inputs") changed since the last build.")
            case "say":
                let m = ev["msg"] as? String ?? ""
                self.say(m)
                if m.contains("[RED]") { self.lastRed = m }
                self.note(m)
            default: break
            }
        }
        if let b = building { g = b }
        record(g)
        if cancelled || r.status == 130 { phase = .cancelled; say("Cancelled."); return }
        guard r.ok else {
            let why = lastRed.isEmpty ? r.reason : lastRed.replacing(#/^\[[0-9:]+\]\s*/#, with: "")
            phase = .failed("The build stopped: \(why)"); return
        }
        g.lastBuilt = Date(); g.lastBuiltDevice = g.device
        record(g)
        if g.install == .xcode, !(await signWithXcode(g)) { return }
        phase = .succeeded(g.install == .xcode ? "Built and signed for \(g.device.label)." : "Built \(URL(fileURLWithPath: g.lastIPA ?? "").lastPathComponent).")
        if thenInstall { await install(id) }
    }

    /// Picks what the script's messages say about the result: the IPA, the Xcode project, the bundle ID, the game data to copy and the build ID of this version's cheats.
    private func note(_ raw: String) {
        guard var g = building else { return }
        defer { building = g }
        let m = raw.replacing(#/^\[[0-9:]+\]\s*/#, with: "")
        if let x = m.firstMatch(of: #/^done: (.+\.ipa) \(/#) { g.lastIPA = String(x.1) }
        if let x = m.firstMatch(of: #/^game project: (.+)$/#) { g.lastProject = String(x.1) }
        if let x = m.firstMatch(of: #/^Xcode derived data: (.+)$/#) { g.lastDerivedData = String(x.1) }
        if m.hasPrefix("==== program ") { laterProgram = true }   // another program of the game: its own lines (app name, cheats) are not the app's
        if !laterProgram, let x = m.firstMatch(of: #/^app name: .*; bundle ID: ([^;\s]+)/#) { g.lastBundleID = String(x.1) }   // every iOS build's, whatever the game files' mode; program 0's is the app's
        if let x = m.firstMatch(of: #/push_romfs\.sh <device UDID> \S+ "(.+)"/#) { g.lastGameData = String(x.1) }
        // game_mods.py pack_cheats: "cheats: <build ID>.txt (this version): ...", main's build ID; program 0's only, when a game of several programs packs each (its own lines come first)
        if !laterProgram, g.lastCheatBuild == nil, let x = m.firstMatch(of: #/^mods: cheats: ([0-9A-Fa-f]{16})\.txt \(this version\)/#) { g.lastCheatBuild = String(x.1).uppercased() }
        if g.gameData == .bundle, m.hasPrefix("done:") || m.hasPrefix("ready:") { g.lastGameData = nil }
    }

    /// The prepared Xcode project built, signed by Xcode with the player's team (automatic signing; -allowProvisioningUpdates lets it make the profile).
    private func signWithXcode(_ g: Game) async -> Bool {
        guard let proj = g.lastProject else { phase = .failed("The build named no Xcode project."); return false }
        stage = "Signing with Xcode"; step = "building the app"; fraction = nil; stageK = 0
        phase = .running("Signing \(g.name) with Xcode")
        let list = await Shell.run("xcodebuild", ["-list", "-json", "-project", proj])
        if cancelled { phase = .cancelled; return false }   // Stop while -list ran (no command of the job's to interrupt): the build below does not start
        guard let d = list.stdout.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let p = j["project"] as? [String: Any], let scheme = (p["schemes"] as? [String])?.first
        else { phase = .failed("Cannot read the Xcode project's scheme: \(list.reason)"); return false }
        let dd = g.lastDerivedData ?? URL(fileURLWithPath: proj).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("xcode-derived-data").path
        // A paid team registers the chosen device on the account as it signs (a profile then covers it); otherwise any iOS device the profile already has
        let dev = selectedDevice.flatMap { $0.connected && !$0.udid.isEmpty ? $0 : nil }
        let destination = settings.paidAccount && dev != nil ? "platform=iOS,id=\(dev!.udid)" : "generic/platform=iOS"
        var args = ["-project", proj, "-scheme", scheme, "-configuration", "Release", "-destination", destination, "-allowProvisioningUpdates",
                    "DM_XCODE_OUTPUT_ROOT=\(dd)", "SYMROOT=\(dd)/Build/Products", "OBJROOT=\(dd)/Build/Intermediates.noindex"]
        if settings.paidAccount && dev != nil { args.append("-allowProvisioningDeviceRegistration") }
        if !settings.teamID.isEmpty { args.append("DEVELOPMENT_TEAM=\(settings.teamID)") }
        args.append("build")
        let r = await run("xcodebuild", args) { [weak self] line in
            guard let self else { return }
            if line.contains("error:") || line.contains("** BUILD") || line.hasPrefix("Signing Identity") || line.contains("Provisioning Profile") { self.say(line) }
            if line.hasPrefix("CompileC") || line.hasPrefix("SwiftCompile") { self.step = "compiling" }
            else if line.hasPrefix("PhaseScriptExecution") { self.step = "copying the game's files into the app" }
            else if line.hasPrefix("CodeSign") { self.step = "signing" }
        }
        if cancelled { phase = .cancelled; return false }
        guard r.ok else {
            phase = .failed("Xcode could not build or sign the app. Check Xcode › Settings › Apple Accounts and the team ID in Settings, then build again. \(r.reason)"); return false
        }
        say("✓ signed: \(dd)/Build/Products/Release-iphoneos/DmIOS.app")
        return true
    }

    private func signedApp(_ g: Game) -> URL? {
        guard let proj = g.lastProject else { return nil }
        let dd = g.lastDerivedData ?? URL(fileURLWithPath: proj).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("xcode-derived-data").path
        let app = URL(fileURLWithPath: dd).appendingPathComponent("Build/Products/Release-iphoneos/DmIOS.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }

    // MARK: - Install and game data

    private func checkDevice(_ g: Game) -> Device? {
        guard let dev = selectedDevice else { phase = .failed("No iPhone or iPad: connect one with a cable (or on the same network after pairing), unlock it, and refresh."); return nil }
        if dev.type.lowercased() != g.device.rawValue { say("⚠︎ This build is for \(g.device.label), but \(dev.name) is an \(dev.type): iOS refuses an app for the other device family.", red: true) }
        return dev
    }

    /// Installs the signed app (Xcode route) and copies the game data and cheats; the sideload route opens the IPA for the player's tool.
    func install(_ id: UUID) async {
        guard let g = binding(id) else { return }
        if g.install == .sideload {
            guard let ipa = g.lastIPA, FileManager.default.fileExists(atPath: ipa) else { phase = .failed("Build the IPA first."); return }
            openInSideloader(URL(fileURLWithPath: ipa))
            phase = .succeeded("Opened the IPA. Install it with your sideloading tool" + (g.gameData == .separate ? ", then use Copy game data." : "."))
            return
        }
        guard let app = signedApp(g) else { phase = .failed("No signed app yet: build first."); return }
        guard let dev = checkDevice(g) else { return }
        guard !repo.writing else { phase = .failed("The checkout is being updated: install again in a moment."); return }   // push_romfs.sh and the cheats' packing run from it
        beginJob(g, "Installing \(g.name) on \(dev.name)")
        let r = await run("xcrun", ["devicectl", "device", "install", "app", "--device", dev.id, app.path])
        if cancelled { phase = .cancelled; return }
        guard r.ok else { phase = .failed("Install failed: \(r.reason). Unlock the device, trust this Mac, and turn on Developer Mode (Settings › Privacy & Security)."); return }
        say("✓ installed")
        if g.gameData == .separate { guard await pushGameData(g, dev) else { return } }
        var cheats = ""   // the app is installed either way: a failed cheat copy is said, not a failed install
        if g.useMods, case .failed(let why) = await pushCheats(g, dev) { cheats = " The cheats were not copied: \(why)" }
        if cancelled { phase = .cancelled; return }
        phase = .succeeded("Installed on \(dev.name). Open it on the device" + (settings.paidAccount ? "." : " (first time: trust your developer certificate in Settings › General › VPN & Device Management).") + cheats)
    }

    func copyGameData(_ id: UUID) async {
        guard let g = binding(id), let dev = checkDevice(g) else { return }
        guard !repo.writing else { phase = .failed("The checkout is being updated: copy again in a moment."); return }   // push_romfs.sh runs from it
        beginJob(g, "Copying \(g.name)'s game data to \(dev.name)")
        if await pushGameData(g, dev) { phase = .succeeded("Game data on \(dev.name).") }
    }

    func copyCheats(_ id: UUID) async {
        guard let g = binding(id), let dev = checkDevice(g) else { return }
        guard !repo.writing else { phase = .failed("The checkout is being updated: copy again in a moment."); return }   // the cheats are packed by its game_mods.py
        beginJob(g, "Copying \(g.name)'s cheats to \(dev.name)")
        switch await pushCheats(g, dev) {
        case _ where cancelled: phase = .cancelled
        case .failed(let why): phase = .failed(why)
        case .copied(let names) where names.isEmpty: phase = .failed("No cheat file is on.")
        case .copied(let names): phase = .succeeded("Copied \(names.joined(separator: ", ")). In the game: gear menu › Cheats › Reload cheats.")
        }
    }

    /// The game's files onto the device (scripts/push_romfs.sh): the Xcode project's resources.env also brings the DLC; an IPA build's image alone otherwise.
    private func pushGameData(_ g: Game, _ dev: Device) async -> Bool {
        var source = g.lastGameData
        if let proj = g.lastProject {
            let env = URL(fileURLWithPath: proj).deletingLastPathComponent().appendingPathComponent("Gen/resources.env")
            if g.install == .xcode, FileManager.default.fileExists(atPath: env.path) { source = env.path }
        }
        guard let source else { phase = .failed("The last build named no game data to copy (a build with the game files inside the app needs none)."); return false }
        stage = "Copying game data"; step = "this takes a few minutes for a big game"
        let r = await run("bash", ["scripts/push_romfs.sh", dev.id, g.effectiveBundleID, source], cwd: URL(fileURLWithPath: settings.repoPath))
        if cancelled { phase = .cancelled; return false }
        guard r.ok else { phase = .failed("Copying the game data failed: \(r.reason). The app must be installed first; run it again to resume."); return false }
        return true
    }

    /// What pushCheats did: the files it copied (none: no cheat file is on), or why it stopped.
    private enum CheatCopy { case copied([String]), failed(String) }

    /// game_mods.py's own scan and pack_cheats over the game's mods folder, so the cheats go in as a build packs them. Arguments: the mods folder, the title ID, this version's
    /// build ID (empty: not known), the folder to write. Exit 3: a file not named after a build ID, and no build ID to pack it as.
    private static let packCheats = """
        import sys
        sys.path.insert(0, 'dm/tools')
        import game_mods as gm
        mods, title, build, dst = sys.argv[1:5]
        found = gm.scan(mods, int(title, 16))
        if not build and not all(gm.TITLE.fullmatch(p.stem) for p in found.cheats): sys.exit(3)
        report, _ = gm.pack_cheats(found, build.upper(), dst)
        if build: print('\\n'.join(report))   # with no build ID, pack_cheats would call each file another version's
        """

    /// The game's cheat files that are on, packed as a build packs them (game_mods.py pack_cheats: a file not named after a build ID is this version's, and the files of one
    /// build are joined into <build ID>.txt, the only name the game reads), into the app's Documents/cheats, where the in-game menu's Reload cheats picks them up. A file of
    /// the same name there is replaced, the one the app copied in from its own packed cheats too.
    private func pushCheats(_ g: Game, _ dev: Device) async -> CheatCopy {
        let root = Paths.mods(g.titleID)
        guard !ModsStore.enabledCheatFiles(root).isEmpty else { return .copied([]) }
        guard repo.exists else { return .failed("No Nintanium checkout at \(settings.repoPath) to pack the cheats with: clone it under Repository.") }
        stage = "Copying cheats"; step = ""
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("nintanium-cheats-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let pack = await run(settings.python, ["-c", Self.packCheats, root.path, g.titleID, g.lastCheatBuild ?? "", tmp.path], cwd: URL(fileURLWithPath: settings.repoPath))
        if pack.status == 3 {
            return .failed("A cheat file not named after a build ID goes in as this game version's <build ID>.txt, and no build has named that ID yet: build the game with its cheats on first.")
        }
        guard pack.ok else { return .failed("Packing the cheats failed: \(pack.reason)") }
        let files = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var copied: [String] = [], failed: [String] = []
        for f in files where !cancelled {
            let r = await run("xcrun", ["devicectl", "device", "copy", "to", "--device", dev.id, "--domain-type", "appDataContainer", "--domain-identifier", g.effectiveBundleID,
                                        "--source", f.path, "--destination", "Documents/cheats/\(f.lastPathComponent)", "-q"])
            if r.ok { copied.append(f.lastPathComponent) } else { failed.append(f.lastPathComponent); say("⚠︎ \(f.lastPathComponent): \(r.reason)", red: true) }
        }
        return failed.isEmpty ? .copied(copied) : .failed("Copying \(failed.joined(separator: ", ")) failed (the log says why). The app must be installed first.")
    }

    private func openInSideloader(_ ipa: URL) {
        let ws = NSWorkspace.shared
        for id in ["io.sideloadly.sideloadly", "com.rileytestut.AltServer", "com.SideStore.SideStore"] {
            if let app = ws.urlForApplication(withBundleIdentifier: id) {
                ws.open([ipa], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        ws.activateFileViewerSelecting([ipa])
    }

    // MARK: - Tools check

    func checkTools() async -> [(String, Bool, String)] {
        var out: [(String, Bool, String)] = []
        for (name, tool, args) in [("Git", "git", ["--version"]), ("Python", settings.python, ["--version"]), ("XcodeGen", "xcodegen", ["--version"]),
                                   (".NET SDK", "dotnet", ["--version"]), ("zstd", "zstd", ["--version"]), ("glslang", "glslangValidator", ["--version"]),
                                   ("Xcode", "xcodebuild", ["-version"]), ("devicectl", "xcrun", ["devicectl", "--version"])] {
            let r = await Shell.run(tool, args)
            out.append((name, r.ok, r.ok ? (r.stdout + r.stderr).split(separator: "\n").first.map(String.init) ?? "" : "not found"))
        }
        let py = await Shell.run(settings.python, ["-c", "import lz4, capstone, fontTools, nsz; print('lz4, capstone, fonttools, nsz')"])
        out.append(("Python packages", py.ok, py.ok ? py.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "missing: run the pip line from README step 1"))
        out.append(("prod.keys", FileManager.default.fileExists(atPath: settings.keysPath), settings.keysPath))
        return out
    }
}
