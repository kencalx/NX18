"""shader_split: an NVN2 shader's stage (nvn2_stage). A graphics stage's code starts with an SPH (word 0: type 1 or 2 in bits 0..4, the stage in bits 10..13); a compute shader's
has none. One Switch 2 game's compute shaders carry a pixel stage byte (+0x56 = 1) and no SPH, and the game dispatches them (S2Arm 576b5653, Apache-2.0): with a vertex, pixel or
geometry stage byte and no valid SPH the shader is compute. Every shader with a valid SPH keeps the stage its SPH gives. Synthetic headers only, no game files."""
import struct
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools/fuzz'))
import fuzz_shader_split as fz   # shader_split with a profile
ss = fz.ss


def ctl(stage):
    c = bytearray(0xe0); c[:4] = ss.CTL_MAGIC; c[4:8] = b'\xc9\0\0\0'; c[0x56] = stage
    return bytes(c)


def code(w0):
    return struct.pack('<I', w0) + bytes(0x7c)   # SPH word 0, then the rest of a 0x80-byte area


def sph(kind, stage):   # SPH word 0: type (1 VTG, 2 PS) in bits 0..4, version 3 in bits 5..9, the stage in bits 10..13
    return kind | 3 << 5 | stage << 10


class Nvn2Stage(unittest.TestCase):
    def test_valid_sph_keeps_its_stage(self):
        # every stage byte below 5 with every valid SPH gives what the SPH says, as before
        for byte in (0, 1, 2, 3, 4):
            for kind, stage, want in ((1, 1, 'vs'), (1, 2, 'hs'), (1, 3, 'ds'), (1, 4, 'gs'), (2, 5, 'ps'), (1, 0, 'vs')):
                with self.subTest(byte=byte, sph=hex(sph(kind, stage))):
                    self.assertEqual(ss.nvn2_stage(ctl(byte), code(sph(kind, stage))), want)
        self.assertEqual(ss.nvn2_stage(ctl(1), code(0x000c5482)), 'ps')   # S2Arm's pixel SPH (type 2, stage 5)

    def test_no_sph_with_graphics_byte_is_compute(self):
        for byte in (0, 1, 2):
            for w0 in (0, 0xdeadbeef & ~0x1f | 7, sph(3, 5), sph(1, 6), sph(2, 0), sph(2, 15)):
                with self.subTest(byte=byte, w0=hex(w0)):
                    self.assertEqual(ss.nvn2_stage(ctl(byte), code(w0)), 'cs')

    def test_other_bytes_unchanged(self):
        self.assertEqual(ss.nvn2_stage(ctl(5), code(sph(2, 5))), 'cs')
        self.assertEqual(ss.nvn2_stage(ctl(6), code(sph(1, 1))), 'ts')
        self.assertEqual(ss.nvn2_stage(ctl(7), code(sph(1, 3))), 'ms')
        self.assertIsNone(ss.nvn2_stage(ctl(3), code(0)))   # tessellation bytes: no SPH stage, none as before
        self.assertIsNone(ss.nvn2_stage(ctl(1), b'\0\0'))   # shorter than SPH word 0


if __name__ == '__main__':
    unittest.main()
