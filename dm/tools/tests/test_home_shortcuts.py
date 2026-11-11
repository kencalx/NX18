"""The home screen shortcuts build_ipa.sh writes into an app's Info.plist (UIApplicationShortcutItems: Game, Launcher, Guide), run on a stand-in Gen/Info.plist without Xcode or game files:
Guide only when the app carries a game guide, a manual or About this game, its subtitle naming which, and the types the app's Swift reads (LauncherShortcuts.swift)."""
from pathlib import Path
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SCRIPT = (REPO / 'dm/ios/tools/build_ipa.sh').read_text(encoding='utf-8')
STEP = SCRIPT[SCRIPT.index('# Home screen shortcuts'):SCRIPT.index('\nRP=; if [ -n "${PROGRAMS_TSV:-}" ]')]
PREAMBLE = 'set -u\nt() { echo "$*"; }; die() { echo "$*" >&2; exit 1; }\n'
PLISTBUDDY = Path('/usr/libexec/PlistBuddy')


@unittest.skipUnless(sys.platform == 'darwin' and PLISTBUDDY.is_file(), 'PlistBuddy is macOS only')
class HomeShortcutsTests(unittest.TestCase):
    def items(self, root, **extra):
        (root / 'Gen/dm').mkdir(parents=True, exist_ok=True)
        if not (root / 'Gen/Info.plist').exists(): (root / 'Gen/Info.plist').write_bytes(plistlib.dumps({'CFBundleName': 'DmIOS'}))
        env = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}
        env.update(ROMFS=str(root / 'game/romfs.img'), **extra)
        r = subprocess.run(['/bin/bash', '-c', PREAMBLE + STEP], cwd=root, env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        info = plistlib.loads((root / 'Gen/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleName'], 'DmIOS', 'the other keys stay')
        return info['UIApplicationShortcutItems'], r.stdout

    @staticmethod
    def page(root, rel):
        p = root / 'game/html' / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('<html></html>')

    def test_three_items_with_the_game_guide(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            self.page(root, 'html1/html-document/htmlcontents.htdocs/html/USen/index.html')
            items, out = self.items(root)
            self.assertEqual([i['UIApplicationShortcutItemType'] for i in items], ['dm.shortcut.game', 'dm.shortcut.launcher', 'dm.shortcut.guide'])
            self.assertEqual([i['UIApplicationShortcutItemTitle'] for i in items], ['Game', 'Launcher', 'Guide'])
            self.assertEqual([i['UIApplicationShortcutItemIconSymbolName'] for i in items], ['play.fill', 'slider.horizontal.3', 'book.closed'])
            self.assertEqual(items[2]['UIApplicationShortcutItemSubtitle'], 'Game guide')
            self.assertIn('Guide (Game guide)', out)
            self.assertEqual(self.items(root)[0], items, 'a second run writes the same items, not twice as many')

    def test_guide_falls_back_to_the_manual_then_about(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            self.page(root, 'html0/html-document/ipnotices.htdocs/html/index.html')   # legal notices only: no guide
            (root / 'Gen/dm').mkdir(parents=True)
            (root / 'Gen/dm/about.json').write_text('{"description": "x"}')
            self.assertEqual(self.items(root)[0][2]['UIApplicationShortcutItemSubtitle'], 'About this game')
            (root / 'Gen/dm/manual.pdf').write_bytes(b'%PDF-1.7')
            self.assertEqual(self.items(root)[0][2]['UIApplicationShortcutItemSubtitle'], 'Manual', 'the manual before About, as the launcher opens it')

    def test_guide_pages_where_the_launcher_finds_them(self):
        # The pages build_ipa.sh counts are those LauncherArt.swift findGuide opens: <html>/html-document or <html>/html<n>/html-document, a .htdocs other than the legal ones,
        # with html/<LANG>/index.html, html/index.html or index.html in it. Any other layout would put a Guide item on the Home Screen that opens nothing
        found = ['html-document/guide.htdocs/index.html', 'html-document/guide.htdocs/html/index.html', 'html2/html-document/guide.htdocs/html/EUfr/index.html']
        missed = ['foo/html-document/x.htdocs/html/USen/index.html', 'html1/html-document/x.htdocs/html/USen/deeper/index.html', 'html1/html-document/x.htdocs/pages/index.html',
                  'html1/html-document/support.htdocs/index.html', 'html-document/html-document/x.htdocs/index.html', 'html1/x.htdocs/index.html']
        for rel in found + missed:
            with self.subTest(rel), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                self.page(root, rel)
                items, _ = self.items(root)
                self.assertEqual(len(items), 3 if rel in found else 2, rel)

    def test_about_only_with_text_the_launcher_shows(self):
        # LauncherAbout.hasText: a JSON object with a non-blank intro, description or publisher, or a release date YYYY-MM-DD; a name or a source alone shows nothing
        cases = {'{"intro": "x"}': True, '{"publisher": " P "}': True, '{"releaseDate": "2019-10-31"}': True, '{"description": "  \\n "}': False,
                 '{"name": "N", "source": "titledb"}': False, '{"description": 3}': False, '{"releaseDate": "soon"}': False, '["description"]': False, 'not json': False, '': False}
        for text, shown in cases.items():
            with self.subTest(text), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                (root / 'Gen/dm').mkdir(parents=True)
                (root / 'Gen/dm/about.json').write_text(text)
                items, _ = self.items(root)
                self.assertEqual([i['UIApplicationShortcutItemSubtitle'] for i in items][2:], ['About this game'] if shown else [], text)

    def test_no_guide_without_anything_to_show(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'Gen/dm').mkdir(parents=True)
            (root / 'Gen/dm/manual.pdf').write_bytes(b'')   # an empty file is none, as LauncherContent.find takes it
            items, out = self.items(root)
            self.assertEqual([i['UIApplicationShortcutItemType'] for i in items], ['dm.shortcut.game', 'dm.shortcut.launcher'])
            self.assertIn('no Guide', out)

    def test_types_agree_with_the_app_and_the_harness(self):
        swift = (REPO / 'dm/ios/Sources/LauncherShortcuts.swift').read_text(encoding='utf-8')
        self.assertIn('case game, launcher, guide', swift)
        self.assertIn('static let typePrefix = "dm.shortcut."', swift)
        self.assertEqual(re.findall(r'dm\.shortcut\.(\w+)', (REPO / 'dm/ios/tests/duo/project.yml').read_text(encoding='utf-8')), ['game', 'launcher', 'guide'])
        main = (REPO / 'dm/ios/Sources/main.m').read_text(encoding='utf-8')
        self.assertIn('dm_shortcut_cold(o.shortcutItem.type.UTF8String)', main, 'a cold start hands the shortcut to the launcher')
        self.assertIn('performActionForShortcutItem', main, 'and so does one chosen while the app runs')


if __name__ == '__main__':
    unittest.main()
