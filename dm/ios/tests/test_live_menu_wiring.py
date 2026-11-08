"""The in-game menu's live settings and its Share log (front_ios.m dm_setting_live, DmGamepad.m, GameMenu.swift, LauncherSettings.swift, nvn_mtl.m), checked in the sources off the
device: Touch control size and opacity, Upscaling while the game runs, and Share log.

Their plain-C rule runs in dm/gfx/tests (make live-menu: t_upscale_pick), and the gear's Duo tests in the Simulator. What none of them runs: which rows the menu offers, the Duo
harness's stubs of the host calls front_ios.m makes, the gamepad's colours made again on a change, a pick reaching the environment under the lock the present thread reads it
under, and the share sheet's snapshot copies and its iPad popover."""
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


def settings_rows():
    rows = {}
    for line in read('dm/games/settings.tsv').splitlines():
        if line.startswith('DM_'):
            c = line.split('\t'); rows[c[0]] = c
    return rows


class LiveMenu(unittest.TestCase):
    def setUp(self):
        self.front = read('dm/ios/Sources/front_ios.m'); self.pad = read('dm/ios/Sources/DmGamepad.m'); self.nvn = read('dm/gfx/nvn/nvn_mtl.m')
        self.live = body(self.front, 'bool dm_setting_live(const char *env, const char *value) {')

    def test_every_live_setting_is_a_menu_row(self):   # GameMenu.swift lists the choice and toggle rows dm_setting_live answers for
        live = set(re.findall(r'!strcmp\(env, "(DM_[A-Z0-9_]+)"\)', self.live))
        self.assertTrue({'DM_TOUCH_SIZE', 'DM_TOUCH_OPACITY', 'DM_PRESENT_UPSCALE'} <= live, live)
        rows = settings_rows()
        for env in live:
            with self.subTest(env=env):
                self.assertIn(env, rows)
                self.assertIn(rows[env][1], ('choice', 'toggle'))
        self.assertNotIn('DM_UPSCALER', live, "the game's own upscaler stays a start-time setting")
        self.assertNotIn('DM_SCREEN_ASPECT', live, 'the picture shape is the game\'s, read when it starts')

    def test_the_harness_has_the_host_calls_front_ios_makes(self):   # the Duo harness links front_ios.m and DmGamepad.m alone (dm/ios/tests/duo/project.yml)
        stubs = read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m')
        for decl, home in (('void mtl_present_upscale_set(const char *mode)', self.nvn), ('void mtl_present_stretch(int on)', self.nvn)):
            with self.subTest(decl=decl):
                self.assertIn(decl + ';', self.front)
                self.assertIn(decl + ' {', home)
                self.assertIn(decl + ' {', stubs)
        self.assertIn('int front_web_touch(void) {', stubs)   # DmGamepad.m calls it; web_apple.m is not in the harness
        h = read('dm/ios/Sources/DmGameMenu.h')
        for decl in ('void dm_gamepad_touch_look(const char *env, const char *value);', 'double dm_gamepad_size(void);'):
            self.assertIn(decl, h); self.assertIn(decl[:-1] + ' {', self.pad)

    def test_the_gamepad_remakes_its_colours_and_every_layer_takes_them(self):   # a live change cannot rely on colours made once
        self.assertNotIn('dispatch_once', body(self.pad, '- (instancetype)initWithFrame:(CGRect)f {'))
        opacity = body(self.pad, '- (void)setTouchOpacity:(CGFloat)o {')
        for part in ('make_colors(o)', '_key[b].strokeColor', '_ring.fillColor', '_knob.sublayers', '[self refresh]'): self.assertIn(part, opacity)
        self.assertIn('* g_touch_size', body(self.pad, '- (CGFloat)u {'))   # hit areas and drawing share u
        rows = settings_rows()
        ranges = {'DM_TOUCH_SIZE': (0.5, 1), 'DM_TOUCH_OPACITY': (0.1, 2)}
        for env, (lo, hi) in ranges.items():
            self.assertIn(f'touch_value("{env}", getenv("{env}"), {lo:g}, {hi:g})', self.pad)
            values = [float(v.split('=')[0]) for v in rows[env][2].split(',')]
            self.assertTrue(all(lo <= v <= hi for v in values), env)
            self.assertEqual(rows[env][3], '1', 'the default is the look the controls always had')

    def test_a_pick_is_taken_by_the_live_present_alone(self):   # the main thread posts a pick; the live present takes it, a capture reads the mode in force
        setter = body(self.nvn, 'void mtl_present_upscale_set(const char *mode) {')
        self.assertIn('up_post(&g_fx_req', setter); self.assertNotIn('g_fx_mode', setter)
        self.assertIn('fx_mode(fx == &g_fx_present)', self.nvn)
        self.assertIn('[MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]', body(self.nvn, 'static int fx_mode(int live) {'))   # a pick on a GPU without the scaler stays bilinear

    def test_a_pick_reaches_the_environment_under_the_lock_the_present_thread_reads_it_under(self):   # setenv rewrites or reallocates a value another thread's getenv points at
        swift = read('dm/ios/Sources/LauncherSettings.swift'); menu = read('dm/ios/Sources/GameMenu.swift')
        self.assertNotIn('setenv', body(swift, 'func choose(_ s: Setting, _ v: String) -> Bool {'))   # the model saves; the menu sets the environment
        self.assertIn('func pick(_ v: String) { if m.choose(s, v) { dm_setting_env(s.env, v) }; _ = dm_setting_live(s.env, v) }', menu)
        self.assertIn('void dm_setting_env(const char *env, const char *value);', read('dm/ios/Sources/DmGameMenu.h'))
        setter, copier = body(self.front, 'void dm_setting_env(const char *env, const char *value) {'), body(self.front, 'int front_env_copy(const char *name, char *out, size_t cap) {')
        for b, call in ((setter, 'setenv(env, value, 1)'), (copier, 'getenv(name)')):
            self.assertLess(b.index('pthread_mutex_lock(&g_env_lock)'), b.index(call)); self.assertLess(b.index(call), b.index('pthread_mutex_unlock(&g_env_lock)'))
        self.assertIn('int front_env_copy(const char *name, char *out, size_t cap);', read('dm/host/front.h'))
        self.assertIn('__attribute__((weak)) int front_env_copy(const char *name, char *out, size_t cap) {', self.nvn)   # the Mac and the graphics unit tests link without the iPhone's
        mode = body(self.nvn, 'static int fx_mode(int live) {')
        self.assertIn('front_env_copy("DM_PRESENT_UPSCALE", e, sizeof e)', mode); self.assertNotIn('getenv(', mode)
        # the other live settings: read on the main thread before the menu exists, or once and kept (dm_opmode), never by a host thread while the game runs
        live = set(re.findall(r'!strcmp\(env, "(DM_[A-Z0-9_]+)"\)', self.live)) - {'DM_PRESENT_UPSCALE'}
        readers = {}
        for d in ('dm/host', 'dm/gfx', 'dm/gfx/nvn', 'dm/gfx/vk', 'dm/gfx/gl', 'dm/gfx/tex', 'dm/ios/Sources'):
            for p in sorted((REPO / d).glob('*.[cm]')):
                for env in re.findall(r'getenv\("(DM_[A-Z0-9_]+)"\)', p.read_text(encoding='utf-8', errors='replace')):
                    if env in live: readers.setdefault(env, set()).add(p.name)
        self.assertEqual(readers, {'DM_PICTURE_FIT': {'front_ios.m'}, 'DM_SHOW_FPS': {'front_ios.m'}, 'DM_TOUCH_HAPTICS': {'DmGamepad.m'}, 'DM_TOUCH_SIZE': {'DmGamepad.m'},
                                   'DM_TOUCH_OPACITY': {'DmGamepad.m'}, 'DM_RUMBLE': {'haptics_apple.m'}, 'DM_OPMODE': {'hle_oe.c'}})
        self.assertIn('if (m < 0) { const char *e = getenv("DM_OPMODE");', read('dm/host/hle_oe.c'))   # once, then kept; the menu's opening asks it first (dm_pad_layout_offered)
        self.assertIn('dm_opmode() == 0', body(self.pad, 'bool dm_pad_layout_offered(int layout) {'))

    def test_share_log_snapshots_and_anchors(self):
        menu = read('dm/ios/Sources/GameMenu.swift'); share = body(menu, 'func dmShareLog(from anchor: UIView?) {')
        for part in ('"log.txt"', '"log.prev.txt"', 'temporaryDirectory', 'copyItem(at: src, to: copy)', 'UIActivityViewController(activityItems: files',
                     'popoverPresentationController', 'pop.sourceView', 'fileExists(atPath: src.path)'):
            self.assertIn(part, share)
        self.assertLess(share.index('copyItem'), share.index('UIActivityViewController'))   # the sheet gets the copies, never the log being written
        self.assertIn('dmShareLog(from: action.sender as? UIView)', menu)


if __name__ == '__main__':
    unittest.main()
