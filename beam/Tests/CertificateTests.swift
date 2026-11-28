// The certificate route without the player's certificates: identities and profiles parsed from synthetic output, every profile check, and a real re-sign
// of a stand-in app with a throwaway self-signed certificate in a temporary keychain (deleted after; the login keychain and the search list are not touched)
import CryptoKit
import Foundation
import Security
import Testing
@testable import NX_18_Beam

@Suite struct CertificateTests {
    let certDER = Data("a certificate".utf8)
    var certSHA1: String { Insecure.SHA1.hash(data: certDER).map { String(format: "%02X", $0) }.joined() }

    func profile(appID: String = "ABCDE12345.*", devices: [String] = ["00008150-AAAA"], all: Bool = false, memory: Bool = true, expires: Date = .now.addingTimeInterval(86_400 * 300)) throws -> Profile {
        var ent: [String: Any] = ["application-identifier": appID, "get-task-allow": true]
        if memory { ent[MemoryEntitlements.iml] = true; ent[MemoryEntitlements.eva] = true }
        var p: [String: Any] = ["UUID": "P-1", "Name": "Games", "TeamIdentifier": ["ABCDE12345"], "Entitlements": ent, "ExpirationDate": expires,
                                "DeveloperCertificates": [certDER], "ProvisionedDevices": devices]
        if all { p["ProvisionsAllDevices"] = true }
        return try #require(Profile.parse(try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0), file: URL(fileURLWithPath: "/p")))
    }

    @Test func identities() {
        let out = """
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: A Person (ABCDE12345)"
             1 identities found

          Valid identities only
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: A Person (ABCDE12345)"
        """
        let i = SigningIdentity.parse(out)
        #expect(i.count == 1 && i[0].shownName == "Apple Development: A Person", "each once, and the team ID never shown")
    }
    @Test func profileChecks() throws {
        let me = SigningIdentity(id: certSHA1, name: "Apple Development: A Person (ABCDE12345)")
        let p = try profile()
        #expect(p.memory && p.wildcard && p.problem(identity: me, deviceUDID: "00008150-aaaa", bundleID: "org.x.game") == nil)
        #expect(p.problem(identity: SigningIdentity(id: String(repeating: "0", count: 40), name: "Other"), deviceUDID: "00008150-AAAA", bundleID: "x")?.contains("not made for the certificate") == true)
        #expect(p.problem(identity: me, deviceUDID: "00008150-BBBB", bundleID: "x")?.contains("does not list this device") == true)
        #expect(try profile(all: true).problem(identity: me, deviceUDID: "00008150-BBBB", bundleID: "x") == nil)
        #expect(try profile(memory: false).problem(identity: me, deviceUDID: "00008150-AAAA", bundleID: "x")?.contains("Increased Memory Limit") == true, "mandatory")
        #expect(try profile(expires: .now.addingTimeInterval(-60)).problem(identity: me, deviceUDID: "00008150-AAAA", bundleID: "x")?.contains("expired") == true)
        let explicit = try profile(appID: "ABCDE12345.org.me.zelda")
        #expect(explicit.bundleID(forGame: "org.nxnative.t1.x") == "org.me.zelda" && explicit.problem(identity: me, deviceUDID: "00008150-AAAA", bundleID: "org.me.zelda") == nil)
        #expect(p.signingEntitlements(bundleID: "org.x.game")["application-identifier"] as? String == "ABCDE12345.org.x.game")
    }

