"""The play record (dm/ios/Sources/PlayRecord.swift): one entry per session however many checkpoints it had, and no battery minutes for the time away (play_record_check.swift)."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCES = REPO / 'dm/ios/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class PlayRecordSessions(unittest.TestCase):
    def test_sessions_and_battery_minutes(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / 'play_record_check'
            r = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tmp) / 'module-cache'), '-o', str(exe),
                                str(SOURCES / 'PlayRecord.swift'), str(Path(__file__).with_name('play_record_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('play record: 0 failed', r.stdout)


if __name__ == '__main__':
    unittest.main()
