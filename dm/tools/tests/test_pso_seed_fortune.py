"""Fire Emblem Fortune's Weave's committed prewarm list (dm/games/04007EF01F8AE000/pso_manifest.tsv, its README "Pipelines on a first start"): the Mac recording, then an
iPhone 18 Pro Max's own pso_user.tsv from the owner's play on X1.0 (handheld, Picture Stretch, a fresh install) below its note. Every row must check clean against the profile's
shader map as the host reads it (dm/tools/pso_seed.py), none refused, in the counts the header and the note give, with no row repeated or dropped; the iPhone rows repeat none of
the Mac rows (pso_user.tsv records only what the list did not hold), and the C rows must be compute shaders of the map (pso_offline.py puts them first in the archive's compute
groups)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/04007EF01F8AE000'


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.shmap = pso_seed.read_map(GAME / 'shader_map.tsv')
        self.lines = [ln for ln in self.text.split('\n') if ln]
        self.note = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Recorded on an iPhone 18 Pro Max'))
        self.grown = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Grown on 2026-11-16'))   # the X2.0 sessions' rows
        self.grown21 = next(i for i, ln in enumerate(self.lines) if ln.startswith('# Grown on 2026-11-21'))   # a short X2.0 session's rows, last

    def found(self, pattern, text):
        """re.search(pattern, text).groups(), or the test fails naming the pattern"""
        m = re.search(pattern, text)
        if m is None: self.fail(f'{pattern!r} not in {text!r}')
        return m.groups()

    def test_checks_clean_none_refused(self):
        rows = [ln for ln in self.lines if not ln.startswith('#')]   # as the host splits them: a '\r' would stay in the row
        keep, bad = pso_seed.collect(rows, self.shmap)
        self.assertEqual((bad, len(keep)), ([], len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 3624, 'R': 2343, 'C': 84, 'M': 0, 'rows': 6051})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 6051)

    def test_the_mac_rows_then_the_iphone_rows(self):
        mac = [ln for ln in self.lines[:self.note] if not ln.startswith('#')]
        phone = [ln for ln in self.lines[self.note:self.grown] if not ln.startswith('#')]
        grown = [ln for ln in self.lines[self.grown:self.grown21] if not ln.startswith('#')]
        late = [ln for ln in self.lines[self.grown21:] if not ln.startswith('#')]
        self.assertEqual(pso_seed.counts(late), {'S': 3, 'R': 52, 'C': 0, 'M': 0, 'rows': 55})
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', self.lines[self.grown21]), ('55', '3', '52', '0'))
        self.assertFalse({pso_seed.identity(r) for r in self.lines if not r.startswith('#') and r not in late} & {pso_seed.identity(r) for r in late})
        self.assertEqual(pso_seed.counts(mac), {'S': 1343, 'R': 442, 'C': 26, 'M': 0, 'rows': 1811})
        self.assertEqual(pso_seed.counts(phone), {'S': 220, 'R': 241, 'C': 13, 'M': 0, 'rows': 474})
        self.assertFalse({pso_seed.identity(r) for r in mac} & {pso_seed.identity(r) for r in phone})
        self.assertEqual(pso_seed.counts(grown), {'S': 2058, 'R': 1608, 'C': 45, 'M': 0, 'rows': 3711})
        self.assertFalse({pso_seed.identity(r) for r in mac + phone} & {pso_seed.identity(r) for r in grown})
        self.assertFalse([r for r in grown if '_bg' in r or '5f626776' in r], 'the geometry kernels\' rows are left out')
        self.assertEqual({len(r.split('\t')[1]) for r in phone if r.startswith('R\t')}, {1024}, 'X1.0 writes the border field')

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertNotIn('Provisional', ''.join(head))
        rec = self.lines[self.note]
        for word in ('X1.0', '6448f757', 'chain 222e58e346d6', 'v131072', 'handheld', 'Picture Stretch', 'fresh install', 'Documents/pso_user.tsv'):
            self.assertIn(word, rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', rec), ('474', '220', '241', '13'))
        self.assertIn('no row refused', self.lines[self.note + 1])
        top = next(ln for ln in head[:4] if ln.startswith('# Then, below the Mac rows'))
        self.assertEqual(self.found(r'In all (\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', top), ('2285', '1563', '683', '39'))   # the two blocks above the X2.0 rows
        g = self.lines[self.grown]
        self.assertEqual(self.found(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', g), ('3711', '2058', '1608', '45'))
        self.assertEqual(self.found(r'In all (\d+) rows: (\d+) S, (\d+) R, (\d+) C\.', g), ('5996', '3621', '2291', '84'))
        for word in ('431d5d18', '29dcbb4d', '--drop-invalid', 'Documents/pso_user.tsv'):
            self.assertIn(word, g)

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 84)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))


if __name__ == '__main__':
    unittest.main()