    /// A real re-sign: a throwaway self-signed code-signing certificate (made here, password made here) in a temporary keychain, a stand-in app
    @Test func resignStandInApp() async throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "beam-cert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let kc = d.appending(path: "t.keychain-db")
        defer { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/security"), arguments: ["delete-keychain", kc.path]).waitUntilExit(); try? FileManager.default.removeItem(at: d) }
        try "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Beam Test Signing\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:false\n"
            .write(to: d.appending(path: "c.cnf"), atomically: true, encoding: .utf8)
        func run(_ exe: String, _ a: [String]) async throws { let r = try await Tool.run(exe, a); #expect(r.code == 0, "\(exe) \(a.first ?? ""): \(r.err)") }
        try await run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", d.appending(path: "k.pem").path, "-out", d.appending(path: "c.pem").path, "-days", "2", "-config", d.appending(path: "c.cnf").path])
        try await run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", d.appending(path: "k.pem").path, "-in", d.appending(path: "c.pem").path, "-out", d.appending(path: "t.p12").path, "-passout", "pass:beamtest"])
        let before = try await Tool.run("/usr/bin/security", ["list-keychains", "-d", "user"]).out
        // Beam's own steps (BeamKeychain.ready, KeychainFile): made and unlocked in process, the partition list's password on security's stdin; none on a command line
        #expect(try BeamKeychain.ready(at: kc, password: "kcpw") == kc)
        #expect(try await Tool.run("/usr/bin/security", ["list-keychains", "-d", "user"]).out == before, "making it leaves the user's search list as it was")
        _ = try await Tool.run("/usr/bin/security", ["lock-keychain", kc.path])
        #expect(throws: KeychainFile.Failure.self) { try KeychainFile.unlock(kc, password: "not it") }
        _ = try BeamKeychain.ready(at: kc, password: "kcpw")   // there: unlocked only
        try await run("/usr/bin/security", ["import", d.appending(path: "t.p12").path, "-k", kc.path, "-f", "pkcs12", "-P", "beamtest", "-x", "-T", "/usr/bin/codesign"])
        await #expect(throws: KeychainFile.Failure.self) { try await KeychainFile.allowCodesign(kc, password: "not it") }   // security reads the password from stdin
        try await KeychainFile.allowCodesign(kc, password: "kcpw")
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Sources/Model/CertificateSigning.swift"), encoding: .utf8)
        #expect(!src.contains(#""-p", pw"#) && !src.contains(#""-k", try password()"#), "no password on a security command line")
        let ids = SigningIdentity.parse(try await Tool.run("/usr/bin/security", ["find-identity", "-p", "codesigning", kc.path]).out)
        let identity = try #require(ids.first)

        let app = d.appending(path: "Payload/Game.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appending(path: "game"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "game", "CFBundleIdentifier": "org.nxnative.old", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        var p = try profile()
        p.file = d.appending(path: "x.mobileprovision"); try Data("profile".utf8).write(to: p.file)
        try await Resigner.sign(app: app, identity: identity, profile: p, bundleID: "org.nxnative.t1.game", keychain: kc)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appending(path: "Info.plist")), format: nil) as? [String: Any]
        #expect(info?["CFBundleIdentifier"] as? String == "org.nxnative.t1.game")
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "embedded.mobileprovision").path))
        #expect(await MemoryEntitlements.signed(app), "both memory entitlements in the new signature")
        let after = try await Tool.run("/usr/bin/security", ["list-keychains", "-d", "user"]).out
        #expect(after == before, "the user's keychain search list is unchanged")
    }
}

/// Making Beam's keychain puts the user's search list back also when the making fails part way (SecKeychainCreate adds the new keychain to the list first)
@Suite struct KeychainFileTests {
    /// The Security calls, stood in for: `n` keychains in the list; making one adds it, then reports `result`
    enum Fake: LegacyKeychain {
        nonisolated(unsafe) static var n = 1
        nonisolated(unsafe) static var result: OSStatus = errSecSuccess
        @available(macOS, deprecated: 10.10)
        static func ref() -> SecKeychain { var k: SecKeychain?; _ = SecKeychainOpen("/nonexistent/beam-test.keychain-db", &k); return k! }   // a reference only: no file
        @available(macOS, deprecated: 10.10)
        static func create(_ path: String, password: [UInt8]) -> OSStatus { n += 1; return result }
        static func unlock(_ path: String, password: [UInt8]) -> OSStatus { errSecSuccess }
        @available(macOS, deprecated: 10.10)
        static func searchList() -> [SecKeychain]? { (0..<n).map { _ in ref() } }
        static func setSearchList(_ list: [SecKeychain]) -> OSStatus { n = list.count; return errSecSuccess }
    }

    @Test func searchListPutBackEvenOnFailure() {
        let p = URL(fileURLWithPath: "/nonexistent/beam-test.keychain-db")
        Fake.n = 1; Fake.result = errSecSuccess
        #expect(throws: Never.self) { try KeychainFile.create(p, password: "x", calls: Fake.self) }
        #expect(Fake.n == 1, "made: the list as it was")
        Fake.n = 1; Fake.result = errSecIO
        #expect(throws: KeychainFile.Failure.self) { try KeychainFile.create(p, password: "x", calls: Fake.self) }
        #expect(Fake.n == 1, "failed part way: the list as it was all the same")
    }
}
