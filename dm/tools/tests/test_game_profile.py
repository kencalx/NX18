# dm/games/game.py's profile-key validation, on a synthetic profile: pso_gpu (the GPU architectures the app's offline pipeline archive is made for) takes, none and no others; the retired pso_mtl4 is tolerated (on silently, off with a warning, never an error),
# and a profile without the key generates its header unchanged; present_sharpen's levels, off without the key; present_trim's ticks, -1 (the host's default: 60 on iOS, off on the Mac) without the key; post_aa's values, off without the key; the game's upscaler shaders (the launcher's Game's upscaler) are the compute shaders its shader map found in an NDSR pack, under any name or container
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


class MovieRestart(unittest.TestCase):   # a VideoToolbox movie session iOS invalidated in the background restarted at the next key frame (hle_movie.c movie_vt_restart; DM_MOVIE_RESTART overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'MOVIE_RESTART' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_MOVIE_RESTART 0'])   # without the key: off, every other game as before
        self.assertEqual(self.macro('movie_restart\ton\n'), ['#define DM_GAME_MOVIE_RESTART 1'])
        self.assertEqual(self.macro('movie_restart\toff\n'), ['#define DM_GAME_MOVIE_RESTART 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'movie_restart\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('movie_restart must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time (X1.0), and any game that sets it names it in its note
        on = [tsv.parent for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['movie_restart', 'on'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertIn('0400486024DEC000', [d.name for d in on])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_MOVIE_RESTART 1'])
        for d in on: self.assertIn('movie_restart', (d / 'README.md').read_text(encoding='utf-8') if (d / 'README.md').is_file() else '', d.name)


class FpsHoldBackoff(unittest.TestCase):   # the waits after a held probe's short run at hold 1 (nvn_fstep.h FSTEP_BURST_N; DM_FPS_HOLD_BACKOFF overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'FPS_HOLD_BACKOFF' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_FPS_HOLD_BACKOFF 0'])   # without the key: doubling, every other game as before
        self.assertEqual(self.macro('fps_hold_backoff\tburst\n'), ['#define DM_GAME_FPS_HOLD_BACKOFF 1'])
        self.assertEqual(self.macro('fps_hold_backoff\tdouble\n'), ['#define DM_GAME_FPS_HOLD_BACKOFF 0'])
        for v in ('on', '1', 'Burst', ''):
            rc, out = header(f'fps_hold_backoff\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('fps_hold_backoff must be double or burst', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time alone (X1.0), named in its note
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['fps_hold_backoff', 'burst'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_FPS_HOLD_BACKOFF 1'])
        self.assertIn('fps_hold_backoff', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class FpsResume(unittest.TestCase):   # the frame across a stay in the background on time and owing nothing (nvn_fstep.h nvn_fstep.away; DM_FPS_RESUME overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'FPS_RESUME' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_FPS_RESUME 0'])   # without the key: off, every other game as before
        self.assertEqual(self.macro('fps_resume\ton\n'), ['#define DM_GAME_FPS_RESUME 1'])
        self.assertEqual(self.macro('fps_resume\toff\n'), ['#define DM_GAME_FPS_RESUME 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'fps_resume\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('fps_resume must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time alone (X1.0), named in its note
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['fps_resume', 'on'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_FPS_RESUME 1'])
        self.assertIn('fps_resume', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class ReplayRt(unittest.TestCase):   # the NVN queue replay and encode threads' time-constraint policy (nvn_rt.h, hle_nvn.c nvn_rtw_tick; DM_REPLAY_RT overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'REPLAY_RT' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_REPLAY_RT 0'])   # without the key: off, every other game as before
        self.assertEqual(self.macro('replay_rt\ton\n'), ['#define DM_GAME_REPLAY_RT 1'])
        self.assertEqual(self.macro('replay_rt\toff\n'), ['#define DM_GAME_REPLAY_RT 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'replay_rt\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('replay_rt must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time (X1.0) alone, and it names the key in its note; Persona 4 Golden keeps the default
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['replay_rt', 'on'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_REPLAY_RT 1'])
        self.assertEqual(self.macro('', '010062B01525C000'), ['#define DM_GAME_REPLAY_RT 0'])
        self.assertIn('replay_rt', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class FrameWg(unittest.TestCase):   # the frame deadline told through a work interval (frame_wg.c, hle_nvn.c frame_wg_on; DM_FRAME_WG overrides): a test arm, off for every game
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'FRAME_WG' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_FRAME_WG 0'])
        self.assertEqual(self.macro('frame_wg\ton\n'), ['#define DM_GAME_FRAME_WG 1'])
        self.assertEqual(self.macro('frame_wg\toff\n'), ['#define DM_GAME_FRAME_WG 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'frame_wg\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('frame_wg must be on or off', out, v)

    def test_no_profile_sets_it(self):   # Ocarina of Time too: DM_FRAME_WG=1 in env.txt arms it for a run (its note says so)
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[0] == 'frame_wg' for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, [])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_FRAME_WG 0'])
        self.assertIn('DM_FRAME_WG', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class ReplaySpares(unittest.TestCase):   # 32 spare command copies and 64 spare pool tables (nvn_queue.inc nvn_replay_spares; DM_REPLAY_SPARES overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'REPLAY_SPARES' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_REPLAY_SPARES 0'])   # without the key: 4 and 16, every other game as before
        self.assertEqual(self.macro('replay_spares\ton\n'), ['#define DM_GAME_REPLAY_SPARES 1'])
        self.assertEqual(self.macro('replay_spares\toff\n'), ['#define DM_GAME_REPLAY_SPARES 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'replay_spares\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('replay_spares must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time (X1.0) alone, and it names the key in its note; Persona 4 Golden keeps the default
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['replay_spares', 'on'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_REPLAY_SPARES 1'])
        self.assertEqual(self.macro('', '010062B01525C000'), ['#define DM_GAME_REPLAY_SPARES 0'])
        self.assertIn('replay_spares', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class DepthLazy(unittest.TestCase):   # large depth textures made placement sparse, tiles mapped where the GPU writes (nvn_mtl.m lz_make; DM_NVN_DEPTH_LAZY overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'DEPTH_LAZY' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_DEPTH_LAZY 0'])
        self.assertEqual(self.macro('depth_lazy\ton\n'), ['#define DM_GAME_DEPTH_LAZY 1'])
        self.assertEqual(self.macro('depth_lazy\toff\n'), ['#define DM_GAME_DEPTH_LAZY 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'depth_lazy\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('depth_lazy must be on or off', out, v)

    def test_no_profile_sets_it_yet(self):   # off for every game until a device A/B decides (Ocarina of Time first)
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:1] == ['depth_lazy'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, [])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_DEPTH_LAZY 0'])


class DepthZeroCopy(unittest.TestCase):   # new single-sample Depth16 / Depth32F textures zeroed by copies, not a clear pass (nvn_mtl.m tex_zero_fill; DM_DEPTH_ZERO_COPY overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'DEPTH_ZERO_COPY' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_DEPTH_ZERO_COPY 0'])   # without the key: the clear pass, every other game as before
        self.assertEqual(self.macro('depth_zero_copy\ton\n'), ['#define DM_GAME_DEPTH_ZERO_COPY 1'])
        self.assertEqual(self.macro('depth_zero_copy\toff\n'), ['#define DM_GAME_DEPTH_ZERO_COPY 0'])
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'depth_zero_copy\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('depth_zero_copy must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time alone while X1.0 is frozen, and it names the key in its note; Luigi's Mansion 3 and Persona 4 Golden keep the default
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['depth_zero_copy', 'on'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_DEPTH_ZERO_COPY 1'])
        self.assertEqual(self.macro('', '0100DCA0064A6000'), ['#define DM_GAME_DEPTH_ZERO_COPY 0'])
        self.assertEqual(self.macro('', '010062B01525C000'), ['#define DM_GAME_DEPTH_ZERO_COPY 0'])
        self.assertIn('depth_zero_copy', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class PoolIds8k(unittest.TestCase):   # a pool table's lists of IDs to take again hold 8,192 instead of 1,024 (nvn_mtl.m pool_ids_max; DM_POOL_IDS_8K overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'POOL_IDS_8K' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_POOL_IDS_8K 0'])   # without the key: 1,024, every other game as before
        self.assertEqual(self.macro('pool_ids_8k\ton\n'), ['#define DM_GAME_POOL_IDS_8K 1'])
        self.assertEqual(self.macro('pool_ids_8k\toff\n'), ['#define DM_GAME_POOL_IDS_8K 0'])
        for v in ('1', 'yes', 'On', '8192', ''):
            rc, out = header(f'pool_ids_8k\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('pool_ids_8k must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time alone while X1.0 is frozen, and it names the key in its note; Luigi's Mansion 3 and Persona 4 Golden keep the default
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[:2] == ['pool_ids_8k', 'on'] for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_POOL_IDS_8K 1'])
        self.assertEqual(self.macro('', '0100DCA0064A6000'), ['#define DM_GAME_POOL_IDS_8K 0'])
        self.assertEqual(self.macro('', '010062B01525C000'), ['#define DM_GAME_POOL_IDS_8K 0'])
        self.assertIn('pool_ids_8k', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class GhostTable(unittest.TestCase):   # the finalized-texture table's size (nvn_mtl.m ghost_cap; DM_NVN_GHOST overrides)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'GHOST_TABLE' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_GHOST_TABLE 512'])   # without the key: 512, every other game as before
        for v in ('64', '4096', '8192', '1000'):
            self.assertEqual(self.macro(f'ghost_table\t{v}\n'), [f'#define DM_GAME_GHOST_TABLE {v}'], v)
        for v in ('63', '8193', '0', '-1', 'on', '4k', ''):
            rc, out = header(f'ghost_table\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('ghost_table must be a number of textures from 64 to 8192', out, v)

    def test_profiles_that_set_it(self):   # Ocarina of Time alone, and it names the key in its note; Persona 4 Golden keeps the default
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[0] == 'ghost_table' for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['0400486024DEC000'])
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_GHOST_TABLE 4096'])
        self.assertEqual(self.macro('', '010062B01525C000'), ['#define DM_GAME_GHOST_TABLE 512'])
        self.assertIn('ghost_table', (REPO / 'dm/games/0400486024DEC000/README.md').read_text(encoding='utf-8'))


class UploadSlots(unittest.TestCase):   # upload batch slots in rotation (nvn_mtl.m up_slots_pick; DM_NVN_UP_SLOTS overrides; adapted from MacNativeGames 6ecb27c1)
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'UPLOAD_SLOTS' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_UPLOAD_SLOTS 3'])   # without the key: 3, every other game as before
        for v in ('3', '5', '8'):
            self.assertEqual(self.macro(f'upload_slots\t{v}\n'), [f'#define DM_GAME_UPLOAD_SLOTS {v}'], v)
        for v in ('2', '9', '0', '-1', 'on', '8x', ''):
            rc, out = header(f'upload_slots\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('upload_slots must be a number of slots from 3 to 8', out, v)

    def test_profiles_that_set_it(self):   # Breath of the Wild alone, and it names the key in its README; Tears of the Kingdom keeps 3 (no gain measured)
        on = [tsv.parent.name for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv'))
              if any(l.split('\t')[0] == 'upload_slots' for l in tsv.read_text(encoding='utf-8').splitlines())]
        self.assertEqual(on, ['01007EF00011E000'])
        self.assertEqual(self.macro('', '01007EF00011E000'), ['#define DM_GAME_UPLOAD_SLOTS 8'])
        self.assertEqual(self.macro('', '0100F2C0115B6000'), ['#define DM_GAME_UPLOAD_SLOTS 3'])
        self.assertIn('upload_slots', (REPO / 'dm/games/01007EF00011E000/README.md').read_text(encoding='utf-8'))


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
       'cs_other.bin\t5\tcompute\t0123456789abcdef\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.release.sarc.zs/agl_common.sharcb#BAHS@0x40\n'
       'cs_other.bin\t6\tcompute\tfa3033d05c0a41d6\t/Lib/agl/agl_resource.Nin_Ounce_NVN2.release.sarc.zs/agl_ndsr_vr_light.pck#NDSR@0x84910\n'   # Ocarina of Time's sibling packs
       'cs_other.bin\t7\tcompute\t805f2de96bd6d78d\t/Bin/Nvn2-upper_left.ndsr#NDSR@0xc4500\n'   # the pack under another engine's name (Kirby Air Riders)
       'cs_other.bin\t8\tcompute\tddc729bcdb4c8df9\t/data.zip/66e36a907a6b7251#NDSR@0x12da#NDSR@0xec640\n'   # nested in another container (Star Fox)
       'cs_other.bin\t9\tcompute\tc2fc2ddd604c25e7\t/Movie/Ndve/Ndve-Nvn2-vid_seq5.dat.zs#NDSR@0x1000\n'   # the pack inside nn::ndve's movie file
       'cs_other.bin\t10\tcompute\tba079f68ae288dba\t/Movie/Ndve/Ndve-Nvn2-vid_seq5.dat.zs#NDVE@0x1423e8\n')   # that file's own movie network: not the pack's


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
        self.assertEqual(macros(MAP), ['#define DM_GAME_UPSCALER_KEYS "7629d857a0a93833,805f2de96bd6d78d,c2fc2ddd604c25e7,c56db3d5a0f1b5af,ddc729bcdb4c8df9,fa3033d05c0a41d6"', '#define DM_GAME_UPSCALER_N 6'])




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


class YieldStorm(unittest.TestCase):   # what the host does with a yield storm (hle_thread.c ystorm_note; DM_YIELD_STORM overrides): count (the default) or sleep
    def macro(self, rows, gid=None):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, 'game.h')
            if gid is None:
                Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
                env = {**os.environ, 'DM_GAMES_DIR': d}
            else: env = {k: v for k, v in os.environ.items() if k != 'DM_GAMES_DIR'}   # a profile of the repository
            subprocess.run([sys.executable, str(GAME), 'header', gid or ID, str(out)], env=env, check=True, capture_output=True)
            return [l for l in out.read_text().splitlines() if 'YIELD_STORM' in l]

    def test_values_and_the_default(self):
        self.assertEqual(self.macro(''), ['#define DM_GAME_YIELD_STORM 0'])   # without the key: count, which changes nothing
        self.assertEqual(self.macro('yield_storm\tcount\n'), ['#define DM_GAME_YIELD_STORM 0'])
        self.assertEqual(self.macro('yield_storm\tsleep\n'), ['#define DM_GAME_YIELD_STORM 1'])
        for v in ('on', '1', 'off', 'Sleep', ''):   # DM_YIELD_STORM's 1 and 0 are not the key's words
            rc, out = header(f'yield_storm\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('yield_storm must be count or sleep', out, v)

    def test_profiles_that_sleep(self):   # Ocarina of Time sleeps (test 3's battery runs on an iPhone 18 Pro Max); a game that sleeps names the key in its note, with the device run behind it
        self.assertEqual(self.macro('', '0400486024DEC000'), ['#define DM_GAME_YIELD_STORM 1'])
        for tsv in sorted((REPO / 'dm/games').glob('*/game.tsv')):
            if not any(l.split('\t')[:2] == ['yield_storm', 'sleep'] for l in tsv.read_text(encoding='utf-8').splitlines()): continue
            note = tsv.parent / 'README.md'
            self.assertIn('yield_storm', note.read_text(encoding='utf-8') if note.is_file() else '', tsv.parent.name)


def profile_macros(rows, word):
    """The lines of a synthetic profile's header that name word, with these extra rows"""
    with tempfile.TemporaryDirectory() as d:
        Path(d, ID).mkdir()
        (Path(d, ID) / 'game.tsv').write_text(TSV + rows)
        subprocess.run([sys.executable, str(GAME), 'header', ID, str(Path(d, ID) / 'game.h')], env={**os.environ, 'DM_GAMES_DIR': d}, check=True, capture_output=True)
        return [l for l in (Path(d, ID) / 'game.h').read_text().splitlines() if word in l]


class UpscalerBilinear(unittest.TestCase):   # the game's upscaler, where MetalFX would draw it, as a bilinear stretch (nvn_mtl.m up_bil_on; DM_NVN_UP_BILINEAR overrides)
    def test_values_and_the_default(self):
        self.assertEqual(profile_macros('', 'UP_BILINEAR'), ['#define DM_GAME_UP_BILINEAR 0'])   # without the key: MetalFX
        self.assertEqual(profile_macros('upscaler_bilinear\ton\n', 'UP_BILINEAR'), ['#define DM_GAME_UP_BILINEAR 1'])
        self.assertEqual(profile_macros('upscaler_bilinear\toff\n', 'UP_BILINEAR'), ['#define DM_GAME_UP_BILINEAR 0'])

    def test_rejected_values(self):
        for v in ('1', 'yes', 'On', ''):
            rc, out = header(f'upscaler_bilinear\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('upscaler_bilinear must be on or off', out, v)

    def test_profiles_that_set_it(self):   # Donkey Kong Bananza alone, and its Quality preset turns it off
        on = [t.parent.name for t in sorted((REPO / 'dm/games').glob('*/game.tsv')) if 'upscaler_bilinear\ton' in t.read_text(encoding='utf-8').splitlines()]
        self.assertEqual(on, ['040074A01BF12000'])
        self.assertIn('preset\tquality\tDM_NVN_UP_BILINEAR=0', (REPO / 'dm/games/040074A01BF12000/game.tsv').read_text(encoding='utf-8').splitlines())


class PassAlternate(unittest.TestCase):   # passes drawn every other frame by shape (nvn_pass_alt.h): <W>x<H>:<colour>/<depth> as before, and cube:<colour>, joined by commas
    def test_values_and_the_default(self):
        self.assertEqual(profile_macros('', 'PASS_ALT'), ['#define DM_GAME_PASS_ALT_N 0', '#define DM_GAME_PASS_ALT_SHAPES {{0}}'])   # without the key: none
        self.assertEqual(profile_macros('pass_alternate\toff\n', 'PASS_ALT'), ['#define DM_GAME_PASS_ALT_N 0', '#define DM_GAME_PASS_ALT_SHAPES {{0}}'])
        self.assertEqual(profile_macros('pass_alternate\t128x128:92/252\n', 'PASS_ALT'), ['#define DM_GAME_PASS_ALT_N 1', '#define DM_GAME_PASS_ALT_SHAPES {{128, 128, 92, 252, 0}}'])   # the one-shape spelling as before
        self.assertEqual(profile_macros('pass_alternate\t128x128:92/252,cube:92\n', 'PASS_ALT'), ['#define DM_GAME_PASS_ALT_N 2', '#define DM_GAME_PASS_ALT_SHAPES {{128, 128, 92, 252, 0}, {0, 0, 92, 0, 1}}'])
        self.assertEqual(profile_macros('pass_alternate\tcube:115\n', 'PASS_ALT'), ['#define DM_GAME_PASS_ALT_N 1', '#define DM_GAME_PASS_ALT_SHAPES {{0, 0, 115, 0, 1}}'])

    def test_rejected_values(self):
        for v in ('on', '128x128:92', '128x128:92/0', '0x128:92/252', 'cube', 'cube:0', 'cube:92/252', '128x128:92/252,', '128x128:92/252 cube:92', 'cube:92,cube:92',
                  'cube:1,cube:2,cube:3,cube:4,cube:5', ''):
            rc, out = header(f'pass_alternate\t{v}\n')
            self.assertNotEqual(rc, 0, v); self.assertIn('pass_alternate', out, v)

    def test_profiles_that_set_it(self):   # Donkey Kong Bananza alone: its 128x128 view and its RG11B10Float cubes, both off in its Quality preset
        on = {t.parent.name: l.split('\t')[1] for t in sorted((REPO / 'dm/games').glob('*/game.tsv')) for l in t.read_text(encoding='utf-8').splitlines() if l.startswith('pass_alternate\t')}
        self.assertEqual(on, {'040074A01BF12000': '128x128:92/252,cube:92', '0400486024DEC000': 'cube:92'})
        rows = (REPO / 'dm/games/040074A01BF12000/game.tsv').read_text(encoding='utf-8').splitlines()
        for sw in ('DM_NVN_PASS_ALT', 'DM_NVN_CUBE_ALT'): self.assertIn(f'preset\tquality\t{sw}=0', rows)


if __name__ == '__main__':
    unittest.main()
