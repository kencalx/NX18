// iPhone and iPad installs (B3) without a device: devicectl's JSON (synthetic, in the shape devicectl 699 writes), Xcode's teams, the profile, bundle IDs, slots
import Foundation
import Testing
@testable import NX_18_Beam

@Suite struct DeviceParsingTests {
    @Test func devices() {
        let result: [String: Any] = ["devices": [
            ["identifier": "AAAA-1", "deviceProperties": ["name": "Phone", "osVersionNumber": "27.3", "developerModeStatus": "enabled"],
             "hardwareProperties": ["platform": "iOS", "reality": "physical", "marketingName": "iPhone 18 Pro Max", "udid": "00008150-X"],
             "connectionProperties": ["pairingState": "paired", "tunnelState": "connected"]],
            ["identifier": "BBBB-2", "deviceProperties": ["name": "Sim"], "hardwareProperties": ["platform": "iOS", "reality": "simulated", "marketingName": "iPhone Duo"],
             "connectionProperties": ["pairingState": "paired", "tunnelState": "disconnected"]],
            ["identifier": "CCCC-3", "deviceProperties": ["name": "Watch"], "hardwareProperties": ["platform": "watchOS", "reality": "physical"], "connectionProperties": [:]],
        ]]
        let d = DeviceCtl.parseDevices(result)
        #expect(d.map(\.id) == ["AAAA-1", "BBBB-2"], "iOS only (iPadOS reports iOS)")
        #expect(d[0].connected && d[0].paired && d[0].developerMode == true && d[0].physical && d[0].udid == "00008150-X")
        #expect(!d[1].physical && !d[1].connected)
    }
    @Test func appsAndTitleIDs() {
        let a = DeviceCtl.parseApps(["apps": [
            ["bundleIdentifier": "org.nxnative.t1a2b3c4d.0400486024dec000", "name": "Ocarina", "builtByDeveloper": true],
            ["bundleIdentifier": "org.nxnative.ABCDE12345.0100dca0064a6000", "builtByDeveloper": true],
            ["bundleIdentifier": "com.example.other", "builtByDeveloper": false],
        ]])
        #expect(a.map(\.titleID) == ["0400486024DEC000", "0100DCA0064A6000", nil])
        #expect(Slots.used(onDevice: a).count == 2)
    }
}

@Suite struct SigningTests {
    let paid = XcodeTeam(id: "ABCDE12345", name: "A Person", free: false)
    let free = XcodeTeam(id: "FREE123456", name: "A Person", free: true)

