"""MetricKit's reports kept in Documents/metrics (DmMetrics.m, Metrics.swift, DM_METRICS) and the prepare step's background task (front_ios.m, DM_BG_PREPARE): what can be checked off the device.

The report files' names and their cap of 30 run as C (metrics_files.h) with any compiler. Metrics.swift typechecks against the iPhone SDK on a Mac with Xcode 27, and elsewhere, with a
swiftc on PATH (or SWIFTC=), against a stand-in of MetricKit's iOS 27 Swift API written from Apple's declarations (metrics_stub/). The rest checks that the pieces agree: the Info.plist
identifier and the one the app registers, the framework links, the prepare step's end hook, the launch calls and the switches' defaults."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / 'dm/ios/Sources'
STUB = Path(__file__).with_name('metrics_stub')

C_MAIN = r'''
#include "metrics_files.h"
int main(int argc, char **argv) {
    if (argc == 5 && !strcmp(argv[1], "name")) {
        char b[256]; int r = dm_metrics_name(b, sizeof b, (time_t)atoll(argv[2]), (unsigned)atoi(argv[3]), argv[4]);
        if (r < 0) { puts("-1"); return 0; }
        puts(b); return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "prune")) { printf("%d\n", dm_metrics_prune(argv[2], atoi(argv[3]))); return 0; }
    return 2;
}
'''


def c_compiler() -> str:
    return os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc') or ''


def found(pattern, text, group=1):
    """The group of pattern's first match in text; a missing match fails the test that asks"""
    m = re.search(pattern, text, re.MULTILINE)
    if not m: raise AssertionError(f'not found: {pattern}')
    return m.group(group)


