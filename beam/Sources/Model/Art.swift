// Art for a game's launcher and icon (beam-design §3.8): Beam calls SteamGridDB itself, with the player's key read from the Keychain at that moment; the key is
// never passed to the build (ScriptRunner.scriptEnvironment removes STEAMGRIDDB_KEY), so it is never in a child's environment, a command line or a log.
// The player's picks are saved in Beam's folder (Art/<title ID>/) and given to the next build with --art, --logo and --icon
import Foundation
import Security

enum SteamGridKey {
    private static let service = "org.nx18.beam.steamgriddb"
    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"] }

    static func read() -> String? {
        var q = base; q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static var isSet: Bool {
        var q = base; q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    /// Saved for this Mac only (not synced), readable while the Mac is unlocked
    static func save(_ key: String) throws {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "NX 18 Beam: SteamGridDB key"
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw ModError.refused("The key could not be saved in the Keychain (\(st)).") }
    }
    static func remove() { SecItemDelete(base as CFDictionary) }
}

enum ArtKind: String, CaseIterable, Sendable, Codable {
    case keyArt, logo, icon
    var label: String { switch self { case .keyArt: "Key art"; case .logo: "Logo"; case .icon: "Icon" } }
    /// SteamGridDB's collection for it: heroes (wide banners) as the launcher's key art, logos with transparency, icons
    var path: String { switch self { case .keyArt: "heroes"; case .logo: "logos"; case .icon: "icons" } }
}

struct GridGame: Decodable, Sendable, Identifiable, Equatable { var id: Int; var name: String }
struct GridImage: Decodable, Sendable, Identifiable, Equatable {
    var id: Int
    var url: String
    var thumb: String
    var width: Int?
    var height: Int?
    var author: Author?
    struct Author: Decodable, Sendable, Equatable { var name: String? }
}

enum SteamGrid {
    static let api = URL(string: "https://www.steamgriddb.com/api/v2/")!
    private struct Reply<T: Decodable>: Decodable { var success: Bool; var data: T? }

    static func decode<T: Decodable>(_ data: Data, as: T.Type) throws -> T {
        let r = try JSONDecoder().decode(Reply<T>.self, from: data)
        guard r.success, let d = r.data else { throw ModError.refused("SteamGridDB found nothing.") }
        return d
    }

    /// One call to SteamGridDB, the key read from the Keychain for it only
    static func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let key = SteamGridKey.read() else { throw ModError.refused("Add a SteamGridDB key in Settings to choose art.") }
        var c = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: 30)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue(ModFetch.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw ModError.refused("SteamGridDB did not accept the key. Check it in Settings.") }
        guard (200..<300).contains(code) else { throw ModError.refused("SteamGridDB answered \(code).") }
        return data
    }

    static func search(_ name: String) async throws -> [GridGame] {
        let term = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        return try decode(try await get("search/autocomplete/\(term)"), as: [GridGame].self)
    }
    static func images(_ kind: ArtKind, game: Int) async throws -> [GridImage] {
        // what the build takes: key art and icon as JPEG or PNG, the logo as PNG (transparency)
        let mimes = kind == .logo ? "image/png" : "image/png,image/jpeg"
        let q = [URLQueryItem(name: "mimes", value: mimes)]
        return try decode(try await get("\(kind.path)/game/\(game)", query: q), as: [GridImage].self)
    }

    /// The picked image saved in Beam's Art folder for the game, as art / logo / icon with its own extension; returns where
    static func save(_ img: GridImage, kind: ArtKind, titleID: String, root: URL = Library.defaultFolder.appending(path: "Art")) async throws -> URL {
        guard let u = URL(string: img.url), u.scheme == "https" else { throw ModError.refused("The image's address is not HTTPS.") }
        let data = try await ModFetch.get(u)
        guard isImage(data) else { throw ModError.refused("The download is not an image.") }
        let ext = u.pathExtension.lowercased().isEmpty ? "png" : u.pathExtension.lowercased()
        let dir = root.appending(path: titleID.uppercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where old.deletingPathExtension().lastPathComponent == kind.rawValue {
            try? FileManager.default.removeItem(at: old)
        }
        let dst = dir.appending(path: "\(kind.rawValue).\(ext)")
        try data.write(to: dst, options: .atomic)
        return dst
    }
    /// PNG, JPEG or WebP by their first bytes (what the build takes)
    static func isImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) || b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        return b.count >= 12 && b[0...3] == [0x52, 0x49, 0x46, 0x46] && b[8...11] == [0x57, 0x45, 0x42, 0x50]
    }
}
