// Signing with the player's own Apple Developer certificate and provisioning profile (the certificate route, beside Xcode signing): for a player whose certificate
// is a .p12 (exported from their own developer account) rather than an Xcode sign-in. The certificate goes into Beam's own keychain file, never the login
// keychain, and macOS asks for the .p12's password in its own dialog: Beam never sees or keeps it. Beam reads each profile and refuses one that has expired,
// was not issued for that certificate, does not list the device, or does not grant both memory entitlements (mandatory, MemoryEntitlements)
import CryptoKit
import Foundation
import Security

/// Beam's keychain file for signing identities: ~/Library/Application Support/NX 18 Beam/Signing/Beam.keychain-db, its password random and kept in the login keychain
enum BeamKeychain {
    static var folder: URL { Library.defaultFolder.appending(path: "Signing", directoryHint: .isDirectory) }
    static var path: URL { folder.appending(path: "Beam.keychain-db") }
    private static let service = "org.nx18.beam.signing-keychain"

    /// The keychain's password from the login keychain, made the first time
    static func password() throws -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "Beam",
                                kSecReturnData as String: true]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DeviceError.signing("No random bytes for Beam's keychain.") }
        let pw = Data(bytes).base64EncodedString()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "Beam",
                                  kSecValueData as String: Data(pw.utf8), kSecAttrLabel as String: "NX 18 Beam signing keychain"]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw DeviceError.signing("Could not keep Beam's keychain password in the login keychain (\(st)).") }
        return pw
    }

    /// The keychain file, made and unlocked; the user's keychain search list is left as it was
    static func ready() async throws -> URL { try ready(at: path, password: try password()) }
    /// `kc` made the first time and unlocked, in Beam's process (KeychainFile): the password is never on a command line, where another process could read it
    static func ready(at kc: URL, password pw: String) throws -> URL {
        if !FileManager.default.fileExists(atPath: kc.path) {
            try FileManager.default.createDirectory(at: kc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try KeychainFile.create(kc, password: pw)
        }
        try KeychainFile.unlock(kc, password: pw)
        return kc
    }

    /// Imports a .p12. With no -P, macOS asks for its password in a secure system dialog. The key is non-extractable and only codesign may use it without asking
    static func importP12(_ p12: URL) async throws {
        let kc = try await ready()
        let r = try await Tool.run("/usr/bin/security", ["import", p12.path, "-k", kc.path, "-f", "pkcs12", "-x", "-T", "/usr/bin/codesign"])
        guard r.code == 0 else { throw DeviceError.signing(r.err.contains("passphrase") || r.err.contains("MAC verification") ? "The password for that certificate file was not right." : "The certificate could not be added: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        do { try await KeychainFile.allowCodesign(kc, password: try password()) }   // as before, not an import failure: the certificate is in, codesign then asks once
        catch { fputs("beam: \(error.localizedDescription)\n", stderr) }
    }

    /// The code-signing identities in Beam's keychain
    static func identities() async -> [SigningIdentity] {
        guard FileManager.default.fileExists(atPath: path.path), let r = try? await Tool.run("/usr/bin/security", ["find-identity", "-p", "codesigning", path.path]) else { return [] }
        return SigningIdentity.parse(r.out)
    }
}

/// A certificate with its private key, named by its common name only (as Keychain Access shows it)
struct SigningIdentity: Sendable, Equatable, Hashable, Identifiable {
    var id: String               // the certificate's SHA-1, as codesign takes it
    var name: String             // "Apple Development: …" / "iPhone Distribution: …"
    /// `security find-identity` lines: `  1) <40 hex> "<common name>"`
    /// (Without -v, so a certificate whose Apple intermediate is missing from this Mac still shows; each identity once)
    static func parse(_ out: String) -> [SigningIdentity] {
        var seen = Set<String>()
        return out.split(separator: "\n").compactMap { line -> SigningIdentity? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[0].hasSuffix(")"), parts[1].count == 40, parts[1].allSatisfy(\.isHexDigit),
                  let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 else { return nil }
            let id = String(parts[1]).uppercased()
            guard seen.insert(id).inserted else { return nil }
            return SigningIdentity(id: id, name: String(line[line.index(after: q1)..<q2]))
        }
    }
    /// The name without the team ID that certificate names end in ("Apple Development: Name (ABCDE12345)" → "Apple Development: Name")
    var shownName: String { name.replacingOccurrences(of: #"\s*\([A-Z0-9]{10}\)$"#, with: "", options: .regularExpression) }
}

/// A provisioning profile the player added, and what Beam checks in it
struct Profile: Sendable, Equatable, Identifiable {
    var id: String               // UUID
    var name: String
    var file: URL
    var teamID: String
    var appID: String            // "TEAM.org.example.game" or "TEAM.*"
    var expires: Date?
    var devices: [String]        // ProvisionedDevices: UDIDs
    var allDevices: Bool         // ProvisionsAllDevices
    var certificates: [String]   // SHA-1 of each DeveloperCertificates entry
    var entitlements: [String: PlistValue]
    var memory: Bool { entitlements[MemoryEntitlements.iml] == .bool(true) && entitlements[MemoryEntitlements.eva] == .bool(true) }
    var wildcard: Bool { appID.hasSuffix(".*") }
    var bundlePattern: String { String(appID.dropFirst(teamID.count + 1)) }

    static func parse(_ plist: Data, file: URL) -> Profile? {
        guard let p = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let uuid = p["UUID"] as? String, let ent = p["Entitlements"] as? [String: Any] else { return nil }
        let team = (p["TeamIdentifier"] as? [String])?.first ?? ""
        let certs = (p["DeveloperCertificates"] as? [Data] ?? []).map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
        return Profile(id: uuid, name: p["Name"] as? String ?? "Profile", file: file, teamID: team,
                       appID: ent["application-identifier"] as? String ?? "", expires: p["ExpirationDate"] as? Date,
                       devices: p["ProvisionedDevices"] as? [String] ?? [], allDevices: p["ProvisionsAllDevices"] as? Bool ?? false,
                       certificates: certs, entitlements: ent.compactMapValues(PlistValue.init))
    }
    static func read(_ file: URL) async -> Profile? {
        guard let r = try? await Tool.run("/usr/bin/security", ["cms", "-D", "-i", file.path]), r.code == 0 else { return nil }
        return parse(Data(r.out.utf8), file: file)
    }

    /// Why this profile cannot sign this game for this device with this certificate, in a sentence; nil when it can
    func problem(identity: SigningIdentity, deviceUDID: String?, bundleID: String, now: Date = .now) -> String? {
        if let e = expires, e <= now { return "The profile \"\(name)\" expired on \(e.formatted(date: .abbreviated, time: .omitted)). Make a new one in your developer account." }
        if !certificates.contains(identity.id) { return "The profile \"\(name)\" was not made for the certificate \"\(identity.shownName)\". Pick the profile made with it." }
        if !allDevices, let u = deviceUDID, !devices.contains(where: { $0.caseInsensitiveCompare(u) == .orderedSame }) {
            return "The profile \"\(name)\" does not list this device. Add the device in your developer account and download the profile again."
        }
        if !memory { return "The profile \"\(name)\" does not grant the Increased Memory Limit and Extended Virtual Addressing that NX 18's games need. Turn both on for its App ID in your developer account, then download the profile again." }
        if !wildcard && bundlePattern != bundleID { return "The profile \"\(name)\" is for another app (\(bundlePattern))." }
        return nil
    }

    /// The bundle ID a game gets under this profile: the profile's own for an explicit App ID, else the game's (XcodeSigning.bundleID)
    func bundleID(forGame gameBundleID: String) -> String { wildcard ? gameBundleID : bundlePattern }

    /// The entitlements the app is signed with: the profile's, its wildcard application identifier made the app's own
    func signingEntitlements(bundleID: String) -> [String: Any] {
        var e = entitlements.mapValues(\.value)
        e["application-identifier"] = "\(teamID).\(bundleID)"
        return e
    }
}

/// A property-list value kept Sendable and comparable (a profile's entitlements)
enum PlistValue: Sendable, Equatable {
    case bool(Bool), string(String), int(Int), array([PlistValue]), dict([String: PlistValue])
    init?(_ v: Any) {
        switch v {
        case let b as Bool: self = .bool(b)
        case let s as String: self = .string(s)
        case let i as Int: self = .int(i)
        case let a as [Any]: self = .array(a.compactMap(PlistValue.init))
        case let d as [String: Any]: self = .dict(d.compactMapValues(PlistValue.init))
        default: return nil
        }
    }
    var value: Any {
        switch self {
        case .bool(let b): b
        case .string(let s): s
        case .int(let i): i
        case .array(let a): a.map(\.value)
        case .dict(let d): d.mapValues(\.value)
        }
    }
}

enum Resigner {
    /// The built IPA's app, unpacked into `into` (the build folder's resign/): ditto keeps the IPA's file modes
    static func unpack(ipa: URL, into dir: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = try await Tool.run("/usr/bin/ditto", ["-x", "-k", ipa.path, dir.path])
        guard r.code == 0, let app = try? FileManager.default.contentsOfDirectory(at: dir.appending(path: "Payload"), includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
        else { throw DeviceError.signing("The IPA could not be unpacked: \(r.err)") }
        return app
    }

    /// Signs an unpacked app with the identity in Beam's keychain: the profile embedded, the bundle ID set, nested code first, then the app with the profile's
    /// entitlements. Checks the result carries both memory entitlements
    static func sign(app: URL, identity: SigningIdentity, profile: Profile, bundleID: String, keychain: URL? = nil) async throws {
        let kc: URL
        if let keychain { kc = keychain } else { kc = try await BeamKeychain.ready() }
        let info = app.appending(path: "Info.plist")
        guard var plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil)) as? [String: Any] else { throw DeviceError.signing("The app has no Info.plist.") }
        plist["CFBundleIdentifier"] = bundleID
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: info)
        let embedded = app.appending(path: "embedded.mobileprovision")
        try? FileManager.default.removeItem(at: embedded)
        try FileManager.default.copyItem(at: profile.file, to: embedded)
        let ent = app.deletingLastPathComponent().deletingLastPathComponent().appending(path: "entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: profile.signingEntitlements(bundleID: bundleID), format: .xml, options: 0).write(to: ent)
        let base = ["-f", "-s", identity.id, "--keychain", kc.path, "--timestamp=none", "--generate-entitlement-der"]
        for nested in nestedCode(in: app) {   // frameworks, dylibs and extensions before the app that seals them
            let r = try await Tool.run("/usr/bin/codesign", base + [nested.path])
            guard r.code == 0 else { throw DeviceError.signing("Signing \(nested.lastPathComponent) failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        let r = try await Tool.run("/usr/bin/codesign", base + ["--entitlements", ent.path, app.path])
        guard r.code == 0 else { throw DeviceError.signing("Signing the game failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        guard await MemoryEntitlements.signed(app) else { throw DeviceError.signing(MemoryEntitlements.missingText) }
    }

    static func nestedCode(in app: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for sub in ["Frameworks", "PlugIns", "Extensions"] {
            let d = app.appending(path: sub)
            for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where ["framework", "dylib", "appex"].contains(u.pathExtension) { out.append(u) }
        }
        return out
    }
}
