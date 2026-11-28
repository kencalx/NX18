"""Super Mario Bros. Wonder – Nintendo Switch 2 Edition's committed prewarm list (dm/games/040015100B514001/pso_manifest.tsv): the owner's iPhone 18 Pro Max pso_user.tsv
from the first runs of this program (2026-11-27, two sessions; the second's list holds the first's rows, then its own), below their notes. The profile registers no shader map
(game.tsv tables_from split: each build takes its tables from its own split, scripts/build_ipa_from_nsp.py split_tables), so the rows are checked here as the host reads them
(dm/tools/pso_seed.py) against the map their own S and C rows give: every R and K row's shaders are S rows of the list at the stage the row names. At build time the list is
checked against the split's map (seed_check). The counts must match the notes, no row is repeated, and the recording's K rows (one-draw passes with no pass-as-compute kernel,
which ask the next shader build for one) are kept in their place, as in Ocarina of Time's 2026-11-25 phone import; the recordings had no G rows."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/040015100B514001'
STAGE_NAMES = {0: 'vertex', 1: 'pixel', 2: 'geometry', 3: 'hull', 4: 'domain', 5: 'compute'}


def own_map(rows):   # {key: stage name} from the list's S and C rows, as shmap_load gives a map's
    out = {}
    for r in rows:
        c = r.split('\t')
        if c[0] == 'S' and len(c) == 3 and c[2].isdigit(): out.setdefault(c[1][:-2], STAGE_NAMES.get(int(c[2]), '?'))
        elif c[0] == 'C' and len(c) == 2: out.setdefault(c[1][:-2], 'compute')
    return out


class Committed(unittest.TestCase):
    def setUp(self):
        self.text = (GAME / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        self.lines = [ln for ln in self.text.split('\n') if ln]
        self.rows = [ln for ln in self.lines if not ln.startswith('#')]

    def test_profile_takes_its_tables_from_the_split(self):
        tsv = (GAME / 'game.tsv').read_text(encoding='utf-8')
        self.assertRegex(tsv, r'(?m)^tables_from\tsplit$')
        self.assertRegex(tsv, r'(?m)^render_cond\ton$')   # the silhouettes the phone drew solid (Mario's body, the slab under the fountain)
        for name in ('shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv', 'pso_pairs.tsv'):
            self.assertFalse((GAME / name).exists(), f'{name}: a registered table would be compared with the split, which differs between layouts')
        self.assertTrue((GAME / 'shader_map.tsv.conflicts.tsv').is_file())   # dmsh_build.py reads the rulings beside the map: the derived profile copies them

    def test_checks_clean_with_no_repeat(self):
        keep, bad = pso_seed.collect(self.rows, own_map(self.rows))
        self.assertEqual(bad, [])
        self.assertEqual(len(keep), len(self.rows))
        self.assertEqual(pso_seed.counts(keep), {'S': 6990, 'R': 815, 'C': 14, 'M': 0, 'K': 15, 'rows': 7834})

    def test_a_stage_mismatch_is_refused(self):   # the list's own map still catches a row that names a shader at another stage
        k = next(r for r in self.rows if r.startswith('K\t'))
        _, vs, fs = k.split('\t')
        wrong = [f'S\t{vs}_b\t0', f'S\t{fs}_b\t0']   # the pixel shader filed as a vertex one
        _, bad = pso_seed.collect(wrong + [k], own_map(wrong))
        self.assertEqual([r for r, _ in bad], [k])

    def test_k_rows_kept_no_g_rows(self):
        k = [r for r in self.rows if r.startswith('K\t')]
        self.assertEqual(len(k), 15)
        self.assertEqual(self.rows.index(k[0]), 1256)   # in the order of first use, not appended at the end
        self.assertEqual(self.rows.index(k[-1]), 7241)
        self.assertFalse([r for r in self.rows if r.startswith('G\t')])

    def test_note_counts_and_source(self):
        first = [ln for ln in self.lines if ln.startswith('# Grown from an iPhone 18 Pro Max')]
        second = [ln for ln in self.lines if ln.startswith("# Grown from the owner's second iPhone 18 Pro Max")]
        self.assertEqual((len(first), len(second)), (1, 1))
        m = re.search(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\), (\d+) M, (\d+) K', first[0])
        if m is None: self.fail(f'no count line in {first[0]!r}')
        self.assertEqual(m.groups(), ('6302', '6217', '73', '0', '0', '12'))
        self.assertIn('96ed6c798', first[0])
        m = re.search(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\), (\d+) M, (\d+) K', second[0])
        if m is None: self.fail(f'no count line in {second[0]!r}')
        self.assertEqual(m.groups(), ('941', '773', '164', '1', '0', '3'))
        self.assertIn('53dd77a29', second[0])
        self.assertLess(self.lines.index(first[0]), self.lines.index(self.rows[0]))   # each note above the rows it names
        self.assertEqual(self.lines.index(second[0]), self.lines.index(self.rows[6302]) - 1)

    def test_upstream_rows_since_the_last_check(self):   # upstream's R and C rows new since 1a54371cf whose shaders the list's S and C rows name, below the phone rows
        up = [ln for ln in self.lines if ln.startswith("# Added on 2026-11-28 from upstream NXNative's list at 7bc66e5a3")]
        self.assertEqual(len(up), 1)
        self.assertEqual(self.lines.index(up[0]), self.lines.index(self.rows[7243]) - 1)
        m = re.search(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\), (\d+) M', up[0])
        if m is None: self.fail(f'no count line in {up[0]!r}')
        self.assertEqual(m.groups(), ('591', '0', '578', '13', '0'))
        self.assertEqual(pso_seed.counts(self.rows[7243:]), {'S': 0, 'R': 578, 'C': 13, 'M': 0, 'rows': 591})
        for word in ('7071a5ef2', '39fdbff96', '98 refused rows'): self.assertIn(word, up[0])


if __name__ == '__main__':
    unittest.main()
