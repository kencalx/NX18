"""The in-game menu's live settings and its Share log (front_ios.m dm_setting_live, DmGamepad.m, GameMenu.swift, LauncherSettings.swift, nvn_mtl.m), checked in the sources off the
device: Touch control size and opacity, Upscaling, Sharpening and Anti-aliasing while the game runs, why a row does nothing at the moment (front_ios.m dm_setting_why, fed by the
present's outcomes in nvn_mtl.m), and Share log.

Their plain-C rule runs in dm/gfx/tests (make live-menu: t_upscale_pick), and the gear's Duo tests in the Simulator. What none of them runs: which rows the menu offers, the Duo
harness's stubs of the host calls front_ios.m makes, the gamepad's colours made again on a change, a pick reaching the environment under the lock the present thread reads it
under, the present's outcomes written by the live present alone and read by the menu's notes, and the share sheet's snapshot copies and its iPad popover."""
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
        self.assertTrue({'DM_TOUCH_SIZE', 'DM_TOUCH_OPACITY', 'DM_PRESENT_UPSCALE', 'DM_PRESENT_SHARPEN', 'DM_POST_AA'} <= live, live)
        rows = settings_rows()
        for env in live:
            with self.subTest(env=env):
                self.assertIn(env, rows)
                self.assertIn(rows[env][1], ('choice', 'toggle'))
        self.assertNotIn('DM_UPSCALER', live, "the game's own upscaler stays a start-time setting")
        self.assertNotIn('DM_SCREEN_ASPECT', live, 'the picture shape is the game\'s, read when it starts')

    def test_the_harness_has_the_host_calls_front_ios_makes(self):   # the Duo harness links front_ios.m and DmGamepad.m alone (dm/ios/tests/duo/project.yml)
        stubs = read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m')
        for decl, home in (('void mtl_present_upscale_set(const char *mode)', self.nvn), ('void mtl_present_sharpen_set(const char *level)', self.nvn),
                           ('void mtl_present_aa_set(const char *mode)', self.nvn), ('void mtl_present_stretch(int on)', self.nvn)):
            with self.subTest(decl=decl):
                self.assertIn(decl + ';', self.front)
                self.assertIn(decl + ' {', home)
                self.assertIn(decl + ' {', stubs)
        front_h = read('dm/host/front.h')
        for decl in ('int mtl_present_fx_why(void)', 'int mtl_present_sharp_why(void)', 'int mtl_present_aa_why(void)'):   # the menu's notes (dm_setting_why)
            with self.subTest(decl=decl):
                self.assertIn(decl + ';', front_h)
                self.assertIn(decl + ' {', self.nvn)
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
        self.assertIn('int live = fx == &g_fx_present, why = fx_mode(live)', self.nvn)
        self.assertIn('[MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]', body(self.nvn, 'static int fx_mode(int live) {'))   # a pick on a GPU without the scaler stays bilinear
        setter = body(self.nvn, 'void mtl_present_sharpen_set(const char *level) {')   # Sharpening: the same rule, its own mode and pick
        self.assertIn('up_post(&g_sharp_req', setter); self.assertNotIn('g_sharp_mode', setter)
        self.assertIn('sharp_mode(live)', body(self.nvn, 'static float present_sharpen(int live, int metalfx, MTLPixelFormat pf) {'))
        self.assertIn('live = fx == &g_fx_present', body(self.nvn, 'static int present_encode_m4('))
        self.assertIn('present_pipeline(dst.pixelFormat)', body(self.nvn, 'static int present_encode_m4('))   # both pipelines are made at the first present: a pick compiles none
        self.assertIn('fs_rcas', body(self.nvn, 'static void present_pipeline(MTLPixelFormat format) {'))
        setter = body(self.nvn, 'void mtl_present_aa_set(const char *mode) {')   # Anti-aliasing: the same rule; ab is the environment's only, never a pick
        self.assertIn('up_post(&g_aa_req', setter); self.assertNotIn('g_aa_mode', setter); self.assertIn('AA_AB', setter)
        self.assertIn('aa_pipelines_start()', setter)   # a pick starts making the kernels in the background
        enc = body(self.nvn, 'static id<MTLTexture> aa_encode(')
        self.assertIn('aa_mode(live)', enc)
        self.assertIn('aa_pipelines(!live)', enc)   # the live present never waits for the compiler while it holds a drawable; a capture does
        self.assertIn('dispatch_async', body(self.nvn, 'static int aa_pipelines_start(void) {'))
        self.assertIn('aa_encode(aa, cb, src, tex, r, uvb, live)', body(self.nvn, 'static int present_encode_m4('))
        self.assertIn('&g_aa_present', body(self.nvn, 'static int present_now('))   # the live present's own state; a capture makes its own (present_offscreen_m4)
        self.assertIn('aa_state aa = {0}', body(self.nvn, 'static int present_offscreen_m4(id<MTLTexture> src, const int crop[4], id<MTLTexture> out, void (^done)(int)) {'))

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
        sharp = body(self.nvn, 'static int sharp_mode(int live) {')
        self.assertIn('front_env_copy("DM_PRESENT_SHARPEN", e, sizeof e)', sharp); self.assertNotIn('getenv(', sharp)
        aa = body(self.nvn, 'static int aa_mode(int live) {')   # ab goes through sw_mode_of with the copy, not sw_mode, whose getenv would race the menu's setenv
        self.assertIn('front_env_copy("DM_POST_AA", e, sizeof e)', aa); self.assertNotIn('getenv(', aa); self.assertIn('sw_mode_of("DM_POST_AA", e, 0)', aa)
        self.assertNotIn('sw_mode("DM_POST_AA"', self.nvn)
        # the other live settings: read on the main thread before the menu exists, or once and kept (dm_opmode), never by a host thread while the game runs
        live = set(re.findall(r'!strcmp\(env, "(DM_[A-Z0-9_]+)"\)', self.live)) - {'DM_PRESENT_UPSCALE'}
        readers = {}
        for d in ('dm/host', 'dm/gfx', 'dm/gfx/nvn', 'dm/gfx/tex', 'dm/ios/Sources'):
            for p in sorted((REPO / d).glob('*.[cm]')):
                for env in re.findall(r'getenv\("(DM_[A-Z0-9_]+)"\)', p.read_text(encoding='utf-8', errors='replace')):
                    if env in live: readers.setdefault(env, set()).add(p.name)
        self.assertNotIn('DM_PRESENT_SHARPEN', readers)   # the present thread's copy above alone; the drawable does not follow it, so startGame has no reason to read it
        self.assertNotIn('DM_POST_AA', readers)   # the same for Anti-aliasing
        self.assertEqual(readers, {'DM_PICTURE_FIT': {'front_ios.m'}, 'DM_SHOW_FPS': {'front_ios.m'}, 'DM_TOUCH_HAPTICS': {'DmGamepad.m'}, 'DM_TOUCH_SIZE': {'DmGamepad.m'},
                                   'DM_TOUCH_OPACITY': {'DmGamepad.m'}, 'DM_RUMBLE': {'haptics_apple.m'}, 'DM_OPMODE': {'hle_oe.c'}})
        self.assertIn('if (m < 0) { const char *e = getenv("DM_OPMODE");', read('dm/host/hle_oe.c'))   # once, then kept; the menu's opening asks it first (dm_pad_layout_offered)
        self.assertIn('dm_opmode() == 0', body(self.pad, 'bool dm_pad_layout_offered(int layout) {'))

    def test_a_row_that_does_nothing_says_why(self):   # GameMenu.swift greys a held or inactive row and gives every row its reason; front_ios.m knows the running game's
        menu = read('dm/ios/Sources/GameMenu.swift'); row = body(menu, 'private func gameMenuRow(_ m: LauncherModel, _ s: Setting) -> GameMenuItem {')
        for part in ('dm_setting_why(s.env)', 'dm_setting_held(s.env)', 'm.inactiveWhy(s)', 'm.reason(s)', 'm.optionInactive(s, o[0])'):
            self.assertIn(part, row)
        self.assertIn('(dm_setting_working(s.env) ? nil : m.reason(s)?.why)', row, 'MetalFX that upscaled drops the launcher\'s Ultrawide hint')
        self.assertIn('let why = greyed ?? ruled ?? live ??', row, 'a rule greying the choice made (MetalFX under Stretch) gives its reason at once, before the next present can')
        self.assertIn('let off = m.optionInactive(s, o[0])', row, 'the option chosen is greyed too while a rule greys it')
        self.assertIn('gameMenuModel?.refreshFacts()', body(menu, '@MainActor func gameMenuSections() -> [GameMenuSection] {'), 'the window the Stretch rules test, as it is now')
        self.assertIn('mtl_present_fx_why() == DM_FX_UPSCALED', body(self.front, 'bool dm_setting_working(const char *env) {'))
        self.assertNotIn('m.values[s.env] =', row, 'greying changes no choice')
        h = read('dm/ios/Sources/DmGameMenu.h')
        for decl in ('bool dm_setting_held(const char *env);', 'const char *dm_setting_why(const char *env);', 'bool dm_setting_working(const char *env);', 'int dm_gamepad_touch_hidden(void);'):
            self.assertIn(decl, h)
        self.assertIn('int dm_gamepad_touch_hidden(void) {', self.pad)
        why = body(self.front, 'const char *dm_setting_why(const char *env) {')
        live = set(re.findall(r'!strcmp\(env, "(DM_[A-Z0-9_]+)"\)', self.live))
        self.assertLessEqual(set(re.findall(r'!strcmp\(env, "(DM_[A-Z0-9_]+)"\)', why)), live, 'a note only for a row the menu shows')
        for call in ('mtl_present_fx_why()', 'mtl_present_sharp_why()', 'mtl_present_aa_why()', 'dm_gamepad_touch_hidden()', 'g_tv_mode_was', 'g_root.ultrawideStretch', 'g_root.split'):
            self.assertIn(call, why)
        whys = re.findall(r'return (?:[^;]*\? )?"([^"]+)"', why) + re.findall(r': "([^"]+)"', why)
        self.assertTrue(whys)
        for w in whys:
            self.assertLessEqual(len(w), 60, w)   # settings.py WHY_MAX: one short line
        # Picture under Ultrawide: shown (the row's question), held, and a pick refused
        self.assertIn('if (g_root.ultrawideStretch) return !value;', self.live)
        self.assertIn('g_root.ultrawideStretch', body(self.front, 'bool dm_setting_held(const char *env) {'))

    def test_the_present_outcomes_come_from_the_live_present_alone(self):   # a capture (a screenshot) has its own state and must not change the menu's notes
        enc = body(self.nvn, 'static id<MTLTexture> fx_encode(')
        self.assertIn('int live = fx == &g_fx_present', enc)
        stores = re.findall(r'(.{0,12})atomic_store_explicit\(&g_fx_why', enc)
        self.assertTrue(stores)
        for before in stores: self.assertIn('if (live) ', before)
        self.assertIn('if (why != DM_FX_UPSCALED) return nil;', enc)
        self.assertIn('fx_why(vp, cw, ch) == DM_FX_UPSCALED', body(self.nvn, 'static int fx_wanted(MTLViewport vp, NSUInteger cw, NSUInteger ch) {'))
        sharp = body(self.nvn, 'static float present_sharpen(int live, int metalfx, MTLPixelFormat pf) {')
        self.assertIn('if (live) atomic_store_explicit(&g_sharp_why, why', sharp)
        self.assertLess(sharp.index('g_sharp_why'), sharp.index('if (!level) return 0;'), 'Off says so too')
        self.assertIn('if (live) atomic_store_explicit(&g_aa_why', body(self.nvn, 'static void aa_outcome(int live, int why) {'))
        aa = body(self.nvn, 'static id<MTLTexture> aa_encode(')
        self.assertEqual(aa.count('return nil;') + 1, aa.count('aa_outcome(live, '), 'every way out says why, the smoothed one too')
        self.assertIn('aa_outcome(live, DM_AA_RAN);', aa)
        for name in ('DM_FX_OFF', 'DM_SHARP_METALFX', 'DM_AA_RAN'):
            self.assertIn(name, read('dm/host/front.h'))

    def test_share_log_snapshots_and_anchors(self):
        menu = read('dm/ios/Sources/GameMenu.swift'); share = body(menu, 'func dmShareLog(from anchor: UIView?) {')
        for part in ('"log.txt"', '"log.prev.txt"', 'temporaryDirectory', 'copyItem(at: src, to: copy)', 'UIActivityViewController(activityItems: files',
                     'popoverPresentationController', 'pop.sourceView', 'fileExists(atPath: src.path)'):
            self.assertIn(part, share)
        self.assertLess(share.index('copyItem'), share.index('UIActivityViewController'))   # the sheet gets the copies, never the log being written
        self.assertIn('{ anchor in dmShareLog(from: anchor) }', menu)   # the menu button: the UIMenu's sender, the panel's anchor (an iPad's popover points at it)
        self.assertIn('perform?(action.sender as? UIView)', body(menu, 'func uiMenuElement(_ i: GameMenuItem) -> UIMenuElement {'))
        panel = read('dm/ios/Sources/GameMenuPanel.swift')
        self.assertIn('if item.closesMenu { close(); item.perform?(anchor); return }', panel)   # the panel goes first: the share sheet and its alert are the system's
        self.assertIn('GameMenuPanelModel(anchor: button)', panel)


if __name__ == '__main__':
    unittest.main()