    @Test func teamsPaidFirst() {
        let t = XcodeTeam.parse(["acct-1": [["teamID": "FREE123456", "teamName": "Me", "isFreeProvisioningTeam": true]],
                                 "acct-2": [["teamID": "ABCDE12345", "teamName": "Me Inc", "isFreeProvisioningTeam": false]]])
        #expect(t.map(\.free) == [false, true] && t[1].label == "Me (Personal Team)")
    }
    @Test func profile() throws {
        let exp = Date(timeIntervalSince1970: 1_800_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": exp, "Entitlements": ["com.apple.developer.kernel.increased-memory-limit": true]], format: .xml, options: 0)
        #expect(ProvisioningInfo.parse(plist) == ProvisioningInfo(expires: exp, increasedMemoryLimit: true))
    }
    @Test func bundleIDs() {
        let onDevice = [DeviceApp(bundleID: "org.nxnative.ABCDE12345.0400486024dec000", byDeveloper: true)]
        #expect(XcodeSigning.bundleID(titleID: "0400486024DEC000", team: paid, onDevice: onDevice) == onDevice[0].bundleID, "an NX Play install is replaced, not doubled")
        let new = XcodeSigning.bundleID(titleID: "0100DCA0064A6000", team: paid, onDevice: onDevice)
        #expect(new.hasPrefix("org.nxnative.t") && new.hasSuffix(".0100dca0064a6000") && !new.lowercased().contains("abcde12345"), "a new ID never carries the team ID")
        #expect(XcodeSigning.bundleID(titleID: "0100DCA0064A6000", team: paid, onDevice: []) == new, "the same every time")
    }
    @Test func messages() {
        #expect(XcodeSigning.signingMessage("error: No profiles for 'x' were found in team ABCDE12345", teamID: "ABCDE12345").contains("(your team)"))
        #expect(!XcodeSigning.signingMessage("error: team ABCDE12345 failed", teamID: "ABCDE12345").contains("ABCDE12345"))
        #expect(XcodeSigning.signingMessage("You have reached the maximum App ID limit").contains("10"))
    }
    @Test func xcodeArguments() {
        var r = BuildRequest(source: URL(fileURLWithPath: "/g/Z/z.nup"), target: .iPhone, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/space/X"))
        r.xcode = .init(bundleID: "org.nxnative.t1.x", teamID: "ABCDE12345", workspace: URL(fileURLWithPath: "/space/X/Beam.xcworkspace"))
        let a = r.arguments(script: URL(fileURLWithPath: "/nx18/s.py"))
        #expect(a.contains("--prepare-xcode") && a.contains("--keep-extracted") && a.contains("/space/X/Beam.xcworkspace"))
        #expect(!a.joined(separator: " ").contains("NxNative.xcworkspace"), "never the workspace beside the player's game folder")
        let b = XcodeSigning.buildArguments(project: URL(fileURLWithPath: "/p.xcodeproj"), scheme: "Z (X)", device: "UDID", team: paid, derived: URL(fileURLWithPath: "/d"))
        #expect(b.contains("-allowProvisioningUpdates") && b.contains("DEVELOPMENT_TEAM=ABCDE12345") && b.contains("id=UDID"))
        #expect(!b.contains { $0.hasPrefix("DM_PROFILE_SEED=") }, "no Profile: no seed setting")
        let seeded = XcodeSigning.buildArguments(project: URL(fileURLWithPath: "/p.xcodeproj"), scheme: "Z (X)", device: "UDID", team: paid, derived: URL(fileURLWithPath: "/d"),
                                                 profileSeed: URL(fileURLWithPath: "/t/s/NX18ProfileSeed"))
        #expect(seeded.contains("DM_PROFILE_SEED=/t/s/NX18ProfileSeed") && seeded.last == "build", "the Profile seed, a build setting the resource phase reads (stage_resources.sh)")
    }
    @Test func ipaRequestCarriesTheSeed() {   // Route B: the IPA for other install tools carries the Profile too (build_ipa.sh DM_PROFILE_SEED through --profile-seed)
        let seed = URL(fileURLWithPath: "/t/beam-seed-1/NX18ProfileSeed")
        var r = BuildRequest(source: URL(fileURLWithPath: "/g/Z/z.nup"), target: .iPhone, keys: nil, package: nil, titleId: nil, workDir: URL(fileURLWithPath: "/space/X"))
        #expect(!r.arguments(script: URL(fileURLWithPath: "/nx18/s.py")).contains("--profile-seed"), "no Profile: no seed")
        r.profileSeed = seed
        let a = r.arguments(script: URL(fileURLWithPath: "/nx18/s.py"))
        #expect(a.firstIndex(of: "--profile-seed").map { a[$0 + 1] } == seed.path)
        var x = r; x.xcode = .init(bundleID: "org.nxnative.t1.x", teamID: "ABCDE12345", workspace: URL(fileURLWithPath: "/space/X/Beam.xcworkspace"))
        #expect(!x.arguments(script: URL(fileURLWithPath: "/nx18/s.py")).contains("--profile-seed"), "the Xcode route takes it at xcodebuild (DM_PROFILE_SEED)")
        var m = r; m.target = .mac
        #expect(!m.arguments(script: URL(fileURLWithPath: "/nx18/s.py")).contains("--profile-seed"), "a Mac app reads the Mac's Profile itself")
    }
}

@Suite struct SlotTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func rec(_ b: String, played: TimeInterval, game: UUID = UUID()) -> InstallRecord {
        InstallRecord(deviceID: "D", deviceName: "Phone", gameID: game, bundleID: b, titleID: "X", installed: now.addingTimeInterval(-10 * 86_400),
                      expires: now.addingTimeInterval(3 * 86_400), freeTeam: true, increasedMemoryLimit: false, lastPlayed: now.addingTimeInterval(played))
    }
    func apps(_ ids: [String]) -> [DeviceApp] { ids.map { DeviceApp(bundleID: $0, byDeveloper: true) } }

    @Test func plans() {
        let recs = [rec("a", played: -100), rec("b", played: -5000), rec("c", played: -10)]
        #expect(Slots.plan(installing: "n", freeTeam: false, onDevice: apps(["a", "b", "c"]), records: recs) == .fits, "a paid team has no slot limit")
        #expect(Slots.plan(installing: "n", freeTeam: true, onDevice: apps(["a", "b"]), records: recs) == .fits)
        #expect(Slots.plan(installing: "a", freeTeam: true, onDevice: apps(["a", "b", "c"]), records: recs) == .fits, "a reinstall takes its own slot")
        #expect(Slots.plan(installing: "n", freeTeam: true, onDevice: apps(["a", "b", "c"]), records: recs) == .replaces(bundleID: "b"), "the one played least recently")
        #expect(Slots.plan(installing: "n", freeTeam: true, onDevice: apps(["x", "y", "z"]), records: recs) == .full, "never another tool's app")
    }
    @Test func expiry() {
        let r = rec("a", played: 0)
        #expect(r.daysLeft(now: now) == 3 && !r.renewDue(now: now) && r.renewDue(now: now.addingTimeInterval(86_400 + 60)) && r.expired(now: now.addingTimeInterval(4 * 86_400)))
    }
    @Test func weeklyAppIDs() {
        var old = rec("old", played: 0); old.installed = now.addingTimeInterval(-8 * 86_400)
        var new = rec("new", played: 0); new.installed = now.addingTimeInterval(-86_400)
        #expect(Slots.appIDsThisWeek([old, new, new], now: now) == 1)
    }
}

/// The paired devices on this Mac, only when asked (BEAM_TEST_DEVICES=1): read only, nothing installed
@Suite struct LiveDeviceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEAM_TEST_DEVICES"] != nil)) func listDevices() async throws {
        let d = try await DeviceCtl.devices()
        let allPhysical = d.allSatisfy { $0.physical }
        #expect(allPhysical)
        print("devices: \(d.count), connected: \(d.filter(\.connected).count)")
    }
}

