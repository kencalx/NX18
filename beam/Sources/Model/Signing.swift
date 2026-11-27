// Signing an iPhone build with the player's own Apple account in Xcode (beam-design §3.4 Route A, §4.4): the teams Xcode knows, the game's Xcode project built with
// automatic provisioning, and what the signed app's profile says (expiry, Increased Memory Limit). Beam never asks for an Apple ID password and never shows a team ID
import CryptoKit
import Foundation

struct XcodeTeam: Sendable, Equatable, Hashable, Identifiable {
    var id: String               // the team ID: kept for xcodebuild, never shown
    var name: String
    var free: Bool               // a Personal Team: 3 apps per device, 7 days, 10 new App IDs a week
    var label: String { free ? "\(name) (Personal Team)" : name }

    /// The teams of the Apple accounts in Xcode > Settings > Apple Accounts (Xcode's own preferences; no password, no network)
    static func inXcode(_ defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.dt.Xcode")) -> [XcodeTeam] {
        guard let byAccount = defaults?.dictionary(forKey: "IDEProvisioningTeamByIdentifier") else { return [] }
        return parse(byAccount)
    }
    static func parse(_ byAccount: [String: Any]) -> [XcodeTeam] {
        var out: [XcodeTeam] = []
        for case let teams as [[String: Any]] in byAccount.values {
            for t in teams {
                guard let id = t["teamID"] as? String, !out.contains(where: { $0.id == id }) else { continue }
                out.append(XcodeTeam(id: id, name: t["teamName"] as? String ?? "Team", free: t["isFreeProvisioningTeam"] as? Bool ?? false))
            }
        }
        return out.sorted { ($0.free ? 1 : 0, $0.name) < ($1.free ? 1 : 0, $1.name) }   // a paid team first
    }
}

/// What a signed app's embedded.mobileprovision says
struct ProvisioningInfo: Sendable, Equatable {
    var expires: Date?
    var increasedMemoryLimit: Bool
    var extendedVirtualAddressing = false
    var grantsMemory: Bool { increasedMemoryLimit && extendedVirtualAddressing }
    static func parse(_ plist: Data) -> ProvisioningInfo? {
        guard let p = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        let ent = p["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningInfo(expires: p["ExpirationDate"] as? Date, increasedMemoryLimit: ent[MemoryEntitlements.iml] as? Bool ?? false,
                                extendedVirtualAddressing: ent[MemoryEntitlements.eva] as? Bool ?? false)
    }
    static func of(app: URL) async -> ProvisioningInfo? {
        let prof = app.appending(path: "embedded.mobileprovision")
        guard FileManager.default.fileExists(atPath: prof.path), let r = try? await Tool.run("/usr/bin/security", ["cms", "-D", "-i", prof.path]), r.code == 0 else { return nil }
        return parse(Data(r.out.utf8))
    }
}

/// The two entitlements every NX 18 app carries (dm/ios/tools/build_ipa.sh, README "Increased Memory Limit"): Beam installs a game only when its signature has both
enum MemoryEntitlements {
    static let iml = "com.apple.developer.kernel.increased-memory-limit"
    static let eva = "com.apple.developer.kernel.extended-virtual-addressing"

    /// Whether a signed app's (or executable's) signature carries both, from codesign's own reading
    static func signed(_ code: URL) async -> Bool {
        guard let r = try? await Tool.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", code.path]), r.code == 0 else { return false }
        return granted(Data(r.out.utf8))
    }
    static func granted(_ plist: Data) -> Bool {
        guard let e = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return false }
        return e[iml] as? Bool == true && e[eva] as? Bool == true
    }

    static let freeTeamText = "A free Apple account (Personal Team) cannot have the Increased Memory Limit that NX 18's games need, so Beam does not install with it. Use a paid Apple Developer account in Xcode, or install the IPA with SideStore and add the limit with GetMoreRam (README, Increased Memory Limit)."
    static let missingText = "The signed game has no Increased Memory Limit (or no Extended Virtual Addressing), which NX 18's games need, so Beam did not install it. Check that the Apple Developer account in Xcode is a paid one, then install again."
}

