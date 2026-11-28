"""Compile and run DmVitals.m's text cache (DM_VITALS_CACHE) for Mac Catalyst: vitals_cache_check.m includes the real file; no simulator or device."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS SDK with Mac Catalyst')
class VitalsCacheTests(unittest.TestCase):
    def test_cache_shows_what_a_full_build_shows(self):
        sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True, timeout=60).stdout.strip()
        ios = f'{sdk}/System/iOSSupport/System/Library/Frameworks'
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'game_profile.h').write_text('#pragma once\n')   # dm.h's include; DmVitals.m reads none of the profile's constants
            exe = tmp / 'vitals_cache_check'
            r = subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-ios27.2-macabi', '-isysroot', sdk, '-iframework', ios, '-F', ios, '-fobjc-arc', '-O2',
                                '-I', str(tmp), '-I', str(REPO / 'dm/ios/Sources'), '-I', str(REPO / 'dm/host'), '-I', str(REPO / 'dm/gfx/nvn'),
                                str(Path(__file__).with_name('vitals_cache_check.m')), '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'CoreText', '-o', str(exe)],
                               capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('0 failed', r.stdout)


if __name__ == '__main__':
    unittest.main()
