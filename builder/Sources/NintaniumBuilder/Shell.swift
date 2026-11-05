import Foundation
#if canImport(Glibc)
import Glibc   // killpg (Darwin comes with Foundation)
#endif

/// One line a command wrote, on stdout or stderr.
enum OutputLine: Sendable {
    case out(String)
    case err(String)
}

struct CommandResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
    /// The last non-empty line of stderr, else of stdout: what to show when the command failed.
    var reason: String {
        let pick = { (s: String) in s.split(separator: "\n").last.map(String.init) }
        return pick(stderr) ?? pick(stdout) ?? "exit code \(status)"
    }
}

/// Splits a pipe's bytes into lines.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let emit: @Sendable (String) -> Void
    init(_ emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let i = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...i)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func finish() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}

/// A command that is running: its lines in order, then the end of the stream when its stdout and stderr are both read to their end (its status: after waitUntilExit).
final class RunningCommand: @unchecked Sendable {
    let process: Process
    let lines: AsyncStream<OutputLine>
    init(process: Process, lines: AsyncStream<OutputLine>) { self.process = process; self.lines = lines }
    /// Stops it the way Ctrl-C would (the build script exits with 130 and keeps what it can reuse): SIGINT to its whole process group, which Process makes the child lead
    /// (env execs the tool, so the group's ID is its pid), so a script's own children get it too (bash waits for its foreground child and goes on when only bash gets it).
    /// killpg fails when the child leads no group (ESRCH): then the child alone, as before. Its EPERM while the group holds a zombie comes after the live members were signalled,
    /// so the child is not signalled twice then (a second SIGINT would cut the build script's own clean-up short, as Ctrl-C pressed twice does).
    func interrupt() {
        guard process.isRunning else { return }
        if killpg(process.processIdentifier, SIGINT) != 0 && errno == ESRCH { process.interrupt() }
    }
    var status: Int32 { process.isRunning ? -1 : process.terminationStatus }
}

enum Shell {
    /// The environment for the tools: a GUI app starts with a short PATH, so Homebrew's, the .NET SDK's and the usual folders are added in front.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/share/dotnet", "\(home)/.dotnet/tools", "\(home)/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Starts a tool found on PATH (through /usr/bin/env).
    static func start(_ tool: String, _ args: [String], cwd: URL? = nil, env extra: [String: String] = [:]) throws -> RunningCommand {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        var env = environment
        for (k, v) in extra { env[k] = v }
        p.environment = env
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let (stream, cont) = AsyncStream<OutputLine>.makeStream()
        let so = LineSplitter { cont.yield(.out($0)) }
        let se = LineSplitter { cont.yield(.err($0)) }
        try p.run()
        // Each pipe is read to its end on a thread of its own, and the stream ends once both are read: a handler that drains the pipes when the process exits races the
        // readability handlers still running, which lost and reordered lines. The readers start after run(), so a launch that failed leaves none blocked on a pipe
        let group = DispatchGroup()
        for (h, s) in [(out.fileHandleForReading, so), (err.fileHandleForReading, se)] {
            group.enter()
            Thread.detachNewThread {
                while true { let d = h.availableData; if d.isEmpty { break }; s.feed(d) }
                s.finish(); group.leave()
            }
        }
        group.notify(queue: .global()) { cont.finish() }
        return RunningCommand(process: p, lines: stream)
    }

    /// Runs a tool to its end and collects its output; onLine sees each line as it comes.
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:],
                    onLine: (@MainActor (OutputLine) -> Void)? = nil, started: (@MainActor (RunningCommand) -> Void)? = nil) async -> CommandResult {
        let cmd: RunningCommand
        do { cmd = try start(tool, args, cwd: cwd, env: env) } catch {
            return CommandResult(status: -1, stdout: "", stderr: "cannot start \(tool): \(error.localizedDescription)")
        }
        await started?(cmd)
        var out = "", err = ""
        for await line in cmd.lines {
            switch line {
            case .out(let s): out += s + "\n"
            case .err(let s): err += s + "\n"
            }
            await onLine?(line)
        }
        cmd.process.waitUntilExit()
        return CommandResult(status: cmd.process.terminationStatus, stdout: out, stderr: err)
    }
}
