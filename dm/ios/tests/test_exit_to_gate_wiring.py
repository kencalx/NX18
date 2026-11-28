"""Exit and return to Gate (the owner, 2026-11-27): the in-game menu's More row that replaced Gate at start, checked in the sources. The row opens a confirmation page of the panel
(GameMenu.swift GameMenuExit, GameMenuPanel.swift): Exit the game? / Progress since your last save is lost., Exit to Gate in the second accent and Keep Playing, which has the focus
and, like B, goes back without exiting. On the iPhone and iPad the game ends the way oe::ExecuteProgram's hand-over ends it (front_ios.m dm_exit_to_gate) and the Gate shows at the
next start, once (launcher.gateNext: set before the exit, honored over the skips, taken away as the Gate shows); a notification brings the app back only where notifications are
already allowed. On the Mac the game quits as the Quit row quits it, then the launcher opens the app again at its settings window (launcher.c), or Beam comes to the front after a
start from Beam (GamePlayer.swift's DM_STARTED_BY=beam).

What runs elsewhere: LauncherShortcuts.start and the panel's page in the Duo harness (DuoShortcutTests, DuoLauncherTests, DuoGameMenuPanelTests), the Mac window's decision in
mac_guide_check.swift (test_mac_guide.py), Beam's marker in beam/Tests (PlayTests)."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


class ExitToGate(unittest.TestCase):
    def setUp(self):
        self.menu = read('dm/ios/Sources/GameMenu.swift'); self.panel = read('dm/ios/Sources/GameMenuPanel.swift')
        self.front = read('dm/ios/Sources/front_ios.m'); self.settings = read('dm/ios/Sources/LauncherSettings.swift')
        self.shortcuts = read('dm/ios/Sources/LauncherShortcuts.swift'); self.launcher = read('dm/ios/Sources/Launcher.swift')

    def test_row_replaces_gate_at_start(self):
        self.assertIn('static let title = "Exit and return to Gate", note = "Ends the game; unsaved progress is lost"', self.menu)
        self.assertNotIn('title: "Gate at start"', self.menu, 'Gate at start stays on the Gate (Skip this screen next time), not in the in-game menu')
        self.assertIn('let gameMenuMoreIDs: Set<String> = ["screenshot", "record", GameMenuExit.rowID, "share"]', self.menu)
        self.assertIn('let gameMenuMoreSummary = "Screenshot, Recording, Exit to Gate, Share log"', self.menu)
        self.assertIn('GameMenuExit.make { dm_exit_to_gate() }', body(self.menu, '@MainActor func settingsAtStartRow('))
        self.assertIn('void dm_exit_to_gate(void);', read('dm/ios/Sources/DmGameMenu.h'))
        self.assertIn('Customize ends with Gate at start', self.launcher, 'the Gate keeps its own choice')

    def test_confirmation_page(self):
        self.assertIn('static let question = "Exit the game?", warning = "Progress since your last save is lost."', self.menu)
        make = body(self.menu, '@MainActor static func make(')
        self.assertIn('yes yesTitle: String = "Exit to Gate"', self.menu)
        self.assertIn('title: "Keep Playing"', make)
        self.assertRegex(make, r'id: Self\.yesID, title: yesTitle, symbol: "[^"]+", closesMenu: true\) \{ _ in exit\(\) \}', 'only Exit to Gate exits, the panel closed first')
        self.assertIn('kind: .submenu([GameMenuSection(id: Self.rowID + ".confirm", inline: false, items: [leave, stay])])', make, 'the row itself only opens the page')
        # the panel: the page's head, the focus on Keep Playing, Keep Playing going back, B going back, the coral Exit
        self.assertIn('case .submenu(let s) where id == GameMenuExit.rowID: return Page(id: id, title: GameMenuExit.question, subtitle: GameMenuExit.warning', self.panel)
        activate = body(self.panel, 'func activate(_ item: GameMenuItem)')
        self.assertIn('focus = GameMenuExit.noID', activate)
        self.assertIn('AccessibilityNotification.Announcement("\\(GameMenuExit.question) \\(GameMenuExit.warning)").post()', activate, 'VoiceOver hears the question')
        self.assertLess(activate.index('if item.id == GameMenuExit.noID { back(); return }'), activate.index('if item.closesMenu'), 'Keep Playing goes back, nothing else')
        self.assertIn('case .b: back()', body(self.panel, 'func handle(_ e: LauncherPadEvent)'))
        self.assertIn('private var coral: Bool { item.id == GameMenuExit.yesID }', self.panel)
        self.assertIn('foregroundStyle(coral ? MenuColor.second : MenuColor.text)', self.panel)

    def test_ios_exit_follows_the_handoff(self):
        ex = body(self.front, 'void dm_exit_to_gate(void)')
        self.assertIn('kGateNext = @"launcher.gateNext"', self.front)
        self.assertIn('nonisolated static let gateNextKey = "launcher.gateNext"', self.settings, 'the same key on both sides')
        # the flag first, written through, then the hand-over's order: the archive's write, the notice, 1.5 s, the notification, the graceful exit
        self.assertIn('static _Atomic int once; if (atomic_exchange(&once, 1)) return;', ex.split('setBool:YES')[0], 'once: the menu can open again over the notice')
        steps = ['setBool:YES forKey:kGateNext', 'synchronize', 'dm_gfx_quit_begin();', 'notify_allowed()', 'handoff_notice(', 'usleep(1500 * 1000);', 'addNotificationRequest:', 'dm_host_shutdown("Exit and return to Gate");']
        at = [ex.index(s) for s in steps]
        self.assertEqual(at, sorted(at), 'in this order')
        self.assertIn('@"Open the app again to return to the Gate."', ex)
        self.assertIn('t.body = @"Tap to return to the Gate"', ex)
        self.assertIn('triggerWithTimeInterval:1.0', ex)
        self.assertIn('if (notify) {', ex, 'the notification only with notifications already allowed')
        self.assertNotIn('requestAuthorization', ex, 'never asks for notifications here')
        self.assertIn('dispatch_get_global_queue', ex, 'off the main thread: the notice draws there while this waits')
        # one plain log line, no names or paths
        line = re.search(r'LOG\("front end: Exit and return to Gate[^"]*"\);', ex)
        self.assertIsNotNone(line); self.assertNotIn('%', line.group(0))
        # the next start: the notification gone
        setup = body(self.front, 'static void front_ios_notify_setup(void) {')
        self.assertLess(setup.index('removeDeliveredNotificationsWithIdentifiers:@[kGateNote]'), setup.index('if (!multi_program()) return;'), 'for an app of one program too')
        # the Duo harness links front_ios.m: its stubs have what the exit calls
        self.assertIn('void dm_gfx_quit_begin(void) {}', read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m'))

    def test_flag_honored_then_cleared(self):
        start = body(self.shortcuts, 'nonisolated static func start(')
        self.assertIn('gateNext: Bool = false', self.shortcuts)
        self.assertLess(start.index('main.m\'s program record'), start.index('if gateNext { return (.show(guide: shortcut == .guide)'), 'the program record still wins')
        self.assertLess(start.index('if gateNext'), start.index('let shows = v != "0"'), 'over DM_LAUNCHER from an env file')
        self.assertLess(start.index('if gateNext'), start.index('switch shortcut {'), 'over the Game shortcut and the player\'s skip')
        self.assertIn('gateNext: LauncherModel.gateNext())', self.launcher)
        present = body(self.launcher, '@MainActor private func presentLauncher(')
        self.assertTrue(present.lstrip('{\n ').startswith('if !checkAtStart { LauncherModel.clearGateNext() }'), 'taken away as the Gate shows, before the welcome')
        clear = body(self.settings, 'nonisolated static func clearGateNext(')
        self.assertIn('defaults.removeObject(forKey: gateNextKey)', clear)

    def test_mac(self):
        mac = self.menu[self.menu.index('@MainActor func macMoreRows()'):]
        self.assertIn('return [shot, macExitRow(), log, quit]', mac, 'Quit stays')
        self.assertIn('nonisolated static func of(_ environment: [String: String]) -> MacExitTarget { environment["DM_STARTED_BY"] == "beam" ? .beam : .gate }', mac)
        ex = body(mac, '@MainActor func macExitToGate()')
        self.assertIn('runningApplications(withBundleIdentifier: MacExitTarget.beamBundleID)', ex)
        self.assertIn('static let beamBundleID = "org.nx18.beam"', mac)
        self.assertIn('BEAM_BUNDLE_ID = org.nx18.beam', read('beam/Config/Beam.xcconfig'))
        self.assertIn('UserDefaults.standard.set(true, forKey: LauncherModel.gateNextKey)', ex)
        self.assertIn('CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)', ex)
        self.assertTrue(ex.rstrip('}\n ').endswith('NSApp.terminate(nil)'), 'the same orderly quit as the Quit row')
        c = read('dm/mac/launcher.c')
        self.assertIn('CFPreferencesGetAppBooleanValue(CFSTR("launcher.gateNext")', c)
        self.assertIn('if (WEXITSTATUS(status) == 0 && gate_next()) reopen_at_gate(contents);', c)
        self.assertLess(c.index('save_sync_after_exit(getenv("DM_SAVE"), id)'), c.index('reopen_at_gate(contents);\n'), 'after the save went to the cloud')
        self.assertIn('char *open_argv[] = {"open", "-n", app, NULL};', c)
        self.assertIn('if (!window && gate_next()) { window = 1;', c)
        sw = read('dm/mac/Launcher.swift')
        self.assertIn('gateNext || optionHeld || windowShow != false', sw)
        lb = body(sw, 'public func dmMacLauncher()')
        self.assertLess(lb.index('LauncherModel.clearGateNext()'), lb.index('guard let url'), 'taken away whatever the start does')
        gp = read('beam/Sources/Model/GamePlayer.swift')
        self.assertIn('env["DM_STARTED_BY"] = "beam"', gp)


if __name__ == '__main__':
    unittest.main()
