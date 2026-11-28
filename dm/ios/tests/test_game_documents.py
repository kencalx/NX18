"""The documents a game app shows while the game runs (dm/ios/Sources/GameDocuments.swift, shared by the iPhone and iPad app and the Mac's game app): compiled alone with
game_documents_check.swift and run on folders it writes in a temporary folder (the app's manual and guide, Documents/Companion, an NX 18 folder with iCloud placeholders).
Also: the Mac's in-game menu module and Beam compile it (dm/host/Makefile MENU_SWIFT, beam/project.yml), and it logs no names or paths."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / 'dm/ios/Sources/GameDocuments.swift'


class GameDocumentsWiring(unittest.TestCase):
    def test_built_by_the_mac_menu_and_beam(self):
        make = (REPO / 'dm/host/Makefile').read_text(encoding='utf-8')
        self.assertIn('GameDocuments.swift', re.search(r'MENU_SWIFT = (.*?)\nMENU_H', make, re.S).group(1))
        self.assertIn('../dm/ios/Sources/GameDocuments.swift', (REPO / 'beam/project.yml').read_text(encoding='utf-8'))

    def test_foundation_only_and_no_names_in_logs(self):
        src = SRC.read_text(encoding='utf-8')
        imports = set(re.findall(r'^import (\w+)', src, re.M))
        self.assertEqual(imports, {'Foundation'}, 'the viewers are each app\'s own')
        for line in re.findall(r'fputs\((.*)\)', src):
            self.assertNotRegex(line, r'\\\((url|dir|name|doc|path|p\.)', line)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class GameDocumentsCheck(unittest.TestCase):
    def test_lists_the_documents(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp); exe = tmp / 'game_documents_check'; work = tmp / 'work'; work.mkdir()
            c = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(tmp / 'module-cache'), '-o', str(exe),
                                str(SRC), str(Path(__file__).with_name('game_documents_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
            r = subprocess.run([str(exe), str(work)], capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('game documents: 0 failed', r.stdout)


if __name__ == '__main__':
    unittest.main()
