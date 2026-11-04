import Foundation

/// The iPhones and iPads this Mac can install on, through Xcode's devicectl.
enum Devices {
    static func list() async -> (devices: [Device], error: String?) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nintanium-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = await Shell.run("xcrun", ["devicectl", "list", "devices", "--quiet", "--json-output", out.path])
        guard r.ok, let data = try? Data(contentsOf: out),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let list = result["devices"] as? [[String: Any]]
        else { return ([], r.ok ? "devicectl gave no device list" : "devicectl: \(r.reason) (Xcode is needed)") }
        let devices: [Device] = list.compactMap { d in
            guard let id = d["identifier"] as? String else { return nil }
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let type = hw["deviceType"] as? String ?? ""
            guard type == "iPhone" || type == "iPad" else { return nil }
            let tunnel = conn["tunnelState"] as? String ?? ""
            return Device(id: id, name: props["name"] as? String ?? type, model: hw["marketingName"] as? String ?? type, type: type, udid: hw["udid"] as? String ?? "",
                          connected: tunnel == "connected" || (conn["pairingState"] as? String == "paired" && tunnel != "unavailable"))
        }
        return (devices.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }, nil)
    }

    /// The team ID of this Mac's Apple Development (else Apple Distribution) certificate: its subject's OU.
    static func teamID() async -> String? {
        for name in ["Apple Development", "Apple Distribution"] {
            let pem = await Shell.run("security", ["find-certificate", "-c", name, "-p"])
            guard pem.ok, !pem.stdout.isEmpty else { continue }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nintanium-cert-\(UUID().uuidString).pem")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try? pem.stdout.write(to: tmp, atomically: true, encoding: .utf8)
            let subj = await Shell.run("openssl", ["x509", "-noout", "-subject", "-in", tmp.path])
            if let m = subj.stdout.firstMatch(of: #/OU\s*=\s*([A-Z0-9]{10})/#) { return String(m.1) }
        }
        return nil
    }
}
