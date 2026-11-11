"""Shaders a game compiles with its own GLSLC while it is played, past the boot the NSP script's capture runs (Catherine: Full Body compiles one whenever its shader cache has no file
for a material): the host saves the outputs its shader map does not name to glslc_play/ beside the save (hle_glslc.c), the NSP script takes such folders into <version dir>/glslc_play
(gather_glslc_play), and shader_split.py gives each new key a /glslc_play/ row. Synthetic GLSLC outputs only, no game files."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts')); sys.path.insert(0, str(REPO / 'dm/games'))
import build_ipa_from_nsp as nsp   # noqa: E402
import game   # noqa: E402

GAME = '01007BB017812000'


def glslc_output(marker, variant=0):
    """One whole single-stage GLSLC output (magic 0x19866891, its own length at +0x44, a control section with the code area after it). variant changes a header byte only: another file, the same shader key"""
    ctl, code = bytearray(0x880), bytearray(0x100)
    ctl[:4] = bytes.fromhex('34127698')
    struct.pack_into('<I', ctl, 0x20, len(ctl))
    struct.pack_into('<I', ctl, 0x704, len(code))
    code[:4] = bytes.fromhex('78563412')
    struct.pack_into('<I', code, 0x30, 1 << 10 | 1)   # vertex SPH
    code[0x80] = marker
    data = bytearray(0x70) + ctl + code
    data[:4] = bytes.fromhex('91688619')
    struct.pack_into('<I', data, 0x44, len(data))
    data[0x08] = variant
    return bytes(data)


def fnv_name(b): return f'{nsp.fnv1a64(b):016x}.glslc'


def rows(text):   # {source folder and file: key} of a shader map's data rows
    return {c[4].split('#')[0]: c[3] for c in (l.split('\t') for l in text.splitlines() if l and not l.startswith(('#', 'package\t')))}


class SplitReadsPlay(unittest.TestCase):
    def split(self, root, play=None):
        out = root / 'out'; shutil.rmtree(out, ignore_errors=True); out.mkdir()
        env = dict(os.environ, DM_GAME=GAME, J='1')
        for name in ('DM_GLSLC_CAPTURE', 'DM_GLSLC_PLAY', 'DM_UE_SHADERS', 'DM_GAMES_DIR'): env.pop(name, None)
        if play: env['DM_GLSLC_PLAY'] = str(play)
        paths = [out / n for n in ('pkg', 'map.tsv', 'facts.tsv', 'pairs.tsv', 'pso.tsv')]
        r = subprocess.run([sys.executable, REPO / 'dm/gfx/tools/shader_split.py', root / 'v0/RomFS', root / 'main', *paths], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return (out / 'map.tsv').read_text()

    def test_play_captures_get_rows_of_their_own(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); (root / 'v0/RomFS').mkdir(parents=True); (root / 'main').write_bytes(b'NSO0' + bytes(0xfc))
            boot, again, new = glslc_output(1), glslc_output(1, variant=7), glslc_output(2)
            (root / 'v0/glslc_capture').mkdir(); (root / 'v0/glslc_capture' / fnv_name(boot)).write_bytes(boot)
            without = rows(self.split(root))
            self.assertEqual(list(without), [f'/glslc_capture/{fnv_name(boot)}'])
            play = root / 'v0/glslc_play'; play.mkdir()
            for b in (again, new): (play / fnv_name(b)).write_bytes(b)
            (play / '._x.glslc').write_bytes(b'\0\5\26\7' + bytes(60))   # AppleDouble metadata is not an input
            got = rows(self.split(root))
            # the boot's row stays as it is; the new shader gets a /glslc_play/ row, the copy of the boot's shader none
            self.assertEqual(got, {**without, f'/glslc_play/{fnv_name(new)}': got.get(f'/glslc_play/{fnv_name(new)}')})
            self.assertEqual(len(set(got.values())), 2)
            self.assertEqual(rows(self.split(root, play=play)), got)   # DM_GLSLC_PLAY names the folder as well


class GatherPlay(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        self.prof = self.tmp / 'profile'; self.prof.mkdir()
        (self.prof / 'game.tsv').write_text(f'title_id\t{GAME}\n')
        self.d = self.tmp / 'extract/v0'; self.d.mkdir(parents=True)
        self.said = []
        p = mock.patch.object(nsp, 'say', side_effect=self.said.append); p.start(); self.addCleanup(p.stop)

    def test_takes_whole_outputs_named_by_their_hash(self):
        a, b = glslc_output(1), glslc_output(2)
        s1, s2 = self.tmp / 'nsp/glslc_play', self.tmp / 'device'
        s1.mkdir(parents=True); s2.mkdir()
        (s1 / fnv_name(a)).write_bytes(a)
        (s2 / fnv_name(a)).write_bytes(a); (s2 / fnv_name(b)).write_bytes(b)
        (s2 / '0123456789abcdef.glslc').write_bytes(b)   # renamed: not the name hle_glslc.c gives it
        (s2 / fnv_name(glslc_output(3))).write_bytes(glslc_output(3)[:-8])   # cut short
        (s2 / '._x.glslc').write_bytes(b'\0\5\26\7')
        g = game.Game(self.prof)
        got = nsp.gather_glslc_play(self.d, [s1, s2, self.tmp / 'absent'], g)
        self.assertEqual(got, {fnv_name(a), fnv_name(b)})
        self.assertEqual(sorted(p.name for p in (self.d / 'glslc_play').iterdir()), sorted(got))
        self.assertEqual(sum('[RED]' in s and 'FNV-1a' in s for s in self.said), 2)
        # the profile names one more than the folders hold: the build says those draws stay missing
        (self.prof / 'shader_map.tsv').write_text(f'vs_other.bin\t0\tvertex\t{"1" * 16}\t/glslc_play/{"f" * 16}.glslc#GLSLC@0x0\n')
        self.said.clear(); nsp.gather_glslc_play(self.d, [s1, s2], game.Game(self.prof))
        self.assertTrue(any(s.startswith('[RED] the profile names 1 shaders') for s in self.said))
        # nothing supplied any more: the folder goes, so the split's inputs follow the sources
        shutil.rmtree(s1); shutil.rmtree(s2)
        self.assertEqual(nsp.gather_glslc_play(self.d, [s1, s2], g), set())
        self.assertFalse((self.d / 'glslc_play').exists())

    def test_default_sources(self):
        src = nsp.glslc_play_sources(self.tmp / 'nsp', self.tmp / 'work', 0x0100BF00112C0000, ['~/x'])
        self.assertEqual(src[0], Path.home() / 'x')
        self.assertIn(self.tmp / 'nsp/glslc_play', src); self.assertIn(self.tmp / 'work/run/glslc_play', src)
        self.assertEqual(src[-1], Path.home() / 'Library/Application Support/nxnative/0100BF00112C0000/glslc_play')

    def test_boot_capture_wants_only_boot_rows(self):
        (self.prof / 'shader_map.tsv').write_text(f'vs_other.bin\t0\tvertex\t{"1" * 16}\t/glslc_capture/{"a" * 16}.glslc#GLSLC@0x0\n'
                                                  f'vs_other.bin\t1\tvertex\t{"2" * 16}\t/glslc_play/{"b" * 16}.glslc#GLSLC@0x0\n')
        self.assertEqual(nsp.glslc_wanted(game.Game(self.prof)), {'a' * 16 + '.glslc'})

    def test_tables_differing_only_in_play_rows_derive(self):
        tables = self.tmp / 'tables'; tables.mkdir()
        base = 'vs_data.bin\t0\tvertex\tbase\t/data/a.vs#GLSLC@0x0\n'
        played = 'vs_other.bin\t0\tvertex\tplay\t/glslc_play/aaaaaaaaaaaaaaaa.glslc#GLSLC@0x0\n'
        (self.prof / 'shader_map.tsv').write_text(base + played); (self.prof / 'shader_facts.tsv').write_text('')
        g = game.Game(self.prof)
        for name, split, want in (('play capture not supplied', base, True),
                                  ('another play capture', base + played.replace('play\t', 'more\t').replace('a' * 16, 'b' * 16), True),
                                  ('the same', base + played, False),
                                  ('a game file differs', base.replace('base', 'other') + played, False)):
            with self.subTest(name):
                (tables / 'shader_map.tsv').write_text(split); (tables / 'shader_facts.tsv').write_text('')
                self.assertEqual(nsp.dlc_only_shader_change(g, tables), want)


HARNESS = r'''
#include "hle_glslc.c"
static uint8_t g_status[16], *g_out; static const uint8_t *g_res[2];
static uint8_t fake_compile(void *obj) { (void)obj; return 1; }
void *guest_sym(const char *name) { return strcmp(name, "glslcCompile") ? NULL : (void *)fake_compile; }
int main(int argc, char **argv) {   // each argument: a file holding one GLSLC output, compiled in turn
    g_status[0xc] = 1; const uint8_t *const *res = g_res; void *obj = &res;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
        g_out = malloc((size_t)n); fread(g_out, 1, (size_t)n, f); fclose(f);
        g_res[0] = g_status; g_res[1] = g_out;
        if (!h_glslc_Compile(obj)) return 2;
    }
    return 0;
}
'''


@unittest.skipUnless(shutil.which('clang'), 'needs clang')
class HostSavesPlay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        (cls.tmp / 'gen').mkdir(); (cls.tmp / 'gen/game_profile.h').write_text('#define DM_GAME_ID "0100000000000000"\n')
        (cls.tmp / 'harness.c').write_text(HARNESS)
        cls.exe = cls.tmp / 'harness'
        r = subprocess.run(['clang', '-Wall', '-Werror', '-Wno-unused-function', '-I', REPO / 'dm/host', '-I', cls.tmp / 'gen', '-o', cls.exe, cls.tmp / 'harness.c'], capture_output=True, text=True)
        if r.returncode: raise AssertionError(r.stderr)

    @classmethod
    def tearDownClass(cls): shutil.rmtree(cls.tmp)

    def run_host(self, root, files, **env):
        e = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}
        e.update(DM_SAVE=str(root / 'save'), **env)
        r = subprocess.run([self.exe, *files], env=e, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stderr

    def test_outputs_the_map_lacks_are_saved_beside_the_save(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); outs = [glslc_output(i) for i in (1, 2, 3)]
            files = []
            for i, b in enumerate(outs): (root / f'o{i}').write_bytes(b); files.append(root / f'o{i}')
            shmap = root / 'shader_map.tsv'   # the build has the first from its boot, the second from play
            shmap.write_text(f'vs_other.bin\t0\tvertex\t{"1" * 16}\t/glslc_capture/{fnv_name(outs[0])}#GLSLC@0x0\n'
                             f'vs_other.bin\t1\tvertex\t{"2" * 16}\t/glslc_play/{fnv_name(outs[1])}#GLSLC@0x0\n')
            log = self.run_host(root, files + files, DM_NVN_SHMAP=str(shmap))
            play = root / 'glslc_play'
            self.assertEqual(sorted(p.name for p in play.iterdir()), [fnv_name(outs[2])])
            self.assertEqual((play / fnv_name(outs[2])).read_bytes(), outs[2])
            self.assertEqual(log.count('[RED] glslc: the game compiled a shader that this build\'s shader map does not have'), 1)
            # no map: every output counts as new; DM_GLSLC_PLAY names the folder, off saves none
            other = root / 'other'
            self.run_host(root, files, DM_NVN_SHMAP=str(root / 'none.tsv'), DM_GLSLC_PLAY=str(other))
            self.assertEqual(sorted(p.name for p in other.iterdir()), sorted(fnv_name(b) for b in outs))
            shutil.rmtree(play)
            self.assertIn('not saved', self.run_host(root, files, DM_NVN_SHMAP=str(shmap), DM_GLSLC_PLAY='off'))
            self.assertFalse(play.exists())

    def test_the_capture_run_saves_every_output(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); b = glslc_output(1); (root / 'o').write_bytes(b)
            shmap = root / 'shader_map.tsv'; shmap.write_text(f'vs_other.bin\t0\tvertex\t{"1" * 16}\t/glslc_capture/{fnv_name(b)}#GLSLC@0x0\n')
            self.run_host(root, [root / 'o'], DM_NVN_SHMAP=str(shmap), DM_GLSLC_CAPTURE=str(root / 'cap'))
            self.assertEqual([p.name for p in (root / 'cap').iterdir()], [fnv_name(b)])
            self.assertFalse((root / 'glslc_play').exists())


if __name__ == '__main__': unittest.main()
