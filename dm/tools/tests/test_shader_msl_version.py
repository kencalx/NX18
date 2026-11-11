"""The game shaders' compile lines name their language and minimum OS: MSL 4.1 (-std=metal4.1, the newest) for the Mac host's minimum (dm/gfx/tools/dmsh_build.py MAC_METAL,
dm/mac/min_os.mk MACOS_MIN) and the iPhone app's (dm/ios/tools/ios_metal.py METAL, dm/host/Makefile MSL_MIN_iphoneos, dm/ios/project.yml). Without them the Mac's language and the
libraries' minimum followed the SDK, so a newer Xcode would have changed both with no change to the lines or the chain version. With a Metal compiler (each SDK skipped without
one), a kernel compiled with each line's flags records Metal 4.1 and that OS in its AIR. No game files."""
import ast
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tools'))
import ios_metal  # noqa: E402

STD = '-std=metal4.1'
KERNEL = 'kernel void k(device uint* o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = __METAL_VERSION__; }\n'


def mac_metal():   # dmsh_build.py's MAC_METAL, read without running the script (it runs a build when imported)
    for n in ast.parse((REPO / 'dm/gfx/tools/dmsh_build.py').read_text()).body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'MAC_METAL' for t in n.targets): return ast.literal_eval(n.value)
    raise AssertionError('no MAC_METAL in dmsh_build.py')


def found(pattern, path):   # the first group of pattern in the file
    m = re.search(pattern, (REPO / path).read_text())
    if m is None: raise AssertionError(f'{path}: no {pattern}')
    return m.group(1)


def macos_min(): return found(r'(?m)^MACOS_MIN\s*:?=\s*(\S+)', 'dm/mac/min_os.mk')


def ios_min():
    mk = found(r'(?m)^MSL_MIN_iphoneos\s*=\s*(\S+)', 'dm/host/Makefile')
    app = found(r'(?m)^\s*iOS:\s*"([\d.]+)"', 'dm/ios/project.yml')
    if mk != app: raise AssertionError(f'dm/host/Makefile MSL_MIN_iphoneos {mk} is not dm/ios/project.yml\'s deployment target {app}')
    return mk


def has_sdk(sdk):
    return bool(shutil.which('xcrun')) and subprocess.run(['xcrun', '-sdk', sdk, 'metal', '--version'], capture_output=True).returncode == 0


class Lines(unittest.TestCase):
    def test_mac_line(self):
        line = mac_metal()
        self.assertEqual(line[:4], ['xcrun', '-sdk', 'macosx', 'metal'])
        self.assertIn(STD, line)
        self.assertEqual([f for f in line if f.startswith('-mmacosx-version-min=')], [f'-mmacosx-version-min={macos_min()}'])
        self.assertFalse([f for f in line if f.startswith('-std=') and f != STD])

    def test_ios_line(self):
        line = ios_metal.METAL
        self.assertEqual(line[:4], ['xcrun', '-sdk', 'iphoneos', 'metal'])
        self.assertIn(STD, line)
        self.assertEqual([f for f in line if f.startswith('-mios-version-min=')], [f'-mios-version-min={ios_min()}'])
        self.assertFalse([f for f in line if f.startswith('-std=') and f != STD])

    def test_records_name_the_lines(self):   # the compile cache keys and each library's chain_metal: a change of language or minimum rebuilds every library
        self.assertIn(STD, ios_metal.RECORD)
        src = (REPO / 'dm/gfx/tools/dmsh_build.py').read_text()
        self.assertRegex(src, r"(?m)^MAC_RECORD = ' '\.join\(MAC_METAL\)")


class Air(unittest.TestCase):
    def air(self, line, sdk):   # → the AIR's text: its target triple and language version
        if not has_sdk(sdk): self.skipTest(f'no Metal compiler for {sdk}')
        with tempfile.TemporaryDirectory() as t:
            src, ll = Path(t) / 'k.metal', Path(t) / 'k.ll'
            src.write_text(KERNEL)
            subprocess.run([*line, '-S', '-emit-llvm', str(src), '-o', str(ll)], check=True, capture_output=True)
            return ll.read_text()

    def check(self, text, os_name, minimum):
        self.assertRegex(text, rf'(?m)^target triple = "air64_v\d+-apple-{os_name}{re.escape(minimum)}(\.0)?"$')
        self.assertRegex(text, r'!\{!"Metal", i32 4, i32 1, i32 0\}')   # air.language_version
        self.assertIn('store i32 410,', text)   # __METAL_VERSION__

    def test_mac(self): self.check(self.air(mac_metal(), 'macosx'), 'macosx', macos_min())

    def test_ios(self): self.check(self.air(ios_metal.METAL, 'iphoneos'), 'ios', ios_min())


if __name__ == '__main__':
    unittest.main()