enum XcodeSigning {
    /// A game's bundle ID on the player's devices, kept across reinstalls so a swap costs no new App ID and the save stays (beam-design §4.4): the one an app for the
    /// same title already has on the device (an NX Play install included, so Beam's reinstall replaces it), else org.nxnative.<team tag>.<title ID>
    static func bundleID(titleID: String, team: XcodeTeam, onDevice apps: [DeviceApp]) -> String {
        if let app = apps.first(where: { $0.titleID == titleID.uppercased() }) { return app.bundleID }
        return "org.nxnative.\(teamTag(team)).\(titleID.lowercased())"
    }

    /// A short tag of the team for new bundle IDs: unique to the team without carrying its ID (NX Play's form puts the team ID itself there, which the build's messages would show)
    static func teamTag(_ team: XcodeTeam) -> String {
        "t" + SHA256.hash(data: Data(team.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The game's scheme in its Xcode project ("Game name (title ID)", which --prepare-xcode generates)
    static func scheme(project: URL, titleID: String) async throws -> String {
        let r = try await Tool.run("/usr/bin/xcrun", ["xcodebuild", "-list", "-json", "-project", project.path])
        let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
        let schemes = (obj?["project"] as? [String: Any])?["schemes"] as? [String] ?? []
        guard let s = schemes.first(where: { $0.localizedCaseInsensitiveContains(titleID) }) ?? schemes.first else {
            throw DeviceError.signing("The game's Xcode project has no scheme (\(project.path)).")
        }
        return s
    }

    /// `profileSeed`: the player's Profile for the app (ProfileSetup.seed), which the project's Copy game resources phase puts in <App>/NX18ProfileSeed before Xcode signs it
    static func buildArguments(project: URL, scheme: String, device: String, team: XcodeTeam, derived: URL, profileSeed: URL? = nil) -> [String] {
        ["xcodebuild", "-project", project.path, "-scheme", scheme, "-configuration", "Release", "-destination", "id=\(device)", "-derivedDataPath", derived.path,
         "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "DEVELOPMENT_TEAM=\(team.id)", "CODE_SIGN_STYLE=Automatic"]
            + (profileSeed.map { ["DM_PROFILE_SEED=\($0.path)"] } ?? []) + ["build"]
    }

    /// Builds and signs the prepared project for one device; returns the signed app. The log goes to `<build folder>/logs/xcodebuild.log`
    static func sign(work: URL, titleID: String, device: DeviceInfo, team: XcodeTeam, profileSeed: URL? = nil) async throws -> URL {
        let project = work.appending(path: "xcode/DmIOS.xcodeproj"), derived = work.appending(path: "xcode-derived-data")
        let logs = work.appending(path: "logs"); try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let scheme = try await scheme(project: project, titleID: titleID)
        let r = try await Tool.run("/usr/bin/xcrun", buildArguments(project: project, scheme: scheme, device: device.udid ?? device.id, team: team, derived: derived, profileSeed: profileSeed),
                                   log: logs.appending(path: "xcodebuild.log"))
        if r.code != 0 { throw DeviceError.signing(signingMessage(r.out + r.err, teamID: team.id)) }
        let products = derived.appending(path: "Build/Products/Release-iphoneos")
        guard let app = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) else { throw DeviceError.noApp }
        return app
    }

    /// xcodebuild's reason in a sentence where Beam knows it (the team ID never in it)
    static func signingMessage(_ raw: String, teamID: String = "") -> String {
        let log = teamID.isEmpty ? raw : raw.replacingOccurrences(of: teamID, with: "(your team)")
        let l = log.lowercased()
        if l.contains("maximum number of apps") || l.contains("app id limit") || l.contains("maximum app id") {
            return "This Apple account reached its limit of new App IDs for the week (a free account has 10). Reinstall a game you already have, or wait a few days."
        }
        if l.contains("no account") || l.contains("no accounts") { return DeviceError.noTeam.errorDescription! }
        if l.contains("developer mode") { return "Developer Mode is off on the device. Turn it on in Settings > Privacy & Security > Developer Mode." }
        if l.contains("is not available") && l.contains("bundle identifier") { return "That bundle ID belongs to another team. Remove the old app from the device and install again." }
        let errors = log.split(separator: "\n").filter { $0.contains("error:") }.prefix(3).joined(separator: "\n")
        return errors.isEmpty ? "Xcode could not sign the game. Show Details has its log." : errors
    }
}
