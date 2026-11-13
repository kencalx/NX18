"""Xenoblade Chronicles: Definitive Edition's committed prewarm list (dm/games/0100FF500E34A000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone's
first recording (build 9e592228), then an iPhone 18 Pro Max's own pso_user.tsv from the owner's play on 0.5 (the 60 fps mod, Picture Stretch) below its note, then the same
iPhone's pso_user.tsv from the owner's play on X1.0 (the same settings) below its own note. Every row must check clean against the profile's shader map as the host reads it
(dm/tools/pso_seed.py), except exactly the six _bg0 / _bgv geometry-variant rows of the first part, which the prewarm drops at load; the counts must match the header and the
notes, with no row repeated, and each later part repeats no row of the parts above it
(pso_seed.py add leaves out what the list names)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/0100FF500E34A000'


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        self.lines = [ln for ln in self.text.split('\n') if ln]
        self.note = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Recorded on an iPhone 18 Pro Max') and 'on 0.5' in ln)
        self.x1 = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Recorded on an iPhone 18 Pro Max') and 'on X1.0' in ln)

    def rows(self, lines):
        return [ln for ln in lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row

    def test_checks_clean_but_the_six_geometry_variants(self):
        rows = self.rows(self.lines)
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual(len(bad), 6)
        self.assertTrue(all(re.search(r'_bg[0v]', str(b)) for b in bad), bad)
        self.assertEqual(pso_seed.counts(keep), {'S': 3869, 'R': 837, 'C': 0, 'M': 0, 'rows': 4706})
        self.assertEqual(len(rows), 4712)

    def test_the_first_rows_then_the_0_5_rows_then_the_x1_0_rows(self):
        self.assertLess(self.note, self.x1)
        first = self.rows(self.lines[:self.note])
        phone = self.rows(self.lines[self.note:self.x1])
        x1 = self.rows(self.lines[self.x1:])
        self.assertEqual(len(first), 3659)
        keep, bad = pso_seed.collect(phone, self.shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 69, 'R': 146, 'C': 0, 'M': 0, 'rows': 215}))
        keep, bad = pso_seed.collect(x1, self.shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 568, 'R': 270, 'C': 0, 'M': 0, 'rows': 838}))
        ids = [{pso_seed.identity(r) for r in part} for part in (first, phone, x1)]
        self.assertFalse(ids[0] & ids[1])
        self.assertFalse((ids[0] | ids[1]) & ids[2])
        self.assertTrue(all(len(r) == 2 + 1024 for r in x1 if r.startswith('R\t')))   # X1.0's keys carry the border field

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        for i, want in ((self.note, ('215', '69', '146', '0')), (self.x1, ('838', '568', '270', '0'))):
            rec = self.lines[i]
            self.assertIn('Picture Stretch', rec)
            self.assertIn('60 fps mod', rec)
            self.assertEqual(re.search(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\b', rec).groups(), want)
        self.assertIn('6448f757', self.lines[self.x1])
        top = next(ln for ln in head[:4] if ln.startswith('# Then, below the first rows'))
        self.assertEqual(re.findall(r'did not hold, (\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', top), [('215', '69', '146', '0'), ('838', '568', '270', '0')])
        self.assertEqual(re.search(r'In all (\d+) rows: (\d+) S, (\d+) R, (\d+) C', top).groups(), ('4712', '3873', '839', '0'))


if __name__ == '__main__':
    unittest.main()
