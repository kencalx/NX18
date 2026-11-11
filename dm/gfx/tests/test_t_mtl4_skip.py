"""t_mtl4.h's standalone back end on a Mac without a Metal 4 GPU (GitHub's virtual Macs): t4_dev ends the runner with exit status 2, which the Python GPU tests' runners
take as a skip (test_ndve_engine, test_dmsh_*: `if r.returncode == 2: self.skipTest(...)`), not with an abort that fails them. T4_TEST_NO_METAL4 makes t4_dev act as on such a
Mac; the first call may come through the compiler (t4_comp), as t4_cps's does. Every other test file here then runs with T4_TEST_NO_METAL4 set (with the committed translator as
DMSH_TEST_XLATE when none is given, as CI's tool-test job sets it) and must pass: a runner that asserts its output without taking status 2 as a skip fails there, as it would on CI."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import sys
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


@unittest.skipUnless(shutil.which('clang'), 'needs Xcode')
@unittest.skipIf(os.environ.get('T4_TEST_NO_METAL4'), 'already a sweep without Metal 4')
class EveryTestFileWithoutMetal4(unittest.TestCase):
    def test_each_file_passes_or_skips(self):
        here = Path(__file__).resolve().parent
        files = sorted(p for p in here.glob('test_*.py') if p.name != Path(__file__).name)
        env = dict(os.environ, T4_TEST_NO_METAL4='1')
        xlate = here.parent / 'tools/dmsh_xlate_bin/dmsh_xlate'
        if not env.get('DMSH_TEST_XLATE') and xlate.exists(): env['DMSH_TEST_XLATE'] = str(xlate)

        def run(p):
            return p.name, subprocess.run([sys.executable, '-m', 'unittest', p.name], cwd=here, env=env, capture_output=True, text=True, timeout=900)

        with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            for name, r in pool.map(run, files):
                with self.subTest(file=name):
                    self.assertEqual(r.returncode, 0, r.stderr[-3000:])


if __name__ == '__main__':
    unittest.main()
