// Beam's library: the games the player added, what NX 18 says each one is (--identify), and their builds.
// Kept in ~/Library/Application Support/NX 18 Beam/library.json (beam-design §4.5); the games' own files stay where they are.
import AppKit
import Foundation
import Observation
import UserNotifications

struct LibraryGame: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var source: URL                  // the folder, .nup or .nx the player added
    var identity: IdentifyEvent?
    var added = Date()
    var lastBuild: BuildRecord?
    var manual: URL?                 // the game's manual (PDF) the player added: --manual at the next build
    var customName: String?          // the player's name for the game (Rename): Beam's library, and the app's name at the next build (--app-name)
    var modsChanged: Bool?           // a mod was added or removed since the last start from Beam: the save is backed up first (beam-design §3.6)
    var builtIcon: String?           // the icon and key art Beam's latest build of the game reported (its game and art events), for the library and Home
    var builtArt: String?
    var art: URL?                    // the player's picks (SteamGridDB, Art.swift): --art, --logo, --icon at the next build
    var artFocus: ArtFocus?          // the player's framing of the key art (Adjust Framing, ArtFocus.swift): Beam Home and the game page now, --art-focus at the next build, the Mac app's preferences at once
    var artFocusStale: Bool?         // a new key art was picked: the framing the Mac app keeps is for the old picture, forgotten after its next Mac build (unless framed again)
    var logo: URL?
    var icon: URL?

    struct BuildRecord: Codable, Sendable, Equatable {
        var target: BuildRequest.Target
        var date: Date
        var ok: Bool
        var output: String?          // the IPA or Mac app (the game event's out)
        var icon: String?
        var build: String?           // main's build ID the app was packed from
        var message: String?         // the reason a failed build gave
        var package: String?         // -p: the version packed, when not the newest (Rebuild Updated Games packs the same)
        var nx18: BuiltFrom?         // the NX 18 checkout it was built from (Rebuilds.swift): what "Update available: rebuild" compares
    }
    var title: String { customName ?? identity?.name ?? source.deletingPathExtension().lastPathComponent }
}

/// One run of the script for a game: its stage, its progress and its messages, for the window to show
@MainActor @Observable final class BuildJob {
    enum State: Equatable { case waitingForPower, checking, running, done, failed(String), cancelled }
    let gameID: UUID
    let target: BuildRequest.Target
    var state: State = .checking
    var pid: Int32?                  // the script's, for BuildPriority while a game plays
    var workDir: URL?                // for Show Details (its logs/)
    var device: String?              // an install's device name: the job prepares, signs and installs for it
    var isActive: Bool { state == .running || state == .checking || state == .waitingForPower }
    var stageName = "Starting"
    var stageIndex = 0
    var stageCount = 0
    var step: String?
    var fraction: Double?            // nil: the stage's work cannot be counted
    var eta: Double?
    var messages: [SayEvent] = []
    var game: GameEvent?
    var art: ArtEvent?
    var mods: ModsEvent?
    var warned = false
    var task: Task<Void, Never>?

    init(gameID: UUID, target: BuildRequest.Target) { self.gameID = gameID; self.target = target }

    func apply(_ e: BuildEvent) {
        switch e {
        case .stage(let s): stageName = s.name; stageIndex = s.k; stageCount = s.n; step = s.step; fraction = nil; eta = nil
        case .step(let s): step = s.step; fraction = nil
        case .progress(let p): stageName = p.name; step = p.step; fraction = p.frac; eta = p.eta
        case .stageEnd(let s): fraction = 1; if s.warn == true { warned = true }
        case .say(let s): messages.append(s); if messages.count > 500 { messages.removeFirst(messages.count - 500) }
        case .game(let g): game = g
        case .art(let a): art = a
        case .mods(let m): mods = m
        default: break
        }
    }
    var overall: Double? {   // the build as a whole: stages done plus the running one's share
        guard stageCount > 0 else { return nil }
        return (Double(max(stageIndex - 1, 0)) + (fraction ?? 0)) / Double(stageCount)
    }
    func cancel() { task?.cancel(); if state == .waitingForPower || state == .checking { state = .cancelled } }
}

