// Rebuild only what changed, in Beam's library (the rule in Rebuilds.swift): the marks, Rebuild Updated Games three at a time, and the night run
import Foundation

extension Library {
    /// The games Rebuild Updated Games would build now: marked, read, and not building
    var rebuildCandidates: [UUID] {
        games.filter { rebuilds[$0.id] != nil && $0.identity != nil && !(jobs[$0.id]?.isActive ?? false) }.map(\.id)
    }

    /// Marks the built games whose NX 18 changed (rebuilds). When Beam comes to the front (at most once a minute) and after each build (`force`). A build from before
    /// Beam recorded its checkout gets the commit HEAD was at its time, once, kept in the library
    func checkRebuilds(force: Bool = false) async {
        if checkingRebuilds { return }
        if !force, let last = lastRebuildCheck, Date.now.timeIntervalSince(last) < 60 { return }
        let checkout = settings.checkout
        guard checkout.isValid else { if !rebuilds.isEmpty { rebuilds = [:] }; return }
        checkingRebuilds = true; defer { checkingRebuilds = false; lastRebuildCheck = .now }
        let folder = checkout.folder
        let legacy = games.compactMap { g in g.lastBuild.flatMap { $0.ok && $0.nx18 == nil ? (g.id, $0.date) : nil } }
        if !legacy.isEmpty {
            let found = await Task.detached(priority: .utility) { legacy.compactMap { id, date in NX18Git.stamp(at: date, of: folder).map { (id, $0) } } }.value
            for (id, s) in found { if let i = games.firstIndex(where: { $0.id == id }) { games[i].lastBuild?.nx18 = s } }
            if !found.isEmpty { save() }
        }
        let built = games.compactMap { g in g.lastBuild.flatMap { $0.ok ? RebuildRule.Built(id: g.id, from: $0.nx18, titles: RebuildRule.titles(of: g.identity)) : nil } }
        let r = await Task.detached(priority: .utility) { RebuildRule.check(built, folder: folder) }.value
        if r != rebuilds { rebuilds = r }
    }

    /// Rebuild Updated Games: the marked games, three at a time (each group done before the next starts), each for the target and version of its last build; the Mac
    /// kept awake (not its display) while it runs. `whenCharging`: each build waits for the power adapter (the night run on battery)
    func rebuildUpdated(whenCharging: Bool = false) {
        guard rebuildTask == nil else { return }
        let ids = rebuildCandidates
        guard !ids.isEmpty else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Rebuilding updated games")
        rebuildProgress = (0, ids.count)
        fputs("beam: rebuilding \(ids.count) updated games, three at a time\n", stderr)
        rebuildTask = Task {
            for group in RebuildRule.groups(ids) {
                if Task.isCancelled { break }
                for id in group { if let b = games.first(where: { $0.id == id })?.lastBuild { build(id, target: b.target, package: b.package, now: true, whenCharging: whenCharging) } }
                let tasks = group.compactMap { jobs[$0]?.task }
                await withTaskCancellationHandler {
                    for t in tasks { await t.value }
                } onCancel: { for t in tasks { t.cancel() } }
                rebuildProgress?.done += group.count
            }
            ProcessInfo.processInfo.endActivity(activity)
            rebuildTask = nil; rebuildProgress = nil
            await checkRebuilds(force: true)
        }
    }
    func stopRebuilding() { rebuildTask?.cancel() }

    /// Rebuild Updated Games Tonight: once, at 1 AM, whatever is marked then. The Mac does not go to sleep on its own until then (its display does); Cancel undoes it
    func rebuildTonight() {
        tonightTask?.cancel()
        let at = RebuildRule.tonight(after: .now)
        tonight = at
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Rebuild updated games tonight")
        tonightTask = Task {
            try? await Task.sleep(for: .seconds(max(at.timeIntervalSinceNow, 0)))   // the continuous clock: a Mac woken after 1 AM starts at once
            if !Task.isCancelled {
                await checkRebuilds(force: true)
                rebuildUpdated(whenCharging: Preflight.onBattery)
            }
            ProcessInfo.processInfo.endActivity(activity)
            if tonight == at { tonight = nil; tonightTask = nil }
        }
    }
    func cancelTonight() { tonightTask?.cancel(); tonightTask = nil; tonight = nil }
}
