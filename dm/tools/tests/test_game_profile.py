# dm/games/game.py's profile-key validation, on a synthetic profile: pso_gpu (the GPU architectures the app's offline pipeline archive is made for) takes, none and no others; the retired pso_mtl4 is tolerated (on silently, off with a warning, never an error),
# and a profile without the key generates its header unchanged; present_sharpen's levels, off without the key; present_trim's ticks, -1 (the host's default: 60 on iOS, off on the Mac) without the key; post_aa's values, off without the key; the game's upscaler shaders (the launcher's Game's upscaler) are the compute shaders its shader map found in agl_ndsr.pck
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
GAME = REPO / 'dm/games/game.py'
ID = '0100000000F0F000'
TSV = ('title_id\t' + ID + '\nname\tTest\nprogram_id\t' + ID + '\nmodules\tmain\nromfs_marker\tromfs.img\n'   # what a header needs beside the keys under test
       'mem_reserve\t0x100000\nmem_alias\t0x100000\nmem_stack\t0x100000\napp_pool\t0x100000\n')


def header(rows):
    """game.py header of a synthetic profile with these extra rows: (exit code, its output)"""
    with tempfile.TemporaryDirectory() as d:
        Path(d, ID).mkdir()
        (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
        r = subprocess.run([sys.executable, str(GAME), 'header', ID, str(Path(d, ID) / 'game.h')],
                           env={**os.environ, 'DM_GAMES_DIR': d}, capture_output=True, text=True)
    return r.returncode, (r.stderr + r.stdout).strip()


class PsoGPU(unittest.TestCase):
    def test_valid_tokens(self):
        for rows in ('', 'pso_gpu\tg18p\n', 'pso_gpu\tapplegpu_g19p\n',   # without the key: the header is made as before, no message
                     'pso_gpu\tg18p g19p\n', 'pso_gpu\tg14s g15s g16s g17p\n', 'pso_mtl4\ton\npso_gpu\tg18p\n'):
            rc, out = header(rows)
            self.assertEqual((rc, out), (0, ''), rows)

    def test_rejected_tokens(self):
        for rows in ('pso_gpu\tnone\n',                     # none is not a value: absence of the key says no archive of its own
                     'pso_gpu\tg18p none\n', 'pso_gpu\tx g18p!\n', 'pso_gpu\tg14s g15s g16s g17p g18p\n',
                     'pso_gpu\tapplegpu_g19p,x\n'):
            rc, out = header(rows)
            self.assertNotEqual(rc, 0, rows)
            self.assertIn(': pso_gpu takes 1-4 whitespace-separated GPU architectures', out, rows)


class PsoMtl4(unittest.TestCase):   # retired: upstream profiles still carry it, and no value stops a build
    def test_tolerated(self):
        for value, warned in (('on', False), ('off', True), ('maybe', True)):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as d:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + f'pso_mtl4\t{value}\n')
                r = subprocess.run([sys.executable, str(GAME), 'header', ID, str(Path(d, ID) / 'game.h')], env={**os.environ, 'DM_GAMES_DIR': d}, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual('pso_mtl4' in r.stderr and 'ignored' in r.stderr, warned, r.stderr)
                self.assertNotIn('PSO_MTL4', (Path(d, ID) / 'game.h').read_text())   # the host reads no such macro



def sharpen_macro(rows):
    """DM_GAME_PRESENT_SHARPEN of a synthetic profile's header with these extra rows"""
    with tempfile.TemporaryDirectory() as d:
        Path(d, ID).mkdir()
        (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
        subprocess.run([sys.executable, str(GAME), 'header', ID, str(Path(d, ID) / 'game.h')], env={**os.environ, 'DM_GAMES_DIR': d}, check=True, capture_output=True)
        return [l for l in (Path(d, ID) / 'game.h').read_text().splitlines() if 'PRESENT_SHARPEN' in l]


class PresentSharpen(unittest.TestCase):   # the present's Sharpening by default (settings.tsv DM_PRESENT_SHARPEN's levels 0 to 3)
    def test_levels_and_the_default(self):
        self.assertEqual(sharpen_macro(''), ['#define DM_GAME_PRESENT_SHARPEN 0'])   # without the key: off
        for i, v in enumerate(('off', 'low', 'medium', 'high')):
            self.assertEqual(sharpen_macro(f'present_sharpen\t{v}\n'), [f'#define DM_GAME_PRESENT_SHARPEN {i}'], v)

    def test_rejected_values(self):
        for v in ('2', 'Medium', 'max', ''):   # the settings row's numbers are not the key's words; an empty value is no level either
            rc, out = header(f'present_sharpen\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('present_sharpen must be off, low, medium or high', out, v)


class PresentTrim(unittest.TestCase):   # DM_PRESENT_TRIM's K by default (nvn_mtl.m present_trim_k): display-link ticks in a row with two or more frames waiting before one is dropped
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'PRESENT_TRIM' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_PRESENT_TRIM -1'])   # without the key: the host's default (nvn_mtl.m present_trim_k: 60 on iOS, off on the Mac)
        for v in ('0', '30', '60', '600'):   # an explicit 0 is off on iOS too
            self.assertEqual(self.macro(f'present_trim\t{v}\n'), [f'#define DM_GAME_PRESENT_TRIM {v}'], v)

    def test_rejected_values(self):
        for v in ('1', '29', '601', '-60', '-1', '60.0', 'on', ''):   # -1 is the macro without the key, not a value   # under 30 ticks a run of frame-time jitter alone could trigger it and drop the frames DM_PRESENT_FIFO keeps
            rc, out = header(f'present_trim\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('present_trim must be 0 (off) or 30 to 600 display-link ticks', out, v)

    def test_profiles_that_set_it(self):   # a game that sets it was run with it on a device, and its note says what it measured: Ocarina of Time (iPhone 18 Pro Max, 30 fps, enqueue to display about 85 -> 53 ms)
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_PRESENT_TRIM 60'])
        on = []
        for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv')):
            keys = dict(l.split('\t', 1) for l in tsv.read_text(encoding='utf-8').splitlines() if '\t' in l and not l.startswith('#'))
            if 'present_trim' not in keys: continue   # an explicit 0 needs its note too: it turns the iOS default off for the game
            on.append(tsv.parent.name); note = tsv.parent / 'README.md'
            self.assertIn('present_trim', note.read_text(encoding='utf-8') if note.is_file() else '', f'{tsv.parent.name}: its README.md should give the device run behind present_trim')
        self.assertIn('0400486024DEC000', on)


class PostAA(unittest.TestCase):   # the present's edge smoothing by default (settings.tsv DM_POST_AA's values, nvn_upscale_pick.h aa_parse)
    def macro(self, rows):
        with tempfile.TemporaryDirectory() as d:
            Path(d, ID).mkdir()
            (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
            subprocess.run([sys.executable, str(GAME), 'header', ID, str(Path(d, ID) / 'game.h')], env={**os.environ, 'DM_GAMES_DIR': d}, check=True, capture_output=True)
            return [l for l in (Path(d, ID) / 'game.h').read_text().splitlines() if 'POST_AA' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_POST_AA "off"'])   # without the key: off
        for v in ('off', 'edge', 'edge-sharp'):
            self.assertEqual(self.macro(f'post_aa\t{v}\n'), [f'#define DM_GAME_POST_AA "{v}"'], v)

    def test_rejected_values(self):
        for v in ('ab', 'on', 'Edge', '1', ''):   # ab is a measurement switch, never a profile's default; an empty value is no choice either
            rc, out = header(f'post_aa\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('post_aa must be off, edge or edge-sharp', out, v)

    def test_no_profile_turns_it_on(self):   # HUD and text are smoothed with the scene until a game has a hook before its HUD: a default waits for a device A/B and captures
        for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv')):
            keys = dict(l.split('\t', 1) for l in tsv.read_text(encoding='utf-8').splitlines() if '\t' in l and not l.startswith('#'))
            self.assertEqual(keys.get('post_aa', 'off').strip(), 'off', tsv.parent.name)


MAP = ('# kind: evidence  Test shaders\n# column 5 records where each key first appears\npackage\tindex\tstage\tdm_ctl_sha16\tsource\n'
       'cs_other.bin\t1\tcompute\tc56db3d5a0f1b5af\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.release.sarc.zs/agl_ndsr.pck#NDSR@0x124900\n'
       'cs_other.bin\t2\tcompute\t7629d857a0a93833\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.debug.sarc.zs/agl_ndsr.pck#NDSR@0xeb4c0\n'
       'cs_other.bin\t3\tcompute\t7629d857a0a93833\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.release.sarc.zs/agl_ndsr.pck#NDSR@0x124a00\n'   # a key twice: once
       'ps_other.bin\t4\tpixel\t0e423e497f1e3355\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.release.sarc.zs/agl_ndsr.pck#NDSR@0x1247d8\n'   # the pack's draw shaders: not the upscaler
       'cs_other.bin\t5\tcompute\t0123456789abcdef\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.release.sarc.zs/agl_common.sharcb#BAHS@0x40\n')


def macros(shader_map):
    """The upscaler macros of a synthetic profile's header, with this shader map (None: none)"""
    with tempfile.TemporaryDirectory() as d:
        Path(d, ID).mkdir()
        (Path(d, ID) / 'game.tsv').write_text(TSV)
        if shader_map is not None: (Path(d, ID) / 'shader_map.tsv').write_text(shader_map)
        subprocess.run([sys.executable, str(GAME), 'header', ID, str(Path(d, ID) / 'game.h')], env={**os.environ, 'DM_GAMES_DIR': d}, check=True, capture_output=True)
        return [l for l in (Path(d, ID) / 'game.h').read_text().splitlines() if 'UPSCALER' in l]


class UpscalerKeys(unittest.TestCase):
    def test_from_shader_map(self):
        none = ['#define DM_GAME_UPSCALER_KEYS ""', '#define DM_GAME_UPSCALER_N 0']   # the launcher hides the setting
        self.assertEqual(macros(None), none)
        self.assertEqual(macros(MAP.split('cs_other.bin')[0]), none)
        self.assertEqual(macros(MAP), ['#define DM_GAME_UPSCALER_KEYS "7629d857a0a93833,c56db3d5a0f1b5af"', '#define DM_GAME_UPSCALER_N 2'])


if __name__ == '__main__':
    unittest.main()


class BuildModules(unittest.TestCase):
    """Versions of a game with different modules (Mario Kart World: the base game has main subsdk0 sdk, 1.8.0 main subsdk0 subsdk1 sdk): each build row's own modules, in the load order
    of modules, go into the header for the host (main.c profile_modules picks the row of main's build), `game.py modules` gives the same list for a folder of rewritten modules, and a
    module a row names that modules does not list stays unloaded (Hades' subsdk0 and subsdk1)"""
    ROWS = ('modules\tmain subsdk0 subsdk1 sdk\n'
            'build\tv0\t1.0.0\tmain=' + 'a' * 32 + '\tsubsdk0=' + 'b' * 32 + '\tsdk=' + 'c' * 32 + '\n'
            'build\tv917504\t1.8.0\tmain=' + 'd' * 32 + '\tsubsdk1=' + 'e' * 32 + '\tsubsdk0=' + 'f' * 32 + '\tsdk=' + '1' * 32 + '\n')

    def run_game(self, rows, *args):
        with tempfile.TemporaryDirectory() as d:
            Path(d, ID).mkdir()
            (Path(d, ID) / 'game.tsv').write_text(TSV.replace('modules\tmain\n', '') + rows)
            args = [a.replace('{d}', d) for a in args]
            mods = Path(d, 'patched'); mods.mkdir()
            (mods / 'main.fixups.tsv').write_text('# PATCH_OFF\t0x1000\n# BUILD_ID\t' + 'd' * 32 + '\n')
            r = subprocess.run([sys.executable, str(GAME), *args], env={**os.environ, 'DM_GAMES_DIR': d}, capture_output=True, text=True)
            text = Path(d, 'game.h').read_text() if Path(d, 'game.h').exists() else ''
        return r, text

    def test_header_rows(self):
        r, text = self.run_game(self.ROWS, 'header', ID, '{d}/game.h')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('#define DM_GAME_MODULES {"main", "subsdk0", "subsdk1", "sdk"}', text)
        self.assertIn('#define DM_GAME_BUILD_MODULES {"' + 'a' * 32 + '", "main subsdk0 sdk"}, {"' + 'd' * 32 + '", "main subsdk0 subsdk1 sdk"}', text)

    def test_modules_of_a_rewritten_folder(self):
        r, _ = self.run_game(self.ROWS, 'modules', ID, '{d}/patched')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'main subsdk0 subsdk1 sdk'), r.stderr)   # main's build is 1.8.0's
        r, _ = self.run_game(self.ROWS.replace('d' * 32, '2' * 32), 'modules', ID, '{d}/patched')
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'main subsdk0 subsdk1 sdk'), r.stderr)   # no row for its build: the profile's modules

    def test_modules_in_a_folder(self):
        sys.path.insert(0, str(REPO / 'dm/games'))
        import game
        with tempfile.TemporaryDirectory() as d:
            Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV.replace('modules\tmain\n', '') + self.ROWS)
            g = game.Game(Path(d, ID))
            for name in ('main', 'sdk', 'subsdk0'): Path(d, name).write_bytes(b'')
            self.assertEqual(g.modules_in(d), ['main', 'subsdk0', 'sdk'])
            self.assertEqual(g.build_modules()['a' * 32], ['main', 'subsdk0', 'sdk'])

    def test_unlisted_module_not_loaded(self):
        r, text = self.run_game(self.ROWS.replace('subsdk1=', 'subsdk2='), 'header', ID, '{d}/game.h')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('{"' + 'd' * 32 + '", "main subsdk0 sdk"}', text)
