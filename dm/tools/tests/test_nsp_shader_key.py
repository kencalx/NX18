"""The NVN shader step's reuse key (scripts/build_ipa_from_nsp.py build_shaders, shader_profile_inputs): it takes from the game profile what the step reads from it, what the library's
stamp names (dm/gfx/tools/dmsh_chain.py inputs: the INPUT_TABLES and the nvn_* / shader_* rows of game.tsv), so an edit of the profile's notes, test tables or other keys reuses the libraries,
and an edit of any shader input builds them again. On a real game.py profile in a temporary folder, with the real fingerprint; no game files, keys or Xcode needed"""
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
chain = nsp.repo_module(REPO, 'dm/gfx/tools/dmsh_chain.py')
gamemod = nsp.repo_module(REPO, 'dm/games/game.py')
GID = '0100ABCD12340000'
GAME_TSV = (f'# a test profile\ntitle_id\t{GID}\nname\tTest\nmodules\tmain sdk\nfps_target\t0\npresent_interval\t1\n'
            'nvn_all_pulling\toff\nshader_key_skip\t0x10 0x20\n\n# ---- After the rewrite ----\n# used memory for the current rewritten modules\nmem_used\t0x5000000\n')
TABLES = {'shader_facts.tsv': 'k1\t{"tex":[]}\n', 'shader_map.tsv': '# map\npackage\tindex\tstage\tkey\tsource\np.bin\t0\tvs\tk1\tsrc\n', 'shader_map.tsv.conflicts.tsv': '',
          'shader_pairs.tsv': 'v p\n', 'pso_pairs.tsv': 'v p\n', 'bf_want.tsv': 'k1\n', 'dual_want.tsv': 'k1\n'}   # geo_mesh.tsv missing: a missing table counts too
OTHER = {'README.md': '# Test\n', 'bench.tsv': 'a\t1\n', 'smoke.tsv': 'a\t1\n', 'usage.tsv': 'a\t1\n', 'validated.tsv': 'a\t1\n', 'pso_manifest.tsv': 'm\n',
         'shader_facts_manual.tsv': 'k1\t{}\n', 'duo_anchor.c': 'int x;\n', 'shader_seen.tsv': 'key\tstage\n', 'c1_full.tsv': '# chain b-x\n', 'cb_extent.tsv': '# chain b-x\n', 'patches.py': 'X = 1\n'}
CHAIN = '0123456789ab'


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        self.dir = self.tmp / 'profile' / GID; self.dir.mkdir(parents=True)
        (self.dir / 'game.tsv').write_text(GAME_TSV)
        for n, t in {**TABLES, **OTHER}.items(): (self.dir / n).write_text(t)
        self.g = gamemod.Game(self.dir)
        self.env = {}
        for cm in (mock.patch.object(nsp, 'PROG', mock.Mock()), mock.patch.object(nsp, 'say', lambda m: None)):
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def key(self, g=None): return nsp.fingerprint(*nsp.shader_profile_inputs(REPO, g or self.g, self.env))

    def edit(self, name, text=None, append=None):   # text None with append None: delete the file
        p = self.dir / name
        if append is not None: p.write_text((p.read_text() if p.exists() else '') + append)
        elif text is None: p.unlink()
        else: p.write_text(text)


