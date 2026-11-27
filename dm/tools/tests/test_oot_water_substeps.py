"""Ocarina of Time v131072's water substeps stub (dm/games/0400486024DEC000/patches.py water_substeps, from MacNativeGames c13d32f2): the multiply of the water simulation's
base substeps by the truncated frame ratio (main+0x4760c) goes to a stub that rounds base x ratio to nearest, at least 1 when the product is positive. The layout is checked
without game files; on an arm64 Mac the stub's words run natively (clang) over upstream's cases, with s0 checked unchanged."""
import importlib.util
import math
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nso_asm import B   # noqa: E402

spec = importlib.util.spec_from_file_location('oot_patches', Path(__file__).resolve().parents[2] / 'games/0400486024DEC000/patches.py')
assert spec is not None and spec.loader is not None
patch = importlib.util.module_from_spec(spec); spec.loader.exec_module(patch)

AREA = 0x5000000


def build():
    """Run the v131072 main's STUBS entry against a recording context: (words emitted at AREA, {site: (words, why)}, {site: original hex})."""
    words, puts, sites = [], {}, {}
    ctx = types.SimpleNamespace(here=lambda: AREA + 4 * len(words), emit=words.append, site=sites.__setitem__, put=lambda off, ws, why: puts.__setitem__(off, (ws, why)),
                                address=lambda off: 0)
    patch.STUBS['e0f3ccfaf50065ae4ea01eb5aeb13b1a'](ctx)
    return words, puts, sites


class Layout(unittest.TestCase):
    def test_the_multiply_goes_to_the_stub_and_back(self):
        words, puts, _ = build()
        self.assertEqual(list(puts), [patch.water_site], 'one site written: the multiply')
        (b,), why = puts[patch.water_site]
        self.assertEqual(b & 0xfc000000, 0x14000000, 'a plain b: the stub returns by a branch')
        start = patch.water_site + (((b & 0x3ffffff) ^ 0x2000000) - 0x2000000) * 4
        self.assertIn('water', why)
        i = (start - AREA) // 4
        self.assertEqual(tuple(words[i:i + 7]), patch.water_stub)
        self.assertEqual(words[i + 7], B(start + 28, patch.water_back), 'back to the store after the site')
        self.assertEqual(patch.water_back, patch.water_site + 4)

    def test_the_build_is_checked_where_it_is_read(self):
        _, _, sites = build()
        self.assertEqual(sites[patch.water_site], struct.pack('<I', 0x1b097d08).hex(), 'the original multiply is asserted')
        for at in (0x475f4, 0x475f8, 0x47614, 0x47618): self.assertIn(at, sites, f'main+{at:#x} is asserted before the stub is written')
        self.assertEqual(list(patch.STUBS), ['e0f3ccfaf50065ae4ea01eb5aeb13b1a'], 'only the v131072 main')
        self.assertNotIn(0xbd000000, [w & 0xff000000 for w in patch.water_stub], 'no store: the stub writes only w8, w9 and s16')


@unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64' and shutil.which('xcrun'), 'runs the stub natively on an arm64 Mac')
class Run(unittest.TestCase):
    CASES = ((6, 0.0, 0), (6, -1.0, 0), (6, math.nan, 0), (0, 1.0, 0), (6, 0.01, 1), (6, 0.25, 2), (6, 0.5, 3), (6, 2.0 / 3.0, 4),
             (6, 0.76, 5), (6, 0.99, 6), (6, 1.0, 6), (6, 1.5, 9), (6, 2.0, 12), (6, 3.0, 18))   # upstream's cases, and three vsyncs

    def test_rounded_and_clamped(self):
        asm = '.text\n.globl _call_water\n.p2align 2\n_call_water:\n mov w8,w0\n' + ''.join(f' .long 0x{w:08x}\n' for w in patch.water_stub) + \
              ' fmov w10,s0\n str w10,[x1]\n mov w0,w8\n ret\n'   # s0 as it left the stub, for the check (x1: the third argument)
        src = r'''#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
extern int32_t call_water(int32_t, float, uint32_t *);
int main(int argc, char **argv) {
    for (int k = 1; k + 1 < argc; k += 2) {
        int32_t base; float ratio; uint32_t bits, after;
        sscanf(argv[k], "%d", &base); sscanf(argv[k + 1], "%x", &bits); memcpy(&ratio, &bits, 4);
        int32_t got = call_water(base, ratio, &after);
        printf("%d %d\n", got, after == bits);
    }
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'w.S').write_text(asm); (Path(d) / 'm.c').write_text(src)
            subprocess.run(['xcrun', 'clang', '-Wall', '-Werror', str(Path(d) / 'm.c'), str(Path(d) / 'w.S'), '-o', str(Path(d) / 'w')], check=True)
            args = [a for base, ratio, _ in self.CASES for a in (str(base), f'{struct.unpack("<I", struct.pack("<f", ratio))[0]:08x}')]
            out = subprocess.run([str(Path(d) / 'w'), *args], check=True, capture_output=True, text=True).stdout.split('\n')
        for (base, ratio, want), line in zip(self.CASES, out):
            got, kept = map(int, line.split())
            self.assertEqual(got, want, f'base {base} ratio {ratio}')
            self.assertEqual(kept, 1, f's0 kept (ratio {ratio})')


if __name__ == '__main__':
    unittest.main()
