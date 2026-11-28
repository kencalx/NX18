"""Ocarina of Time's committed prewarm list (dm/games/0400486024DEC000/pso_manifest.tsv, its README "Frame rate"): Mac and iPad recordings, then blocks from an iPhone 18 Pro
Max's own Documents/pso_user.tsv, each below its own note. Test build 4's block is that phone's file after two runs of test build 4 (3d4aa08e, 2026-11-13): every one of its 29
lines, since the list above named none of them. The last block is the same phone's file after the owner's 55-minute run to Hyrule Field on build 431d5d18 (2026-11-15): all
1,489 of its lines, none named above. Every row must check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), none refused or repeated;
each phone block (in the recorded order, which the recording outside the repo confirms, not this test) repeats no row above it, and its C rows must be compute shaders of the map
(pso_offline.py puts the C rows first in the archive's compute groups)."""
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
        self.field = next(i for i, ln in enumerate(self.lines) if ln.startswith('# The rows below:') and '431d5d18' in ln)
        self.round = next(i for i, ln in enumerate(self.lines) if ln.startswith('# The rows below:') and 'd656dd60' in ln)

    def rows(self, lines):
        return [ln for ln in lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row

    def found(self, pattern, text):
        """re.search(pattern, text).groups(), or the test fails naming the pattern"""
        m = re.search(pattern, text)
        if m is None: self.fail(f'{pattern!r} not in {text!r}')
        return m.groups()

    def test_checks_clean_none_refused(self):
        rows = self.rows(self.lines)
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 19607, 'R': 11678, 'C': 1780, 'M': 285, 'K': 36, 'rows': 33386})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 33386)
        up = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Added on 2026-11-27 from upstream NXNative dc8710ec5, 41c5c8328, 95a9510c6'))
        up2 = next(i for i, ln in enumerate(self.lines) if ln.startswith("# Added on 2026-11-27 from upstream NXNative's list at 1a54371cf"))   # the second check: upstream's rows since the first
        block = self.rows(self.lines[up:up2])   # upstream's three small captures; its five bulk captures are still left out (the README)
        self.assertEqual(pso_seed.counts(block), {'S': 47, 'R': 137, 'C': 3, 'M': 2, 'rows': 189})
        self.assertIn('189 rows (47 S, 137 R, 3 C), 2 M', self.lines[up])
        self.assertFalse({pso_seed.identity(r) for r in self.rows(self.lines[:up])} & {pso_seed.identity(r) for r in block})
        up3 = next(i for i, ln in enumerate(self.lines) if ln.startswith("# Added on 2026-11-28 from upstream NXNative's list at 7bc66e5a3"))   # the third check: upstream's rows since the second
        block2 = self.rows(self.lines[up2:up3])
        self.assertEqual(pso_seed.counts(block2), {'S': 674, 'R': 1219, 'C': 197, 'M': 15, 'rows': 2105})
        self.assertIn('2090 rows (674 S, 1219 R, 197 C), 15 M', self.lines[up2])
        self.assertFalse({pso_seed.identity(r) for r in self.rows(self.lines[:up2])} & {pso_seed.identity(r) for r in block2}, 'the second check repeats none above it')
        block3 = self.rows(self.lines[up3:])   # only rows new upstream since 1a54371cf (no S rows, 28d41fc9d); its border_spare rows refused
        self.assertEqual(pso_seed.counts(block3), {'S': 0, 'R': 856, 'C': 10, 'M': 45, 'rows': 911})
        self.assertIn('911 rows (0 S, 856 R, 10 C), 45 M', self.lines[up3])
        for c in ('c79fb4d17', '4031aa56d', '045c179f1', '18a2480ac', '13105 refused rows'): self.assertIn(c, self.lines[up3])
        self.assertFalse({pso_seed.identity(r) for r in self.rows(self.lines[:up3])} & {pso_seed.identity(r) for r in block3}, 'the third check repeats none above it')

    def test_test_build_4_block(self):
        above, block = self.rows(self.lines[:self.test4]), self.lines[self.test4 + 1:self.field]
        self.assertEqual(len(above), 14789, 'the rows above the block stay as they were')
        self.assertFalse([ln for ln in block if ln.startswith('#')], 'no note inside the block')
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
        self.assertEqual(self.found(r'all (\d+) of its lines \((\d+) R, (\d+) C;', note), ('29', '19', '10'))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines[self.test4 + 1:self.field] if ln.startswith('C\t')]
        self.assertEqual(len(c), 10)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))

    def test_field_run_block(self):
        above, block = self.rows(self.lines[:self.field]), self.lines[self.field + 1:self.round]
        self.assertEqual(len(above), 14818, 'the rows above the block stay as they were')
        self.assertFalse([ln for ln in block if ln.startswith('#')], 'no note inside the block')
        keep, bad = pso_seed.collect(block, self.shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 504, 'R': 796, 'C': 178, 'M': 11, 'rows': 1489}))
        self.assertEqual(len({pso_seed.identity(r) for r in block}), 1489)
        self.assertFalse({pso_seed.identity(r) for r in above} & {pso_seed.identity(r) for r in block}, 'no row above names one of the block\'s')
        self.assertTrue(all(len(r) == 2 + 1024 for r in block if r.startswith('R\t')))
        c = [ln.split('\t')[1] for ln in block if ln.startswith('C\t')]
        self.assertTrue(c and all(self.shmap.get(k[:-2]) == 'compute' for k in c))

    def test_field_run_note(self):
        note = self.lines[self.field]
        for word in ('Documents/pso_user.tsv', 'iPhone 18 Pro Max', '55-minute run to Hyrule Field', '431d5d18', 'chain 73e39f15505b', 'v131072', 'handheld',
                     'Picture Stretch', '2026-11-15', 'none named above, none repeated, none refused', 'compiled 601 bases in play (317 s', 'prepare step'):
            self.assertIn(word, note)
        self.assertEqual(self.found(r'all (\d+) of its lines \((\d+) S, (\d+) R, (\d+) C, (\d+) M;', note), ('1489', '504', '796', '178', '11'))




