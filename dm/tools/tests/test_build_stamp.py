"""G17 (gate-ui §20.5a): the build stamp. The builder's Profile name comes only from the build Mac's Profile files and must pass GW21; every build gets a new build
ID; build_ipa.sh and pack_app.py write DMBuiltBy and DMBuildID; bug reports name the build ID and replace the name on the host's "build: built by" line."""
import importlib.util
import os
from pathlib import Path
import re
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


nsp = load('build_ipa_from_nsp_stamp', REPO / 'scripts/build_ipa_from_nsp.py')
packer = load('pack_app_stamp', REPO / 'dm/mac/pack_app.py')
br = load('bug_report_stamp', REPO / 'scripts/bug_report.py')
ID = re.compile(r'^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$')


class NameRule(unittest.TestCase):
    def test_gw21(self):
        for good in ('Player 1', 'Zoë', 'あきら', "O'Neil", 'a.b_c-d', '  Link  '):
            self.assertEqual(nsp.profile_name_ok(good), good.strip(), good)
        for bad in ('', '   ', 'Player', 'ElevenChars', 'Link🎮', 'a/b', 'x<y>', None):
            self.assertIsNone(nsp.profile_name_ok(bad), bad)


class Stamp(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory(); self.base = Path(self.home.name) / 'Library/Application Support/nxnative'

    def tearDown(self): self.home.cleanup()

    def write(self, rel, text):
        p = self.base / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text, encoding='utf-8'); return p

    def test_no_profile_gives_an_id_only(self):
        name, bid = nsp.build_stamp(self.home.name)
        self.assertIsNone(name); self.assertRegex(bid, ID)

    def test_the_macs_profile(self):
        self.write('Profile/name.txt', 'Player 1\n')
        self.assertEqual(nsp.build_stamp(self.home.name)[0], 'Player 1')

    def test_the_folder_profile_when_the_mac_has_none(self):
        folder = Path(self.home.name) / 'iCloud/NX 18'
        (folder / 'Profile').mkdir(parents=True); (folder / 'Profile/name.txt').write_text('Kiki\n', encoding='utf-8')
        self.write('nx18-folder', str(folder) + '\n')
        self.assertEqual(nsp.build_stamp(self.home.name)[0], 'Kiki')

    def test_player_or_a_refused_name_is_no_name(self):
        for n in ('Player', 'Name with way too many letters', '🎮'):
            self.write('Profile/name.txt', n)
            self.assertIsNone(nsp.build_stamp(self.home.name)[0], n)

    def test_a_new_id_every_build(self):
        ids = {nsp.build_stamp(self.home.name)[1] for _ in range(20)}
        self.assertEqual(len(ids), 20)
        self.assertTrue(all(ID.match(i) for i in ids))
        self.assertRegex(packer.new_build_id(), ID)


class Packers(unittest.TestCase):
    def test_build_ipa_writes_both_keys(self):
        sh = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        self.assertIn('plutil -insert DMBuiltBy -string "$DM_BUILT_BY" Gen/Info.plist', sh)
        self.assertIn('plutil -insert DMBuildID -string "$BID" Gen/Info.plist', sh)
        self.assertIn('BID=${DM_BUILD_ID:-', sh, 'an ID even when run on its own')

    def test_the_script_hands_them_on(self):
        src = (REPO / 'scripts/build_ipa_from_nsp.py').read_text()
        self.assertIn("ipa_env['DM_BUILD_ID'] = stamp_id", src)
        self.assertIn("if built_by: ipa_env['DM_BUILT_BY'] = built_by", src)
        self.assertIn("stamp=(built_by, stamp_id)", src)
        for never in ('getpass', 'DM_TEAM_ID'):   # never the user name or the team ID in the stamp
            body = src[src.index('def build_stamp'):src.index('def ui_font_info')]
            self.assertNotIn(never, body)


class BugReport(unittest.TestCase):
    def test_the_name_is_replaced(self):
        text = '[dm] build: commit 482b7210, shader chain x, profile y\n[dm] build: built by Player 1, build ID 7K4Q-92XD, acknowledged 2026-11-16\n'
        out, _ = br.redact(text, '/Users/nobody')
        self.assertIn('build: built by (name), build ID 7K4Q-92XD', out)
        self.assertNotIn('Player 1', out)


if __name__ == '__main__':
    unittest.main()
