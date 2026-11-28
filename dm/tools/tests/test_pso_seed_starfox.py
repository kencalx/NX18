"""Star Fox's committed prewarm list (dm/games/0400E88025B1A000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone 18 Pro Max's own pso_user.tsv from
the owner's play on X1.0 (handheld, Picture Stretch) over two starts, the first after a fresh install with no list. Every row must check clean against the profile's shader map as
the host reads it (dm/tools/pso_seed.py), none refused, in the counts its header gives, with no row repeated or dropped; the provisional profile's line is gone, and the C rows
must be compute shaders of the map (pso_offline.py puts them first in the archive's compute groups)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/0400E88025B1A000'


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
        self.assertEqual(pso_seed.counts(keep), {'S': 700, 'R': 738, 'C': 15, 'M': 0, 'rows': 1453})   # the X1.0 recording, X2.0 sessions, NXNative's ring course rows, the owner's 11-24 run, upstream's inbox rows, then upstream's rows since 1a54371cf
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 1453)
        self.assertEqual(pso_seed.counts(pso_seed.collect(rows[-208:-130], self.shmap)[0]), {'S': 43, 'R': 35, 'C': 0, 'M': 0, 'rows': 78})   # NXNative 8e38d3e03's
        self.assertEqual(pso_seed.counts(pso_seed.collect(rows[-130:], self.shmap)[0]), {'S': 0, 'R': 130, 'C': 0, 'M': 0, 'rows': 130})   # upstream's rows since 1a54371cf (5cbfbfea7, ada6bba01, 39fdbff96), last
        self.assertEqual(pso_seed.counts(pso_seed.collect(rows[:999], self.shmap)[0]), {'S': 542, 'R': 443, 'C': 14, 'M': 0, 'rows': 999})   # the recording comes first

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertTrue(head[0].startswith('# Prewarm seed list'))
        self.assertNotIn('Provisional', ''.join(head))
        self.assertTrue(all(ln.startswith('#') for ln in self.lines[:len(head)]), 'the notes stand above the rows')
        rec = next(ln for ln in head if ln.startswith('# Recorded on an iPhone 18 Pro Max'))
        for word in ('X1.0', '6448f757', 'chain 222e58e346d6', 'v131072', 'handheld', 'Picture Stretch', 'fresh install', 'Documents/pso_user.tsv'):
            self.assertIn(word, rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec), ('999', '542', '443', '14'))
        self.assertEqual(self.found(r'recording (\d+) rows .* the (\d+) rows they did not hold', rec), ('929', '70'))
        self.assertIn('no row refused', next(ln for ln in head if 'pso_seed.py check' in ln))
        up = next(ln for ln in head if ln.startswith('# Added on 2026-11-27 from upstream NXNative 8e38d3e03'))
        self.assertIn('78 rows (43 S, 35 R, 0 C)', up)
        up2 = next(ln for ln in head if ln.startswith("# Added on 2026-11-28 from upstream NXNative's list at 7bc66e5a3"))
        self.assertIn('130 rows (0 S, 130 R, 0 C)', up2)
        self.assertIn('21 rows with a key this list already holds not repeated', up2)

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 15)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
