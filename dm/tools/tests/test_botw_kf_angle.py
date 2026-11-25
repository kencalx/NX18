"""Breath of the Wild 1.9.0's moving-platform angle stub (dm/games/01007EF00011E000/patches.py frame_step, from MacNativeGames b87be2a6f): the call to
hkQuaternion::getAngle at main+0x12d57fc goes to a stub that returns 2 atan2(|xyz|, |w|), and at target fps 0 runs getAngle as shipped. The layout is checked
without game files; with unicorn (optional) the stub runs on ARM64, atan2f answered in single precision, on turns from 0.1 mrad to 3 rad with w of either sign,
against the shipped formula 2 acos(|w|) in single precision, which reads turns under about half a milliradian as none."""
import importlib.util
import math
from pathlib import Path
import struct
import sys
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nso_asm import B, BL   # noqa: E402
try:
    import unicorn as uc
    from unicorn import arm64_const as arm
except ImportError:
    uc = arm = None

spec = importlib.util.spec_from_file_location('botw_patches', Path(__file__).resolve().parents[2] / 'games/01007EF00011E000/patches.py')
patch = importlib.util.module_from_spec(spec); spec.loader.exec_module(patch)

BASE, AREA, STATE, SCRATCH, STACK, RET = 0x10000000, 0x2000000, 0x2100000, 0x40000000, 0x40100000, 0x40200000
SITE, GET_ANGLE, ATAN2F = 0x12d57fc, 0xb06d4, 0x159ff10
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]   # rounded to single precision


TURNS = (1e-4, 2.9e-4, 4.3e-4, 8.7e-4, 1.7e-3, 1e-2, 0.5, 2.0, 3.0)


def build():
    """Run frame_step against a recording context: (words emitted at AREA, {site: (words, why)}, {site: original hex})."""
    words, puts, sites = [], {}, {}
    ctx = types.SimpleNamespace(here=lambda: AREA + 4 * len(words), emit=words.append, site=lambda off, orig: sites.__setitem__(off, orig),
                                put=lambda off, ws, why: puts.__setitem__(off, (ws, why)), state=STATE, render_scale=0, step_max=0, capabilities=set(), address=lambda off: 0)
    patch.frame_step(ctx)
    return words, puts, sites


def quaternion(turn, sign):
    axis = (0.36, -0.48, 0.8)
    return [f32(a * math.sin(turn / 2)) for a in axis] + [f32(sign * math.cos(turn / 2))]


def shipped(q):   # getAngle as the game computes it, in single precision
    return f32(2 * f32(math.acos(f32(abs(q[3])))))


class Layout(unittest.TestCase):
    def test_the_call_goes_to_the_stub(self):
        words, puts, sites = build()
        self.assertIn(SITE, puts)
        (bl,), why = puts[SITE]
        start = SITE + (((bl & 0x3ffffff) ^ 0x2000000) - 0x2000000) * 4
        self.assertEqual(bl & 0xfc000000, 0x94000000, 'a bl: the caller returns to the next instruction')
        self.assertEqual(bl, BL(SITE, start)); self.assertIn('moving platforms', why)
        i = (start - AREA) // 4
        self.assertIn(BL(start + 4 * 13, ATAN2F), words[i:i + 18], 'atan2f through the game\'s PLT stub')
        self.assertEqual(words[i + 17], B(start + 4 * 17, GET_ANGLE), 'target fps 0: getAngle as shipped')
        self.assertEqual(words[i + 2] & 0xff00001f, 0x34000011, 'cbz w17 on the target fps')
        self.assertEqual(i + 2 + ((words[i + 2] >> 5) & 0x7ffff), i + 17)

    def test_the_build_is_checked_where_it_is_read(self):
        _, _, sites = build()
        for at in (0x12d57f8, SITE, 0x12d5800, 0x12d5804, GET_ANGLE, 0xb06f8, ATAN2F, 0x159ff14, 0x159ff1c):
            self.assertIn(at, sites, f'main+{at:#x} is asserted before the stub is written')
        self.assertEqual(sites[SITE], struct.pack('<I', 0x97b76bb6).hex(), 'the original bl to getAngle')
        self.assertEqual(list(patch.FRAME_STEP), ['cd57b23fa4bbad65803d9788c01821ee'], 'only the 1.9.0 main build')


