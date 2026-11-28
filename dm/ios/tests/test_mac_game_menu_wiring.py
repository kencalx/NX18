"""The Mac's in-game menu (dm/mac/GameMenuMac.swift, front_mac.m, the shared GameMenu.swift and GameMenuPanel.swift, dm/host/Makefile), checked in the sources: the host builds the
menu's Swift with the bridging header, every live row the Mac's menu applies is a Mac settings row, the env lock the present thread copies under, the three ways to open it, the
input that waits while it is up and settles after, and the rows the Mac leaves out or adds.

The plain-C pieces run in dm/host/tests (t_game_menu_input, t_home_quit's tap). What none of them runs: the panel itself, which needs a window (a harness of the same sources draws
it: see docs/frontends.md, The in-game menu on the Mac)."""
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


def mac_rows():
    rows = {}
    for line in read('dm/games/settings.tsv').splitlines():
        if line.startswith('DM_'):
            c = line.split('\t')
            if 'platform:ios' not in c[4]: rows[c[0]] = c   # the Mac's list: no iPhone-only row
    return rows


class MacGameMenu(unittest.TestCase):
    def setUp(self):
        self.front = read('dm/host/front_mac.m'); self.make = read('dm/host/Makefile')
        self.menu = read('dm/ios/Sources/GameMenu.swift'); self.panel = read('dm/ios/Sources/GameMenuPanel.swift'); self.mac = read('dm/mac/GameMenuMac.swift')
        self.bridge = read('dm/mac/GameMenuMac-Bridging.h')

    def test_host_builds_and_links_the_menu(self):
        files = re.search(r'MENU_SWIFT = (.*?)\nMENU_H', self.make, re.S).group(1)
        for f in ('GameMenuMac.swift', 'GameMenu.swift', 'GameMenuPanel.swift', 'LauncherSettings.swift', 'LauncherPanel.swift', 'NX18Glass.swift'):
            self.assertIn(f, files)
        self.assertIn('-import-objc-header ../mac/GameMenuMac-Bridging.h', self.make)
        self.assertRegex(self.make, r'\$\(HOST_BIN\): \$\(HOST_OBJ\) \$\(MENU_OBJ\)')
        self.assertIn('$(MENU_OBJ) $(VPX_LIB)', self.make)
        self.assertNotIn('Launcher.swift ', files.replace('LauncherSettings.swift', '').replace('LauncherRow.swift', '').replace('LauncherPanel.swift', '').replace('LauncherFocus.swift', ''),
                         'the settings window stays out of the host')
        for name in ('dm_mac_pads_any', 'dm_mac_capture'): self.assertIn(name, self.bridge)
        self.assertIn('DmGameMenu.h', self.bridge)

    def test_nsp_and_regress_keys_take_the_swift(self):
        for script in ('scripts/build_ipa_from_nsp.py', 'scripts/regress.py'):
            src = read(script)
            self.assertIn("HOST_SWIFT_DIRS = ('dm/mac', 'dm/ios/Sources')", src, script)
            self.assertIn("'.swift'", src, script)

    def test_live_rows_are_mac_rows(self):
        live = body(self.front, 'bool dm_setting_live(const char *env, const char *value) {')
        envs = re.findall(r'!strcmp\(env, "(DM_\w+)"\)', live)
        self.assertEqual(sorted(envs), sorted(['DM_OPMODE', 'DM_PRESENT_UPSCALE', 'DM_PRESENT_SHARPEN', 'DM_POST_AA', 'DM_RUMBLE', 'DM_FULLSCREEN']))
        rows = mac_rows()
        for e in envs:
            self.assertIn(e, rows, f'{e}: the Mac has a settings row for it')
            self.assertIn(rows[e][1], ('choice', 'toggle'), f'{e}: the menu shows choices and switches only')
        self.assertIn('toggleFullScreen', live)
        for setter in ('mtl_present_upscale_set', 'mtl_present_sharpen_set', 'mtl_present_aa_set', 'dm_haptics_set_enabled', 'dm_set_opmode'): self.assertIn(setter, live)

    def test_env_lock_is_the_strong_front_env_copy(self):
        lock = body(self.front, 'int front_env_copy(const char *name, char *out, size_t cap) {')
        self.assertIn('pthread_mutex_lock(&g_env_lock)', lock)
        self.assertIn('pthread_mutex_lock(&g_env_lock); setenv(env, value, 1)', self.front)
        self.assertNotIn('__attribute__((weak)) int front_env_copy', self.front)

    def test_notes_are_shared(self):
        self.assertIn('front_setting_present_why(env, mtl_present_fx_why(), mtl_present_sharp_why(), mtl_present_aa_why(), 0)', self.front)
        self.assertIn('front_setting_present_why(env, mtl_present_fx_why(), mtl_present_sharp_why(), mtl_present_aa_why(), 1)', read('dm/ios/Sources/front_ios.m'))

    def test_three_ways_to_open(self):
        self.assertIn('hq_take_tap(&g_hq)', body(self.front, 'static void hq_poll(void) {'))
        self.assertIn('gm_open("Escape")', body(self.front, 'static int gm_key_event(NSEvent *e, int down) {'))
        self.assertRegex(self.front, r'addItemWithTitle:@"Game Menu…" action:@selector\(gameMenu:\) keyEquivalent:@","')
        self.assertIn('g_hq.no_quit = !g_hq_on', self.front, 'DM_HOME_QUIT=0 still lets a press open the menu')
        self.assertNotIn('if (!g_hq_on || !g_win || busy) return;', self.front)

    def test_input_waits_while_open_and_settles(self):
        pad_set = body(self.front, 'static void pad_set(int p, uint64_t m, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {')
        self.assertTrue(pad_set.lstrip('{ \n').startswith('if (gm_blocks_input(g_gm)) { gm_pad(p, m, lx, ly); return; }'), 'every controller path ends in pad_set')
        on_key = body(self.front, 'static void on_key(NSEvent *e, int down) {')
        self.assertIn('if (gm_key_event(e, down)) return;', on_key)
        opened = body(self.front, 'static void gm_open(const char *by) {')
        for step in ('pads_release();', 'dm_touch_set(NULL, 0)', 'push();', 'dm_front_menu_set(1, by)'): self.assertIn(step, opened)
        closed = body(self.front, 'void dm_gamepad_panel_closed(void) {')
        self.assertIn('g_gm = GM_SETTLE', closed)
        self.assertIn('gm_settle(g_gm, held)) == GM_CLOSED) pads_reread()', self.front)
        self.assertIn('gm_release();', body(self.front, 'static void input_release(void) {'))

    def test_swift_side_has_no_polling(self):
        self.assertNotIn('Timer.scheduledTimer', self.mac)
        self.assertIn('Task.sleep(for: .seconds(3600))', self.mac, 'the pad waits on its task, events come from front_mac.m')
        self.assertIn('typealias GameMenuPad = GameMenuMacPad', self.panel)
        self.assertIn('typealias GameMenuPad = LauncherGamepad', self.panel)
        for name in ('dm_mac_game_menu_open', 'dm_mac_game_menu_close', 'dm_mac_game_menu_input'):
            self.assertIn(f'@_cdecl("{name}")', self.mac)
            self.assertIn(name, self.front)

    def test_mac_rows(self):
        mac_part = self.menu[self.menu.index('@MainActor func macMoreRows()'):]
        for row in ('"screenshot"', '"log"', '"quit"', 'macExitRow()'): self.assertIn(row, mac_part)
        self.assertNotIn('"atstart"', self.menu, 'Gate at start stays in the settings window (Customize), not in the in-game menu')
        self.assertIn('NSApp.terminate(nil)', mac_part)
        self.assertRegex(self.menu, r'#else\n    let layout: GameMenuItem\? = nil')
        self.assertIn('let gameMenuTileOrder = ["DM_OPMODE", "DM_FULLSCREEN", "DM_RUMBLE"]', self.menu)
        self.assertIn('"Cheats menu › Open cheats folder"', self.menu)
        # the iPhone's rows stay
        self.assertIn('let gameMenuTileOrder = ["DM_PICTURE_FIT", "DM_OPMODE", "DM_SHOW_FPS", "DM_RUMBLE", "touch", "layout"]', self.menu)
        self.assertIn('dmShareLog(from: anchor)', self.menu)


if __name__ == '__main__':
    unittest.main()
