"""The bundled pipeline archive's crash guard (dm/gfx/nvn/nvn_pso_guard.h): the hooks that tell it the app is away, where it sits in pso_bundle_open, the end of its window,
and its defaults, checked in the sources off the device.

Its decisions run as plain C in dm/gfx/tests/t_pso_guard.c (make pso-guard) and with a real archive in t_pso_bundle.m on an Apple-silicon Mac. What neither runs: the iOS scene's
calls (front_ios.m), the host's graceful exit (hle_lifecycle.c), which tells the guard before anything that can wait or be cut short by its 1.5 s fallback, the reasons' numbers
across the C files, the record written after the container checks and before Metal reads the archive, the prepare step's end, two early ends in a row for every game, and the
guard being on by default on iOS only."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the C function whose definition starts with header, through its closing brace"""
    i = src.index(header)
    j = src.index('{', i)
    depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth:
            return src[j:k + 1]
    raise AssertionError(header)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.guard = read('dm/gfx/nvn/nvn_pso_guard.h')
        self.nvn = read('dm/gfx/nvn/nvn_mtl.m')
        self.hle = read('dm/gfx/nvn/hle_nvn.c')
        self.why = {k: int(v) for k, v in re.findall(r'PSG_AWAY_(\w+) = (\d+)', self.guard)}

    def test_the_away_reasons_agree(self):   # hle_nvn.c passes them as numbers (it does not include the header); nvn_mtl.h documents them
        self.assertEqual(self.why, {'BACKGROUND': 1, 'INACTIVE': 2, 'EXIT': 4})
        self.assertIn(f'void dm_gfx_inactive(int on) {{ mtl_pso_guard_away({self.why["INACTIVE"]}, on); }}', self.hle)
        self.assertIn(f'void dm_gfx_exiting(void) {{ mtl_pso_guard_away({self.why["EXIT"]}, 1); }}', self.hle)
        suspend = body(self.hle, 'void dm_gfx_suspend(int on) {')
        self.assertTrue(suspend.split('\n')[1].strip().startswith(f'mtl_pso_guard_away({self.why["BACKGROUND"]}, on);'))   # first, before the waits
        h = read('dm/gfx/nvn/nvn_mtl.h')
        self.assertIn('1 the background (dm_gfx_suspend), 2 inactive (dm_gfx_inactive), 4 the graceful exit (dm_gfx_exiting)', h)
        dm = read('dm/host/dm.h')
        for f in ('void dm_gfx_inactive(int on);', 'void dm_gfx_exiting(void);'):
            self.assertIn(f, dm)

    def test_the_graceful_exit_tells_it_first(self):   # before the fallback timer and the steps that can take long (file writes, audio, the graphics drain)
        exit_ = body(read('dm/host/hle_lifecycle.c'), 'void dm_host_shutdown_then(')
        at = exit_.index('dm_gfx_exiting();')
        for later in ('dispatch_after(', 'hlecount_flush();', 'dm_rec_finish();', 'dm_cheats_exit();', 'dm_audio_suspend(1);', 'dm_gfx_suspend(1);', '_exit(0);'):
            self.assertLess(at, exit_.index(later), later)
        self.assertLess(exit_.index('atomic_exchange(&once, 1)'), at)   # once

    def test_the_scene_tells_it_active_and_inactive(self):   # resign active before the background (an app-switcher swipe), become active after it
        front = body(read('dm/ios/Sources/front_ios.m'), 'void front_ios_focus_event(int ev) {')
        cases = dict(re.findall(r'case (\d):(.*?)break;', front, re.S))
        self.assertIn('dm_gfx_inactive(1);', cases['0'])
        self.assertIn('dm_gfx_inactive(0);', cases['3'])
        self.assertIn('dm_gfx_suspend(1);', cases['1'])
        self.assertIn('dm_gfx_suspend(0);', cases['2'])
        self.assertIn('void dm_gfx_inactive(int on) { (void)on; }', read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m'))   # the harness links front_ios.m alone
        scenes = read('dm/ios/Sources/main.m')   # the scene callbacks behind the numbers
        self.assertIn('- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }', scenes)
        self.assertIn('- (void)sceneDidBecomeActive:(UIScene *)s { front_ios_focus_event(3); }', scenes)

    def test_the_record_comes_after_the_container_checks_and_before_metal(self):
        """A file arch_file_ok refuses never reaches Metal and needs no record; the record must be on disk before newArchiveWithURL, the call #640's crash came from; an archive
        Metal does not open after all is no evidence (psg_unused)"""
        open_ = body(self.nvn, 'static void pso_bundle_open(')
        ok, begin, metal = open_.index('if (!arch_file_ok(p))'), open_.index('if (!pso_guard_begin(p)) return;'), open_.index('newArchiveWithURL:')
        self.assertLess(ok, begin)
        self.assertLess(begin, metal)
        self.assertIn('if (!a) { psg_unused(&g_psg);', open_)
        self.assertEqual(self.nvn.count('pso_guard_begin(p)'), 1)

    def test_the_window_ends(self):
        """The window counts from the end of the prepare step (and of every compile of its prebuild) or of the background prebuild, then PSG_FRAMES presents"""
        warm = body(self.nvn, 'static void warm_start(void) {')
        branch = warm[warm.index('if (prepare_on()) {'):warm.index('dispatch_queue_attr_t attr')]
        self.assertRegex(branch, r'prepare_prebuild\(\); \}[^\n]*\n\s*pso_guard_prepared\(\);[^\n]*\n\s*return;')
        self.assertIn('static void pso_guard_prepared(void) { if (!atomic_load(&g_pre_running)) pso_guard_mark("the prepare step ended"); }', self.nvn)
        pre = body(self.nvn, 'static int pso_prebuild(int threads, int wait, dispatch_qos_class_t qos) {')
        done = pre[pre.index('dispatch_block_t done = ^{'):]
        self.assertLess(done.index('if (!wait) pso_guard_mark("the pipeline prebuild ended");'), done.index('g_pre_running = 0;'))   # no end falls between the two
        bg = body(self.nvn, 'static void pso_prebuild_bg(void) {')
        self.assertIn('pso_guard_mark("the prewarm ended, no prebuild")', bg)
        self.assertIn('pso_guard_mark("the prewarm ended, nothing to prebuild")', bg)
        present = body(self.nvn, 'static int present_now(const tex_t *t,')
        self.assertIn('if (atomic_load_explicit(&g_psg.watching, memory_order_relaxed)) pso_guard_frame();', present)

    def test_its_defaults(self):
        self.assertIn('#define PSO_GUARD_NEED 2\n', self.nvn)   # two early ends in a row for every game (pso_mtl4 is retired: every game reads its archive)
        self.assertNotIn('DM_GAME_PSO_MTL4', self.nvn)
        begin = body(self.nvn, 'static int pso_guard_begin(NSString *p) {')
        self.assertIn('if (!(e && *e ? strcmp(e, "0") != 0 : TARGET_OS_IPHONE)) {', begin)   # on by default on iOS only; 0 / 1 override
        self.assertIn('psg_begin(&g_psg, rec.fileSystemRepresentation, os, id_.UTF8String, PSO_GUARD_NEED)', begin)
        self.assertNotRegex(begin, r'g_psg\.(found|armed|err)')   # the verdict as psg_begin copied it under its lock, not the guard's fields
        row = next(ln for ln in read('docs/env_switches.tsv').splitlines() if ln.startswith('DM_PSO_BUNDLE_GUARD\t'))
        self.assertIn('on by default on iOS', row)
        self.assertIn('off by default on the Mac', row)

    def test_names_are_its_own(self):
        """nvn_mtl.m includes the header at the top. The Nintanium line's GPU profiler (DM_NVN_GPUPROF) had file-scope pg_ names (a pg_pass type, a g_pg int): the guard's first
        version used the same prefix, and its pg_pass function and g_pg variable broke every build of nvn_mtl.m there. Every name the header defines carries psg_ / PSG_, and
        nothing else in the files that include it defines one"""
        defined = set(re.findall(r'^(?:static inline \w+ \**|typedef struct \{[^}]*\} |#define |static const char \*const )(\w+)', self.guard, re.M))
        defined |= set(re.findall(r'\b(PSG_[A-Z0-9_]+)\s*(?:=|,|\})', self.guard))
        self.assertTrue(defined)
        for name in defined:
            self.assertRegex(name, r'^(psg_|PSG_)', name)
        for rel in ('dm/gfx/nvn/nvn_mtl.m', 'dm/gfx/tests/t_pso_bundle.m', 'dm/gfx/tests/t_pso_guard.c'):
            src = read(rel)
            for name in defined:
                n = re.escape(name)
                self.assertNotRegex(src, rf'(?m)^\s*(?:#define\s+{n}\b|typedef\b.*\b{n}\s*;|(?:static\s+)?(?:inline\s+)?[\w\s\*]+\b{n}\s*\([^;)]*\)\s*\{{)',
                                    f'{rel} defines {name}, a name of nvn_pso_guard.h')
        for var in ('g_psg', 'g_psg_why'):   # the guard's own globals in nvn_mtl.m: one definition each
            self.assertEqual(len(re.findall(rf'(?m)^static\b[^;=\n]*\b{var}\s*(?:=[^;\n]*)?;', self.nvn)), 1, var)


if __name__ == '__main__':
    unittest.main()
