"""The Gate's wash blur (dm/ios/Sources/NX18Blur.swift): on the CPU, never a Core Image context before the game's Metal device (#840), and close to the Core Image blur it replaced
(blur_check.swift compares the two byte by byte)."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCES = REPO / 'dm/ios/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class GateBlurLooksTheSame(unittest.TestCase):
    def test_cpu_blur_matches_core_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / 'blur_check'
            r = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tmp) / 'module-cache'), '-o', str(exe),
                                str(SOURCES / 'NX18Blur.swift'), str(Path(__file__).with_name('blur_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('gate blur: 0 failed', r.stdout)


class GateBlurWiring(unittest.TestCase):
    def test_no_core_image_before_the_game(self):
        art = (SOURCES / 'LauncherArt.swift').read_text()
        code = '\n'.join(ln.split('//')[0] for ln in art.splitlines())
        for banned in ('import CoreImage', 'CIContext', 'CIImage', 'CIFilter', 'MTLCreateSystemDefaultDevice'):
            self.assertFalse(banned in code, f'{banned} in LauncherArt.swift: a Core Image context makes the first Metal device before front_hud_env (#840)')
        wash = art[art.index('static func wash('):art.index('static func appIcon(')]
        self.assertIn('NX18Blur.blur(ctx)', wash)
        self.assertNotIn('CoreImage', (SOURCES / 'NX18Blur.swift').read_text().split('enum NX18Blur')[1])
        self.assertIsNone(re.search(r'^import (CoreImage|Metal|UIKit)', (SOURCES / 'NX18Blur.swift').read_text(), re.M))

    def test_the_duo_harness_compiles_it(self):
        self.assertIn('../../Sources/NX18Blur.swift', (REPO / 'dm/ios/tests/duo/project.yml').read_text())


if __name__ == '__main__':
    unittest.main()
