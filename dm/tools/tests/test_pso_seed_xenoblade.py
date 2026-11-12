"""Xenoblade Chronicles: Definitive Edition's committed prewarm list (dm/games/0100FF500E34A000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone's
first recording (build 9e592228), then an iPhone 18 Pro Max's own pso_user.tsv from the owner's play on release 1 (the 60 fps mod, Picture Stretch) below its note. Every row must
check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), except exactly the six _bg0 / _bgv geometry-variant rows of the first part, which the
prewarm drops at load; the counts must match the header and the note, with no row repeated, and the release-1 rows repeat none of the first rows (pso_user.tsv records only
what the list did not hold)."""
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
        self.note = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Recorded on an iPhone 18 Pro Max'))

    def test_checks_clean_but_the_six_geometry_variants(self):
        rows = [ln for ln in self.lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual(len(bad), 6)
        self.assertTrue(all(re.search(r'_bg[0v]', str(b)) for b in bad), bad)
        self.assertEqual(pso_seed.counts(keep), {'S': 3301, 'R': 567, 'C': 0, 'M': 0, 'rows': 3868})
        self.assertEqual(len(rows), 3874)

    def test_the_first_rows_then_the_release_1_rows(self):
        first = [ln for ln in self.lines[:self.note] if not ln.startswith('#')]
        phone = [ln for ln in self.lines[self.note:] if not ln.startswith('#')]
        self.assertEqual(len(first), 3659)
        keep, bad = pso_seed.collect(phone, self.shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 69, 'R': 146, 'C': 0, 'M': 0, 'rows': 215}))
        self.assertFalse({pso_seed.identity(r) for r in first} & {pso_seed.identity(r) for r in phone})

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        rec = self.lines[self.note]
        self.assertIn('Picture Stretch', rec)
        self.assertIn('60 fps mod', rec)
        self.assertEqual(re.search(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec).groups(), ('215', '69', '146', '0'))
        top = next(ln for ln in head[:4] if ln.startswith('# Then, below the first rows'))
        self.assertEqual(re.search(r'In all (\d+) rows: (\d+) S, (\d+) R, (\d+) C', top).groups(), ('3874', '3305', '569', '0'))


if __name__ == '__main__':
    unittest.main()
