"""The Legend of Zelda: Breath of the Wild's committed prewarm list (dm/games/01007EF00011E000/pso_manifest.tsv, its README "Pipelines on a first start"): the Mac recording,
then an iPhone 18 Pro Max's own pso_user.tsv from the owner's play on 0.5 (Frame rate 60, Picture Stretch) below its note, then the same iPhone's pso_user.tsv after a start of
X1.0 (docked) below its own note: the rows the lists did not hold, 82 from later play on 0.5 (release 1's 1,008-digit keys) and then 153 from X1.0 (the border field, 1,024).
Every row must check clean against the profile's shader map as the host reads it (dm/tools/pso_seed.py), in the counts the header and the notes give, with no row repeated or
dropped; each part repeats none of the rows above it (pso_user.tsv records only what the list did not hold), and the C rows must be compute shaders of the map (pso_offline.py
puts them first in the archive's compute groups)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/01007EF00011E000'


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        self.lines = [ln for ln in self.text.split('\n') if ln]
        notes = [i for i, ln in enumerate(self.lines) if ln.startswith('# Recorded on an iPhone 18 Pro Max from the owner')]
        play05 = [i for i in notes if self.lines[i].startswith("# Recorded on an iPhone 18 Pro Max from the owner's play on 0.5 ")]
        playx1 = [i for i in notes if self.lines[i].startswith("# Recorded on an iPhone 18 Pro Max from the owner's play on X1.0 ")]
        self.assertEqual((len(notes), len(play05), len(playx1)), (2, 1, 1), 'one note for each phone part')
        self.note, self.x1 = play05[0], playx1[0]
        self.r3 = next(i for i, ln in enumerate(self.lines) if ln.startswith('# The rows below:') and '29dcbb4d' in ln)
        self.assertLess(self.note, self.x1, 'the 0.5 rows come before the X1.0 rows')

    def found(self, pattern, text):
        """re.search(pattern, text).groups(), or the test fails naming the pattern"""
        m = re.search(pattern, text)
        if m is None: self.fail(f'{pattern!r} not in {text!r}')
        return m.groups()

    def test_checks_clean(self):
        rows = [ln for ln in self.lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 12874, 'R': 13256, 'C': 78, 'M': 0, 'rows': 26208})

    def test_the_mac_rows_then_the_iphone_rows(self):
        mac = [ln for ln in self.lines[:self.note] if not ln.startswith('#')]
        phone = [ln for ln in self.lines[self.note:self.x1] if not ln.startswith('#')]
        x1 = [ln for ln in self.lines[self.x1:self.r3] if not ln.startswith('#')]
        r4 = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Grown on 2026-11-19'))   # the X2.0 runs' block after it
        r3 = [ln for ln in self.lines[self.r3:r4] if not ln.startswith('#')]
        r5 = next(i for i, ln in enumerate(self.lines) if ln.startswith('# iPhone 18 Pro Max play session 2026-11-24'))   # the 11-24 sessions' blocks
        up = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Added on 2026-11-27 from upstream NXNative 0a57ea236'))   # upstream's inbox rows (morning check)
        r4rows = [ln for ln in self.lines[r4:r5] if not ln.startswith('#')]
        r5rows = [ln for ln in self.lines[r5:up] if not ln.startswith('#')]
        up2 = next(i for i, ln in enumerate(self.lines) if ln.startswith("# Added on 2026-11-27 from upstream NXNative's list at 1a54371cf"))   # the second check's rows
        up3 = next(i for i, ln in enumerate(self.lines) if ln.startswith("# Added on 2026-11-28 from upstream NXNative's list at 7bc66e5a3"))   # the third check's rows, last
        uprows = [ln for ln in self.lines[up:up2] if not ln.startswith('#')]
        up2rows = [ln for ln in self.lines[up2:up3] if not ln.startswith('#')]
        up3rows = [ln for ln in self.lines[up3:] if not ln.startswith('#')]
        self.assertEqual(pso_seed.counts(mac), {'S': 819, 'R': 960, 'C': 10, 'M': 0, 'rows': 1789})
        self.assertEqual(pso_seed.counts(phone), {'S': 4070, 'R': 392, 'C': 5, 'M': 0, 'rows': 4467})
        self.assertEqual(pso_seed.counts(x1), {'S': 38, 'R': 197, 'C': 0, 'M': 0, 'rows': 235})
        ids = [{pso_seed.identity(r) for r in part} for part in (mac, phone, x1)]
        self.assertFalse(ids[0] & ids[1])
        self.assertFalse((ids[0] | ids[1]) & ids[2])
        self.assertEqual(pso_seed.counts(r3), {'S': 801, 'R': 496, 'C': 4, 'M': 0, 'rows': 1301})
        self.assertFalse((ids[0] | ids[1] | ids[2]) & {pso_seed.identity(r) for r in r3}, 'the X2.0 rows repeat none above them')
        self.assertEqual(pso_seed.counts(r4rows), {'S': 312, 'R': 127, 'C': 0, 'M': 0, 'rows': 439})
        self.assertFalse((ids[0] | ids[1] | ids[2] | {pso_seed.identity(r) for r in r3}) & {pso_seed.identity(r) for r in r4rows}, 'the 2026-11-19 rows repeat none above them')
        self.assertEqual(pso_seed.counts(r5rows), {'S': 8, 'R': 31, 'C': 0, 'M': 0, 'rows': 39})
        self.assertEqual(pso_seed.counts(uprows), {'S': 179, 'R': 34, 'C': 0, 'M': 0, 'rows': 213})
        self.assertIn('213 rows (179 S, 34 R, 0 C)', self.lines[up])
        above = set().union(*ids, *({pso_seed.identity(r) for r in part} for part in (r3, r4rows, r5rows)))
        self.assertFalse(above & {pso_seed.identity(r) for r in uprows}, 'upstream\'s rows repeat none above them')
        self.assertEqual(pso_seed.counts(up2rows), {'S': 6647, 'R': 8164, 'C': 48, 'M': 0, 'rows': 14859})
        self.assertIn('14859 rows (6647 S, 8164 R, 48 C)', self.lines[up2])
        self.assertFalse((above | {pso_seed.identity(r) for r in uprows}) & {pso_seed.identity(r) for r in up2rows}, 'the second check repeats none above it')
        self.assertEqual(pso_seed.counts(up3rows), {'S': 0, 'R': 2855, 'C': 11, 'M': 0, 'rows': 2866})   # only rows new upstream since 1a54371cf, no S rows (28d41fc9d)
        self.assertIn('2866 rows (0 S, 2855 R, 11 C)', self.lines[up3])
        self.assertFalse((above | {pso_seed.identity(r) for r in uprows + up2rows}) & {pso_seed.identity(r) for r in up3rows}, 'the third check repeats none above it')
        lengths = [len(r.split('\t')[1]) for r in x1 if r.startswith('R\t')]
        self.assertEqual((lengths[:66].count(1008), lengths[66:].count(1024)), (66, 131), 'the later 0.5 rows, then X1.0\'s with the border field')

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertNotIn('Provisional', ''.join(head))
        rec = self.lines[self.note]
        self.assertIn('Picture Stretch', rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec), ('4467', '4070', '392', '5'))
        rec = self.lines[self.x1]
        for word in ('6448f757', 'chain 222e58e346d6', 'v1114112', 'docked', 'Picture Stretch', 'edge smoothing', 'held 4549 lines', 'Documents/pso_user.tsv'):
            self.assertIn(word, rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C:', rec), ('235', '38', '197', '0'))
        self.assertIn('no row refused', self.lines[self.x1 + 1])
        top = next(ln for ln in head[:4] if ln.startswith('# Then, below the Mac rows'))
        self.assertEqual(self.found(r'In all (\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', top), ('7792', '5728', '2045', '19'))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 78)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
