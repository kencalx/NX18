// The script's events as docs/frontends.md defines them, and the runner's handling of a script (a stand-in shell script: no game, keys or NX 18 build needed)
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct BuildEventTests {
    @Test func identify() throws {   // a line as --identify writes it (Luigi's Mansion 3's shape; the values are made up)
        let line = #"{"ev": "identify", "title_id": "0100000000AAA000", "name": "Game", "platform": "switch1", "kind": "nsp", "versions": [{"version": "v0", "display": "1.0.0", "build": "486F6A3B2D6BCF5C", "registered": false}, {"version": "v327680", "display": "1.4.0", "build": "79E5950FFA85ACF6", "registered": true}], "packs": "v327680", "dlc": [{"title_id": "0100000000AAB001", "version": 65536}], "programs": ["0100000000AAA000"], "profile": "0100000000AAA000", "alias": false, "t": 1.0, "later_field": 3}"#
        guard case .identify(let i)? = BuildEvent.parse(line) else { Issue.record("not an identify event"); return }
        #expect(i.titleId == "0100000000AAA000" && i.packs == "v327680" && i.needsKeys && !i.isSwitch2)
        #expect(i.versions.map(\.number) == [0, 327680] && i.versions[1].registered == true && i.dlc.first?.version == 65536)
    }
    @Test func progressAndStages() {
        #expect(BuildEvent.parse(#"{"ev": "stage", "k": 2, "n": 9, "name": "extract", "step": "v0", "t": 1}"#) == .stage(.init(k: 2, n: 9, name: "extract", step: "v0")))
        guard case .progress(let p)? = BuildEvent.parse(#"{"ev": "progress", "k": 2, "name": "extract", "step": "", "done": 10, "total": 20, "unit": "B", "est": false, "note": "", "frac": 0.5, "eta": null, "elapsed": 3.2, "t": 1}"#) else { Issue.record("no progress"); return }
        #expect(p.frac == 0.5 && p.eta == nil && p.total == 20)
        guard case .stageEnd(let e)? = BuildEvent.parse(#"{"ev": "stage_end", "k": 9, "name": "Pipeline archive", "ok": true, "summary": "failed", "elapsed": 1, "warn": true, "t": 1}"#) else { Issue.record("no stage_end"); return }
        #expect(e.warn == true)
    }
    @Test func gameAndMods() {
        guard case .game(let g)? = BuildEvent.parse(#"{"ev": "game", "title_id": "0400486024DEC000", "name": "Z", "version": "1.0", "bundle_id": "b", "out": null, "icon": null, "build": "E0F3CCFAF50065AE", "t": 1}"#) else { Issue.record("no game"); return }
        #expect(g.build == "E0F3CCFAF50065AE" && g.out == nil)
        guard case .mods(let m)? = BuildEvent.parse(#"{"ev": "mods", "title_id": "X", "build": null, "folder": "/m", "report": null, "cheats": false, "offered": [{"role": "fps", "mod": "60 FPS", "runs": 3, "left_out": []}], "left_out": [{"path": "romfs", "why": "a RomFS mod"}], "t": 1}"#) else { Issue.record("no mods"); return }
        #expect(m.offered.first?.role == "fps" && m.leftOut.first?.why == "a RomFS mod")
    }
    @Test func sayAndUnknown() {
        guard case .say(let s)? = BuildEvent.parse(#"{"ev": "say", "msg": "[RED] [10:37:15] no such file", "t": 1}"#) else { Issue.record("no say"); return }
        #expect(s.isError && s.text == "no such file")
        guard case .say(let s2)? = BuildEvent.parse(#"{"ev": "say", "msg": "[10:37:15] [RED] keys too old", "t": 1}"#) else { Issue.record("no say"); return }
        #expect(s2.text == "keys too old")
        #expect(BuildEvent.parse(#"{"ev": "something_new", "x": 1}"#) == .unknown("something_new"), "an event this Beam does not know is ignored")
        #expect(BuildEvent.parse(#"{"ev": "stage", "k": "not a number"}"#) == .unknown("stage"), "a known event it cannot read is not an error")
        #expect(BuildEvent.parse("Traceback (most recent call last):") == nil)
        #expect(ScriptExit(code: 143) == .stopped && ScriptExit(code: 2) == .badArguments)
    }
}

@Suite struct ScriptRunnerTests {
    private func script(_ body: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "beam-test-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body).write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    @Test func eventsInOrderAndExit() async throws {
        let s = try script(#"""
        echo '{"ev": "stage", "k": 1, "n": 1, "name": "one"}'
        echo 'not an event'
        echo '{"ev": "say", "msg": "[RED] it broke"}'
        echo 'traceback here' >&2
        exit 1
        """#)
        let seen = LockedValue<[BuildEvent]>([])
        let r = try await ScriptRunner.run(s, []) { e in seen.set(seen.get() + [e]) }
        #expect(r.exit == .failed && r.lastError == "it broke" && r.stderr.contains("traceback here"))
        #expect(seen.get().count == 2)
    }
    @Test func largeOutputDoesNotStall() async throws {   // more than a pipe holds (64 KB) on both streams while the script runs
        let s = try script(#"""
        i=0; while [ $i -lt 3000 ]; do echo '{"ev": "say", "msg": "line padded to make the output larger than one pipe buffer holds"}'; echo 'err line padded the same way to fill stderr' >&2; i=$((i+1)); done
        """#)
        let n = LockedValue(0)
        let r = try await ScriptRunner.run(s, []) { _ in n.set(n.get() + 1) }
        #expect(r.exit == .done && n.get() == 3000)
    }
    @Test func cancelSendsSIGTERM() async throws {
        let s = try script(#"""
        trap 'echo "{\"ev\": \"say\", \"msg\": \"stopping\"}"; exit 143' TERM
        echo '{"ev": "stage", "k": 1, "n": 1, "name": "long"}'
        while true; do sleep 0.1; done
        """#)
        let started = LockedValue(false), stopping = LockedValue(false)
        let t = Task { try await ScriptRunner.run(s, []) { e in
            if case .stage = e { started.set(true) }
            if case .say(let m) = e, m.msg == "stopping" { stopping.set(true) }
        } }
        while !started.get() { try await Task.sleep(for: .milliseconds(20)) }
        t.cancel()
        let r = try await t.value
        #expect(r.exit == .stopped && stopping.get())
    }
    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) { try await ScriptRunner.run(URL(fileURLWithPath: "/nonexistent/beam-python"), []) { _ in } }
    }
    @Test func buildArguments() {
        let r = BuildRequest(source: URL(fileURLWithPath: "/g/Zelda/z.nup"), target: .mac, keys: nil, package: "v131072", titleId: nil,
                             workDir: BuildRequest.defaultWorkDir(source: URL(fileURLWithPath: "/g/Zelda/z.nup"), titleId: "X", buildSpace: nil))
        let a = r.arguments(script: URL(fileURLWithPath: "/nx18/scripts/build_ipa_from_nsp.py"))
        #expect(a == ["/nx18/scripts/build_ipa_from_nsp.py", "/g/Zelda/z.nup", "--progress", "json", "--work-dir", "/g/Zelda/build", "--platform", "mac-app", "--package", "v131072"])
        #expect(!a.contains("--allow-other-metal"), "never passed by Beam")
        #expect(BuildRequest.defaultWorkDir(source: URL(fileURLWithPath: "/g/Zelda/z.nup"), titleId: "X", buildSpace: URL(fileURLWithPath: "/space")).path == "/space/X")
    }
}

/// Against a real NX 18 folder and game, only when asked: BEAM_TEST_NX18=<NX 18 folder> BEAM_TEST_GAME=<a folder, .nup or .nx> (identify reads the game and writes nothing beside it)
@Suite struct LiveIdentifyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEAM_TEST_GAME"] != nil)) func identifyRealGame() async throws {
        let env = ProcessInfo.processInfo.environment
        let checkout = NX18Checkout(folder: URL(fileURLWithPath: env["BEAM_TEST_NX18"] ?? NX18Checkout.defaultFolder.path))
        let py = try #require(checkout.python(checkModules: false))
        let found = LockedValue<IdentifyEvent?>(nil)
        let r = try await ScriptRunner.run(py, Identify.arguments(script: checkout.script, source: URL(fileURLWithPath: env["BEAM_TEST_GAME"]!), keys: nil)) { e in
            if case .identify(let i) = e { found.set(i) }
        }
        #expect(r.exit == .done, "\(r.lastError ?? r.stderr)")
        let i = try #require(found.get())
        #expect(!i.versions.isEmpty && i.titleId.count == 16)
    }
}
