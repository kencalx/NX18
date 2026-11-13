"""Ocarina of Time's committed prewarm list (dm/games/0400486024DEC000/pso_manifest.tsv, its README "Frame rate"): Mac and iPad recordings, then blocks from an iPhone 18 Pro
Max's own Documents/pso_user.tsv, each below its own note. The last block is that phone's file after two runs of test build 4 (3d4aa08e, 2026-11-13): every one of its 29 lines,
since the list above named none of them. Every row must check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), none refused or repeated;
the last block (in the recorded order, which the recording outside the repo confirms, not this test) repeats no row above it, and its C rows must be compute shaders of the map (pso_offline.py puts the C rows first in the
archive's compute groups)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/0400486024DEC000'


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        self.lines = [ln for ln in self.text.split('\n') if ln]
        self.test4 = next(i for i, ln in enumerate(self.lines) if ln.startswith('# The rows below:') and '3d4aa08e' in ln)

    def rows(self, lines):
        return [ln for ln in lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row

    def test_checks_clean_none_refused(self):
        rows = self.rows(self.lines)
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 11576, 'R': 2742, 'C': 336, 'M': 164, 'rows': 14818})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 14818)

    def test_test_build_4_block(self):
        above, block = self.rows(self.lines[:self.test4]), self.lines[self.test4 + 1:]
        self.assertEqual(len(above), 14789, 'the rows above the block stay as they were')
        self.assertFalse([ln for ln in block if ln.startswith('#')], 'the block is the last one')
        keep, bad = pso_seed.collect(block, self.shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 0, 'R': 19, 'C': 10, 'M': 0, 'rows': 29}))
        self.assertEqual(len({pso_seed.identity(r) for r in block}), 29)
        self.assertFalse({pso_seed.identity(r) for r in above} & {pso_seed.identity(r) for r in block}, 'no row above names one of the block\'s')
        self.assertTrue(all(len(r) == 2 + 1024 for r in block if r.startswith('R\t')))   # X1.0's keys carry the border field

    def test_test_build_4_note(self):
        note = self.lines[self.test4]
        for word in ('Documents/pso_user.tsv', 'iPhone 18 Pro Max', 'iOS 27.3', 'two runs', 'test build 4', '3d4aa08e', 'chain 222e58e346d6', 'v131072', 'handheld',
                     'Picture Stretch', '2026-11-13', 'none named above, none repeated, none refused', '162.5 ms', '7 new pipelines'):
            self.assertIn(word, note)
        self.assertEqual(re.search(r'all (\d+) of its lines \((\d+) R, (\d+) C;', note).groups(), ('29', '19', '10'))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines[self.test4 + 1:] if ln.startswith('C\t')]
        self.assertEqual(len(c), 10)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