@MainActor @Observable final class Library {
    var games: [LibraryGame] = []
    var jobs: [UUID: BuildJob] = [:]
    var identifying: Set<UUID> = []
    var lastError: String?
    var myFilesNote: String?         // what the last settle of My files did (Settings, under Keep My files in the NX 18 folder)
    @ObservationIgnored var myFilesSettle: Task<Void, Never>?   // the settle running, which the next one waits for (LibraryMods.swift settleMyFiles)
    var myFilesSettled = 0           // counts finished settles that moved something: an open game page reads its My files again
    var lastAdded: UUID?             // the window selects it (a game opened with Beam from Finder or the Dock)
    var showingHome = false
    var pageRequest: UUID?           // a game whose page the window should show (the right-click menu, Beam Home); LibraryView clears it
    var settingsRequest: UUID?
    var renameRequest: UUID?         // a game the Rename sheet is asked for       // a game whose settings sheet is asked for (the right-click menu, Beam Home's Y), shown by LibraryView          // the main window shows Beam Home (the console view) in place of the library; one window, one switch
    var batteryQuestion: PendingBuild?   // a first build asked for on battery: build now, or when plugged in (beam-design §3.3)
    var playing: UUID?               // the game playing from Beam (one at a time)
    var lastEnd: (game: UUID, message: String)?   // how the last game played from Beam ended, when it was not a plain quit

    struct PendingBuild: Equatable { var id: UUID; var target: BuildRequest.Target; var package: String? }

    // iPhone and iPad installs (DeviceInstalls.swift)
    var devices: [DeviceInfo] = []
    var deviceApps: [String: [DeviceApp]] = [:]
    var installs: [InstallRecord] = [] { didSet { saveInstalls(); syncReminders(from: oldValue) } }
    var refreshingDevices = false
    var renewingAll = false
    var renewNote: String?           // how the last Renew All ended, in plain words (the library's alert, or Home's note)
    let reminders: any ExpiryScheduler   // the day-before-expiry notifications (ExpiryReminders)
    var swapQuestion: SwapQuestion?
    struct SwapQuestion: Equatable { var gameID: UUID; var device: DeviceInfo; var victim: String; var victimTitle: String }
    let installsFile: URL
    var folder: URL { installsFile.deletingLastPathComponent() }   // this library's own folder (Application Support/NX 18 Beam, or a test's)
    var sources: [SavedSource] = [] { didSet { saveSources() } }   // mod sources the player added (Mods.swift); none ship with Beam
    var sourceLists: [String: ModSource] = [:]                      // read when the player opens Mods or checks for updates
    struct SavedSource: Codable, Equatable, Identifiable { var id: String { url }; var url: String; var name: String; var maintainer: String?; var homepage: String? }
    var updateAvailable: BeamRelease?        // a newer Beam release (Updates.swift), when the player turned the check on
    var updateStep: UpdateStep?              // installing it (LibraryUpdates.swift)
    var identities: [SigningIdentity] = []   // the certificates in Beam's keychain (CertificateSigning.swift)
    var profiles: [Profile] = []
    // Rebuild only what changed (Rebuilds.swift)
    var rebuilds: [UUID: RebuildRule.Reason] = [:]   // built games whose NX 18 changed since their build: "Update available: rebuild"
    var rebuildTask: Task<Void, Never>?              // Rebuild Updated Games, three at a time
    var rebuildProgress: (done: Int, total: Int)?
    var tonight: Date?                               // Rebuild Updated Games Tonight: when it runs
    var tonightTask: Task<Void, Never>?
    @ObservationIgnored var rebuildCheck = RebuildCheckGate()   // one check at a time; a forced one during it runs after it
    var lastRebuildCheck: Date?
    let settings: BeamSettings

    private let file: URL
    init(settings: BeamSettings, folder: URL = Library.defaultFolder, reminders: any ExpiryScheduler = SystemExpiryScheduler()) {
        self.settings = settings
        self.reminders = reminders
        file = folder.appending(path: "library.json")
        installsFile = folder.appending(path: "installs.json")
        load()
        installs = (try? JSONDecoder().decode([InstallRecord].self, from: Data(contentsOf: installsFile))) ?? []
        sources = (try? JSONDecoder().decode([SavedSource].self, from: Data(contentsOf: folder.appending(path: "sources.json")))) ?? []
    }
    nonisolated static var defaultFolder: URL { URL.applicationSupportDirectory.appending(path: "NX 18 Beam", directoryHint: .isDirectory) }