@unittest.skipIf(uc is None, 'optional ARM64 execution dependency: unicorn')
class Run(unittest.TestCase):
    def angle(self, q, fps=60.0):
        words, puts, _ = build()
        u = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        for a, n in ((BASE, AREA), (BASE + AREA, 0x10000), (BASE + STATE, 0x4000), (SCRATCH, 0x1000), (STACK, 0x10000), (RET, 0x1000)):   # main up to the stub area: unicorn 2.1 refuses overlapping maps
            u.mem_map(a, n)
        u.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)
        u.mem_write(BASE + AREA, struct.pack(f'<{len(words)}I', *words))
        for off, (ws, _) in puts.items(): u.mem_write(BASE + off, struct.pack(f'<{len(ws)}I', *ws))
        u.mem_write(BASE + STATE, struct.pack('<f', fps))
        u.mem_write(SCRATCH, struct.pack('<4f', *q))
        u.mem_write(BASE + SITE + 4, struct.pack('<I', 0xd65f03c0))   # ret: stop after the call
        for reg, v in ((arm.UC_ARM64_REG_X0, SCRATCH), (arm.UC_ARM64_REG_SP, STACK + 0x8000), (arm.UC_ARM64_REG_LR, RET)):
            u.reg_write(reg, v)
        seen = []

        def library(u, address, size, _):   # atan2f answered in single precision; getAngle as shipped, from the same quaternion
            s = lambda r: struct.unpack('<f', struct.pack('<I', u.reg_read(r) & 0xffffffff))[0]
            if address == BASE + ATAN2F: r = f32(math.atan2(s(arm.UC_ARM64_REG_S0), s(arm.UC_ARM64_REG_S1))); seen.append('atan2f')
            else: r = shipped(struct.unpack('<4f', u.mem_read(u.reg_read(arm.UC_ARM64_REG_X0), 16))); seen.append('getAngle')
            u.reg_write(arm.UC_ARM64_REG_S0, struct.unpack('<I', struct.pack('<f', float(r)))[0])
            u.reg_write(arm.UC_ARM64_REG_PC, u.reg_read(arm.UC_ARM64_REG_LR))
        for at in (ATAN2F, GET_ANGLE): u.hook_add(uc.UC_HOOK_CODE, library, begin=BASE + at, end=BASE + at)
        u.hook_add(uc.UC_HOOK_CODE, lambda u, a, n, d: u.emu_stop(), begin=BASE + SITE + 4, end=BASE + SITE + 4)
        u.emu_start(BASE + SITE, BASE + SITE + 4, count=200)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC), BASE + SITE + 4)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_SP), STACK + 0x8000)
        return struct.unpack('<f', struct.pack('<I', u.reg_read(arm.UC_ARM64_REG_S0) & 0xffffffff))[0], seen

    def test_small_turns_are_kept(self):
        lost = set()
        for turn in TURNS:
            for sign in (1, -1):
                q = quaternion(turn, sign)
                got, seen = self.angle(q)
                self.assertEqual(seen, ['atan2f'])
                self.assertLessEqual(abs(got - turn), max(2e-6, 2e-6 * turn), (turn, sign, got))
                if turn >= 1e-2: self.assertLessEqual(abs(shipped(q) - got), 1e-5 * max(1.0, turn), (turn, sign))
                if shipped(q) == 0.0: lost.add(turn)
        self.assertEqual(lost, {1e-4, 2.9e-4, 4.3e-4}, 'negative control: the shipped angle reads these turns as none')

    def test_target_fps_0_runs_get_angle_as_shipped(self):
        q = quaternion(2.9e-4, 1)
        got, seen = self.angle(q, fps=0.0)
        self.assertEqual(seen, ['getAngle']); self.assertEqual(got, 0.0)


if __name__ == '__main__':
    unittest.main()
