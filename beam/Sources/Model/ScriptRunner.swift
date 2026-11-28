// Runs NX 18's build script and hands its JSON events over as they come (beam-design §4.2, docs/frontends.md).
// Cancelling the task sends SIGTERM, a front end's cancel: the script stops its tools and kills what is left of them 5 seconds later.
import Foundation

struct ScriptResult: Sendable, Equatable {
    var exit: ScriptExit
    var code: Int32
    var stderr: String          // always kept: an argument error or an unexpected traceback is only here
    var lastError: String?      // the last "[RED] " message, the reason a failed build gives
}

enum ScriptRunner {
    /// Runs `executable arguments…`, calling `onEvent` for every event line of stdout (on a background thread, in order). Lines that are not events are ignored.
    /// `background`: the build runs at background priority (taskpolicy -b), for builds while a game plays on the Mac (beam-design §4.2, Build QoS)
    /// `onStart`: the script's process ID once it runs (Beam lowers a running build's priority while a game plays: BuildPriority)
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil, background: Bool = false,
                    onStart: (@Sendable (Int32) -> Void)? = nil, onEvent: @escaping @Sendable (BuildEvent) -> Void) async throws -> ScriptResult {
        let p = Process()
        if background {
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy"); p.arguments = ["-b", executable.path] + arguments
        } else {
            p.executableURL = executable; p.arguments = arguments
        }
        p.environment = Self.scriptEnvironment(environment ?? ProcessInfo.processInfo.environment)
        if let directory { p.currentDirectoryURL = directory }
        p.qualityOfService = background ? .background : .utility
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let box = ProcessBox(p)
        let lastRed = LockedValue<String?>(nil)

        // both pipes are read while the script runs (a full pipe would stop it) and to their end after it: its own children may still hold them a moment
        let reader = Task.detached {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let e = BuildEvent.parse(line) else { continue }
                if case .say(let s) = e, s.isError { lastRed.set(s.text) }
                onEvent(e)
            }
        }
        let errReader = Task.detached { String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, any Error>) in
                    p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                    do {   // a Cancel that came before this point is kept by the box: the script then never starts
                        if try box.start() { onStart?(p.processIdentifier) } else { p.terminationHandler = nil; c.resume(throwing: CancellationError()) }
                    } catch { p.terminationHandler = nil; c.resume(throwing: error) }
                }
            } onCancel: { box.terminate() }
        } catch {   // it never started: end the readers, which wait for the pipes' write ends
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            _ = try? await reader.value; _ = await errReader.value
            throw error
        }
        _ = try? await reader.value
        return ScriptResult(exit: ScriptExit(code: exitCode), code: exitCode, stderr: await errReader.value, lastError: lastRed.get())
    }
}

extension ScriptRunner {
    /// The environment a build runs with: never STEAMGRIDDB_KEY, and never DM_ENTITLEMENTS, which would drop the Increased Memory Limit and Extended Virtual Addressing that every NX 18 app
    /// asks for (dm/ios/tools/build_ipa.sh); the bigger games need them, so Beam keeps them whatever the player's environment says
    static func scriptEnvironment(_ env: [String: String]) -> [String: String] {
        var e = env; e.removeValue(forKey: "DM_ENTITLEMENTS")
        e.removeValue(forKey: "STEAMGRIDDB_KEY")   // Beam's key stays in the Keychain: never in a child's environment, a command line or a log (beam-design §3.8)
        return e
    }
}

extension ScriptRunner {
    /// A script whose stdout is lines of its own (the setup script's JSON): each line to onLine as it comes, stderr kept
    static func runLines(_ executable: URL, _ arguments: [String], onLog: (@Sendable (String) -> Void)? = nil, onLine: @escaping @Sendable (String) -> Void) async throws -> ScriptResult {
        let p = Process(); p.executableURL = executable; p.arguments = arguments
        p.environment = scriptEnvironment(ProcessInfo.processInfo.environment)
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let box = ProcessBox(p)
        let reader = Task.detached { for try await l in out.fileHandleForReading.bytes.lines { onLine(l) } }
        let errReader = Task.detached { () -> String in
            var all = ""
            for try await l in err.fileHandleForReading.bytes.lines { onLog?(l); all += l + "\n" }
            return all
        }
        let code: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, any Error>) in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { if try box.start() { return }; throw CancellationError() }
                catch { p.terminationHandler = nil; try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close(); c.resume(throwing: error) }
            }
        } onCancel: { box.terminate() }
        _ = try? await reader.value
        return ScriptResult(exit: ScriptExit(code: code), code: code, stderr: (try? await errReader.value) ?? "", lastError: nil)
    }
}

/// A Process for a task's cancel handler, which runs on another thread: start() and terminate() (SIGTERM). A cancel that comes before the start is kept,
/// and the process then never starts: a task cancelled just before its tool runs (a Cancel pressed while a build reads the git stamp, say) stops it all the same
final class ProcessBox: @unchecked Sendable {
    private let p: Process
    private let lock = NSLock()
    private var cancelled = false
    init(_ p: Process) { self.p = p }
    /// Runs the process, unless a cancel came first: false then, and it never runs
    func start() throws -> Bool { try lock.withLock { if cancelled { return false }; try p.run(); return true } }
    func terminate() { lock.withLock { cancelled = true; if p.isRunning { p.terminate() } } }
}

final class LockedValue<T: Sendable>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { lock.withLock { v } }
    func set(_ n: T) { lock.withLock { v = n } }
}

/// A build's place on the Mac's cores: background priority (PRIO_DARWIN_BG) while a game plays from Beam, so the game keeps the performance cores and clocks (beam-design §3.5)
enum BuildPriority {
    /// The script and every process under it (its tools: the shader compilers do the work); tools it starts later inherit the setting from the script
    static func set(pid: Int32, background: Bool) {
        for t in [pid] + descendants(of: pid) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
            p.arguments = [background ? "-b" : "-B", "-p", String(t)]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit() }
        }
    }
    static func descendants(of pid: Int32) -> [Int32] {
        var out: [Int32] = [], todo = [pid]
        while let next = todo.popLast(), out.count < 4096 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-P", String(next)]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let kids = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
            p.waitUntilExit()
            out += kids; todo += kids
        }
        return out
    }
}
