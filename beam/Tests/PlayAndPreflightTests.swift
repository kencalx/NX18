// Play on Mac and the checks before a build (B2), with stand-ins: a tiny Mac app made of a shell script, temporary folders
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct PlayTests {
    /// A stand-in Mac app: its executable writes DM_LAUNCHER to `mark` and exits with `code`
    private func fakeApp(code: Int32, mark: URL) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "beam-test-\(UUID().uuidString)/Game.app")
        let macos = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleExecutable": "game", "CFBundleIdentifier": "org.nx18.beam.test-game", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let exe = macos.appending(path: "game")
        try "#!/bin/sh\nprintf '%s' \"$DM_LAUNCHER\" > '\(mark.path)'\nexit \(code)\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return app
    }

    @Test func playStartsWithoutTheSettingsWindow() async throws {
        let mark = FileManager.default.temporaryDirectory.appending(path: "beam-mark-\(UUID().uuidString)")
        let started = LockedValue<Int32?>(nil)
        let end = try await GamePlayer.play(try fakeApp(code: 0, mark: mark)) { started.set($0) }
        #expect(end == .quit && end.message == nil && started.get() != nil)
        #expect(try String(contentsOf: mark, encoding: .utf8) == "0", "DM_LAUNCHER=0: the game starts at once")
    }
    @Test func exitCodes() async throws {
        let mark = FileManager.default.temporaryDirectory.appending(path: "beam-mark-\(UUID().uuidString)")
        #expect(try await GamePlayer.play(try fakeApp(code: 70, mark: mark)) == .gpuLost)
        #expect(try await GamePlayer.play(try fakeApp(code: 134, mark: mark)) == .crashed(134))
        #expect(GameEnd(status: 9, reason: .uncaughtSignal) == .crashed(9) && GameEnd.gpuLost.message != nil)
    }
    @Test func notAnApp() async {
        #expect(GamePlayer.executable(of: URL(fileURLWithPath: "/nonexistent/Game.app")) == nil)
        await #expect(throws: (any Error).self) { try await GamePlayer.play(URL(fileURLWithPath: "/nonexistent/Game.app")) }
    }
}

@Suite struct PreflightTests {
    @Test func gameSizeLeavesBuildFoldersOut() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "beam-game-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appending(path: "build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.appending(path: "0100000000AAA000_build"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: d.appending(path: "game.nsp"))
        try Data(count: 500).write(to: d.appending(path: "update.nsp"))
        try Data(count: 9999).write(to: d.appending(path: "build/RomFS.img"))
        try Data(count: 9999).write(to: d.appending(path: "0100000000AAA000_build/x"))
        #expect(Preflight.gameBytes(d) == 1500)
        #expect(Preflight.gameBytes(d.appending(path: "game.nsp")) == 1000)
        #expect(Preflight.neededBytes(gameBytes: 1_000_000_000) == 12_000_000_000)
        #expect((Preflight.freeBytes(at: d.appending(path: "not/yet/made")) ?? 0) > 0, "asked of the first folder that exists")
    }
    @Test func friendlyErrors() {
        #expect(FriendlyError.text("this Mac's Metal compiler is not the one the shaders were tested with").hasPrefix("This Mac's Xcode"))
        #expect(FriendlyError.text("the current Python (/x) is missing modules: lz4.block").contains("nx18-setup.sh"))
        #expect(FriendlyError.text("something else") == "something else")
    }
    @Test func buildTreeIsFound() async throws {   // BuildPriority reaches the tools under the script
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 5 & sleep 5 & wait"]
        try p.run(); defer { p.terminate() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(BuildPriority.descendants(of: p.processIdentifier).count == 2)
        BuildPriority.set(pid: p.processIdentifier, background: true)   // runs taskpolicy on each; must not throw or hang
        BuildPriority.set(pid: p.processIdentifier, background: false)
    }
}

