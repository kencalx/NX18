// Setting up this Mac from Beam (beam-design §3.1): Beam runs NX 18's own setup script (scripts/release/nx18-setup.sh, a copy inside Beam) with --json, shows
// what it reports as a checklist, and runs only the fixes the player approves (--only), one at a time or all at once. The script asks nothing then, never uses
// sudo and never changes a folder that holds the player's own work; Xcode itself stays the player's download from Apple
import Foundation
import Observation

/// Which NX 18 Beam sets up: the X2.0 preview until X2.0 is released, then its release tag ("System X2.0")
enum BeamSystem {
    static let ref = "x2-preview"
    static let shown = "X2.0 preview"
}

struct SetupEvent: Decodable, Sendable, Equatable {
    var ev: String
    var name: String?, state: String?, text: String?, id: String?, question: String?, answer: String?, cmd: String?, msg: String?
    var detail: [String]?, ready: Bool?, missing: Int?, dir: String?, ref: String?
    static func parse(_ line: String) -> SetupEvent? { try? JSONDecoder().decode(SetupEvent.self, from: Data(line.utf8)) }
}

@MainActor @Observable final class SetupModel {
    struct Item: Identifiable, Equatable { let id = UUID(); var state: String; var text: String; var section: String }
    struct Fix: Identifiable, Equatable { var id: String; var question: String }
    var items: [Item] = []
    var fixes: [Fix] = []
    var log: [String] = []
    var stopped: String?
    var ready = false
    var running: String?             // "checking", or the fixes being made
    var checked = false
    private var section = ""

    /// The setup script: the copy inside Beam (it must work before NX 18 is on the Mac), else the one in a checkout next to Beam's sources
    static var script: URL? {
        if let u = Bundle.main.url(forResource: "nx18-setup", withExtension: "sh") { return u }
        return nil
    }
    var xcodeMissing: Bool { items.contains { $0.state == "missing" && $0.text.localizedCaseInsensitiveContains("xcode") && !$0.text.localizedCaseInsensitiveContains("metal") } }

    func check(folder: URL) async {
        running = "checking"
        items = []; fixes = []; stopped = nil
        await run(["--check", "--json", "--dir", folder.path, "--ref", BeamSystem.ref])
        running = nil; checked = true
    }
    /// The fixes the player approved, then a fresh check (a clone makes the virtualenv and modules fixable)
    func fix(_ ids: [String], folder: URL) async {
        guard !ids.isEmpty else { return }
        running = ids.joined(separator: ", ")
        log.append("Fixing: \(ids.joined(separator: ", "))")
        await run(["--json", "--only", ids.joined(separator: ","), "--dir", folder.path, "--ref", BeamSystem.ref], keepItems: false)
        await check(folder: folder)
    }

    private func run(_ args: [String], keepItems: Bool = true) async {
        guard let script = Self.script else { stopped = "Beam's copy of the setup script is missing. Reinstall Beam."; return }
        section = ""
        do {
            _ = try await ScriptRunner.runLines(URL(fileURLWithPath: "/bin/bash"), [script.path] + args,
                                                onLog: { [weak self] l in Task { @MainActor in self?.appendLog(l) } },   // the commands' own output, live
                                                onLine: { [weak self] line in Task { @MainActor in self?.take(line, keepItems: keepItems) } })
        } catch { stopped = "The setup script could not be started: \(error.localizedDescription)" }
        try? await Task.sleep(for: .milliseconds(50))   // the last lines' main-actor updates
    }
    private func appendLog(_ l: String) { log.append(l); if log.count > 400 { log.removeFirst(log.count - 400) } }
    private func take(_ line: String, keepItems: Bool) {
        guard let e = SetupEvent.parse(line) else { appendLog(line); return }
        switch e.ev {
        case "section": section = e.name ?? ""
        case "item": if keepItems, let s = e.state, let t = e.text { items.append(Item(state: s, text: t, section: section)) }
        case "fixable": if let id = e.id, let q = e.question, !fixes.contains(where: { $0.id == id }) { fixes.append(Fix(id: id, question: q)) }
        case "run": if let c = e.cmd { log.append("$ " + c) }
        case "ask": if let q = e.question, let a = e.answer { log.append("\(q) \(a)") }
        case "info": if let t = e.text { log.append(t) }
        case "stop": stopped = ([e.msg ?? "The setup stopped."] + (e.detail ?? [])).joined(separator: " ")
        case "done": ready = e.ready ?? false
        default: break
        }
    }
}
