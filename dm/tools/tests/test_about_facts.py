"""F9 (gate-ui §18.1): About this game's facts. The control data's RatingAge (0x3040, 13 bodies, -1 for none), the profile's tested / known_issue keys, and a switchable
mod's credit.json (only a web link kept); the NSP script writes dm/facts.json and both packers copy it."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import about_facts as af
import nacp


def control(path, ages):
    b = bytearray(0x4000)
    for i in range(0x20): b[0x3040 + i] = 0xFF
    for body, age in ages.items(): struct.pack_into('<b', b, 0x3040 + nacp.RATING_BODIES.index(body), age)
    Path(path).write_bytes(bytes(b))


class Ratings(unittest.TestCase):
    def test_the_bodies_with_a_rating(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'control.nacp'; control(p, {'ESRB': 10, 'PEGI': 7, 'CERO': 0})
            self.assertEqual(nacp.ratings(p), {'CERO': 0, 'ESRB': 10, 'PEGI': 7})

    def test_missing_or_short_gives_none(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(nacp.ratings(Path(d) / 'none.nacp'), {})
            (Path(d) / 's.nacp').write_bytes(b'\0' * 100); self.assertEqual(nacp.ratings(Path(d) / 's.nacp'), {})


class Facts(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.d = Path(self.t.name)
        (self.d / 'game').mkdir(); (self.d / 'mods/60 FPS').mkdir(parents=True); (self.d / 'mods/Wide').mkdir()
        control(self.d / 'control.nacp', {'USK': 12})

    def tearDown(self): self.t.cleanup()

    def test_all_parts(self):
        (self.d / 'game/game.tsv').write_text('id\tx\ntested\tiPhone 18 Pro Max, iOS 27.3, 2026-11-15\nknown_issue\tWater looks flat in the first town\n', encoding='utf-8')
        (self.d / 'mods/60 FPS/credit.json').write_text(json.dumps({'author': 'Someone', 'link': 'https://example.org/mod', 'license': 'MIT'}), encoding='utf-8')
        (self.d / 'mods/Wide/credit.json').write_text(json.dumps({'author': 'Other', 'link': 'javascript:alert(1)'}), encoding='utf-8')
        f = af.facts(self.d / 'control.nacp', self.d / 'game', self.d / 'mods', {'fps': '60 FPS', 'ultrawide': 'Wide'})
        self.assertEqual(f['ratings'], {'USK': 12})
        self.assertEqual(f['tested'], 'iPhone 18 Pro Max, iOS 27.3, 2026-11-15')
        self.assertEqual(f['known_issue'], 'Water looks flat in the first town')
        self.assertEqual(f['mods'][0], {'role': 'High frame rate', 'name': '60 FPS', 'author': 'Someone', 'link': 'https://example.org/mod', 'license': 'MIT'})
        self.assertEqual(f['mods'][1], {'role': 'Ultrawide', 'name': 'Wide', 'author': 'Other'}, 'only a web link is kept')

    def test_nothing_but_ratings(self):
        f = af.facts(self.d / 'control.nacp', self.d / 'game', self.d / 'mods', {'fps': '60 FPS'})
        self.assertEqual(set(f), {'ratings', 'mods'}); self.assertEqual(f['mods'], [{'role': 'High frame rate', 'name': '60 FPS'}])
        self.assertEqual(af.facts(None, self.d / 'game'), {'ratings': {}})


class Packers(unittest.TestCase):
    def test_copied_into_both_apps(self):
        self.assertIn('Gen/dm/facts.json', (REPO / 'dm/ios/tools/build_ipa.sh').read_text())
        pk = (REPO / 'dm/mac/pack_app.py').read_text(); self.assertIn("'--facts'", pk); self.assertIn("dm / 'facts.json'", pk)
        src = (REPO / 'scripts/build_ipa_from_nsp.py').read_text()
        self.assertIn("('DM_FACTS', facts)", src); self.assertIn('facts=facts,', src)
        body = src[src.index('def about_facts'):src.index('def launcher_art')]
        for never in ('urlopen', 'requests', 'http'): self.assertNotIn(never, body, 'nothing is looked up online')


if __name__ == '__main__':
    unittest.main()
