// iPhones and iPads through Xcode's devicectl (beam-design §4.4): the paired devices, the apps on one, install, remove, launch, and a save copied off or back.
// Every command's result is read from its --json-output file; the fields read are the stable ones (identifier, deviceProperties, hardwareProperties, connectionProperties)
import Foundation

/// A command-line tool's run: its exit code and output (a small helper for xcrun, xcodebuild, security)
enum Tool {
    struct Result: Sendable { var code: Int32; var out: String; var err: String }
    static func run(_ exe: String, _ args: [String], log: URL? = nil) async throws -> Result {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
        let outTask = Task.detached { o.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { e.fileHandleForReading.readDataToEndOfFile() }
        let box = TerminateBox(p)
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { p.terminationHandler = nil; try? o.fileHandleForWriting.close(); try? e.fileHandleForWriting.close(); c.resume(throwing: error) }
            }
        } onCancel: { box.terminate() }
        let out = String(decoding: await outTask.value, as: UTF8.self), err = String(decoding: await errTask.value, as: UTF8.self)
        if let log { try? (out + err).write(to: log, atomically: true, encoding: .utf8) }
        return Result(code: code, out: out, err: err)
    }
}
private final class TerminateBox: @unchecked Sendable {
    let p: Process
    init(_ p: Process) { self.p = p }
    func terminate() { if p.isRunning { p.terminate() } }
}

struct DeviceInfo: Identifiable, Sendable, Equatable, Hashable, Codable {
    var id: String                 // devicectl's identifier (CoreDevice UUID)
    var name: String
    var model: String              // "iPhone 18 Pro Max"
    var platform: String           // "iOS"
    var osVersion: String?
    var udid: String?
    var paired: Bool
    var connected: Bool            // a tunnel is up: cable or network
    var developerMode: Bool?
    var physical: Bool
    var isIPad: Bool { model.hasPrefix("iPad") }
}

struct DeviceApp: Sendable, Equatable, Codable {
    var bundleID: String
    var name: String?
    var version: String?
    var byDeveloper: Bool          // signed for development (a sideloaded app: it counts against a free account's 3)
    /// The title ID an NX 18 or NX Play app carries in its bundle ID (16 hex digits as one component: org.nxnative.<title ID>, org.nxnative.<team>.<title ID>)
    var titleID: String? {
        bundleID.split(separator: ".").last(where: { $0.count == 16 && $0.allSatisfy(\.isHexDigit) }).map { $0.uppercased() }
    }
}

enum DeviceCtl {
    static let xcrun = "/usr/bin/xcrun"

    /// devicectl's --json-output of one command: (its result object, the run). Throws when the command fails, with devicectl's own message
    static func json(_ args: [String]) async throws -> [String: Any] {
        let out = FileManager.default.temporaryDirectory.appending(path: "beam-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await Tool.run(xcrun, ["devicectl"] + args + ["--json-output", out.path, "--quiet"])
        let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: out))) as? [String: Any] ?? [:]
        if r.code != 0 { throw DeviceError.failed(message(obj) ?? r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return obj["result"] as? [String: Any] ?? [:]
    }
    private static func message(_ obj: [String: Any]) -> String? {
        let e = (obj["error"] as? [String: Any]) ?? ((obj["info"] as? [String: Any])?["error"] as? [String: Any])
        return (e?["userInfo"] as? [String: Any]).flatMap { ($0["NSLocalizedDescription"] as? [String: Any])?["string"] as? String } ?? e?["localizedDescription"] as? String
    }

    static func parseDevices(_ result: [String: Any]) -> [DeviceInfo] {
        (result["devices"] as? [[String: Any]] ?? []).compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:], dp = d["deviceProperties"] as? [String: Any] ?? [:], cp = d["connectionProperties"] as? [String: Any] ?? [:]
            guard let id = d["identifier"] as? String, (hw["platform"] as? String) == "iOS" else { return nil }   // iPhone and iPad (iPadOS reports iOS)
            return DeviceInfo(id: id, name: dp["name"] as? String ?? hw["marketingName"] as? String ?? "Device", model: hw["marketingName"] as? String ?? hw["deviceType"] as? String ?? "",
                              platform: "iOS", osVersion: dp["osVersionNumber"] as? String, udid: hw["udid"] as? String,
                              paired: (cp["pairingState"] as? String) == "paired", connected: (cp["tunnelState"] as? String) == "connected",
                              developerMode: (dp["developerModeStatus"] as? String).map { $0 == "enabled" }, physical: (hw["reality"] as? String) == "physical")
        }
    }
    static func parseApps(_ result: [String: Any]) -> [DeviceApp] {
        (result["apps"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["bundleIdentifier"] as? String else { return nil }
            return DeviceApp(bundleID: id, name: a["name"] as? String, version: a["version"] as? String, byDeveloper: a["builtByDeveloper"] as? Bool ?? false)
        }
    }

    /// The paired iPhones and iPads (simulators left out: they cannot run a game's code)
    static func devices() async throws -> [DeviceInfo] { parseDevices(try await json(["list", "devices"])).filter(\.physical) }
    static func apps(on device: String) async throws -> [DeviceApp] {
        parseApps(try await json(["device", "info", "apps", "--device", device, "--include-removable-apps", "--no-include-default-apps"]))
    }
    static func install(_ app: URL, on device: String) async throws { _ = try await json(["device", "install", "app", "--device", device, app.path]) }
    static func uninstall(_ bundleID: String, on device: String) async throws { _ = try await json(["device", "uninstall", "app", "--device", device, bundleID]) }
    static func launch(_ bundleID: String, on device: String) async throws { _ = try await json(["device", "process", "launch", "--device", device, "--terminate-existing", bundleID]) }

    /// The app's save folder (Documents/save) copied off the device into `folder` (a development-signed app's data container only)
    static func copySave(of bundleID: String, on device: String, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await json(["device", "copy", "from", "--device", device, "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                            "--source", "Documents/save", "--destination", folder.path])
    }
    /// A file copied into the app's Documents folder (My files: Documents/Companion/<name>)
    static func copyFile(_ file: URL, of bundleID: String, on device: String, to destination: String) async throws {
        _ = try await json(["device", "copy", "to", "--device", device, "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                            "--source", file.path, "--destination", destination])
    }
    /// A save folder copied back into the app's Documents/save, merging into what is there (never --remove-existing-content: it empties the whole container, docs/reference/packing.md)
    static func restoreSave(_ folder: URL, of bundleID: String, on device: String) async throws {
        _ = try await json(["device", "copy", "to", "--device", device, "--domain-type", "appDataContainer", "--domain-identifier", bundleID,
                            "--source", folder.path, "--destination", "Documents/save"])
    }
}

enum DeviceError: LocalizedError, Equatable {
    case failed(String), developerModeOff(String), notConnected(String), noTeam, signing(String), noApp
    var errorDescription: String? {
        switch self {
        case .failed(let m): m.isEmpty ? "The device did not answer." : m
        case .developerModeOff(let n): "Developer Mode is off on \(n). Turn it on in Settings > Privacy & Security > Developer Mode, then restart the device."
        case .notConnected(let n): "\(n) is not reachable. Connect it with a cable, or unlock it on the same network as this Mac."
        case .noTeam: "No Apple account in Xcode. Add one in Xcode > Settings > Apple Accounts. Beam never asks for your password."
        case .signing(let m): m
        case .noApp: "The signed app was not found after the build."
        }
    }
}