class RoundBlock(unittest.TestCase):
    """The X2.0 round's block (runs 3 and 3b on d656dd60, 2026-11-16): the last one, new rows only"""
    def test_round_block(self):
        lines = [ln for ln in (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8').split('\n') if ln]
        shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        i = next(i for i, ln in enumerate(lines) if ln.startswith('# The rows below:') and 'd656dd60' in ln)
        j = next(j for j, ln in enumerate(lines) if ln.startswith('# The rows below:') and 'ae1dd68dc11c' in ln)
        above, block = [ln for ln in lines[:i] if not ln.startswith('#')], lines[i + 1:j]
        self.assertEqual(len(above), 16307, 'the rows above the block stay as they were')
        self.assertFalse([ln for ln in block if ln.startswith('#')], 'no note inside the block')
        keep, bad = pso_seed.collect(block, shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 224, 'R': 256, 'C': 17, 'M': 0, 'rows': 497}))
        self.assertFalse({pso_seed.identity(r) for r in above} & {pso_seed.identity(r) for r in block}, 'no row above names one of the block\'s')
        for word in ('iPhone 18 Pro Max', 'd656dd60', 'chain 6e77a31a0071', '2026-11-16', '497 rows', 'none named above, none repeated, none refused', '26.2 s'):
            self.assertIn(word, lines[i])



class ChainAe1dBlock(unittest.TestCase):
    """The phone's own file as copied on 2026-11-17 after the day's runs on chain ae1dd68dc11c builds: the last block, new rows only. Unlike upstream's iPhone 17 block taken
    out the same day, these rows are the phone's own list, which it prepares at every start already; listed here, the next build's archive holds their layout bases"""
    def test_chain_ae1d_block(self):
        lines = [ln for ln in (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8').split('\n') if ln]
        shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        i = next(i for i, ln in enumerate(lines) if ln.startswith('# The rows below:') and 'ae1dd68dc11c' in ln)
        k = next(k for k, ln in enumerate(lines) if ln.startswith('# Grown on 2026-11-19'))   # the next block: the X2.0 runs of 2026-11-17 to 19
        above, block = [ln for ln in lines[:i] if not ln.startswith('#')], lines[i + 1:k]
        self.assertEqual(len(above), 16804, 'the rows above the block stay as they were')
        self.assertFalse([ln for ln in block if ln.startswith('#')], 'no note inside the block')
        nxt = next((j for j in range(k + 1, len(lines)) if lines[j].startswith('#')), len(lines))   # the 2026-11-21 blocks and later follow it
        later = lines[k + 1:nxt]
        lk, lbad = pso_seed.collect(later, shmap)
        self.assertEqual((lbad, pso_seed.counts(lk)), ([], {'S': 337, 'R': 491, 'C': 61, 'M': 1, 'rows': 890}))
        self.assertFalse({pso_seed.identity(r) for r in above + block} & {pso_seed.identity(r) for r in later}, 'the 2026-11-19 rows repeat none above them')
        keep, bad = pso_seed.collect(block, shmap)
        self.assertEqual((bad, pso_seed.counts(keep)), ([], {'S': 989, 'R': 1333, 'C': 23, 'M': 2, 'rows': 2347}))
        self.assertFalse({pso_seed.identity(r) for r in above} & {pso_seed.identity(r) for r in block}, 'no row above names one of the block\'s')
        self.assertTrue(all(len(r) == 2 + 1024 for r in block if r.startswith('R\t')))
        self.assertTrue(all(shmap.get(r.split('\t')[1][:-2]) == 'compute' for r in block if r.startswith('C\t')))
        for word in ('iPhone 18 Pro Max', 'ae1dd68dc11c', '2026-11-17', '2347 rows (989 S, 1333 R, 23 C, 2 M', 'none named above, none repeated, none refused',
                     '4333 lines', 'prepare step reads the same lines'):
            self.assertIn(word, lines[i])


if __name__ == '__main__':
    unittest.main()
