// Home screen quick actions: holding the app's icon offers Game, Launcher and Guide (UIApplicationShortcutItems in the app's Info.plist, which build_ipa.sh writes, so they are there from the install on).
// Each acts this time only and changes no saved choice: Skip this screen next time (launcher.skip) stays as it is. Opening the app from one (main.m's SceneDelegate hands over the scene's
// connection options' item, before the root view controller appears and dmShowLauncher decides): Game starts the game at once with the saved choices, as Play or the skip would; Launcher
// shows the settings screen; Guide shows it with the game guide open (the manual when the app has one instead, About this game when it has neither) and closing it leaves the player there.
// main.m's program record (a game of several programs handing over) wins over everything, then DM_LAUNCHER from an env file or the launch, then a shortcut, then the player's skip (start).
// One chosen while the app runs (main.m's windowScene:performActionForShortcutItem:, dmShortcutPerform): on the settings screen Game plays, Launcher closes the guide, About or the folder
// picker and stays, Guide opens the guide. Once the game runs the process cannot go back to the settings screen without a restart, so Game resumes the game, and Launcher and Guide open the
// in-game menu, whose Settings screen at start brings the screen back at the next start. The guide is not shown over a running game: the in-game menu does not pause the game (nothing in the
// front end pauses it short of the app leaving the screen, front_ios.m front_ios_focus_event), so it would run on under the guide, and the guide's web view would add its memory beside the
// game's. docs/settings.md, Home screen shortcuts; docs/frontends.md, Starting a game
import Combine
import UIKit

enum LauncherShortcut: String, CaseIterable, Sendable {
    case game, launcher, guide
    static let typePrefix = "dm.shortcut."   // UIApplicationShortcutItemType: dm.shortcut.game, .launcher, .guide (build_ipa.sh)
    init?(type: String) {
        guard type.hasPrefix(Self.typePrefix) else { return nil }
        self.init(rawValue: String(type.dropFirst(Self.typePrefix.count)))
    }
    var type: String { Self.typePrefix + rawValue }
    var title: String {
        switch self {
        case .game: return "Game"
        case .launcher: return "Launcher"
        case .guide: return "Guide"
        }
    }
}

// How the app starts, decided once (LauncherShortcuts.start, for dmShowLauncher)
enum LauncherStart: Equatable, Sendable {
    case skip(String)        // no settings screen: the saved choices apply and the game starts; the log line's reason
    case show(guide: Bool)   // the settings screen, with the guide (or the manual, or About this game) open
    case playerSkip          // the player's Skip this screen next time: a controller button held while the app opens may still ask for the screen
}

enum LauncherShortcuts {
    @MainActor static var pending: LauncherShortcut?   // the shortcut the app was opened with (or one chosen before dmShowLauncher decided), until dmShowLauncher takes it
    @MainActor static var started = false               // dmShowLauncher has decided: the settings screen is up, or the game started
    @MainActor static var screenUp = false              // the settings screen is on screen (presentLauncher until Play)
    @MainActor static let requests = PassthroughSubject<LauncherShortcut, Never>()   // to the settings screen on screen (LauncherView.shortcut)
    @MainActor static var openMenu: () -> Void = { dm_gamepad_menu_open() }   // the in-game menu, over the running game (DmGamepad.m); the Duo harness's test replaces it

    @MainActor static func take() -> LauncherShortcut? {
        defer { pending = nil }
        return pending
    }

