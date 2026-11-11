"""t_mtl4.h's standalone back end on a Mac without a Metal 4 GPU (GitHub's virtual Macs): t4_dev ends the runner with exit status 2, which the Python GPU tests' runners
take as a skip (test_ndve_engine, test_dmsh_*: `if r.returncode == 2: self.skipTest(...)`), not with an abort that fails them. T4_TEST_NO_METAL4 makes t4_dev act as on such a
Mac; the first call may come through the compiler (t4_comp), as t4_cps's does."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

T4_DIR = str(Path(__file__).resolve().parent)
RUNNER = r'''#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "t_mtl4.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1) (void)t4_comp(); else (void)t4_dev();
        puts("ran");
    }
    return 0;
}
'''


@unittest.skipUnless(shutil.which('clang'), 'needs Xcode')
class NoMetal4IsASkip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        (d / 'run.m').write_text(RUNNER)
        cls.run_bin = str(d / 'run')
        subprocess.run(['clang', '-fobjc-arc', '-I', T4_DIR, '-O1', str(d / 'run.m'), '-framework', 'Metal', '-framework', 'Foundation', '-o', cls.run_bin], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_it(self, *args, no_metal4):
        env = dict(os.environ)
        env.pop('T4_TEST_NO_METAL4', None)
        if no_metal4: env['T4_TEST_NO_METAL4'] = '1'
        return subprocess.run([self.run_bin, *args], capture_output=True, text=True, env=env, timeout=60)

    def test_device_without_metal4_exits_2(self):
        for args in ((), ('compiler',)):
            r = self.run_it(*args, no_metal4=True)
            self.assertEqual(r.returncode, 2, f'{args}: {r.stdout}{r.stderr}')
            self.assertIn('no Metal 4 device', r.stdout)
            self.assertNotIn('ran', r.stdout)

    def test_metal4_device_runs(self):   # where the Mac has one; elsewhere the same skip
        r = self.run_it(no_metal4=False)
        if r.returncode == 2: self.skipTest(r.stdout.strip())
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'ran'), r.stderr)


if __name__ == '__main__':
    unittest.main()
