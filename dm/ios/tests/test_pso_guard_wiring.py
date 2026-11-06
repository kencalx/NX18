"""The bundled pipeline archive's crash guard (dm/gfx/nvn/nvn_pso_guard.h): the hooks that tell it the app is away, and its defaults, checked in the sources off the device.

Its decisions run as plain C in dm/gfx/tests/t_pso_guard.c (make pso-guard) and with a real archive in t_pso_bundle.m on an Apple-silicon Mac. What neither runs: the iOS scene's
calls (front_ios.m), the host's graceful exit (hle_lifecycle.c), which tells the guard before anything that can wait or be cut short by its 1.5 s fallback, the reasons' numbers
across the C files, the profile's pso_mtl4 as the number of early ends in a row, and the guard being on by default on iOS only."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the C function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.guard = read('dm/gfx/nvn/nvn_pso_guard.h'); self.nvn = read('dm/gfx/nvn/nvn_mtl.m'); self.hle = read('dm/gfx/nvn/hle_nvn.c')
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
        for f in ('void dm_gfx_inactive(int on);', 'void dm_gfx_exiting(void);'): self.assertIn(f, dm)

    def test_the_graceful_exit_tells_it_first(self):   # before the fallback timer and the steps that can take long (file writes, audio, the graphics drain)
        exit_ = body(read('dm/host/hle_lifecycle.c'), 'void dm_host_shutdown_then(')
        at = exit_.index('dm_gfx_exiting();')
        for later in ('dispatch_after(', 'hlecount_flush();', 'dm_rec_finish();', 'dm_cheats_exit();', 'dm_audio_suspend(1);', 'dm_gfx_suspend(1);', '_exit(0);'):
            self.assertLess(at, exit_.index(later), later)
        self.assertLess(exit_.index('atomic_exchange(&once, 1)'), at)   # once

    def test_the_scene_tells_it_active_and_inactive(self):   # resign active before the background (an app-switcher swipe), become active after it
        front = body(read('dm/ios/Sources/front_ios.m'), 'void front_ios_focus_event(int ev) {')
        cases = dict(re.findall(r'case (\d):(.*?)break;', front, re.S))
        self.assertIn('dm_gfx_inactive(1);', cases['0']); self.assertIn('dm_gfx_inactive(0);', cases['3'])
        self.assertIn('dm_gfx_suspend(1);', cases['1']); self.assertIn('dm_gfx_suspend(0);', cases['2'])
        self.assertIn('void dm_gfx_inactive(int on) { (void)on; }', read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m'))   # the harness links front_ios.m alone

    def test_its_defaults(self):
        self.assertIn('#define PSO_GUARD_NEED (DM_GAME_PSO_MTL4 ? 2 : 1)', self.nvn)   # two early ends in a row for a profile that sets pso_mtl4 on
        self.assertIn('f\'#define DM_GAME_PSO_MTL4 {int(p4 == "on")}\'', read('dm/games/game.py'))
        begin = body(self.nvn, 'static int pso_guard_begin(NSString *p) {')
        self.assertIn('if (!(e && *e ? strcmp(e, "0") != 0 : TARGET_OS_IPHONE)) {', begin)   # on by default on iOS only; 0 / 1 override
        self.assertIn('psg_begin(&g_psg, rec.fileSystemRepresentation, os, id_.UTF8String, PSO_GUARD_NEED)', begin)
        self.assertNotRegex(begin, r'g_psg\.(found|armed|err)')   # the verdict as psg_begin copied it under its lock, not the guard's fields
        self.assertIn('if (!pso_guard_begin(p)) return;', body(self.nvn, 'static void pso_bundle_open('))
        row = next(ln for ln in read('docs/env_switches.tsv').splitlines() if ln.startswith('DM_PSO_BUNDLE_GUARD\t'))
        self.assertIn('on by default on iOS', row); self.assertIn('off by default on the Mac', row)

    def test_names_are_its_own(self):
        """nvn_mtl.m includes the header at the top, and its GPU profiler (DM_NVN_GPUPROF) already has file-scope pg_ names (a pg_pass type, a g_pg int): the guard's first
        version used the same prefix, and its pg_pass function and g_pg variable broke every build of nvn_mtl.m. Every name the header defines carries psg_ / PSG_, and
        nothing else in the files that include it defines one"""
        defined = set(re.findall(r'^(?:static inline \w+ \**|typedef struct \{[^}]*\} |#define |static const char \*const )(\w+)', self.guard, re.M))
        defined |= set(re.findall(r'\b(PSG_[A-Z0-9_]+)\s*(?:=|,|\})', self.guard))
        self.assertTrue(defined)
        for name in defined: self.assertRegex(name, r'^(psg_|PSG_)', name)
        for rel in ('dm/gfx/nvn/nvn_mtl.m', 'dm/gfx/tests/t_pso_bundle.m', 'dm/gfx/tests/t_pso_guard.c'):
            src = read(rel)
            for name in defined:
                n = re.escape(name)
                self.assertNotRegex(src, rf'(?m)^\s*(?:#define\s+{n}\b|typedef\b.*\b{n}\s*;|(?:static\s+)?(?:inline\s+)?[\w\s\*]+\b{n}\s*\([^;)]*\)\s*\{{)', f'{rel} defines {name}, a name of nvn_pso_guard.h')
        for var in ('g_psg', 'g_psg_why'):   # the guard's own globals in nvn_mtl.m: one definition each
            self.assertEqual(len(re.findall(rf'(?m)^static\b[^;=\n]*\b{var}\s*(?:=[^;\n]*)?;', self.nvn)), 1, var)


if __name__ == '__main__':
    unittest.main()
