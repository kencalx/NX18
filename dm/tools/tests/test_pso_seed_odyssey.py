"""Super Mario Odyssey's committed prewarm list (dm/games/0100000000010000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone 18 Pro Max's own pso_user.tsv
from the owner's play on 0.5 with Ultrawide on. Every row must check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), in the counts its
header gives, with no row repeated or dropped, and the C rows must be compute shaders of the map (pso_offline.py puts them first in the archive's compute groups)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/0100000000010000'


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.shmap = pso_seed.read_map(GAME / 'shader_map.tsv')

    def found(self, pattern, text):
        """re.search(pattern, text).groups(), or the test fails naming the pattern"""
        m = re.search(pattern, text)
        if m is None: self.fail(f'{pattern!r} not in {text!r}')
        return m.groups()

    def test_checks_clean(self):
        rows = [ln for ln in self.text.split('\n') if ln and not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 15697, 'R': 1681, 'C': 14, 'M': 0, 'rows': 17392})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 17392)
        self.assertEqual(pso_seed.counts(keep[:17358]), {'S': 15694, 'R': 1650, 'C': 14, 'M': 0, 'rows': 17358})   # the rows before 2026-11-17's

    def test_header_counts_and_source(self):
        head = [ln for ln in self.text.split('\n') if ln.startswith('#')]
        self.assertNotIn('Provisional', ''.join(head))
        rec = next(ln for ln in head if ln.startswith('# Recorded on an iPhone 18 Pro Max'))
        self.assertIn('Ultrawide on', rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec), ('15895', '15164', '723', '8'))
        lines = [ln for ln in self.text.split('\n') if ln]
        self.assertTrue(all(ln.startswith('#') for ln in lines[:len(head)]), 'the notes stand above the rows')
        grown = next(ln for ln in head if ln.startswith('# Grown on 2026-11-15'))   # the second session (build 431d5d18), with its log
        self.assertIn('431d5d18', grown)
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown), ('859', '305', '551', '3'))
        added = next(ln for ln in head if ln.startswith('# Added on 2026-11-15'))   # the X1.0 list's rows the others lack
        self.assertIn('6448f757', added)
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', added), ('604', '225', '376', '3'))
        grown2 = next(ln for ln in head if ln.startswith('# Grown on 2026-11-17'))   # the chain ae1dd68dc11c runs
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown2), ('34', '3', '31', '0'))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.text.split('\n') if ln.startswith('C\t')]
        self.assertEqual(len(c), 14)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