/// The memory entitlements are mandatory: every build keeps the request, and an install needs a signature and profile with both
@Suite struct MemoryEntitlementTests {
    @Test func buildsNeverDropTheRequest() async throws {
        #expect(ScriptRunner.scriptEnvironment(["DM_ENTITLEMENTS": "", "PATH": "/usr/bin"]) == ["PATH": "/usr/bin"])
        let s = FileManager.default.temporaryDirectory.appending(path: "beam-ent-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho \"{\\\"ev\\\": \\\"say\\\", \\\"msg\\\": \\\"${DM_ENTITLEMENTS-unset}\\\"}\"\n".write(to: s, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path)
        let msg = LockedValue<String?>(nil)
        _ = try await ScriptRunner.run(s, [], environment: ["DM_ENTITLEMENTS": "", "PATH": "/usr/bin:/bin"]) { e in if case .say(let m) = e { msg.set(m.msg) } }
        #expect(msg.get() == "unset", "the build script never sees DM_ENTITLEMENTS")
    }
    @Test func signatureIsRead() async throws {   // a real ad-hoc signature, with and without the entitlements
        let dir = FileManager.default.temporaryDirectory.appending(path: "beam-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let both = try PropertyListSerialization.data(fromPropertyList: [MemoryEntitlements.iml: true, MemoryEntitlements.eva: true], format: .xml, options: 0)
        let one = try PropertyListSerialization.data(fromPropertyList: [MemoryEntitlements.iml: true], format: .xml, options: 0)
        for (name, ent) in [("both", both), ("one", one)] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: dir.appending(path: name))
            try ent.write(to: dir.appending(path: "\(name).plist"))
            let r = try await Tool.run("/usr/bin/codesign", ["-f", "-s", "-", "--entitlements", dir.appending(path: "\(name).plist").path, dir.appending(path: name).path])
            #expect(r.code == 0, "\(r.err)")
        }
        #expect(await MemoryEntitlements.signed(dir.appending(path: "both")))
        #expect(!(await MemoryEntitlements.signed(dir.appending(path: "one"))), "Extended Virtual Addressing is needed too")
        #expect(!(await MemoryEntitlements.signed(URL(fileURLWithPath: "/nonexistent"))))
    }
    @Test func profileGrantsBoth() throws {
        let p = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": [MemoryEntitlements.iml: true, MemoryEntitlements.eva: true]], format: .xml, options: 0)
        #expect(ProvisioningInfo.parse(p)?.grantsMemory == true)
        let q = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": [MemoryEntitlements.iml: true]], format: .xml, options: 0)
        #expect(ProvisioningInfo.parse(q)?.grantsMemory == false)
    }
}
