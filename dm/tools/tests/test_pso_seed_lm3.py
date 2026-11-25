"""Luigi's Mansion 3's committed prewarm list (dm/games/0100DCA0064A6000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone 18 Pro Max's own pso_user.tsv
from the owner's play on X1.0 (docked, Picture Stretch) over two starts, the first after X1.0 was installed over an older install whose rows the file still held. Every row must
check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), none refused, in the counts its header gives, with no row repeated; the provisional
profile's line is gone, the three geometry-kernel rows the host's prewarm drops (86a76ee7f14336b3_bg1 / _bgv) are left out as the header says, and the C row must be a compute
shader of the map (pso_offline.py puts it first in the archive's compute groups). Below X1.0's rows, the R rows of an earlier iPhone list it did not hold (NX 18 port of 14ea5ad2),
with their own header notes."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/0100DCA0064A6000'


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
        # X1.0's 5,663 rows, then the 269 R rows of the earlier iPhone list (NX 18 port of 14ea5ad2) it did not hold,
        # then the 92 R rows of the 2026-11-15 session (build 431d5d18) less its geometry-path rows,
        # then the 73 R rows of the 2026-11-16 session (build 29dcbb4d) the list lacked, less its geometry-path rows,
        # then the 9 R rows of the 2026-11-17 runs (chain ae1dd68dc11c) the list lacked, less its geometry-path rows
        self.assertEqual(pso_seed.counts(keep), {'S': 5317, 'R': 788, 'C': 1, 'M': 0, 'rows': 6106})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 6106)
        self.assertEqual(pso_seed.counts(keep[:6097]), {'S': 5317, 'R': 779, 'C': 1, 'M': 0, 'rows': 6097})
        self.assertEqual(pso_seed.counts(keep[:6024]), {'S': 5317, 'R': 706, 'C': 1, 'M': 0, 'rows': 6024})
        self.assertEqual(pso_seed.counts(keep[:5932]), {'S': 5317, 'R': 614, 'C': 1, 'M': 0, 'rows': 5932})
        self.assertEqual(pso_seed.counts(keep[:5663]), {'S': 5317, 'R': 345, 'C': 1, 'M': 0, 'rows': 5663}, 'X1.0\'s recorded rows first, in their order')
        self.assertEqual({r.split('\t')[1][:-2] for r in rows if r.startswith('S\t')}, set(self.shmap), 'every shader of the map, once')
        self.assertFalse([r for r in rows if '_bg' in r or '5f626776' in r or '5f626731' in r], 'the geometry kernels\' rows are left out')

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertTrue(head[0].startswith('# Prewarm seed list'))
        self.assertNotIn('Provisional', ''.join(head))
        self.assertTrue(all(ln.startswith('#') for ln in self.lines[:len(head)]), 'the notes stand above the rows')
        rec = next(ln for ln in head if ln.startswith('# Recorded on an iPhone 18 Pro Max'))
        for word in ('X1.0', '6448f757', 'chain 222e58e346d6', 'v327680', 'docked', 'Picture Stretch', '(0.5)', 'Documents/pso_user.tsv'):
            self.assertIn(word, rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec), ('5663', '5317', '345', '1'))
        self.assertEqual(self.found(r'held (\d+) lines .* recording (\d+) rows they did not hold \((\d+) kept here\)', rec), ('5579', '88', '87'))
        out = next(ln for ln in head if ln.startswith('# Left out'))
        for word in ('86a76ee7f14336b3_bg1', '86a76ee7f14336b3_bgv', 'warm_map_stage', 'the R row'):
            self.assertIn(word, out)
        self.assertIn('no row refused', next(ln for ln in head if 'pso_seed.py check' in ln))
        add = next(ln for ln in head if ln.startswith('# Added (NX 18 port of 14ea5ad2)'))
        for word in ('d0f144d9', 'the last 269 R rows', '8b771499d5dda384', '86a76ee7f14336b3', 'border field'):
            self.assertIn(word, add)
        self.assertIn('5932 rows, 5317 S, 614 R, 1 C', next(ln for ln in head if ln.startswith('# Checked with dm/tools/pso_seed.py on X1.0')))
        grown = next(ln for ln in head if ln.startswith('# Grown on 2026-11-15'))   # the 431d5d18 session, with its log
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown), ('92', '0', '92', '0'))
        for word in ('431d5d18', '_bgv', '--drop-invalid', '3a6ba698f2b1d9a2', '8b771499d5dda384'):
            self.assertIn(word, grown)
        grown2 = next(ln for ln in head if ln.startswith('# Grown on 2026-11-16'))   # the 29dcbb4d session, with its log
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown2), ('73', '0', '73', '0'))
        for word in ('29dcbb4d', '_bgv', '--drop-invalid', '3190f30b989e314e'):
            self.assertIn(word, grown2)
        grown3 = next(ln for ln in head if ln.startswith('# Grown on 2026-11-17'))   # the chain ae1dd68dc11c runs
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', grown3), ('9', '0', '9', '0'))
        for word in ('ae1dd68dc11c', '_bgv', '--drop-invalid', '3190f30b989e314e'):
            self.assertIn(word, grown3)

    def test_compute_row_is_a_map_compute_shader(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 1)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
