// The library's mods, sources and manual (Mods.swift has the checks): what the game page and Settings call
import Foundation

extension Library {
    /// Beam's own pieces of a build: the mods (Beam's folder for the game once it keeps any, else the mods folder beside the game's files, read only, as the
    /// script itself would take it) and the manual
    func dress(_ req: inout BuildRequest, _ g: LibraryGame, _ ident: IdentifyEvent) {
        let f = ModStore.folder(titleID: ident.titleId)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        if !beamKeepsMods(ident.titleId), let own = GameFolderMods.read(g.source), !own.isEmpty { req.mods = own.folder } else { req.mods = f }
        if let m = g.manual, FileManager.default.fileExists(atPath: m.path) { req.manual = m }
        let have = { (u: URL?) in u.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        req.art = have(g.art); req.logo = have(g.logo); req.icon = have(g.icon)
        req.appName = g.customName
    }

    func saveSources() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(sources).write(to: folder.appending(path: "sources.json"), options: .atomic)
    }

    /// Reads a source and keeps it when it is one (its name, maintainer and homepage are shown before the player saves it: Settings)
    func readSource(_ text: String) async throws -> ModSource {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ModError.refused("That is not a web address.") }
        let s = try await ModFetch.source(url)
        sourceLists[url.absoluteString] = s
        return s
    }
    func addSource(_ url: String, _ s: ModSource) {
        guard !sources.contains(where: { $0.url == url }) else { return }
        sources.append(SavedSource(url: url, name: s.name, maintainer: s.maintainer, homepage: s.homepage))
    }
    func removeSource(_ s: SavedSource) { sources.removeAll { $0 == s }; sourceLists[s.url] = nil }

    /// Every saved source read again (the player opened Mods or pressed Check for Mod Updates); a source that fails is named, the others still load
    func refreshSources() async {
        var failed: [String] = []
        for s in sources {
            guard let u = URL(string: s.url) else { continue }
            do { sourceLists[s.url] = try await ModFetch.source(u) } catch { failed.append(s.name) }
        }
        if !failed.isEmpty { lastError = "Could not read: \(failed.joined(separator: ", "))." }
    }

    /// The source mods for a game, with whether they fit its build (beam-design §5: a mod for another build is listed greyed)
    struct Offer: Identifiable { var id: String { entry.id }; var entry: ModSource.Entry; var source: SavedSource; var fits: Bool }
    func offers(for g: LibraryGame) -> [Offer] {
        guard let ident = g.identity else { return [] }
        let builds = gameBuilds(g)
        return sources.flatMap { s in (sourceLists[s.url]?.mods(for: ident.titleId) ?? []).map { e in
            Offer(entry: e, source: s, fits: !builds.isDisjoint(with: e.buildIds.map { String($0.prefix(16)).uppercased() }))
        } }
    }
    /// The builds a mod can be for: the version that is packed, else every version the folder holds
    func gameBuilds(_ g: LibraryGame) -> Set<String> {
        guard let ident = g.identity else { return [] }
        if let packed = ident.versions.first(where: { $0.version == ident.packs })?.build { return [packed] }
        return Set(ident.versions.compactMap(\.build))
    }

    /// Whether Beam keeps any mods or cheats of its own for a game (its folder then decides the build's mods)
    func beamKeepsMods(_ titleID: String) -> Bool {
        let f = ModStore.folder(titleID: titleID)
        return ((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []).contains { !$0.hasPrefix(".") }
    }
    /// The game folder's mods copied into Beam's folder, before Beam's first mod or cheat for the game, so the build keeps carrying them
    func bringInGameMods(_ g: LibraryGame) {
        guard let ident = g.identity, !beamKeepsMods(ident.titleId), let own = GameFolderMods.read(g.source), !own.isEmpty else { return }
        do { _ = try own.bringIn(to: ModStore.folder(titleID: ident.titleId)); markModsChanged(g.id) } catch { lastError = "The game folder's mods could not be brought in: \(error.localizedDescription)" }
    }

    /// Gets a source's mod for a game: downloaded from its author, checked, kept. The next build carries it
    func getMod(_ o: Offer, for g: LibraryGame) async {
        guard let ident = g.identity, let kind = o.entry.role else { return }
        let work = FileManager.default.temporaryDirectory.appending(path: "beam-mod-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        bringInGameMods(g)
        do {
            let c = try await ModFetch.download(o.entry, into: work)
            try fitBuild(c, g)
            let credit = ModCredit(kind: kind, variant: o.entry.variant, author: o.entry.author, license: o.entry.license, homepage: o.entry.homepage,
                                   version: o.entry.version, source: o.source.url, sha256: o.entry.sha256.lowercased(), buildIds: c.buildIds.sorted(), added: .now)
            try ModStore.keep(c, credit: credit, titleID: ident.titleId)
            markModsChanged(g.id)
        } catch { lastError = error.localizedDescription }
    }

    /// A mod file the player got themselves (a .zip of patches, or one patch file): the same checks, credited "Added by you"
    func addModFile(_ file: URL, kind: ModKind, variant: String?, author: String, for g: LibraryGame) async {
        guard let ident = g.identity else { return }
        let work = FileManager.default.temporaryDirectory.appending(path: "beam-mod-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        bringInGameMods(g)
        do {
            let data = try Data(contentsOf: file)
            let c = try await ModFetch.unpack(data, name: file.lastPathComponent, into: work)
            try fitBuild(c, g)
            let credit = ModCredit(kind: kind, variant: variant, author: author.isEmpty ? "You" : author, license: nil, homepage: nil, version: nil, source: nil,
                                   sha256: ModFetch.sha256(data), buildIds: c.buildIds.sorted(), added: .now)
            try ModStore.keep(c, credit: credit, titleID: ident.titleId)
            markModsChanged(g.id)
        } catch { lastError = error.localizedDescription }
    }

    /// A mod's patches must name the game's build (beam-design §5, exact build-ID match)
    private func fitBuild(_ c: ModContents, _ g: LibraryGame) throws {
        let builds = gameBuilds(g)
        guard !builds.isEmpty, !c.buildIds.isDisjoint(with: builds) else {
            let shown = g.identity?.versions.first { $0.version == g.identity?.packs }?.display ?? "this version"
            throw ModError.refused("This mod is for another version of the game (its patches name build \(c.buildIds.sorted().first ?? "none"); your game is \(shown)).")
        }
    }

    func removeMod(_ k: ModStore.Kept, for g: LibraryGame) {
        do { try ModStore.remove(k); markModsChanged(g.id) } catch { lastError = error.localizedDescription }
    }
    private func markModsChanged(_ id: UUID) {
        if let i = games.firstIndex(where: { $0.id == id }) { games[i].modsChanged = true; save() }
    }

    func setManual(_ url: URL?, for id: UUID) {
        if let url {
            guard (try? FileHandle(forReadingFrom: url).read(upToCount: 4)) == Data("%PDF".utf8) else { lastError = "That file is not a PDF."; return }
        }
        if let i = games.firstIndex(where: { $0.id == id }) { games[i].manual = url; save() }
    }

    /// The Mac app's save copied before the first start with a changed mod: <DM_ROOT>/save into Beam's Backups (nothing when the game has no save yet)
    func backUpMacSave(titleID: String) {
        let save = URL.applicationSupportDirectory.appending(path: "nxnative/\(titleID.uppercased())/save")
        guard FileManager.default.fileExists(atPath: save.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let dst = folder.appending(path: "Backups/\(titleID.uppercased())/\(stamp)/save")
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: save, to: dst)
        } catch { lastError = "The save could not be backed up before the start: \(error.localizedDescription)" }
    }
}

// MARK: Cheats, art and My files (beam-design §3.7-§3.9)
extension Library {
    /// The game's cheats for the build it packs (nil before NX 18 has read the game)
    func cheats(_ g: LibraryGame) -> GameCheats? {
        guard let ident = g.identity, let b = ident.versions.first(where: { $0.version == ident.packs })?.build ?? ident.versions.compactMap(\.build).last else { return nil }
        return GameCheats(titleID: ident.titleId, build: b)
    }
    func addCheats(_ file: URL, for g: LibraryGame) {
        guard playing != g.id else { lastError = "Quit the game first: it reads cheats only when it starts."; return }
        guard let c = cheats(g) else { return }
        let shown = g.identity?.versions.first { $0.build == c.build }?.display ?? "this version"
        bringInGameMods(g)
        do { try c.add(file, versionShown: shown) } catch { lastError = error.localizedDescription }
    }
    /// A switch on the Mac app's cheats: written before a start only (the host reads them at the start or on Reload Cheats)
    func setCheat(_ name: String, on: Bool, for g: LibraryGame) {
        guard playing != g.id else { lastError = "Quit the game first, or use its Cheats panel: the game reads these when it starts."; return }
        guard let c = cheats(g) else { return }
        var e = c.enabled; if on { e.insert(name) } else { e.remove(name) }
        do { try c.setEnabled(e) } catch { lastError = error.localizedDescription }
    }
    func setCheatsOff(_ off: Bool, for g: LibraryGame) {
        guard playing != g.id, let c = cheats(g) else { return }
        do { try c.setAllOff(off) } catch { lastError = error.localizedDescription }
    }
    func removeCheats(for g: LibraryGame) {
        guard playing != g.id, let c = cheats(g) else { return }
        do { try c.remove() } catch { lastError = error.localizedDescription }
    }

    func setArt(_ url: URL?, _ kind: ArtKind, for id: UUID) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        switch kind { case .keyArt: games[i].art = url; case .logo: games[i].logo = url; case .icon: games[i].icon = url }
        save()
    }

    /// My files: the player's own guides and maps for a game (never packed into an IPA, which can be shared): Beam's folder, or the NX 18 folder's <TITLE ID>/Documents with
    /// Keep My files in the NX 18 folder on and a folder connected (MyFilesPlace.swift)
    func myFilesFolder(_ g: LibraryGame) -> URL? {
        g.identity.map { MyFilesPlace.current(library: folder, titleID: $0.titleId, keepInNX18: settings.myFilesInNX18, nx18: myFilesNX18) }
    }
    /// The NX 18 folder My files go to: the one this Mac's games use, when the switch is on
    var myFilesNX18: URL? { settings.myFilesInNX18 ? ProfileSetup.connectedFolder().flatMap { MyFilesPlace.reachable($0) ? $0 : nil } : nil }   // a folder gone since: Beam's
    /// Brings My files to where the switch says (MyFilesPlace.settle), off the main thread and one settle at a time: every game at the switch and at launch, one game when its page
    /// opens (a folder connected since then). What moved shows under the switch (myFilesNote)
    func settleMyFiles(titleIDs: [String]? = nil) async {
        let before = myFilesSettle
        let library = folder, on = settings.myFilesInNX18, nx18 = ProfileSetup.connectedFolder()
        let run = Task { () -> MyFilesPlace.Report in
            await before?.value
            return await Task.detached(priority: .userInitiated) { MyFilesPlace.settle(library: library, keepInNX18: on, nx18: nx18, titleIDs: titleIDs) }.value
        }
        myFilesSettle = Task { _ = await run.value }
        let r = await run.value
        if r.moved > 0 { myFilesSettled += 1 }
        guard titleIDs == nil || r != MyFilesPlace.Report() else { return }
        let n = r.moved
        var parts = [n == 0 ? nil : "\(n) file\(n == 1 ? "" : "s") moved \(on ? "to the NX 18 folder" : "back to Beam")."]
        if r.waiting > 0 { parts.append("\(r.waiting) still downloading from iCloud: Beam moves \(r.waiting == 1 ? "it" : "them") when \(r.waiting == 1 ? "it arrives" : "they arrive").") }
        if r.failed > 0 { parts.append("\(r.failed) could not be moved and stayed where \(r.failed == 1 ? "it was" : "they were").") }
        if on && !(nx18.map(MyFilesPlace.reachable) ?? false) { parts.append("Connect an NX 18 folder above: until then My files stay in Beam.") }
        let text = parts.compactMap { $0 }.joined(separator: " ")
        myFilesNote = text.isEmpty ? nil : text
    }
    func myFiles(_ g: LibraryGame) -> [URL] {
        guard let f = myFilesFolder(g) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// Every file in My files copied into a Beam install's Documents/Companion with devicectl
    func sendMyFiles(_ g: LibraryGame, to r: InstallRecord) async {
        let files = myFiles(g).filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        do { for f in files { try await DeviceCtl.copyFile(f, of: r.bundleID, on: r.deviceID, to: "Documents/Companion/\(f.lastPathComponent)") } }
        catch { lastError = "Could not send the files to \(r.deviceName): \(error.localizedDescription)" }
    }
}
