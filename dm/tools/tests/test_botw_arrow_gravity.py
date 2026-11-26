"""Breath of the Wild 1.9.0's arrow gravity stub (dm/games/01007EF00011E000/patches.py arrow_gravity, from MacNativeGames c9fb354b): the load of a falling arrow's gravity
at main+0x5ee734 goes to a stub that scales it by the VFR's ratio (+0x3c of the VFR at [main+0x1e93890]), so an arrow turns down at the 30 fps rate at any frame step. The
layout is checked without game files; with unicorn (optional) the stub runs on ARM64 at ratios 1.0 (30 fps), 0.5 (60), 0.25 (120), with no VFR and with a ratio of 0, and its
condition flags are checked unchanged."""
import importlib.util
from pathlib import Path
import struct
import sys
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nso_asm import B   # noqa: E402
try:
    import unicorn as uc  # pyright: ignore[reportMissingImports]   (optional: the runs are skipped without it)
    from unicorn import arm64_const as arm  # pyright: ignore[reportMissingImports]
except ImportError:
    uc = arm = None

spec = importlib.util.spec_from_file_location('botw_patches', Path(__file__).resolve().parents[2] / 'games/01007EF00011E000/patches.py')
assert spec is not None and spec.loader is not None
patch = importlib.util.module_from_spec(spec); spec.loader.exec_module(patch)

BASE, AREA, STATE, ARROW, VFR = 0x10000000, 0x2000000, 0x2100000, 0x40000000, 0x40001000
SITE, BACK, VFR_PTR = 0x5ee734, 0x5ee738, 0x1e93890
GRAVITY = -0.01089   # m per console frame, as MacNativeGames logged it


def build():
    """Run frame_step against a recording context: (words emitted at AREA, {site: (words, why)}, {site: original hex})."""
    words, puts, sites = [], {}, {}
    ctx = types.SimpleNamespace(here=lambda: AREA + 4 * len(words), emit=words.append, site=sites.__setitem__,
                                put=lambda off, ws, why: puts.__setitem__(off, (ws, why)), state=STATE, render_scale=0, step_max=0, capabilities=set(), address=lambda off: 0)
    patch.frame_step(ctx)
    return words, puts, sites


class Layout(unittest.TestCase):
    def test_the_load_goes_to_the_stub_and_back(self):
        words, puts, _ = build()
        self.assertIn(SITE, puts)
        (b,), why = puts[SITE]
        self.assertEqual(b & 0xfc000000, 0x14000000, 'a plain b: the stub returns by a branch, not a call')
        start = SITE + (((b & 0x3ffffff) ^ 0x2000000) - 0x2000000) * 4
        self.assertIn('arrows', why)
        i = (start - AREA) // 4
        self.assertEqual(words[i], 0xbd410a81, 'the shipped load of the gravity first')
        self.assertEqual(words[i + 9], B(start + 4 * 9, BACK), 'back to the instruction after the site')
        for k, target in ((3, 9), (5, 9), (6, 9)):   # cbz x8 / cbz w8 / tbnz w8: all to the branch back
            w = words[i + k]
            imm = (w >> 5) & (0x7ffff if (w & 0x7e000000) == 0x34000000 else 0x3fff)
            self.assertEqual(k + imm, target, f'word {k} {w:#x}')
        self.assertNotIn(0x1e202068, words[i:i + 10], 'no fcmp: the flags at the site stay the game\'s')

    def test_the_build_is_checked_where_it_is_read(self):
        _, _, sites = build()
        for at in (0x5ee71c, 0x5ee724, 0x5ee730, SITE, BACK, 0x5ee744, 0x5ee74c, 0x5ee764):
            self.assertIn(at, sites, f'main+{at:#x} is asserted before the stub is written')
        self.assertEqual(sites[SITE], struct.pack('<I', 0xbd410a81).hex(), 'the original load of the gravity')
        self.assertEqual(list(patch.FRAME_STEP), ['cd57b23fa4bbad65803d9788c01821ee'], 'only the 1.9.0 main build')


@unittest.skipIf(uc is None, 'optional ARM64 execution dependency: unicorn')
class Run(unittest.TestCase):
    def gravity(self, ratio, vfr=True):
        assert uc is not None and arm is not None   # the class is skipped without unicorn
        words, puts, _ = build()
        u = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        for a, n in ((BASE, AREA), (BASE + AREA, 0x10000), (BASE + STATE, 0x4000), (ARROW, 0x1000), (VFR, 0x1000)):
            u.mem_map(a, n)
        u.reg_write(arm.UC_ARM64_REG_CPACR_EL1, 3 << 20)
        u.mem_write(BASE + AREA, struct.pack(f'<{len(words)}I', *words))
        for off, (ws, _) in puts.items(): u.mem_write(BASE + off, struct.pack(f'<{len(ws)}I', *ws))
        u.mem_write(BASE + VFR_PTR, struct.pack('<Q', VFR if vfr else 0))
        u.mem_write(VFR + 0x3c, struct.pack('<f', ratio))
        u.mem_write(ARROW + 0x108, struct.pack('<f', GRAVITY))
        u.reg_write(arm.UC_ARM64_REG_X20, ARROW)
        u.reg_write(arm.UC_ARM64_REG_NZCV, 0x60000000)   # Z and C set: must come back as they were
        u.emu_start(BASE + SITE, BASE + BACK, count=20)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC), BASE + BACK)
        self.assertEqual(u.reg_read(arm.UC_ARM64_REG_NZCV) & 0xf0000000, 0x60000000)
        return struct.unpack('<f', struct.pack('<I', u.reg_read(arm.UC_ARM64_REG_S1) & 0xffffffff))[0]

    def test_scaled_by_the_ratio(self):
        for ratio in (1.0, 0.5, 0.25, 1.5):
            self.assertAlmostEqual(self.gravity(ratio), GRAVITY * ratio, places=7)

    def test_shipped_without_a_vfr_or_a_positive_ratio(self):
        self.assertAlmostEqual(self.gravity(0.5, vfr=False), GRAVITY, places=7)
        self.assertAlmostEqual(self.gravity(0.0), GRAVITY, places=7)
        self.assertAlmostEqual(self.gravity(-0.5), GRAVITY, places=7)


if __name__ == '__main__':
    unittest.main()
