// Rebuild only what changed (Rebuilds.swift): which built games NX 18 changed. Fake build records and fake NX 18 checkouts (git repositories in temporary folders);
// never the player's checkout or library
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct RebuildRuleTests {
    let a = "0100AAAA00000000", b = "0100BBBB00000000"

    @Test func whatGoesIntoAnApp() {
        let mine: Set<String> = [a]
        for p in ["docs/beam.md", "beam/Sources/Model/Library.swift", ".github/workflows/fuzz.yml", "README.md", "AGENTS.md", ".gitignore", "LICENSE",
                  "dm/ios/tests/test_pack_ipa.py", "dm/gfx/tests/t_pass.c", "dm/tools/tests/fixtures/x.bin", "scripts/release/nx18-setup.sh", "dm/games/\(b)/game.tsv"] {
            #expect(!RebuildRule.affects(p, titles: mine), "\(p) is not in this game's app")
        }
        for p in ["dm/host/main.c", "dm/gfx/nvn/dmsh_chain.h", "dm/ios/Sources/Launcher.swift", "dm/mac/launcher.c", "scripts/build_ipa_from_nsp.py",
                  "dm/games/game.py", "dm/games/settings.tsv", "dm/games/\(a)/game.tsv", "dm/games/\(a.lowercased())/patches.py", "pyproject.toml", "dm/third_party/x/y.cs"] {
            #expect(RebuildRule.affects(p, titles: mine), "\(p) goes into this game's app")
        }
    }

    @Test func theRule() {
        let built = BuiltFrom(commit: "c1", changes: nil, chain: "aaa")
        func r(_ now: BuiltFrom, _ changed: [String]?, from: BuiltFrom? = BuiltFrom(commit: "c1", changes: nil, chain: "aaa")) -> RebuildRule.Reason? {
            RebuildRule.reason(built: from, now: now, changed: changed, titles: [a])
        }
        #expect(r(built, nil) == nil, "the same checkout: current")
        #expect(r(BuiltFrom(commit: "c2", changes: nil, chain: "bbb"), []) == .shaders, "another shader chain: every game")
        #expect(r(BuiltFrom(commit: "c2", changes: nil, chain: "aaa"), ["docs/x.md", "dm/games/\(b)/game.tsv"]) == nil, "only docs and another game's profile")
        #expect(r(BuiltFrom(commit: "c2", changes: nil, chain: "aaa"), ["dm/games/\(a)/game.tsv"]) == .nx18, "its own profile")
        #expect(r(BuiltFrom(commit: "c2", changes: nil, chain: "aaa"), ["dm/host/svc.c"]) == .nx18, "the host, in every app")
        #expect(r(BuiltFrom(commit: "c1", changes: "d", chain: "aaa"), ["dm/host/svc.c"]) == .nx18, "an uncommitted change since")
        #expect(r(BuiltFrom(commit: "c2", changes: nil, chain: "aaa"), nil) == .unknown, "git cannot say: rebuild")
        #expect(r(built, nil, from: nil) == .unknown, "no record of its NX 18: rebuild")
        #expect(r(BuiltFrom(commit: nil, changes: nil, chain: "aaa"), nil) == .unknown, "the checkout lost git: rebuild")
        #expect(r(BuiltFrom(commit: nil, changes: nil, chain: "aaa"), nil, from: BuiltFrom(commit: nil, changes: nil, chain: "aaa")) == nil, "no git either time: the chain decides")
    }

    @Test func titlesAndGroups() {
        let i = IdentifyEvent(titleId: "0100aaaa00000000", name: "A", platform: "switch1", kind: "nup", versions: [], packs: nil, dlc: [], programs: ["0100AAAA00000001"], profile: "0100CCCC00000000", alias: true)
        #expect(RebuildRule.titles(of: i) == ["0100AAAA00000000", "0100AAAA00000001", "0100CCCC00000000"])
        #expect(RebuildRule.titles(of: nil).isEmpty)
        #expect(RebuildRule.groups(Array(1...7)) == [[1, 2, 3], [4, 5, 6], [7]], "three at a time")
        #expect(RebuildRule.groups([Int]()).isEmpty)
    }

    @Test func tonightIsTheNext1AM() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let evening = cal.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 22))!, late = cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 0, minute: 30))!
        #expect(RebuildRule.tonight(after: evening, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 1)))
        #expect(RebuildRule.tonight(after: late, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 1)))
    }
}

