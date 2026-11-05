"""The NSP script keeps the Mac from idle sleep while it builds (keep_awake: caffeinate -i -w <its pid>), once per process, never in Spyder or with DM_KEEP_AWAKE=0, and a caffeinate that
does not start never stops the build. Mocked on any system; on a Mac the real caffeinate ends with the process, also after kill -9."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time
import types
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / 'scripts/build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', SCRIPT)
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class KeepAwake(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, nsp, 'CAFFEINATE', None); nsp.CAFFEINATE = None

    def run_it(self, platform='darwin', ipython=False, exists=True, env=None, popen=None):
        popen = popen or mock.MagicMock(name='Popen')
        env = {k: v for k, v in os.environ.items() if k != 'DM_KEEP_AWAKE'} | (env or {})
        with mock.patch.object(nsp.sys, 'platform', platform), mock.patch.object(nsp, 'in_ipython', return_value=ipython), \
             mock.patch.object(nsp.os.path, 'exists', side_effect=lambda p: exists if p == '/usr/bin/caffeinate' else os.path.lexists(p)), \
             mock.patch.object(nsp.subprocess, 'Popen', popen), mock.patch.dict(os.environ, env, clear=True):
            nsp.keep_awake(); nsp.keep_awake()   # main runs again for each program of a game of several: one caffeinate
        return popen

    def test_a_mac_build_holds_an_idle_sleep_assertion_while_the_process_lives(self):
        p = self.run_it()
        p.assert_called_once_with(['/usr/bin/caffeinate', '-i', '-w', str(os.getpid())], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  start_new_session=True)   # no -d: the display may sleep; detached, and without the Builder's pipes
        self.assertIs(nsp.CAFFEINATE, p.return_value)

    def test_none_off_a_mac_in_spyder_without_caffeinate_or_with_the_switch(self):
        for kw in (dict(platform='linux'), dict(ipython=True), dict(exists=False), dict(env={'DM_KEEP_AWAKE': '0'})):
            with self.subTest(**kw):
                nsp.CAFFEINATE = None
                self.run_it(**kw).assert_not_called(); self.assertIsNone(nsp.CAFFEINATE)
        self.run_it(env={'DM_KEEP_AWAKE': '1'}).assert_called_once()   # any other value keeps it on

    def test_a_caffeinate_that_does_not_start_never_stops_the_build(self):
        for e in (PermissionError(13, 'denied'), OSError(8, 'Exec format error'), subprocess.SubprocessError('no')):
            with self.subTest(e=e):
                nsp.CAFFEINATE = None
                self.run_it(popen=mock.MagicMock(side_effect=e)); self.assertIsNone(nsp.CAFFEINATE)

    def test_main_starts_it_first(self):   # before the arguments and every check, so a build stopped later still had it
        class First(Exception): pass
        with mock.patch.object(nsp, 'keep_awake', side_effect=First), mock.patch.object(nsp, 'parse_args', side_effect=AssertionError('parsed first')):
            with self.assertRaises(First): nsp.main(types.SimpleNamespace())

    def test_the_builders_pipes_end_with_the_build(self):   # a stand-in caffeinate that waits for the pid as -w does: the reader of the build's output sees its end when the build ends
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            stub, mark = Path(d) / 'caffeinate', Path(d) / 'ended'
            stub.write_text(f'#!/bin/sh\n[ "$1 $2" = "-i -w" ] || exit 2\nwhile kill -0 "$3" 2>/dev/null; do sleep 0.05; done\ntouch "{mark}"\n'); stub.chmod(0o755)
            code = ('import importlib.util, subprocess, sys\nspec = importlib.util.spec_from_file_location("n", sys.argv[1]); n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)\n'
                    'real = subprocess.Popen\nn.sys.platform = "darwin"; n.in_ipython = lambda: False; n.os.path.exists = lambda p: True\n'
                    'n.subprocess.Popen = lambda a, **kw: real([sys.argv[2]] + a[1:], **kw)\nn.keep_awake(); print("built", flush=True)\n')
            t0 = time.monotonic()
            r = subprocess.run([sys.executable, '-c', code, str(SCRIPT), str(stub)], capture_output=True, text=True, timeout=30,
                               env={k: v for k, v in os.environ.items() if k != 'DM_KEEP_AWAKE'})
            self.assertEqual((r.returncode, r.stdout, r.stderr), (0, 'built\n', ''))
            self.assertLess(time.monotonic() - t0, 10)
            for _ in range(100):
                if mark.exists(): break
                time.sleep(0.05)
            self.assertTrue(mark.exists(), 'the stand-in did not end with the build')

    @unittest.skipUnless(sys.platform == 'darwin' and os.path.exists('/usr/bin/caffeinate'), 'macOS caffeinate')
    def test_real_caffeinate_ends_with_the_process(self):
        code = ('import importlib.util, sys, time\nspec = importlib.util.spec_from_file_location("n", sys.argv[1]); n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)\n'
                'n.keep_awake(); print(n.CAFFEINATE.pid, flush=True); time.sleep(60)\n')
        env = {k: v for k, v in os.environ.items() if k != 'DM_KEEP_AWAKE'}
        child = subprocess.Popen([sys.executable, '-c', code, str(SCRIPT)], stdout=subprocess.PIPE, text=True, env=env)
        try:
            caf = int(child.stdout.readline())
            args = subprocess.run(['ps', '-o', 'args=', '-p', str(caf)], capture_output=True, text=True).stdout.split()
            self.assertEqual(args[1:], ['-i', '-w', str(child.pid)])
            self.assertIn('caffeinate', subprocess.run(['pmset', '-g', 'assertions'], capture_output=True, text=True).stdout)
        finally: child.kill(); child.wait()
        for _ in range(50):
            if subprocess.run(['kill', '-0', str(caf)], capture_output=True).returncode != 0: break
            time.sleep(0.1)
        else: self.fail(f'caffeinate {caf} outlived the killed build')


if __name__ == '__main__':
    unittest.main()
