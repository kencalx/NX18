"""The in-game menu's live settings and the share sheet (front_ios.m dm_setting_live, DmGamepad.m, GameMenu.swift, Launcher.swift, nvn_mtl.m, hle_nvn.c), checked in the sources off the
device: Touch control size and opacity, Upscaling while the game runs, the frame-rate counter's heat / Low Power mark and Share log.

Their plain-C rules run in dm/gfx/tests (make live-menu: t_upscale_pick, t_power_mark), the frame cap's mark in t_thermal on a Mac, a pick of Upscaling on the live present in t_present_crop
on an Apple-silicon Mac, and the Picture shape default in launcher_storage_check.swift on macOS. What none of them runs: which rows the menu offers, the Duo harness's stubs of the host
calls front_ios.m makes, the gamepad's colours made again on a change, the share sheet's snapshot copies and its iPad popover, and the present thread alone restarting Automatic's count."""
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
        stubs = read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m'); hle = read('dm/gfx/nvn/hle_nvn.c')
        for decl, home in (('void mtl_present_upscale_set(const char *mode)', self.nvn), ('int dm_power_cap_now(void)', hle), ('int mtl_fx_power_hold(void)', self.nvn)):
            with self.subTest(decl=decl):
                self.assertIn(decl + ';', self.front)
                self.assertIn(decl + ' {', home)
                self.assertIn(decl + ' {', stubs)
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

    def test_only_the_present_thread_restarts_automatic(self):   # the main thread posts a pick; fx_encode (the present thread) restarts g_fx_auto
        setter = body(self.nvn, 'void mtl_present_upscale_set(const char *mode) {')
        self.assertNotIn('g_fx_auto', setter); self.assertIn('up_post(&g_fx_req', setter)
        restarts = [m.start() for m in re.finditer(r'g_fx_auto\.left = FX_AUTO_SETTLE', self.nvn)]
        encode = self.nvn.index('static id<MTLTexture> fx_encode(')
        self.assertEqual(len(restarts), 1); self.assertGreater(restarts[0], encode)
        self.assertIn('fx_mode(fx == &g_fx_present ? &fresh : NULL)', self.nvn)   # a capture takes no pick
        self.assertIn('[MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]', body(self.nvn, 'static int fx_mode(int *fresh) {'))   # a pick on a GPU without the scaler stays bilinear

    def test_share_log_snapshots_and_anchors(self):
        menu = read('dm/ios/Sources/GameMenu.swift'); share = body(menu, '@MainActor func dmShareLog(from anchor: UIView?) {')
        for part in ('"log.txt"', '"log.prev.txt"', '"run_layouts.txt"', '"metrics"', 'temporaryDirectory', 'copyItem(at: src, to: copy)', 'UIActivityViewController(activityItems: files',
                     'popoverPresentationController', 'pop.sourceView', 'fileExists(atPath: src.path)'):
            self.assertIn(part, share)
        self.assertLess(share.index('copyItem'), share.index('UIActivityViewController'))   # the sheet gets the copies, never the log being written
        self.assertIn('dmShareLog(from: action.sender as? UIView)', menu)
        self.assertIn('dmShareLog(from: nil)', read('dm/ios/Sources/Launcher.swift'))
        self.assertIn('UIActivityViewController', share); self.assertNotIn('UIActivityViewController', read('dm/ios/Sources/Launcher.swift'), 'one share sheet, in one place')

    def test_the_counter_mark_costs_nothing_per_frame(self):   # read with the count once a second; written by the host only when it changes
        label = body(self.front, 'static UILabel *front_ios_fps_label(void) {')
        self.assertIn('scheduledTimerWithTimeInterval:1.0', label); self.assertIn('fps_show(l, count);', label)
        hle = read('dm/gfx/nvn/hle_nvn.c')
        self.assertIn('if (atomic_load_explicit(&g_cap_mark, memory_order_relaxed) != v) atomic_store_explicit', hle)
        self.assertIn('static int fx_held_note(int h) { static int was; if (h != was)', self.nvn)


if __name__ == '__main__':
    unittest.main()
