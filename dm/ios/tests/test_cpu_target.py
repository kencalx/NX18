"""The iOS app's CPU target: the chip the app is built for, the iPhone 18 Pro Max's A20 Pro, and nothing newer.

dav1d (dm/third_party/dav1d/src/cpu.h) adds every CPU feature the compiler's target promises to the features it detects at run time, so a target newer than
the device runs instructions the device lacks: with -mcpu=apple-a18, Ocarina of Time's title movie stopped an M1 iPad Pro (no I8MM) with SIGILL in
put_8tap_neon_i8mm. This build keeps no older device or iOS version (iOS 27.3, the A20 Pro only), so the target may promise what the A20 has (I8MM, BF16,
SME among them) and nothing beyond it; the host's assembly needs LSE atomics (ARMv8.1), which it has."""
import re
import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SUPPORTED = 'apple-a20'   # the one chip the app is built for: every feature the target promises must be one it has
NEEDED = ('__ARM_FEATURE_ATOMICS',)


def macros(mcpu):
    out = subprocess.run(['xcrun', '-sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios27.3', f'-mcpu={mcpu}', '-dM', '-E', '-x', 'c', '/dev/null'],
                         capture_output=True, text=True, check=True).stdout
    return {line.split()[1] for line in out.splitlines() if line.startswith('#define ')}


def features(m): return {x for x in m if x.startswith('__ARM_FEATURE_')}


class CpuTarget(unittest.TestCase):
    def targets(self):
        project = (REPO / 'dm/ios/project.yml').read_text()
        check = (REPO / 'dm/ios/tools/compile_check.py').read_text()
        found = {'project.yml': re.findall(r'-mcpu=([\w-]+)', project), 'compile_check.py': re.findall(r"-mcpu=([\w-]+)", check)}
        for where, cpus in found.items(): self.assertEqual(len(cpus), 1, f'{where}: one -mcpu, found {cpus}')
        return {where: cpus[0] for where, cpus in found.items()}

    def test_ios_target_promises_no_feature_the_supported_chip_lacks(self):
        if not shutil.which('xcrun'): self.skipTest('Xcode required')
        has = features(macros(SUPPORTED))
        for where, cpu in self.targets().items():
            with self.subTest(where=where, cpu=cpu):
                m = macros(cpu)
                for feature in NEEDED: self.assertIn(feature, m, f'{where}: -mcpu={cpu} lacks {feature} (LSE), which the host assembly uses')
                extra = sorted(features(m) - has)
                self.assertEqual(extra, [], f'{where}: -mcpu={cpu} promises {extra}, which the {SUPPORTED} lacks')

    def test_both_builds_use_the_same_target(self):
        self.assertEqual(len(set(self.targets().values())), 1)


if __name__ == '__main__': unittest.main()