class ProfileInputs(Base):
    def test_the_stamp_inputs_are_what_the_chain_names(self):   # the same list and row filter as the stamp, not a copy: geo_mesh.tsv, the conflicts table and dual_want.tsv among them
        self.assertEqual(set(chain.INPUT_TABLES) - set(TABLES), {'geo_mesh.tsv'})
        items = nsp.shader_profile_inputs(REPO, self.g, self.env)
        self.assertIn(('files', [self.dir.resolve() / n for n in chain.INPUT_TABLES]), items)
        self.assertIn(chain.profile_rows(self.g), items)
        self.assertIn(b'nvn_all_pulling\toff\n', chain.profile_rows(self.g)); self.assertIn(b'shader_key_skip\t0x10 0x20\n', chain.profile_rows(self.g))

    def test_not_inputs_leave_the_key(self):
        k = self.key()
        for name in ('README.md', 'bench.tsv', 'smoke.tsv', 'usage.tsv', 'validated.tsv', 'pso_manifest.tsv', 'shader_facts_manual.tsv', 'duo_anchor.c', 'shader_seen.tsv',
                     'c1_full.tsv', 'cb_extent.tsv', 'patches.py', 'notes.txt'):
            with self.subTest(edit=name):
                self.edit(name, append='changed\n'); self.assertEqual(self.key(), k)
                self.edit(name); self.assertEqual(self.key(), k, 'deleted')
        for line in ('# address regions: 2026-11-05 (rewrite 0123)\n', '\n', 'mem_used\t0x6000000\n', 'fps_target\t60\n', 'pad_layout\tfull\n', 'heap\t0x1000\n'):
            with self.subTest(game_tsv=line):
                self.edit('game.tsv', append=line); self.assertEqual(self.key(), k)
        self.edit('game.tsv', GAME_TSV.replace('present_interval\t1', 'present_interval\t2').replace('# a test profile', '# another comment'))
        self.assertEqual(self.key(), k)

    def test_each_input_changes_the_key(self):
        def changed(what, *edit, **kw):
            k = self.key(); self.edit(*edit, **kw); self.assertNotEqual(self.key(), k, what)
        for name in chain.INPUT_TABLES:
            with self.subTest(table=name):
                changed('edited or made', name, append='k9\tx\n')
                changed('deleted', name)
                changed('made empty', name, '')
        for line in ('nvn_depth_mode\tzero_one\n', 'shader_note\tone\n', 'nvn_all_pulling\ton\n'):
            with self.subTest(row=line): changed(line, 'game.tsv', append=line)
        changed('a shader_* value', 'game.tsv', (self.dir / 'game.tsv').read_text().replace('shader_key_skip\t0x10 0x20', 'shader_key_skip\t0x10 0x30'))
        changed('an nvn_* row removed', 'game.tsv', (self.dir / 'game.tsv').read_text().replace('nvn_all_pulling\toff\n', ''))

    def test_game_tsv_read_now(self):   # the profile the build loaded before a step rewrote game.tsv (set_keys, the region check) still keys the file as the chain will read it
        k = self.key()
        self.edit('game.tsv', append='nvn_flush\ton\n')
        self.assertNotEqual(self.key(self.g), k)

    def test_profile_id(self):   # the stamp names the game: another profile of the same content is another key
        other = self.tmp / 'profile' / '0100ABCD12350000'; shutil.copytree(self.dir, other)
        self.assertNotEqual(self.key(gamemod.Game(other)), self.key())

    def test_switch_keys_every_profile_file(self):
        self.env['DM_SHADER_KEY_ALL_PROFILE'] = '1'
        self.assertEqual(nsp.shader_profile_inputs(REPO, self.g, self.env), [('files', nsp.profile_files(self.g))])
        k = self.key(); self.edit('README.md', append='x\n'); self.assertNotEqual(self.key(), k)

    def test_unreadable_profile_falls_back_to_every_file(self):   # no game.tsv (or a repository without the chain modules): the wider key, never an error here
        (self.dir / 'game.tsv').unlink()
        self.assertEqual(nsp.shader_profile_inputs(REPO, self.g, self.env), [('files', nsp.profile_files(self.g))])
        self.assertEqual(nsp.shader_profile_inputs(self.tmp / 'no-repo', self.g, self.env), [('files', nsp.profile_files(self.g))])


