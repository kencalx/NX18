"""Ultrawide's camera stubs (dm/games/01007EF00011E000/patches.py and dm/games/0100F2C0115B6000/patches.py camera_aspect; adapted from ComicBit/nxnative eb9a42ba4, MIT):
each site is checked by its bytes' SHA-256 (no game code in the patch files), its words are replayed from the image, the last store takes the host's ratio at state +0x64
(0: the game's own), and only a camera update stores the ratio it wrote at +0x68, after the projection's store. Without game files: the sites' words here are the test's own
stand-ins of the same shape (a producer, a flag store, the aspect store). With unicorn (optional) the stubs run on ARM64."""
import importlib.util
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nso_asm import NOP   # noqa: E402
try:
    import unicorn as uc  # pyright: ignore[reportMissingImports]   (optional: the runs are skipped without it)
    from unicorn import arm64_const as arm  # pyright: ignore[reportMissingImports]
except ImportError:
    uc = arm = None

GAMES = Path(__file__).resolve().parents[2] / 'games'


def load(gid):
    spec = importlib.util.spec_from_file_location(f'patches_{gid}', GAMES / gid / 'patches.py')
    assert spec is not None and spec.loader is not None
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


botw, totk = load('01007EF00011E000'), load('0100F2C0115B6000')
BOTW_BUILD, TOTK_BUILD = 'cd57b23fa4bbad65803d9788c01821ee', '277178b7dba1b6d4949a84778d4abc58'
AREA, STATE = 0x3000000, 0x3100000
FMOV_S0_1 = 0x1e2e1000      # fmov s0,#1.0             the stand-in producer: the game's own ratio is 1.0 here
STRB_W1_X2_8 = 0x39002041   # strb w1,[x2,#8]          the stand-in dirty flag
STR_S0_X2_B0 = 0xbd00b040   # str s0,[x2,#0xb0]        the stand-in aspect store
STR_S0_X2_C0 = 0xbd00c040   # str s0,[x2,#0xc0]


class Ctx:
    """A recording frame-step context; words(off, n) gives the test's stand-in words; site() may refuse one offset (a mismatch)"""
    def __init__(self, words, build=None, refuse=None):
        self.cursor, self.code, self.puts, self.sites, self.order = AREA, {}, {}, {}, []
        self.state, self.render_scale, self.live_scale, self.step_max, self.capabilities = STATE, 0, 0, 0, set()
        self._words, self.refuse = words, refuse
        self.others: dict | None = None; self.base = 0   # set by a test that runs the frame step's matcher
        if build: self.build = build
    def here(self): return self.cursor
    def emit(self, w): self.code[self.cursor] = w; self.cursor += 4
    def site(self, off, orig):
        if off == self.refuse: raise AssertionError(f'frame step original bytes mismatch {off:#x}')
        self.sites[off] = orig; self.order.append(('site', off))
    def put(self, off, ws, why): self.puts[off] = (ws, why); self.order.append(('put', off))
    def words(self, off, n): return list(self._words[off][:n])
    def address(self, off): return 0


BOTW_WORDS = {0x10edae0: [FMOV_S0_1] + [NOP] * 11 + [STR_S0_X2_C0]}
TOTK_WORDS = {0x628c74: [FMOV_S0_1, STRB_W1_X2_8, STR_S0_X2_B0], 0xb43460: [FMOV_S0_1, STRB_W1_X2_8, STR_S0_X2_B0],
              0x1ff04f4: [FMOV_S0_1, STR_S0_X2_B0], 0x253fbb0: [FMOV_S0_1, STR_S0_X2_B0]}


