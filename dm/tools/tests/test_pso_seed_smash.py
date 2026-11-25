"""Super Smash Bros. Ultimate's committed prewarm list (dm/games/01006A800016E000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone 18 Pro Max's own
pso_user.tsv from the owner's play (update 13.0.5), which came without a log. Every row must check clean against the profile's shader map as the host reads it
(dm/tools/pso_seed.py), none refused, in the counts its header gives, with no row repeated or dropped; the provisional profile's line is gone, the header says what is not known
of the run, the R rows are the X1.0 line's (the border field: 1,024 hex digits), and the C rows must be compute shaders of the map (pso_offline.py puts them first in the
archive's compute groups)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/01006A800016E000'


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        self.lines = [ln for ln in self.text.split('\n') if ln]

    def found(self, pattern, text):
        """re.search(pattern, text).groups(), or the test fails naming the pattern"""
        m = re.search(pattern, text)
        if m is None: self.fail(f'{pattern!r} not in {text!r}')
        return m.groups()

    def test_checks_clean_none_refused(self):
        rows = [ln for ln in self.lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 13051, 'R': 4752, 'C': 14, 'M': 0, 'rows': 17817})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 17817)
        self.assertEqual(pso_seed.counts(keep[:17282]), {'S': 12804, 'R': 4465, 'C': 13, 'M': 0, 'rows': 17282})   # the rows before 2026-11-17's
        self.assertEqual(pso_seed.counts(keep[:16266]), {'S': 12328, 'R': 3925, 'C': 13, 'M': 0, 'rows': 16266})
        self.assertEqual({len(r.split('\t')[1]) for r in rows if r.startswith('R\t')}, {1024})

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertTrue(head[0].startswith('# Prewarm seed list'))
        self.assertNotIn('Provisional', ''.join(head))
        self.assertTrue(all(ln.startswith('#') for ln in self.lines[:len(head)]), 'the notes stand above the rows')
        rec = next(ln for ln in head if ln.startswith('# Recorded on an iPhone 18 Pro Max'))
        for word in ('13.0.5', 'v2031616', 'Documents/pso_user.tsv', 'No log.txt', 'not known', 'border field'):
            self.assertIn(word, rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec), ('10303', '9169', '1128', '6'))
        self.assertIn('no row refused', next(ln for ln in head if 'pso_seed.py check' in ln))
        grown = next(ln for ln in head if ln.startswith('# Grown on 2026-11-15'))   # the second session (build 431d5d18), with its log
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown), ('5963', '3159', '2797', '7'))
        grown2 = next(ln for ln in head if ln.startswith('# Grown on 2026-11-16'))   # the third session (build 29dcbb4d)
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown2), ('1016', '476', '540', '0'))
        grown3 = next(ln for ln in head if ln.startswith('# Grown on 2026-11-17'))   # the chain ae1dd68dc11c runs
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown3), ('535', '247', '287', '1'))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 14)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
