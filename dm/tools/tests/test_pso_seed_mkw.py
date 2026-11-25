"""Mario Kart World's committed prewarm list (dm/games/0400C3F00006E000/pso_manifest.tsv, its README "Pipelines on a first start"): an iPhone 18 Pro Max's own
pso_user.tsv from the owner's play on X1.0 (the base game v0, handheld, Picture Stretch) over two starts, the first after a fresh install with no list. Every row must check clean
against the profile's shader map as the host reads it (dm/tools/pso_seed.py), none refused, in the counts its header gives, with no row repeated or dropped; the provisional
profile's line is gone, the header names the M row form, the C rows must be compute shaders of the map (pso_offline.py puts them first in the archive's compute groups) and the
M rows native task / mesh pipelines whose task, mesh and pixel shaders are the map's (pso_offline.py builds them whole for the archive)."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/0400C3F00006E000'


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
        self.assertEqual(pso_seed.counts(keep), {'S': 5719, 'R': 3844, 'C': 155, 'M': 12, 'rows': 9730})
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), 9730)
        self.assertEqual(pso_seed.counts(keep[:6563]), {'S': 4900, 'R': 1526, 'C': 125, 'M': 12, 'rows': 6563})   # the X1.0 recording first
        grown = next(ln for ln in self.lines if ln.startswith('# Grown on 2026-11-16'))
        self.assertIn('2404 rows (652 S, 1733 R, 19 C)', grown)
        self.assertEqual(pso_seed.counts(keep[:8967]), {'S': 5552, 'R': 3259, 'C': 144, 'M': 12, 'rows': 8967})   # the rows before 2026-11-17's
        grown2 = next(ln for ln in self.lines if ln.startswith('# Grown on 2026-11-17'))   # the chain ae1dd68dc11c runs
        self.assertIn('278 rows (52 S, 224 R, 2 C)', grown2)

    def test_header_counts_and_source(self):
        head = [ln for ln in self.lines if ln.startswith('#')]
        self.assertTrue(head[0].startswith('# Prewarm seed list'))
        self.assertIn('M<TAB>task shader key or -<TAB>native task / mesh pipeline key', head[0])
        self.assertNotIn('Provisional', ''.join(head))
        self.assertTrue(all(ln.startswith('#') for ln in self.lines[:len(head)]), 'the notes stand above the rows')
        rec = next(ln for ln in head if ln.startswith('# Recorded on an iPhone 18 Pro Max'))
        for word in ('X1.0', '6448f757', 'chain 222e58e346d6', 'base game v0', 'handheld', 'Picture Stretch', 'fresh install', 'Documents/pso_user.tsv'):
            self.assertIn(word, rec)
        self.assertEqual(self.found(r'(\d+) rows: (\d+) S, (\d+) R, (\d+) C, (\d+) M\.', rec), ('6563', '4900', '1526', '125', '12'))
        self.assertEqual(self.found(r'recording (\d+) rows .* the (\d+) rows they did not hold', rec), ('6074', '489'))
        self.assertIn('no row refused', next(ln for ln in head if 'pso_seed.py check' in ln))

    def test_compute_rows_are_map_compute_shaders(self):
        c = [ln.split('\t')[1] for ln in self.lines if ln.startswith('C\t')]
        self.assertEqual(len(c), 155)
        self.assertTrue(all(self.shmap.get(k[:-2]) == 'compute' for k in c))

    def test_mesh_rows_are_map_task_mesh_pipelines(self):
        m = [ln.split('\t') for ln in self.lines if ln.startswith('M\t')]
        self.assertEqual((len(m), sum(r[1] == '-' for r in m)), (12, 5))
        for _, task, key in m:
            if task != '-': self.assertEqual(self.shmap.get(task[:-2]), 'task')
            b, why = pso_seed.parse_skey(key)
            if b is None: self.fail(f'{key}: {why}')
            (vs, _), (fs, _) = pso_seed.name_field(b[0:24]), pso_seed.name_field(b[24:48])
            self.assertEqual((self.shmap.get(vs[:-2]), self.shmap.get(fs[:-2])), ('mesh', 'pixel'))


if __name__ == '__main__':
    unittest.main()
