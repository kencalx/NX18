"""Compile and run the launcher's real settings model on macOS; no simulator or UI required. It compiles the Mac app's launcher Swift as pack_app.py does: its sources and the C
header of its entry (@c @implementation), in the Swift 6 language mode, for the Mac host's minimum macOS (MACOS_MIN of dm/mac/min_os.mk), so an API newer than that fails here."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/games'))
sys.path.insert(0, str(REPO / 'dm/mac'))
import pack_app
import settings


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class LauncherStorageTests(unittest.TestCase):
    def test_only_changed_choices_are_stored(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'patched').mkdir()
            (tmp / 'patched/main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')   # the render-scale row, a range
            with patch.dict(os.environ, {'GFXAPI': 'nvn'}), patch.object(settings.nacp, 'languages', return_value=['en-US', 'ja']):
                (tmp / 'launcher.json').write_text(json.dumps(settings.build('01007EF00011E000', tmp / 'patched', tmp / 'control.nacp')))
                with patch.dict(os.environ, {'SETTINGS_PLATFORM': 'mac'}):   # the Mac window's list: Display mode, the render scale's base size
                    (tmp / 'launcher_mac.json').write_text(json.dumps(settings.build('01007EF00011E000', tmp / 'patched', tmp / 'control.nacp')))
            exe = tmp / 'launcher_storage_check'
            compile_result = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-target', f'arm64-apple-macos{pack_app.macos_min()}', '-swift-version', '6', '-parse-as-library',
                            '-module-cache-path', str(tmp / 'module-cache'), '-import-objc-header', str(pack_app.swift_header()), '-o', str(exe), *map(str, pack_app.swift_sources()),
                            str(Path(__file__).with_name('launcher_layout_check.swift')), str(Path(__file__).with_name('launcher_storage_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            r = subprocess.run([str(exe), str(tmp / 'launcher.json'), str(tmp / 'launcher_mac.json')], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('launcher storage: 0 failed', r.stdout)


class LauncherBuild(unittest.TestCase):
    def test_the_swift_is_compiled_as_the_mac_app_compiles_it(self):   # what the compile above takes from pack_app.py, checked on any machine
        self.assertEqual(pack_app.macos_min(), (REPO / 'dm/mac/min_os.mk').read_text().split('MACOS_MIN := ')[1].split()[0])
        self.assertEqual([p.name for p in pack_app.swift_sources()], ['Launcher.swift', 'LauncherSettings.swift', 'LauncherRow.swift'])
        self.assertIn('int dm_mac_launcher(void);', pack_app.swift_header().read_text())


if __name__ == '__main__':
    unittest.main()