class Layout(unittest.TestCase):
    def test_no_game_code_in_the_patch_files(self):
        for m, words in ((botw, BOTW_WORDS), (totk, TOTK_WORDS)):
            ctx = Ctx(words, build=TOTK_BUILD); m.camera_aspect(ctx)
            for off, spec in ctx.sites.items():
                kind, n, digest = spec.split(':')
                self.assertEqual((kind, len(digest)), ('sha256', 64), f'{off:#x}: checked by digest, not by its bytes')
                self.assertEqual(int(n), 4 * len(words[off]))
        self.assertEqual(set(ctx.sites), set(TOTK_WORDS))

    def test_botw_stub(self):
        ctx = Ctx(BOTW_WORDS); botw.camera_aspect(ctx)
        ws, why = ctx.puts[0x10edae0]
        self.assertEqual(len(ws), 13); self.assertEqual(ws[0] & 0xfc000000, 0x14000000); self.assertTrue(all(w == NOP for w in ws[1:]))
        code = [ctx.code[a] for a in sorted(ctx.code)]
        self.assertEqual(code[:12], BOTW_WORDS[0x10edae0][:12], 'the first 12 words replayed as they are')
        self.assertEqual(code[13:20], [0x91019108, 0x88dffd09, 0x34000049, 0x1e270120, STR_S0_X2_C0, 0x91001108, 0x889ffd09],
                         'add #0x64; ldar; cbz; fmov; the store; add #4; stlr (after the store)')
        self.assertEqual(ctx.capabilities, {'CAMERA_ASPECT'})

    def test_botw_frame_step_includes_it(self):
        self.assertIn(BOTW_BUILD, botw.FRAME_STEP)
        ctx = Ctx(BOTW_WORDS); ctx.words = lambda off, n: (BOTW_WORDS.get(off) or [NOP] * n)[:n]
        botw.FRAME_STEP[BOTW_BUILD](ctx)
        self.assertIn(0x10edae0, ctx.puts); self.assertIn('CAMERA_ASPECT', ctx.capabilities)

    def test_totk_only_on_its_build_and_all_sites_checked_first(self):
        self.assertEqual(totk.camera_build, TOTK_BUILD)
        for build, on in ((None, False), ('0' * 32, False), (TOTK_BUILD, True)):   # a dry run or another build the frame step's fingerprints match: no camera sites
            ctx = Ctx(TOTK_WORDS, build=build); ctx.others = {}; ctx.base = 0
            totk.matched_frame_step(ctx)   # (its other functions are not found here: no frame step)
            self.assertEqual(set(ctx.puts) == set(TOTK_WORDS), on); self.assertEqual('CAMERA_ASPECT' in ctx.capabilities, on)
        ctx = Ctx(TOTK_WORDS, build=TOTK_BUILD); totk.camera_aspect(ctx)
        first_put = next(i for i, (k, _) in enumerate(ctx.order) if k == 'put')
        self.assertEqual({off for k, off in ctx.order[:first_put] if k == 'site'}, set(TOTK_WORDS), 'every site checked before any is written')
        self.assertEqual(ctx.capabilities, {'CAMERA_ASPECT'})
        ctx = Ctx(TOTK_WORDS, build=TOTK_BUILD, refuse=0x253fbb0)
        with self.assertRaisesRegex(AssertionError, 'mismatch'): totk.camera_aspect(ctx)
        self.assertFalse(ctx.puts or ctx.code, 'a mismatch at the last site writes nothing')

    def test_totk_acknowledges_only_camera_updates(self):
        ctx = Ctx(TOTK_WORDS, build=TOTK_BUILD); totk.camera_aspect(ctx)
        stlr = [a for a, w in ctx.code.items() if w == 0x889ffd4b]
        self.assertEqual(len(stlr), 2, 'two camera stubs store the acknowledgement, the viewport ones none')
        for off, (ws, why) in ctx.puts.items(): self.assertEqual(len(ws), len(TOTK_WORDS[off]))


@unittest.skipIf(uc is None, 'optional ARM64 execution: unicorn')
class Runs(unittest.TestCase):
    OBJ, STACK = 0x5000000, 0x5100000

    def run_site(self, mod, words, site, ratio, build=None):
        ctx = Ctx(words, build=build); mod.camera_aspect(ctx)
        assert uc is not None and arm is not None   # the class is skipped without unicorn
        u = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        u.mem_map(0, 0x5200000)
        for a, w in ctx.code.items(): u.mem_write(a, struct.pack('<I', w))
        for a, (ws, _) in ctx.puts.items(): u.mem_write(a, struct.pack(f'<{len(ws)}I', *ws))
        u.mem_write(STATE + 0x64, struct.pack('<f', ratio)); u.mem_write(STATE + 0x68, struct.pack('<f', 9.0))
        for i in range(31): u.reg_write(getattr(arm, f'UC_ARM64_REG_X{i}'), 0x1234000 + i)
        u.reg_write(arm.UC_ARM64_REG_X2, self.OBJ); u.reg_write(arm.UC_ARM64_REG_W1, 1)
        u.reg_write(arm.UC_ARM64_REG_SP, self.STACK + 0x800); u.reg_write(arm.UC_ARM64_REG_NZCV, 0xa0000000)
        end = site + 4 * len(words[site])
        u.emu_start(site, end, count=200)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC), end)
        aspect = struct.unpack('<f', u.mem_read(self.OBJ + (0xc0 if mod is botw else 0xb0), 4))[0]
        ack = struct.unpack('<f', u.mem_read(STATE + 0x68, 4))[0]
        return u, aspect, ack

    def test_botw(self):
        assert arm is not None   # the class is skipped without unicorn
        for ratio in (0.0, 2868 / 1320):
            u, aspect, ack = self.run_site(botw, BOTW_WORDS, 0x10edae0, ratio)
            want = struct.unpack('<f', struct.pack('<f', ratio))[0]
            self.assertEqual(aspect, want or 1.0, 'the host ratio, or the game\'s own (1.0 here) at 0')
            self.assertEqual(ack, want, 'acknowledged after the store (0 too)')

    def test_totk(self):
        assert arm is not None   # the class is skipped without unicorn
        for site in TOTK_WORDS:
            for ratio in (0.0, 2868 / 1320):
                u, aspect, ack = self.run_site(totk, TOTK_WORDS, site, ratio, TOTK_BUILD)
                want = struct.unpack('<f', struct.pack('<f', ratio))[0]
                self.assertEqual(aspect, want or 1.0)
                camera = len(TOTK_WORDS[site]) == 3
                self.assertEqual(ack, want if camera else 9.0, 'only camera updates acknowledge')
                if camera: self.assertEqual(u.mem_read(self.OBJ + 8, 1), b'\x01', 'the flag store replayed')
                self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X10), 0x1234000 + 10); self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X11), 0x1234000 + 11)
                self.assertEqual(u.reg_read(arm.UC_ARM64_REG_SP), self.STACK + 0x800); self.assertEqual(u.reg_read(arm.UC_ARM64_REG_NZCV) & 0xf0000000, 0xa0000000)


if __name__ == '__main__':
    unittest.main()