/// A real Mac build through Beam's runner, only when asked: BEAM_TEST_BUILD_GAME=<game> BEAM_TEST_BUILD_WORK=<build folder> BEAM_TEST_BUILD_OUT=<.app> [BEAM_TEST_NX18=<NX 18 folder>]
@Suite struct LiveBuildTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEAM_TEST_BUILD_GAME"] != nil), .timeLimit(.minutes(60))) func macBuild() async throws {
        let env = ProcessInfo.processInfo.environment
        let checkout = NX18Checkout(folder: URL(fileURLWithPath: env["BEAM_TEST_NX18"] ?? NX18Checkout.defaultFolder.path))
        let py = try #require(checkout.python())
        let req = BuildRequest(source: URL(fileURLWithPath: env["BEAM_TEST_BUILD_GAME"]!), target: .mac, keys: nil, package: nil, titleId: nil,
                               workDir: URL(fileURLWithPath: env["BEAM_TEST_BUILD_WORK"]!), output: URL(fileURLWithPath: env["BEAM_TEST_BUILD_OUT"]!))
        let stages = LockedValue(0), game = LockedValue<GameEvent?>(nil)
        let r = try await ScriptRunner.run(py, req.arguments(script: checkout.script), directory: checkout.folder) { e in
            if case .stage = e { stages.set(stages.get() + 1) }
            if case .game(let g) = e { game.set(g) }
        }
        #expect(r.exit == .done, "\(r.lastError ?? r.stderr)")
        #expect(stages.get() > 0 && game.get()?.build?.count == 16 && game.get()?.out == req.output?.path)
        #expect(GamePlayer.executable(of: req.output!) != nil, "a Mac app Beam can play")
    }
}

@MainActor @Suite struct GameSettingsTests {
    /// A stand-in Mac app with a real launcher.json (Tests/Fixtures, an NX 18 settings list) under a made-up bundle ID: no real game's preferences are touched
    private func fakeApp() throws -> (URL, String) {
        let id = "org.nx18.beam.test.\(UUID().uuidString.prefix(8).lowercased())"
        let app = FileManager.default.temporaryDirectory.appending(path: "beam-test-\(UUID().uuidString)/Game.app")
        let dm = app.appending(path: "Contents/Resources/dm")
        try FileManager.default.createDirectory(at: dm, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/launcher.json")
        try FileManager.default.copyItem(at: fixture, to: dm.appending(path: "launcher.json"))
        let plist: [String: Any] = ["CFBundleExecutable": "game", "CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        return (app, id)
    }

    @Test func choicesGoToTheAppsDomainOnly() throws {
        let (app, id) = try fakeApp()
        let src = try #require(GameSettingsSource(app: app))
        defer {   // the stand-in's domain and its file, so no test leaves a preference file behind
            ScratchPrefs.clean(id)
        }
        #expect(src.bundleID == id)
        let m = src.model()
        let rumble = try #require(m.settings.first { $0.env == "DM_RUMBLE" })
        let other = rumble.def == rumble.onValue ? rumble.offValue : rumble.onValue
        #expect(m.choose(rumble, other))
        m.save()
        #expect(src.defaults.string(forKey: "launcher.DM_RUMBLE") == other, "a choice that differs from the default is kept in the app's domain")
        #expect(ProcessInfo.processInfo.environment["DM_RUMBLE"] == nil, "save never sets Beam's own environment")
        m.reset(); m.save()
        #expect(src.defaults.object(forKey: "launcher.DM_RUMBLE") == nil, "a default is not stored")
    }
    @Test func notAGameApp() {
        #expect(GameSettingsSource(app: URL(fileURLWithPath: "/nonexistent/Game.app")) == nil)
    }
}

@Suite struct HomeInputTests {
    @Test func pressesOnceThenRepeatWhileHeld() {
        var e = PadEdges()
        #expect(e.update([.right], time: 0) == [.right])
        #expect(e.update([.right], time: 0.2) == [], "held: nothing until 0.4 s")
        #expect(e.update([.right], time: 0.41) == [.right])
        #expect(e.update([.right], time: 0.5) == [])
        #expect(e.update([.right], time: 0.54) == [.right], "then every 0.12 s")
        #expect(e.update([], time: 0.6) == [])
        #expect(e.update([.a], time: 0.7) == [.a])
        #expect(e.update([.a], time: 2.0) == [], "a button never repeats")
    }
}
