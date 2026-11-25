// The library's mods, sources and manual (Mods.swift has the checks): what the game page and Settings call
import Foundation

extension Library {
    /// Beam's own pieces of a build: its mods folder (made, so --mods always names Beam's and never the player's mods folder beside the game) and the manual
    func dress(_ req: inout BuildRequest, _ g: LibraryGame, _ ident: IdentifyEvent) {
        let f = ModStore.folder(titleID: ident.titleId)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        req.mods = f
        if let m = g.manual, FileManager.default.fileExists(atPath: m.path) { req.manual = m }
        let have = { (u: URL?) in u.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        req.art = have(g.art); req.logo = have(g.logo); req.icon = have(g.icon)
    }

    func saveSources() {
        try? FileManager.default.createDirectory(at: Library.defaultFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(sources).write(to: Library.defaultFolder.appending(path: "sources.json"), options: .atomic)
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

    /// Gets a source's mod for a game: downloaded from its author, checked, kept. The next build carries it
    func getMod(_ o: Offer, for g: LibraryGame) async {
        guard let ident = g.identity, let kind = o.entry.role else { return }
        let work = FileManager.default.temporaryDirectory.appending(path: "beam-mod-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
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
        let dst = Library.defaultFolder.appending(path: "Backups/\(titleID.uppercased())/\(stamp)/save")
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

    /// My files: the player's own guides and maps for a game, in Beam's folder (never packed into an IPA, which can be shared)
    func myFilesFolder(_ g: LibraryGame) -> URL? {
        g.identity.map { Library.defaultFolder.appending(path: "My Files/\($0.titleId.uppercased())", directoryHint: .isDirectory) }
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
