"""Luigi's Mansion 3's committed prewarm list (dm/games/0100DCA0064A6000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone 18 Pro Max's own pso_user.tsv
from the owner's play on X1.0 (docked, Picture Stretch) over two starts, the first after X1.0 was installed over an older install whose rows the file still held. Every row must
check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), none refused, in the counts its header gives, with no row repeated; the provisional
profile's line is gone, the three geometry-kernel rows the host's prewarm drops (86a76ee7f14336b3_bg1 / _bgv) are left out as the header says, and the C row must be a compute
shader of the map (pso_offline.py puts it first in the archive's compute groups)."""
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

    def test_checks_clean_none_refused(self):
        rows = [ln for ln in self.lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 5317, 'R': 345, 'C': 1, 'M': 0, 'rows': 5663})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 5663)
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
        self.assertEqual(re.search(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec).groups(), ('5663', '5317', '345', '1'))
        self.assertEqual(re.search(r'held (\d+) lines .* recording (\d+) rows they did not hold \((\d+) kept here\)', rec).groups(), ('5579', '88', '87'))
        out = next(ln for ln in head if ln.startswith('# Left out'))
        for word in ('86a76ee7f14336b3_bg1', '86a76ee7f14336b3_bgv', 'warm_map_stage', 'the R row'):
            self.assertIn(word, out)
        self.assertIn('no row refused', next(ln for ln in head if 'pso_seed.py check' in ln))

    def test_compute_row_is_a_map_compute_shader(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 1)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
