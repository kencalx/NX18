// Plays a built Mac app from Beam (beam-design §3.5): the game starts at once with DM_LAUNCHER=0 (the player chose settings already),
// builds drop to background priority while it runs, and its exit code says how it ended
import Foundation

enum GameEnd: Sendable, Equatable {
    case quit                      // 0
    case gpuLost                   // 70: macOS took the GPU away
    case crashed(Int32)            // 134 (an abort) or a signal
    case other(Int32)

    init(status: Int32, reason: Process.TerminationReason) {
        if reason == .uncaughtSignal { self = .crashed(status); return }
        self = switch status { case 0: .quit; case 70: .gpuLost; case 134: .crashed(134); default: .other(status) }
    }
    var message: String? {
        switch self {
        case .quit: nil
        case .gpuLost: "macOS took the graphics processor away from the game (for example after the Mac slept or a display changed), so it ended. Start it again."
        case .crashed: "The game stopped unexpectedly. Share its log so the problem can be looked at."
        case .other(let c): "The game ended with code \(c)."
        }
    }
}

enum GamePlayer {
    /// The executable inside a Mac app (its Info.plist's CFBundleExecutable)
    static func executable(of app: URL) -> URL? {
        guard let b = Bundle(url: app), let exe = b.executableURL, FileManager.default.isExecutableFile(atPath: exe.path) else { return nil }
        return exe
    }

    /// Runs the app's executable until the game ends. `onStart` gets its process ID
    static func play(_ app: URL, extraEnvironment: [String: String] = [:], onStart: @escaping @Sendable (Int32) -> Void = { _ in }) async throws -> GameEnd {
        guard let exe = executable(of: app) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: app.path]) }
        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnvironment { env[k] = v }
        env["DM_LAUNCHER"] = "0"   // no settings window (the Gate), whatever else is set: Beam's Play starts the game at once. Set here, in the launch environment, it wins over
                                   // the game's env.txt files and its "Show this window at launch" (dm/mac/launcher.c: env files never replace a set variable; the window is decided before saved choices)
        env["DM_STARTED_BY"] = "beam"   // the game's in-game menu reads it: Exit and return to Beam quits the game and brings Beam (Home) to the front, not the game's own window
                                        // (dm/ios/Sources/GameMenu.swift MacExitTarget)
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { c in
            p.terminationHandler = { c.resume(returning: GameEnd(status: $0.terminationStatus, reason: $0.terminationReason)) }
            do { try p.run(); onStart(p.processIdentifier) } catch { p.terminationHandler = nil; c.resume(throwing: error) }
        }
    }
}