    // The start for a shortcut (nil: none) in this environment, with skipChosen the player's Skip this screen next time, and a log line when the shortcut gives way. In order:
    // - main.m's program record set DM_LAUNCHER=0 itself (no env file or the launch lists it, LauncherModel.launcherSetByEnv): a program of a game of several handing over starts
    //   without the screen, whatever else says;
    // - DM_LAUNCHER from an env file or the launch: 0 skips the screen, any other value shows it (a Guide shortcut then still opens the guide on it);
    // - a shortcut: Game skips the screen, Launcher shows it, Guide shows it with the guide open;
    // - the player's Skip this screen next time, else the screen
    nonisolated static func start(shortcut: LauncherShortcut?, environment: [String: String], skipChosen: Bool) -> (start: LauncherStart, note: String?) {
        if let v = environment["DM_LAUNCHER"], !v.isEmpty {
            guard LauncherModel.launcherSetByEnv(environment: environment) else {
                return (.skip("off (DM_LAUNCHER=0)"), shortcut.map { "launcher: shortcut \($0.title) ignored: a program of this game hands over to another (main.m's program record), which starts without the settings screen" })
            }
            let shows = v != "0"
            let note = shortcut.flatMap { s in (s != .game) == shows ? nil : "launcher: shortcut \(s.title) ignored: DM_LAUNCHER=\(v) from an env file or the launch decides" }
            return (shows ? .show(guide: shortcut == .guide) : .skip("off (DM_LAUNCHER=0)"), note)
        }
        switch shortcut {
        case .game?: return (.skip("shortcut Game: the game starts at once with the saved choices (this time only)"), nil)
        case .launcher?: return (.show(guide: false), "launcher: shortcut Launcher: the settings screen shows (this time only\(skipChosen ? "; Skip this screen next time stays on" : ""))")
        case .guide?: return (.show(guide: true), "launcher: shortcut Guide: the settings screen shows with the guide open (this time only)")
        case nil: return (skipChosen ? .playerSkip : .show(guide: false), nil)
        }
    }

    // A shortcut chosen while the app runs: to the settings screen when it is up, kept for dmShowLauncher when it has not decided yet (the player's skip waiting for a held
    // controller button), else the running game's answer. Waits (up to 5 s) for the app to be active: the system hands the shortcut over as the app comes back, and a menu or a sheet
    // presented before then may not show
    @MainActor static func perform(_ s: LauncherShortcut, waited: Int = 0) {
        if UIApplication.shared.applicationState != .active && waited < 100 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                perform(s, waited: waited + 1)
            }
            return
        }
        if screenUp { fputs("launcher: shortcut \(s.title) on the settings screen\n", stderr); requests.send(s); return }
        if !started { pending = s; fputs("launcher: shortcut \(s.title) before the settings screen decided: taken at the start\n", stderr); return }
        switch s {
        case .game: fputs("launcher: shortcut Game: the game is running; it carries on\n", stderr)
        case .launcher:
            fputs("launcher: shortcut Launcher: the game is running, and the settings screen shows only before it starts; the in-game menu opens (its Settings screen at start shows the screen at the next start)\n", stderr)
            openMenu()
        case .guide:
            fputs("launcher: shortcut Guide: the game is running, and the guide shows on the settings screen before it starts (the in-game menu does not pause the game); the in-game menu opens\n", stderr)
            openMenu()
        }
    }
}

// main.m's SceneDelegate, as the app's scene connects with a shortcut in its connection options: kept for dmShowLauncher, which decides the start once the root view controller appears
@_cdecl("dm_shortcut_cold")
public func dmShortcutCold(_ type: UnsafePointer<CChar>) {
    let t = String(cString: type)
    MainActor.assumeIsolated {   // UIKit calls the scene delegate on the main thread
        guard let s = LauncherShortcut(type: t) else { fputs("[RED] launcher: unknown shortcut \(t); the app starts as usual\n", stderr); return }
        LauncherShortcuts.pending = s
        fputs("launcher: opened from the shortcut \(s.title)\n", stderr)
    }
}

// main.m's SceneDelegate windowScene:performActionForShortcutItem:completionHandler:, while the app runs: whether the shortcut is one of ours
@_cdecl("dm_shortcut_perform")
public func dmShortcutPerform(_ type: UnsafePointer<CChar>) -> Bool {
    let t = String(cString: type)
    return MainActor.assumeIsolated {
        guard let s = LauncherShortcut(type: t) else { fputs("[RED] launcher: unknown shortcut \(t)\n", stderr); return false }
        LauncherShortcuts.perform(s)
        return true
    }
}
