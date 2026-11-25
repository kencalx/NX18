"""Indexed AST.P: a synthetic hull with a register-indexed patch store translates and converts to MSL (upstream 8d62601f3 also ran it on the GPU
through its tessellation lowering, dmsh_tess.py, which NX 18 does not have)."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_geometry  # noqa: E402   (NX 18 has no tessellation lowering, dmsh_tess.py: the hull is translated and converted, not run)


def instruction(op, rd=0, ra=255, rb=0, address=0, high=0):
    return struct.pack('<QQ', op | 7 << 12 | rd << 16 | ra << 24 | rb << 32 | address << 40,
                       0x000fe20000000000 | high)


def hull(immediate, components):
    header = bytearray(0x80)
    struct.pack_into('<3I', header, 0, 1 | 4 << 5 | 2 << 10, 128 << 24, 1 << 24)
    # A position input and output keep this a complete hull through the production lowering.
    header[0x17] = header[0x35] = 0xf0
    # c4 is bank 4: its encoding in the immediate cbuf operand is bit 56.
    code = [struct.pack('<QQ', 0x0100000000077a02, 0x000fe20000000f00)]  # MOV R7, c4[0]
    for i in range(components):
        code.append(struct.pack('<QQ', 0x0100000000007a02 | (2 + i) << 16 | (i + 1) << 40,
                                0x000fe20000000f00))
    code += [instruction(0x321, rd=16, rb=255, address=0x70, high=3 << 10),
             instruction(0x322, rb=16, address=0x70, high=255 | 3 << 10),
             instruction(0x322, ra=7, rb=2, address=immediate, high=255 | (components - 1) << 10 | 1 << 12),
             struct.pack('<QQ', 0x000000000000794d, 0x000fea0003800000)]
    return bytes(header) + b''.join(code)




@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class IndexedPatchStore(unittest.TestCase):
    def build(self, work, immediate, components):
        (work / 'shader.bin').write_bytes(hull(immediate, components))
        (work / 'jobs.json').write_text(json.dumps([dict(key='k', stage='hs', arch='sm86', code=str(work / 'shader.bin'),
                                                        tex={}, img={}, attr={}, fout={}, debug=True)]))
        r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), str(work)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue((work / 'k.spv').is_file(), r.stdout + r.stderr)
        dmsh_geometry.flatten_sets(work / 'k.spv')
        r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), str(work / 'k.spv'), '--msl', '--msl-version', '20300',
                            '--msl-argument-buffers'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('kernel void main0(', r.stdout)   # spirv-cross writes a hull as a compute kernel
        return r.stdout

    def test_indexed_patch_store_translates(self):
        for immediate, components in [(0, 1), (0x10, 4), (0x1f8, 4)]:
            with self.subTest(immediate=immediate, components=components), tempfile.TemporaryDirectory() as d:
                self.build(Path(d), immediate, components)


if __name__ == '__main__':
    unittest.main()
