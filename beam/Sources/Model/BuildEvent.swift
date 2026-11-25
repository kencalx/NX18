// The build script's JSON events (`--progress json`, one object per line; docs/frontends.md, "Building: the NSP script").
// Beam relies only on what that page promises: an unknown event or field is ignored, since later builds may add both.
import Foundation

struct StageEvent: Decodable, Sendable, Equatable { var k: Int; var n: Int; var name: String; var step: String? }
struct StepEvent: Decodable, Sendable, Equatable { var k: Int; var name: String; var step: String? }
struct ProgressEvent: Decodable, Sendable, Equatable {
    var k: Int; var name: String; var step: String?
    var done: Double?; var total: Double?; var unit: String?; var est: Bool?; var note: String?
    var frac: Double?          // 0 to 0.99, nil when the work cannot be counted
    var eta: Double?; var elapsed: Double?
}
struct StageEndEvent: Decodable, Sendable, Equatable { var k: Int; var name: String; var ok: Bool; var summary: String?; var elapsed: Double?; var warn: Bool? }
struct GameEvent: Decodable, Sendable, Equatable {
    var titleId: String; var name: String; var version: String; var bundleId: String
    var out: String?; var icon: String?
    var build: String?         // main's build ID of the packed version, 16 hex digits (Beam B0, N3)
}
struct ArtEvent: Decodable, Sendable, Equatable { var path: String?; var source: String?; var url: String?; var logo: String?; var about: String? }
struct SayEvent: Decodable, Sendable, Equatable {
    var msg: String
    var isError: Bool { msg.hasPrefix("[RED] ") }
    /// The message without the console's time stamp ("[10:37:15] ") and the "[RED] " mark
    var text: String {
        var s = Substring(msg)
        if s.hasPrefix("[RED] ") { s = s.dropFirst(6) }
        if s.first == "[", let close = s.firstIndex(of: "]"), s[s.index(after: s.startIndex)..<close].allSatisfy({ $0.isNumber || $0 == ":" }) {
            s = s[s.index(after: close)...].drop(while: { $0 == " " })
        }
        if s.hasPrefix("[RED] ") { s = s.dropFirst(6) }
        return String(s)
    }
}
struct ShadersStaleEvent: Decodable, Sendable, Equatable { var reason: String; var count: Int? }

/// `--identify`: which game a folder, NUP or NX holds (Beam B0, N2)
struct IdentifyEvent: Codable, Sendable, Equatable, Hashable {
    struct Version: Codable, Sendable, Equatable, Hashable {
        var version: String; var display: String?; var build: String?; var registered: Bool?; var note: String?
        var number: Int { Int(version.dropFirst()) ?? 0 }
    }
    struct DLC: Codable, Sendable, Equatable, Hashable { var titleId: String; var version: Int? }
    var titleId: String
    var name: String?
    var platform: String       // "switch1" or "switch2"
    var kind: String           // "nsp", "nup", "nx" or "folder"
    var versions: [Version]
    var packs: String?
    var dlc: [DLC]
    var programs: [String]
    var profile: String?
    var alias: Bool?
    var isSwitch2: Bool { platform == "switch2" }
    var needsKeys: Bool { kind == "nsp" }
}

/// What the packer took from the mods folder and left out (Beam B0, N4)
struct ModsEvent: Decodable, Sendable, Equatable {
    struct Offered: Decodable, Sendable, Equatable { var role: String; var mod: String; var runs: Int?; var leftOut: [String]? }
    struct LeftOut: Decodable, Sendable, Equatable { var path: String?; var mod: String?; var role: String?; var why: String }
    var titleId: String; var build: String?; var folder: String?; var report: String?; var cheats: Bool?
    var offered: [Offered]; var leftOut: [LeftOut]
}

enum BuildEvent: Sendable, Equatable {
    case stage(StageEvent), step(StepEvent), progress(ProgressEvent), stageEnd(StageEndEvent)
    case game(GameEvent), art(ArtEvent), say(SayEvent), shadersStale(ShadersStaleEvent)
    case identify(IdentifyEvent), mods(ModsEvent)
    case unknown(String)       // an event this Beam does not know: ignored (docs/frontends.md)

    private struct Head: Decodable { var ev: String }

    /// One line of the script's stdout; nil for a line that is not a JSON object with `ev` (a front end never stops on one)
    static func parse(_ line: some StringProtocol) -> BuildEvent? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        guard let head = try? d.decode(Head.self, from: data) else { return nil }
        func get<T: Decodable>(_ t: T.Type) -> T? { try? d.decode(t, from: data) }
        let e: BuildEvent? = switch head.ev {
        case "stage": get(StageEvent.self).map(BuildEvent.stage)
        case "step": get(StepEvent.self).map(BuildEvent.step)
        case "progress": get(ProgressEvent.self).map(BuildEvent.progress)
        case "stage_end": get(StageEndEvent.self).map(BuildEvent.stageEnd)
        case "game": get(GameEvent.self).map(BuildEvent.game)
        case "art": get(ArtEvent.self).map(BuildEvent.art)
        case "say": get(SayEvent.self).map(BuildEvent.say)
        case "shaders_stale": get(ShadersStaleEvent.self).map(BuildEvent.shadersStale)
        case "identify": get(IdentifyEvent.self).map(BuildEvent.identify)
        case "mods": get(ModsEvent.self).map(BuildEvent.mods)
        default: .unknown(head.ev)
        }
        return e ?? .unknown(head.ev)   // a known event whose fields this Beam cannot read: treated as unknown, not as an error
    }
}

/// The script's exit codes (docs/frontends.md)
enum ScriptExit: Sendable, Equatable {
    case done, failed, badArguments, interrupted, stopped, other(Int32)
    init(code: Int32) {
        self = switch code {
        case 0: .done
        case 1: .failed
        case 2: .badArguments
        case 130: .interrupted
        case 129, 143: .stopped
        default: .other(code)
        }
    }
}
