"""The Legend of Zelda: Breath of the Wild's committed prewarm list (dm/games/01007EF00011E000/pso_manifest.tsv, its README "Pipelines on a first start"): the Mac recording,
then an iPhone 18 Pro Max's own pso_user.tsv from the owner's play on release 1 (Frame rate 60, Picture Stretch) below its note. Every row must check clean against the profile's
shader map as the host reads it (dm/tools/pso_seed.py), in the counts the header and the note give, with no row repeated or dropped; the iPhone rows repeat none of the Mac rows
(pso_user.tsv records only what the list did not hold), and the C rows must be compute shaders of the map (pso_offline.py puts them first in the archive's compute groups)."""
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
        self.note = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Recorded on an iPhone 18 Pro Max'))

    def test_checks_clean(self):
        rows = [ln for ln in self.lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 4889, 'R': 1352, 'C': 15, 'M': 0, 'rows': 6256})

    def test_the_mac_rows_then_the_iphone_rows(self):
        mac = [ln for ln in self.lines[:self.note] if not ln.startswith('#')]
        phone = [ln for ln in self.lines[self.note:] if not ln.startswith('#')]
        self.assertEqual(pso_seed.counts(mac), {'S': 819, 'R': 960, 'C': 10, 'M': 0, 'rows': 1789})
        self.assertEqual(pso_seed.counts(phone), {'S': 4070, 'R': 392, 'C': 5, 'M': 0, 'rows': 4467})
        self.assertFalse({pso_seed.identity(r) for r in mac} & {pso_seed.identity(r) for r in phone})

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertNotIn('Provisional', ''.join(head))
        rec = self.lines[self.note]
        self.assertIn('Picture Stretch', rec)
        self.assertEqual(re.search(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec).groups(), ('4467', '4070', '392', '5'))
        top = next(ln for ln in head[:4] if ln.startswith('# Then, below the Mac rows'))
        self.assertEqual(re.search(r'In all (\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', top).groups(), ('6256', '4889', '1352', '15'))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 15)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