class Step(Base):   # build_shaders itself, with the real fingerprint: reused or run again
    def setUp(self):
        super().setUp()
        self.env = {'DM_GAME': GID, 'DM_GAMES_DIR': str(self.tmp / 'profile'), 'DM_GAMES_FIRST': '1'}   # the chain finds the test profile as a provisional one (dmsh_chain.py --inputs)
        self.sh = self.tmp / 'shader'; self.logs = self.tmp / 'logs'; self.ran = 0
        self.tool = self.tmp / 'chain_tool.py'; self.tool.write_text('v1\n')
        self.compiler = self.tmp / 'metal'; self.compiler.write_text('metal 1\n')
        for cm in (mock.patch.object(nsp, 'run', self.fake_run), mock.patch.object(nsp, 'chain_of', lambda repo: CHAIN), mock.patch.object(nsp, 'chain_tables', lambda *a: True),
                   mock.patch.object(nsp, 'shader_regressions', lambda *a: None), mock.patch.object(nsp, 'stale_shaders', lambda *a: None),
                   mock.patch.object(nsp, 'chain_files', lambda repo: [self.tool]), mock.patch.object(nsp, 'toolchain', lambda repo, env=None: (('files', [self.compiler]),)),
                   mock.patch.object(nsp.tree_tar, 'pack', lambda *a: None), mock.patch.object(nsp.tree_tar, 'unpack', lambda *a: None)):
            cm.__enter__(); self.addCleanup(cm.__exit__, None, None, None)

    def fake_run(self, cmd, log, env=None, **kw):   # own_compilers.py <pkg> <out>: a library for each target it builds
        self.ran += 1
        log.parent.mkdir(parents=True, exist_ok=True); log.write_text('shaders 1: ok 1\n')
        for d in [Path(cmd[3])] + ([Path(env['IOSOUT'])] if env.get('IOSOUT') else []):
            (d / f'b-{CHAIN}').mkdir(parents=True, exist_ok=True); (d / f'b-{CHAIN}' / 'k_b.metallib').write_bytes(b'x')

    def build(self, mac):
        before = self.ran
        nsp.build_shaders(sys.executable, REPO, self.sh, self.tmp / 'xlate/dmsh_xlate', dict(self.env, WORK=str(self.tmp)), self.logs, self.g, pkg_key='P', mac=mac)
        return self.ran - before

    def test_reuse_follows_the_inputs(self):
        for mac in (False, True):
            with self.subTest(mac=mac):
                self.sh = self.tmp / f'shader-{mac}'   # a build folder of its own: a Mac build takes an iOS build's key beside its libraries
                self.assertEqual(self.build(mac), 1)
                self.assertEqual(self.build(mac), 0, 'nothing changed')
                for name in ('README.md', 'bench.tsv', 'smoke.tsv', 'usage.tsv', 'validated.tsv'):
                    self.edit(name, append='more\n'); self.assertEqual(self.build(mac), 0, name)
                self.edit('game.tsv', append='# address regions: 2026-11-05\nfps_target\t30\n'); self.assertEqual(self.build(mac), 0, 'other game.tsv rows and comments')
                for name in chain.INPUT_TABLES:
                    self.edit(name, append=f'{name} {mac}\n'); self.assertEqual(self.build(mac), 1, name)
                self.edit('game.tsv', append=f'nvn_test\t{mac}\n'); self.assertEqual(self.build(mac), 1, 'an nvn_* row')
                self.edit('game.tsv', append=f'shader_test\t{mac}\n'); self.assertEqual(self.build(mac), 1, 'a shader_* row')

    def test_the_rest_of_the_key_is_as_before(self):   # what the step keys beside the profile: the package, the chain's tools, the compilers, the split's pso_pairs.tsv, the translation options
        self.assertEqual(self.build(False), 1)
        self.tool.write_text('v2\n'); self.assertEqual(self.build(False), 1, 'a chain tool')
        self.compiler.write_text('metal 2\n'); self.assertEqual(self.build(False), 1, 'the compilers')
        self.edit('pso_pairs.tsv'); self.assertEqual(self.build(False), 1, 'the profile\'s pairs gone')
        self.sh.mkdir(exist_ok=True); (self.sh / 'pso_pairs.tsv').write_text('v q\n'); self.assertEqual(self.build(False), 1, 'the split\'s pairs, which the step then reads')
        self.env['XLATE_REDUCED'] = '0'; self.assertEqual(self.build(False), 1, 'a translation option')
        self.assertEqual(self.build(False), 0)

    def test_the_folder_the_chain_reads(self):   # the stamp's digest, as dmsh_chain.py prints it in the step's environment: a profile folder other than the build's own counts too
        other = self.tmp / 'other'; shutil.copytree(self.dir, other / GID)
        self.env['DM_GAMES_DIR'] = str(other)
        self.assertEqual(self.build(False), 1); self.assertEqual(self.build(False), 0)
        (other / GID / 'shader_map.tsv').write_text('changed\n'); self.assertEqual(self.build(False), 1, 'the chain\'s folder, not g.dir')
        self.assertEqual(self.build(False), 0)

    def test_switch(self):
        self.env['DM_SHADER_KEY_ALL_PROFILE'] = '1'
        self.assertEqual(self.build(False), 1)
        self.edit('README.md', append='more\n'); self.assertEqual(self.build(False), 1, 'every profile file, as before')


if __name__ == '__main__':
    unittest.main()
