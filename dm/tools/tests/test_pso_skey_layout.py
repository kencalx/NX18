"""The pso_skey layout the prewarm-row tools share (dm/gfx/tools/pso_skey_layout.py: pso_offline.py, dm/tools/pso_seed.py) against the host's own header (dm/gfx/nvn/nvn_pso_skey.h),
compiled: sizeof(pso_skey), where its pso_key starts, and the four row lengths pso_skey_parse accepts. A change of the header that the module does not follow fails here, not in a seed
check or an archive that holds bases the host never asks for. Needs clang (Xcode); no game files."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
import pso_skey_layout as layout   # noqa: E402
sys.path.insert(0, str(REPO / 'dm/tools'))
import pso_seed   # noqa: E402

PROBE = r'''
#include <stddef.h>
#include <stdio.h>
typedef struct { int stage; char key[24]; } NvShader;   /* what pso_skey_from reads of a shader (nvn_mtl.m's is an Objective-C object) */
#include "nvn_pso_skey.h"
int main(void) {   /* the lengths as pso_skey_parse computes them */
    pso_skey s; size_t n = sizeof s * 2, old2 = n - 2 * (sizeof s.k.border + sizeof s.k.border_spare), old1 = old2 - 2 * sizeof s.k.attr_hi, old = old1 - 2 * (sizeof s.k.atest + sizeof s.k.logic);
    printf("%zu %zu %zu %zu %zu %zu\n", sizeof s, offsetof(pso_skey, k), n, old2, old1, old);
    return 0;
}
'''


class Layout(unittest.TestCase):
    def test_matches_the_host_header(self):
        if not shutil.which('xcrun'): self.skipTest('no xcrun')
        with tempfile.TemporaryDirectory() as t:
            src, exe = Path(t) / 'probe.c', Path(t) / 'probe'
            src.write_text(PROBE)
            c = subprocess.run(['xcrun', 'clang', '-I', str(REPO / 'dm/gfx/nvn'), '-I', str(REPO / 'dm/gfx/nvn/include'), '-o', str(exe), str(src)], capture_output=True, text=True, timeout=300)
            self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
            size, key, *lengths = map(int, subprocess.run([str(exe)], capture_output=True, text=True, check=True).stdout.split())
        self.assertEqual((layout.SKEY, layout.KEY, layout.LENGTHS), (size, key, tuple(lengths)))

    def test_seed_check_takes_them(self):   # pso_seed reads the shared values, not copies of its own
        self.assertEqual((pso_seed.SKEY, pso_seed.DESC, pso_seed.LENGTHS), (layout.SKEY, layout.KEY, layout.LENGTHS))


if __name__ == '__main__':
    unittest.main()