/// A fake NX 18 checkout: a git repository in a temporary folder with a chain header, two game profiles, host code and docs
struct FakeCheckout {
    let folder = FileManager.default.temporaryDirectory.appending(path: "beam-rebuild-\(UUID().uuidString)", directoryHint: .isDirectory)
    func git(_ args: String...) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", folder.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"] + args
        p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    func write(_ path: String, _ s: String) {
        let u = folder.appending(path: path)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }
    func commit(_ m: String) { git("add", "-A"); git("commit", "-q", "-m", m) }
    init(a: String, b: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main")
        write("dm/gfx/nvn/dmsh_chain.h", "// generated\n#define DMSH_CHAIN \"aaa111\"\n")
        write("dm/games/\(a)/game.tsv", "name\tA\n"); write("dm/games/\(b)/game.tsv", "name\tB\n")
        write("dm/host/main.c", "int main;\n"); write("docs/beam.md", "Beam\n")
        commit("first")
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@Suite(.serialized) struct RebuildCheckoutTests {
    let a = "0100AAAA00000000", b = "0100BBBB00000000"
    func check(_ c: FakeCheckout, _ from: BuiltFrom?) -> (a: RebuildRule.Reason?, b: RebuildRule.Reason?) {
        let ia = UUID(), ib = UUID()
        let r = RebuildRule.check([.init(id: ia, from: from, titles: [a]), .init(id: ib, from: from, titles: [b])], folder: c.folder)
        return (r[ia], r[ib])
    }

    @Test func aCheckoutMovingOn() {
        let c = FakeCheckout(a: a, b: b); defer { c.remove() }
        let built = NX18Git.stamp(of: c.folder)
        #expect(built.commit?.count == 40 && built.changes == nil && built.chain == "aaa111")
        #expect(check(c, built) == (nil, nil), "nothing changed")

        c.write("docs/beam.md", "Beam, again\n"); c.write("dm/games/\(b)/notes.md", "x\n"); c.commit("docs")
        #expect(check(c, built) == (nil, .nx18), "docs leave every game; B's own folder changed")

        c.write("dm/games/\(a)/game.tsv", "name\tA2\n"); c.commit("A's profile")
        #expect(check(c, built) == (.nx18, .nx18))
        let afterA = NX18Git.stamp(of: c.folder)
        #expect(check(c, afterA) == (nil, nil), "rebuilt: current")

        c.write("dm/host/main.c", "int main2;\n")   // not committed
        let dirty = NX18Git.stamp(of: c.folder)
        #expect(dirty.changes != nil && dirty.commit == afterA.commit)
        #expect(check(c, afterA) == (.nx18, .nx18), "an uncommitted host change goes into every app")
        #expect(check(c, dirty) == (nil, nil), "built with that change: current")
        #expect(dirty.dirty == ["dm/host/main.c"], "the build keeps which files its uncommitted changes were in")

        c.git("checkout", "-q", "--", "dm/host/main.c")   // the experiment reverted: the checkout is the commit again, the app still has the change
        #expect(check(c, dirty) == (.nx18, .nx18), "built with a change that was then reverted: not current")
        #expect(check(c, afterA) == (nil, nil), "built from the commit alone: current again")
        var legacy = dirty; legacy.dirty = nil
        #expect(check(c, legacy) == (.nx18, .nx18), "a record with the changes' digest but not their files: rebuild")

        c.write("docs/beam.md", "Beam, an edit\n"); c.write("dm/games/\(b)/game.tsv", "name\tB2\n")   // docs and B's profile, not committed
        let docs = NX18Git.stamp(of: c.folder)
        c.git("checkout", "-q", "--", "docs/beam.md", "dm/games/\(b)/game.tsv")
        #expect(check(c, docs) == (nil, .nx18), "a reverted docs edit leaves every game; a reverted edit of B's profile only B")

        c.write("dm/host/main.c", "int main2;\n")

        c.git("checkout", "-q", "--", "dm/host/main.c")
        c.write("dm/gfx/nvn/dmsh_chain.h", "// generated\n#define DMSH_CHAIN \"bbb222\"\n"); c.commit("chain")
        #expect(check(c, afterA) == (.shaders, .shaders), "a new shader chain: every game")

        #expect(check(c, BuiltFrom(commit: String(repeating: "d", count: 40), changes: nil, chain: "bbb222")) == (.unknown, .unknown), "a commit this checkout does not have")
        #expect(check(c, nil) == (.unknown, .unknown), "no record")
    }

    @Test func aBuildFromBeforeTheRecord() {
        let c = FakeCheckout(a: a, b: b); defer { c.remove() }
        let first = NX18Git.stamp(of: c.folder)
        #expect(NX18Git.stamp(at: Date().addingTimeInterval(-86_400 * 400), of: c.folder) == nil, "before the reflog: unknown")
        let guess = NX18Git.stamp(at: Date().addingTimeInterval(1), of: c.folder)
        #expect(guess?.commit == first.commit && guess?.chain == "aaa111" && guess?.guessed == true)
    }

    @Test func noCheckout() {
        let none = FileManager.default.temporaryDirectory.appending(path: "beam-rebuild-none-\(UUID().uuidString)")
        let s = NX18Git.stamp(of: none)
        #expect(s.commit == nil && s.chain == nil)
        #expect(NX18Git.changedPaths(none, since: "HEAD") == nil)
    }
}

/// One rebuild check at a time (LibraryRebuilds.swift): a forced check that comes while one runs makes that one go round again; it is not dropped
@Suite struct RebuildCheckGateTests {
    @Test func aForcedCheckDuringOneRunsAfterIt() {
        var g = RebuildCheckGate()
        var steps: [Bool] = []
        steps.append(g.begin(force: false))   // nothing running: this caller checks
        steps.append(g.begin(force: true))    // one running: the forced caller does not start a second
        steps.append(g.next())                // the forced check is not dropped: the running check goes round once more
        steps.append(g.next())                // then it is over
        #expect(steps == [true, false, true, false] && !g.running)
        steps = [g.begin(force: true), g.begin(force: false), g.next()]   // Beam coming to the front during a check asks for no second pass
        #expect(steps == [true, false, false])
        steps = [g.begin(force: true), g.begin(force: true), g.begin(force: true), g.next(), g.next()]   // two forced callers during one pass: one more covers both
        #expect(steps == [true, false, false, true, false])
    }
}
