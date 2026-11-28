"""The game profile key tables_from split (dm/games/README.md): a registered profile with no shader tables takes them from each build's own split, in a shader-only derived profile
(scripts/build_ipa_from_nsp.py split_tables, as main calls it before the split), and its prewarm list is checked against that map (seed_check). Every other profile keeps the strict
comparison. Mock tool runs as in test_nsp_incremental; no game files, keys or Xcode needed."""
from pathlib import Path
import re
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_nsp_incremental import Base, REPO, game, nsp   # noqa: E402 (Base has no tests of its own: nothing runs twice)

SEED = 'S\tc97808102b93c6b8_b\t0\nS\t532ebae27e13efc9_b\t1\nK\tc97808102b93c6b8\t532ebae27e13efc9\n'
SPLIT_MAP = 'shaders.bin\t0\tvertex\tc97808102b93c6b8\t/Lib/a\nshaders.bin\t1\tpixel\t532ebae27e13efc9\t/Lib/b\n'


class SplitTables(Base):
    NAMES = ('shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv', 'pso_pairs.tsv')

    def setUp(self):
        super().setUp()
        self.repo = self.tmp / 'repo'
        for f in ('dm/gfx/tools/shader_split.py', 'dm/gfx/tools/dmsh_chain.lock', 'dm/games/game.py', 'dm/ios/tools/ios_metal.py'):
            p = self.repo / f; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('v1')
        self.pkg = self.tmp / 'work/shader/pkg'; self.logs = self.tmp / 'logs'; self.logs.mkdir()
        self.splits = 0
        self.tables = {'shader_map.tsv': SPLIT_MAP, 'shader_facts.tsv': '# facts\n', 'shader_pairs.tsv': 'c97808102b93c6b8\t532ebae27e13efc9\n', 'pso_pairs.tsv': '# none\n'}
        cm = mock.patch.object(nsp, 'run', self.split); cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)
        # the registered profile as 040015100B514001 has it: no shader tables, the key, the empty conflict rulings and a prewarm list
        (self.src / 'shader_map.tsv').unlink()
        with (self.src / 'game.tsv').open('a') as f: f.write('render_cond\ton\ntables_from\tsplit\n')
        (self.src / 'shader_map.tsv.conflicts.tsv').write_text('# kind: evidence  control-section key conflict rulings: empty\ndm_ctl_sha16\tchosen_pc\tclass\tcandidates\trecords\n')
        (self.src / 'pso_manifest.tsv').write_text('# seeds\n' + SEED)
        self.said = []
        cm = mock.patch.object(nsp, 'say', self.said.append); cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def split(self, cmd, log, env=None, cwd=None, on_line=None):   # shader_split.py: the package and the four tables
        self.splits += 1; out = Path(cmd[5]); out.mkdir(parents=True); (out / 'main.bin').write_bytes(b'pkg')   # cmd[2] is --json-paths
        for n, t in zip(self.NAMES, cmd[6:]): Path(t).write_text(self.tables[n])
        Path(log).write_text('shaders: 2 (1 vertex, 1 pixel)\n')

    def from_split(self):   # what main does for such a profile: the shader-only derived profile, then the split as its own (own = True)
        g = game.Game(self.src)
        self.assertTrue(nsp.split_tables(g))
        nsp.derive_profile(g, self.pdir, 'v0', self.ex, g.words('modules'), shader_only=True)
        d = game.Game(self.pdir)
        nsp.split_shaders(sys.executable, self.repo, [self.ex / 'RomFS'], [self.ex / 'ExeFS/main'], self.pkg, {}, self.logs, d, True)
        return g, d

    def test_the_value(self):
        g = game.Game(self.src)
        self.assertTrue(nsp.split_tables(g))
        for text, want in (('', False), ('tables_from\tregistered\n', False)):
            (self.src / 'game.tsv').write_text(re.sub(r'(?m)^tables_from\t.*\n', text, (self.src / 'game.tsv').read_text()))
            self.assertIs(nsp.split_tables(game.Game(self.src)), want)
        (self.src / 'game.tsv').write_text((self.src / 'game.tsv').read_text() + 'tables_from\tyes\n')
        with self.assertRaisesRegex(nsp.BuildError, 'tables_from must be registered or split'):
            nsp.split_tables(game.Game(self.src))

    def test_the_split_fills_the_derived_profile_and_the_registered_one_stays_without_tables(self):
        g, d = self.from_split()
        self.assertEqual(self.splits, 1)
        for n in self.NAMES:
            self.assertFalse(g.table(n).exists(), f'the registered profile got {n}')
            self.assertEqual(d.table(n).read_text(), self.tables[n])
        self.assertEqual(d.rows, g.rows)   # every registered key, render_cond among them
        self.assertEqual(d.get('render_cond'), 'on')
        for n in ('pso_manifest.tsv', 'shader_map.tsv.conflicts.tsv'): self.assertEqual(d.table(n).read_bytes(), g.table(n).read_bytes())
        self.from_split()   # the next build: the same derived folder, the split reused
        self.assertEqual(self.splits, 1)

    def test_other_layouts_split_without_a_stop(self):   # the reason for the key: another copy's split is taken as it comes
        self.from_split()
        self.tables['shader_map.tsv'] = SPLIT_MAP + 'shaders.bin\t2\tpixel\t00000000000000aa\t/SecredUber/c\n'
        (self.ex / 'RomFS/b.bin').write_bytes(b'another layout')
        _, d = self.from_split()
        self.assertEqual(self.splits, 2)
        self.assertEqual(d.table('shader_map.tsv').read_text(), self.tables['shader_map.tsv'])

    def test_a_registered_profile_keeps_the_strict_comparison(self):
        (self.src / 'game.tsv').write_text(re.sub(r'(?m)^tables_from\t.*\n', '', (self.src / 'game.tsv').read_text()))
        for n in self.NAMES: (self.src / n).write_text(self.tables[n].replace('/Lib/a', '/Lib/other'))
        g = game.Game(self.src)
        self.assertFalse(nsp.split_tables(g))
        with self.assertRaisesRegex(nsp.BuildError, 'the split shader tables differ'):
            nsp.split_shaders(sys.executable, self.repo, [self.ex / 'RomFS'], [self.ex / 'ExeFS/main'], self.pkg, {}, self.logs, g, False)

    def test_the_prewarm_list_is_checked_against_the_split(self):
        _, d = self.from_split()
        self.said.clear(); nsp.seed_check(d)
        self.assertEqual(self.said, ['prewarm list: 3 rows, every one in this build\'s shader map'])
        d.table('pso_manifest.tsv').write_text(SEED + 'S\t00000000000000bb_b\t1\n')   # a key this split lacks: a red line, not a stop (the app leaves it out)
        self.said.clear(); nsp.seed_check(d)
        self.assertEqual(len(self.said), 1)
        self.assertRegex(self.said[0], r'^\[RED\] prewarm list: 1 of 4 rows are not in this build\'s shader map, and the app leaves them out \(the first: not in the shader map: 00000000000000bb_b\)$')
        d.table('pso_manifest.tsv').unlink()
        self.said.clear(); nsp.seed_check(d)
        self.assertEqual(self.said, [])

    def test_main_derives_before_the_split_and_checks_the_list_after_it(self):
        src = (REPO / 'scripts/build_ipa_from_nsp.py').read_text(encoding='utf-8')
        body = src[src.index('def main('):]
        decide, dlc = body.index('from_split = not own and split_tables(g)'), body.index('derive_dlc = ')
        call, check = body.index('pkey = split_shaders('), body.index('if from_split: seed_check(g)')
        self.assertLess(decide, dlc)   # derived first, so the DLC and compute promotions (registered tables only) are off
        self.assertLess(call, check)
        self.assertIn('own = True', body[decide:dlc])


class WonderProfile(unittest.TestCase):
    def test_it_takes_its_tables_from_the_split(self):
        g = game.load('040015100B514001')
        self.assertTrue(nsp.split_tables(g))
        self.assertEqual(g.get('render_cond'), 'on')
        self.assertEqual(g.get('mem_map_limit'), 'on')
        self.assertEqual(g.get('app_pool'), '0x240000000')   # 9.00 GB, as the phone ran it

    def test_the_key_is_not_a_shader_input(self):   # every shader's cache key holds the nvn_* / shader_* rows (dmsh_chain.profile_rows): the key must not rebuild them
        sys.path.insert(0, str(REPO / 'dm/gfx/tools')); import dmsh_chain
        rows = dmsh_chain.profile_rows(game.load('040015100B514001'))
        self.assertNotIn(b'tables_from', rows)
        self.assertIn(b'shader_groups', rows)


if __name__ == '__main__':
    unittest.main()