    func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        games = (try? JSONDecoder().decode([LibraryGame].self, from: data)) ?? []
    }
    func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(games).write(to: file, options: .atomic)
        } catch { lastError = "Could not save the library: \(error.localizedDescription)" }
    }

    /// Adds a game the player dropped or picked, then asks NX 18 what it is
    @discardableResult func add(_ source: URL) -> UUID {
        if let g = games.first(where: { $0.source.standardizedFileURL == source.standardizedFileURL }) { identify(g.id); lastAdded = g.id; return g.id }
        let g = LibraryGame(source: source)
        games.append(g); save(); identify(g.id)
        lastAdded = g.id
        return g.id
    }
    func remove(_ id: UUID) {   // from the library only: the game's files are never touched
        jobs[id]?.cancel(); jobs[id] = nil
        games.removeAll { $0.id == id }; save()
    }

    func identify(_ id: UUID) { Task { await identifyNow(id) } }

    /// Asks NX 18 what a game is (--identify) and waits for the answer. `quiet`: a failure is returned, not shown (an import reads many games and sums them up)
    @discardableResult
    func identifyNow(_ id: UUID, quiet: Bool = false) async -> String? {
        guard let g = games.first(where: { $0.id == id }), !identifying.contains(id) else { return nil }
        let checkout = settings.checkout
        func fail(_ m: String) -> String { if !quiet { lastError = m }; return m }
        guard checkout.isValid else { return fail("No NX 18 folder at \(checkout.folder.path). Choose it in Settings.") }
        guard let py = checkout.python(checkModules: false) else { return fail("No Python 3.12 or newer found. Run NX 18's setup (scripts/release/nx18-setup.sh).") }
        identifying.insert(id)
        defer { identifying.remove(id) }
        let args = Identify.arguments(script: checkout.script, source: g.source, keys: settings.keys)
        let found = LockedValue<IdentifyEvent?>(nil)
        let result = try? await ScriptRunner.run(py, args, directory: checkout.folder) { e in if case .identify(let i) = e { found.set(i) } }
        guard let i = games.firstIndex(where: { $0.id == id }) else { return nil }
        if let ident = found.get() { games[i].identity = ident; save(); return nil }
        return fail(result?.lastError ?? result.map { "NX 18 could not read this game (exit code \($0.code))." } ?? "NX 18's script could not be started.")
    }

    /// Starts a build after its checks. `now`: the player chose to build on battery
    func build(_ id: UUID, target: BuildRequest.Target, package: String? = nil, now: Bool = false, whenCharging: Bool = false) {
        guard !(jobs[id]?.isActive ?? false), let g = games.first(where: { $0.id == id }), let ident = g.identity else { return }
        let checkout = settings.checkout
        guard let py = checkout.python() else { lastError = "No Python with NX 18's build modules. Run NX 18's setup (scripts/release/nx18-setup.sh)."; return }
        if ident.needsKeys && settings.keys == nil { lastError = "This game's NSP files need your console's keys. Choose prod.keys in Settings."; return }
        if !now && !whenCharging && g.lastBuild == nil && Preflight.onBattery { batteryQuestion = PendingBuild(id: id, target: target, package: package); return }
        var req = BuildRequest(source: g.source, target: target, keys: ident.needsKeys ? settings.keys : nil, package: package,
                               titleId: nil, workDir: BuildRequest.defaultWorkDir(source: g.source, titleId: ident.titleId, buildSpace: settings.buildSpace))
        dress(&req, g, ident)
        let job = BuildJob(gameID: id, target: target)
        job.workDir = req.workDir
        jobs[id] = job
        askToNotify()
        job.task = Task {
            if whenCharging {   // "Build when charging": wait for the power adapter, checking every 30 s
                job.state = .waitingForPower
                while Preflight.onBattery { try? await Task.sleep(for: .seconds(30)); if Task.isCancelled { job.state = .cancelled; return } }
            }
            job.state = .checking
            let source = req.source, work = req.workDir
            let (need, free) = await Task.detached { (Preflight.neededBytes(gameBytes: Preflight.gameBytes(source)), Preflight.freeBytes(at: work)) }.value
            if Task.isCancelled { job.state = .cancelled; return }
            if let free, free < need {
                let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file), n = ByteCountFormatter.string(fromByteCount: need, countStyle: .file)
                job.state = .failed("Not enough space for this build: it needs about \(n) free where the build folder goes, and \(f) is free. Free some space, or choose a build space on another disk in Settings.")
                return
            }
            // an iPhone build's IPA, which goes to other install tools (Route B): the player's Profile as it is now goes in, as in every install Beam makes (ProfileSetup.swift)
            var req = req
            if target == .iPhone { req.profileSeed = await ProfileSetup.seed() }
            let folder = checkout.folder
            let stamp = await Task.detached(priority: .utility) { NX18Git.stamp(of: folder) }.value   // the NX 18 this build is made from, read as it starts
            await runScript(job, req, py: py, checkout: checkout)
            if let seed = req.profileSeed { try? FileManager.default.removeItem(at: seed.deletingLastPathComponent()) }
            if job.state != .cancelled, let i = games.firstIndex(where: { $0.id == id }) {
                if case .failed(let why) = job.state { games[i].lastBuild = .init(target: target, date: .now, ok: false, message: why, package: package, nx18: stamp) }
                else { games[i].lastBuild = .init(target: target, date: .now, ok: true, output: job.game?.out, icon: job.game?.icon, build: job.game?.build, package: package, nx18: stamp) }
                save()
                if target == .mac, job.state == .done, let app = macApp(id) {   // the player's framing over one the app's window kept before; after a new key art, none from the old one
                    if let f = games[i].artFocus { MacArtFocus.write(f, app: app) } else if games[i].artFocusStale == true { MacArtFocus.forget(app: app) }
                    if games[i].artFocusStale != nil { games[i].artFocusStale = nil; save() }
                }
                notify(games[i].title, ok: job.state == .done, target: target)
                await checkRebuilds(force: true)
            }
        }
    }

    /// One run of the build script for a job: its events into the job, its end into the job's state (done, cancelled, or failed with the reason in a sentence)
    func runScript(_ job: BuildJob, _ req: BuildRequest, py: URL, checkout: NX18Checkout) async {
        if Task.isCancelled || job.state == .cancelled { job.state = .cancelled; return }   // a Cancel during the checks before it (the git stamp, the Profile, a device's apps)
        job.state = .running
        var req = req
        if req.artFocus != nil && !checkout.knows("--art-focus") { req.artFocus = nil }   // an NX 18 from before the option stops at it: built with the middle of the art (a Mac app's framing is still written after its build)
        let stream = AsyncStream<BuildEvent>.makeStream()
        let pump = Task { @MainActor in for await e in stream.stream { job.apply(e); self.updateDock() } }
        let result: ScriptResult?
        var cancelled = false
        let playingNow = playing != nil
        do {
            result = try await ScriptRunner.run(py, req.arguments(script: checkout.script), directory: checkout.folder, background: playingNow,
                                                onStart: { pid in Task { @MainActor in job.pid = pid } }) { stream.continuation.yield($0) }
        } catch is CancellationError { result = nil; cancelled = true   // cancelled before the script started: it never ran
        } catch { result = nil; job.messages.append(SayEvent(msg: "[RED] \(error.localizedDescription)")) }
        stream.continuation.finish(); await pump.value
        job.pid = nil
        if let i = games.firstIndex(where: { $0.id == job.gameID }) {   // the build's icon and key art, kept for the library whichever route the build was for
            if let icon = job.game?.icon { games[i].builtIcon = icon }
            if let art = job.art?.path { games[i].builtArt = art }
            save()
        }
        switch cancelled ? ScriptExit.interrupted : result?.exit {
        case .done?: job.state = .done
        case .interrupted?, .stopped?: job.state = .cancelled
        default: job.state = .failed(FriendlyError.text(result?.lastError ?? result.map { "The build stopped (exit code \($0.code))." } ?? "NX 18's script could not be started."))
        }
        updateDock()
    }

    // MARK: Play on Mac (beam-design §3.5)

    /// The Mac app a game's last Mac build made, when it is still there
    func macApp(_ id: UUID) -> URL? {
        guard let b = games.first(where: { $0.id == id })?.lastBuild, b.ok, b.target == .mac, let out = b.output else { return nil }
        let u = URL(fileURLWithPath: out)
        return GamePlayer.executable(of: u) != nil ? u : nil
    }

    func play(_ id: UUID) {
        guard playing == nil, let app = macApp(id), let gi = games.firstIndex(where: { $0.id == id }) else { return }
        playing = id; lastEnd = nil
        if games[gi].modsChanged == true, let tid = games[gi].identity?.titleId {   // the first start with a changed mod: the Mac save copied first
            backUpMacSave(titleID: tid); games[gi].modsChanged = nil; save()
        }
        let builds = jobs.values.compactMap(\.pid)
        Task {
            for pid in builds { await Task.detached { BuildPriority.set(pid: pid, background: true) }.value }   // the game keeps the performance cores
            let end: GameEnd
            // The Beam dashes' sweep once the game's process runs, so it never holds the start back (LaunchSweep.swift); gone when the game ends or fails to start
            do { end = try await GamePlayer.play(app, onStart: { _ in Task { @MainActor in LaunchSweep.begin() } }) } catch { end = .other(-1); lastError = "The game could not be started: \(error.localizedDescription)" }
            playing = nil; LaunchSweep.end()
            for pid in jobs.values.compactMap(\.pid) { await Task.detached { BuildPriority.set(pid: pid, background: false) }.value }
            if let m = end.message { lastEnd = (id, m) }
        }
    }

    // MARK: Dock and notifications (beam-design §3.3)

    func updateDock() {
        let running = jobs.values.filter { $0.state == .running }
        let tile = NSApp.dockTile
        if let f = running.compactMap(\.overall).min() { tile.badgeLabel = "\(Int(f * 100))%" }
        else { tile.badgeLabel = running.isEmpty ? nil : "…" }
    }
    private func askToNotify() { SystemExpiryScheduler.askToNotify() }
    func notify(_ title: String, ok: Bool, target: BuildRequest.Target) {
        guard !NSApp.isActive else { return }   // the window says it already
        let c = UNMutableNotificationContent()
        c.title = ok ? "\(title) is built" : "\(title): the build stopped"
        c.body = ok ? (target == .mac ? "Ready to play on this Mac." : "Ready to install on your iPhone or iPad.") : "Open Beam to see why."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