@unittest.skipUnless(c_compiler(), 'needs a C compiler')
class MetricsFiles(unittest.TestCase):
    """metrics_files.h: one file per report, named so the names sort by age, and only the newest DM_METRICS_KEEP (30) kept"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        t = Path(cls.tmp.name)
        (t / 'main.c').write_text(C_MAIN)
        cls.exe = t / 'metrics_files_check'
        r = subprocess.run([c_compiler(), '-std=gnu11', '-Wall', '-Werror', '-I', str(SRC), '-o', str(cls.exe), str(t / 'main.c')], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_check(self, *args):
        r = subprocess.run([str(self.exe), *map(str, args)], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def test_names_sort_by_age_whatever_the_kind(self):
        self.assertEqual(self.run_check('name', 1793889012, 0, 'diagnostic-memoryException'), '20261105-143012-000-diagnostic-memoryException.json')
        names = [self.run_check('name', t, s, k) for t, s, k in ((1793889012, 7, 'metrics'), (1793889012, 8, 'diagnostic-crash'), (1793889013, 0, 'diagnostic-appLaunch'), (1793975412, 1, 'metrics'))]
        self.assertEqual(sorted(names), names)
        self.assertEqual(self.run_check('name', 0, 1234, 'metrics'), '19700101-000000-234-metrics.json')   # the sequence wraps at 1000, keeping three digits

    def test_unsafe_kinds_get_no_name(self):
        for kind in ('', 'a/b', '../x', 'a b', 'crash.json'):
            with self.subTest(kind=kind):
                self.assertEqual(self.run_check('name', 1793889012, 0, kind), '-1')

    def test_prune_keeps_the_newest_reports_and_nothing_else_is_touched(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            reports = [self.run_check('name', 1793889012 + i, 0, 'metrics' if i % 2 else 'diagnostic-hang') for i in range(35)]
            for n in reports: (d / n).write_text('{}')
            others = ['README.txt', 'notes.json', '.20261105-tmp.json', '2026-draft.txt']   # a player's files, a write in progress: not reports
            for n in others: (d / n).write_text('x')
            self.assertEqual(self.run_check('prune', d, 30), '5')
            left = sorted(p.name for p in d.iterdir())
            self.assertEqual(left, sorted(reports[5:] + others))
            self.assertEqual(self.run_check('prune', d, 30), '0')

    def test_prune_of_a_missing_folder_fails_quietly(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(self.run_check('prune', Path(d) / 'none', 30), '-1')


def swift_command():
    """(command prefix, uses the stand-in) for a typecheck of Metrics.swift, or None"""
    if sys.platform == 'darwin' and shutil.which('xcrun'):
        v = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], capture_output=True, text=True)
        try:
            major = int(v.stdout.strip().split('.')[0])
        except ValueError:
            major = 0
        if v.returncode == 0 and major >= 27:   # MetricManager is in the iOS 27 SDK
            return ['xcrun', '-sdk', 'iphoneos', 'swiftc', '-target', 'arm64-apple-ios27.0'], False
        return None
    sw = os.environ.get('SWIFTC') or shutil.which('swiftc')
    return ([sw], True) if sw else None


@unittest.skipUnless(swift_command(), 'needs the iOS 27 SDK (a Mac) or a swiftc (SWIFTC=)')
class MetricsSwift(unittest.TestCase):
    def test_metrics_swift_typechecks_in_swift_6(self):
        found_cmd = swift_command()
        assert found_cmd
        cmd, stand_in = found_cmd
        with tempfile.TemporaryDirectory() as t:
            extra = []
            if stand_in:
                r = subprocess.run(cmd + ['-emit-module', '-enable-library-evolution', '-swift-version', '6', '-module-name', 'MetricKit', '-emit-module-path', f'{t}/MetricKit.swiftmodule',
                                          str(STUB / 'MetricKit.swift')], capture_output=True, text=True, timeout=300)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                extra = ['-I', t]
            r = subprocess.run(cmd + ['-typecheck', '-swift-version', '6', '-parse-as-library', '-module-cache-path', f'{t}/mc', *extra, str(SRC / 'Metrics.swift'), str(STUB / 'bridge.swift')],
                               capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertNotIn('error:', r.stderr)


class Wiring(unittest.TestCase):
    """The pieces agree with each other (nothing here runs them)"""

    @classmethod
    def setUpClass(cls):
        cls.yml = (REPO / 'dm/ios/project.yml').read_text()
        cls.duo = (REPO / 'dm/ios/tests/duo/project.yml').read_text()
        cls.front = (SRC / 'front_ios.m').read_text()
        cls.main = (SRC / 'main.m').read_text()
        cls.metrics = (SRC / 'DmMetrics.m').read_text()
        cls.nvn = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text()

    def test_the_registered_identifier_is_one_the_info_plist_permits(self):
        rows = found(r'^        BGTaskSchedulerPermittedIdentifiers:.*\n((?:          - .*\n)+)', self.yml)
        ids = [l.split('- ', 1)[1].split('#')[0].strip() for l in rows.splitlines()]
        self.assertEqual(ids, ['$(PRODUCT_BUNDLE_IDENTIFIER).prepare.*'])   # the build's bundle ID, also when it is changed in Xcode to sign with another team; iOS asks this task for the wildcard form
        wild = found(r'stringByAppendingString:@"(\.prepare\.\*)"', self.front)
        reg = found(r'NSString \*ident = \[bid stringByAppendingString:@"([^"]+)"\]', self.front)
        self.assertEqual(ids[0], '$(PRODUCT_BUNDLE_IDENTIFIER)' + wild)
        self.assertTrue(reg.startswith(wild[:-1]) and '*' not in reg and len(reg) > len(wild) - 1, reg)

    def test_no_background_gpu_no_entitlement_no_background_mode(self):
        self.assertNotRegex(self.yml, r'(?m)^\s+UIBackgroundModes:')
        self.assertNotIn('requiredResources =', self.front)
        self.assertNotIn('continued-processing', (REPO / 'dm/ios/tools/build_ipa.sh').read_text())
        self.assertIn('BGContinuedProcessingTaskRequestSubmissionStrategyFail', self.front)

    def test_frameworks_are_linked(self):
        deps = found(r'^    dependencies:.*\n((?:      - .*\n)+)', self.yml)
        for fw in ('MetricKit.framework', 'BackgroundTasks.framework'):
            self.assertIn(f'- sdk: {fw}', deps)
        self.assertIn('- sdk: BackgroundTasks.framework', self.duo)   # the Duo harness compiles front_ios.m
        self.assertIn('../../Sources/front_ios.m', self.duo)
        self.assertIn('#import <BackgroundTasks/BackgroundTasks.h>', self.front)
        self.assertIn('#import <MetricKit/MetricKit.h>', self.metrics)
        self.assertIn('import MetricKit', (SRC / 'Metrics.swift').read_text())
        self.assertIn('#import "DmMetrics.h"', (SRC / 'DmIOS-Bridging-Header.h').read_text())

    def test_the_prepare_step_reports_its_end(self):
        self.assertIn('__attribute__((weak)) void front_prepare_end(void) {}', self.nvn)   # the Mac and the graphics unit tests link without a front end's
        branch = self.nvn[self.nvn.index('static void warm_start(void) {'):]
        branch = branch[branch.index('if (prepare_on()) {'):branch.index('dispatch_queue_attr_t attr')]
        # right after the prebuild, with only the bundled pipeline archive's crash guard told first (its window starts at the prepare step's end, or at the end of the prebuild's
        # compiles still under way: nvn_pso_guard.h)
        self.assertRegex(branch, r'prepare_prebuild\(\); \}[^\n]*\n(\s*pso_guard_prepared\(\);[^\n]*\n)?\s*front_prepare_end\(\);\n\s*return;')
        self.assertIn('pso_guard_prepared();', branch)
        self.assertRegex(self.front, r'\nvoid front_prepare_end\(void\) \{ dispatch_async\(dispatch_get_main_queue\(\)')
        self.assertIn('prep_end("the game showed its first picture")', self.front)

    def test_launch_registers_and_subscribes(self):
        body = self.main[self.main.index('didFinishLaunchingWithOptions:'):]
        body = body[:body.index('\n}\n')]
        self.assertIn('front_ios_bg_prepare_register();', body)
        self.assertIn('dm_metrics_start();', body)

    def test_switch_defaults(self):
        self.assertRegex(self.front, r'getenv\("DM_BG_PREPARE"\);\n\s*if \(!e \|\| strcmp\(e, "1"\)\) return;')   # off unless 1: not yet measured on the devices
        # Off, nothing else of it runs: every count front_progress hands over returns at once while no task identifier was registered, and the end does nothing more than note it
        self.assertRegex(self.front, r'static void prep_progress\(NSString \*phase, long done, long total\) \{\n\s*if \(!g_prep_id \|\|')
        self.assertRegex(self.front, r'static void prep_end\(const char \*why\) \{[^\n]*\n\s*if \(g_prep_over\) return;\n\s*g_prep_over = YES;\n\s*if \(!g_prep_id\) return;')
        self.assertEqual(self.front.count('prep_progress(tt, done, total)'), 2)   # both paths of front_progress: the host app's hook and the front end's own screen
        self.assertRegex(self.metrics, r'getenv\("DM_METRICS"\);\n\s*if \(e && !strcmp\(e, "0"\)\)')   # on unless 0
        self.assertIn('l.name = @"game";', self.front)   # MetricKit's frame-rate metric names the layer


if __name__ == '__main__':
    unittest.main()
