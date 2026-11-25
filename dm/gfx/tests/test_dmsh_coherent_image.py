#!/usr/bin/env python3
"""Coherent images at the chain's MSL (dmsh_chain.CROSS_MSL, 3.2). The translator decorates an image Coherent when a Maxwell SULD or SUST of it has the .CG cache operation
(InstEmitSurface EmitSuld / EmitSust, CodeGen/Spirv/Declarations.cs); Ampere's surface loads and stores never set it (InstEmitAmpereMem ASurface takes .CA / .WB). SPIRV-Cross gives a
storage image the access its uses need (only read: none, which is access::sample; only written: access::write; both: access::read_write). From MSL 3.2 it writes a Coherent image as
a device-coherent texture, adding memory_coherence_device, and as that needs an access qualifier, a Coherent image the shader only reads becomes access::read; below 3.2 it wrote
neither. Every other image is written as before. The modules are written here word by word, so only spirv-cross is needed; with DMSH_TEST_METAL=1 the MSL also compiles with the
Mac's and the iPhone's compile lines (dmsh_build.py MAC_METAL, ios_metal.py METAL), and with DMSH_TEST_XLATE Maxwell SULD / SUST of each cache operation go through the translator."""
from pathlib import Path
import ast
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
RYU = TOOLS.parents[1] / 'third_party/ryujinx/src/Ryujinx.Graphics.Shader'
sys.path.insert(0, str(TOOLS))
import dmsh_chain

COHERENT = 23                     # SPIR-V decoration
GLCOMPUTE, FRAGMENT = 5, 4        # SPIR-V execution models
RW = 'texture2d<uint, access::read_write>'
RW_COHERENT = 'texture2d<uint, access::read_write, memory_coherence_device>'


def name_words(s):
    b = s.encode() + b'\0'
    b += b'\0' * (-len(b) % 4)
    return list(struct.unpack('<%dI' % (len(b) // 4), b))


def module(model=GLCOMPUTE, decorations=(COHERENT,), read_only=False):   # pylint: disable=too-many-locals
    """A shader that reads a 2D r32ui storage image `img` and writes twice the value back to it (the translator's SULD then SUST of one image), `img` with the given decorations;
    read_only: the value goes to a second image `dst` (binding 1, no decorations) and `img` is only read"""
    void, fn, uint, int_, v2int, v4uint, imgty, ptr, img, zero, coord, main, label, im, rd, sum, dst, om = range(1, 19)
    name = name_words('main')
    words = [2 << 16 | 17, 1,                                                       # OpCapability Shader
             3 << 16 | 14, 0, 1,                                                    # OpMemoryModel Logical GLSL450
             (3 + len(name)) << 16 | 15, model, main, *name]                        # OpEntryPoint
    words += [6 << 16 | 16, main, 17, 64, 1, 1] if model == GLCOMPUTE else [3 << 16 | 16, main, 7]   # LocalSize 64 1 1 / OriginUpperLeft
    for var, label_ in ((img, 'img'),) + (((dst, 'dst'),) if read_only else ()):
        words += [(2 + len(name_words(label_))) << 16 | 5, var, *name_words(label_)]   # OpName
    words += [4 << 16 | 71, img, 34, 0, 4 << 16 | 71, img, 33, 0]                   # DescriptorSet 0, Binding 0
    words += [w for d in decorations for w in (3 << 16 | 71, img, d)]
    if read_only: words += [4 << 16 | 71, dst, 34, 0, 4 << 16 | 71, dst, 33, 1]
    words += [2 << 16 | 19, void, 3 << 16 | 33, fn, void, 4 << 16 | 21, uint, 32, 0, 4 << 16 | 21, int_, 32, 1,
              4 << 16 | 23, v2int, int_, 2, 4 << 16 | 23, v4uint, uint, 4,
              9 << 16 | 25, imgty, uint, 1, 0, 0, 0, 2, 33,                         # OpTypeImage uint 2D, storage (sampled 2), R32ui
              4 << 16 | 32, ptr, 0, imgty, 4 << 16 | 59, ptr, img, 0]              # UniformConstant
    if read_only: words += [4 << 16 | 59, ptr, dst, 0]
    words += [4 << 16 | 43, int_, zero, 0, 5 << 16 | 44, v2int, coord, zero, zero,
              5 << 16 | 54, void, main, 0, fn, 2 << 16 | 248, label,
              4 << 16 | 61, imgty, im, img, 5 << 16 | 98, v4uint, rd, im, coord,     # OpLoad, OpImageRead
              5 << 16 | 128, v4uint, sum, rd, rd]                                   # OpIAdd
    if read_only: words += [4 << 16 | 61, imgty, om, dst, 4 << 16 | 99, om, coord, sum]   # OpImageWrite to dst
    else: words += [4 << 16 | 99, im, coord, sum]                                  # OpImageWrite to img
    words += [1 << 16 | 253, 1 << 16 | 56]
    return struct.pack('<%dI' % (5 + len(words)), 0x07230203, 0x00010000, 0, om + 1, 0, *words)


def cross(spv_bytes, version=dmsh_chain.MSL_VERSION):   # spirv-cross with the chain's options, at its MSL version or another
    args = [version if a == dmsh_chain.MSL_VERSION else a for a in dmsh_chain.CROSS_MSL]
    with tempfile.TemporaryDirectory(prefix='coherent_') as d:
        p = Path(d) / 'k.spv'; p.write_bytes(spv_bytes)
        r = subprocess.run([dmsh_chain.SPIRV_CROSS, *args, str(p)], capture_output=True, text=True)
    if r.returncode: raise AssertionError(r.stderr)
    return r.stdout


def images(msl):   # {member name: its type} of the argument buffer's 2D textures
    return {m.group(2): m.group(1) for m in re.finditer(r'^\s*(texture2d<[^>]*>)\s+(\w+)\s*\[\[id\(\d+\)', msl, re.M)}


def mac_metal():   # dmsh_build.py's MAC_METAL, read without running the script (it runs a build when imported)
    for n in ast.parse((TOOLS / 'dmsh_build.py').read_text()).body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'MAC_METAL' for t in n.targets): return ast.literal_eval(n.value)
    raise AssertionError('no MAC_METAL in dmsh_build.py')


def compiles(test, msl):
    sys.path.insert(0, str(TOOLS.parents[1] / 'ios/tools')); import ios_metal
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'k.metal'; p.write_text(msl)
        for name, cmd in (('mac', mac_metal()), ('ios', ios_metal.METAL)):
            r = subprocess.run([*cmd, str(p), '-o', str(Path(d) / f'{name}.air')], capture_output=True, text=True)
            test.assertEqual(r.returncode, 0, name + ': ' + r.stderr)


class CoherentImage(unittest.TestCase):
    def test_a_coherent_image_is_device_coherent(self):   # a compute kernel's SULD.CG / SUST.CG image
        self.assertEqual(images(cross(module())), {'img': RW_COHERENT})
        self.assertEqual(images(cross(module(), '20300')), {'img': RW})   # the chain before upstream 6dad34067ce

    def test_in_a_pixel_shader_too(self):
        msl = cross(module(FRAGMENT))
        self.assertIn('fragment void main0(', msl)
        self.assertEqual(images(msl), {'img': RW_COHERENT})

    def test_other_images_are_unchanged(self):   # .CA / .WB (and every Ampere image): no decoration, the type 2.3 wrote
        msl = cross(module(decorations=()))
        self.assertEqual(images(msl), {'img': RW})
        self.assertNotIn('memory_coherence', msl)

    def test_a_read_only_coherent_image_is_read(self):   # only SULD.CG: memory_coherence_device needs an access qualifier, so access::read where 2.3 wrote none (sample)
        self.assertEqual(images(cross(module(read_only=True))), {'img': 'texture2d<uint, access::read, memory_coherence_device>', 'dst': 'texture2d<uint, access::write>'})
        self.assertEqual(images(cross(module(read_only=True), '20300')), {'img': 'texture2d<uint>', 'dst': 'texture2d<uint, access::write>'})
        self.assertEqual(images(cross(module(decorations=(), read_only=True))), {'img': 'texture2d<uint>', 'dst': 'texture2d<uint, access::write>'})

    @unittest.skipUnless(os.environ.get('DMSH_TEST_METAL') and shutil.which('xcrun'), 'set DMSH_TEST_METAL=1 to compile with the Metal compiler')
    def test_it_compiles_for_the_mac_and_the_iphone(self):
        for model in (GLCOMPUTE, FRAGMENT):
            for read_only in (False, True):
                with self.subTest(model=model, read_only=read_only):
                    compiles(self, cross(module(model, read_only=read_only)))


# Maxwell encodings: each instruction's fixed bits from the translator's own decoder table, as test_image_atomic_bounds.py takes them
def base(name):
    pattern = re.search(r'Add\("([01x]{64})", InstName\.' + name + r'\s*,', (RYU / 'Decoders/InstTable.cs').read_text())[1]
    return int(pattern.replace('x', '0'), 2)


CA, CG = 0, 1                     # CacheOpLd .CA (the default) / .CG; CacheOpSt .WB / .CG have the same values
WB = 0
D2, R = 3, 1                      # SuDim _2d, SuRgba R
IMG = [0x48 + 2 * n for n in range(8)]   # TidB of image slots 0 to 7 (c[2] byte 0x120 + 8 n, Program.cs ImgBase)


def mov(reg, value): return base('Mov32i') | ((value & 0xffffffff) << 20) | (7 << 16) | (15 << 12) | reg
def suld(slot, cache, dest): return base('Suld') | (IMG[slot] << 36) | (D2 << 33) | (7 << 30) | (cache << 24) | (R << 20) | (7 << 16) | (0 << 8) | dest   # SULD.P.2D.R [R0, R1]
def sust(slot, cache, src): return base('Sust') | (IMG[slot] << 36) | (D2 << 33) | (cache << 24) | (R << 20) | (7 << 16) | (0 << 8) | src                 # SUST.P.2D.R [R0, R1], src


def maxwell(*insts):
    insts = list(insts) + [base('Exit') | (7 << 16) | 15]
    words = []
    for i, inst in enumerate(insts):
        if i % 3 == 0: words.append(0x001f8000fc0007e0)   # the scheduling word
        words.append(inst)
    while len(words) % 4: words.append(0x50b0000000070f00)   # NOP
    return struct.pack('<%dQ' % len(words), *words)


def suatom_max_u64(slot): return base('Suatom') | (2 << 51) | (IMG[slot] << 36) | (D2 << 33) | (2 << 29) | (2 << 20) | (7 << 16) | (0 << 8) | 255   # SUATOM.D.2D.MAX.U64 RZ, [R0, R1], R2
def suld_d64(slot, cache, dest): return base('SuldD') | (IMG[slot] << 36) | (D2 << 33) | (7 << 30) | (cache << 24) | (5 << 20) | (7 << 16) | (0 << 8) | dest   # SULD.D.2D.64
def sust_d64(slot, src): return base('SustD') | (IMG[slot] << 36) | (D2 << 33) | (WB << 24) | (5 << 20) | (7 << 16) | (0 << 8) | src                       # SUST.D.2D.64


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class TranslatedCoherentImage(unittest.TestCase):
    def translate(self, code, fmt, slots):   # the translator's SPIR-V of a Maxwell compute shader whose image slots 0 to slots - 1 have format fmt
        with tempfile.TemporaryDirectory(prefix='coherent_xlate_') as d:
            work = Path(d); (work / 'k.bin').write_bytes(code)
            img = {str(n): dict(type='2d', fmt=fmt) for n in range(slots)}
            (work / 'jobs.json').write_text(json.dumps([dict(key='k', stage='cs', code=str(work / 'k.bin'), tex={}, img=img, attr={}, fout={}, local=[64, 1, 1], debug=True)]))
            r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            import dmsh_geometry
            dmsh_geometry.flatten_sets(work / 'k.spv')
            return (work / 'k.spv').read_bytes()

    def test_cg_loads_and_stores_make_device_coherent_images(self):
        # Slot 0 loaded with .CG, slot 1 with .CA; slot 2 stored with .WB, slot 3 with .CG (formatted SULD.P / SUST.P: float images). An image both loaded and stored takes the
        # flags of its last load or store in the shader (ResourceManager.GetTextureOrImageBinding hands Properties.AddOrUpdateImage that instruction's flags, not the merged ones):
        # slot 4 loaded with .CG, then stored with .WB, is not Coherent; slot 5 stored with .WB, then loaded with .CG (the value stored to slot 6), is
        spv = self.translate(maxwell(mov(0, 1), mov(1, 2), suld(0, CG, 4), suld(1, CA, 5), sust(2, WB, 4), sust(3, CG, 5), suld(4, CG, 6), sust(4, WB, 6),
                                     sust(5, WB, 4), suld(5, CG, 7), sust(6, WB, 7)), 'R32Uint', 7)
        def by_slot(msl):   # the image's handle is in its name (cp_i_tcb_<TidB>_)
            out = {}
            for name, ty in images(msl).items():
                m = re.search(r'_i_tcb_([0-9A-F]+)_', name)
                self.assertIsNotNone(m, name)
                out[IMG.index(int(m.group(1), 16))] = ty   # pyright: ignore[reportOptionalMemberAccess]
            return out
        msl = cross(spv)
        self.assertEqual(by_slot(msl), {0: 'texture2d<float, access::read, memory_coherence_device>', 1: 'texture2d<float>', 2: 'texture2d<float, access::write>',
                                        3: 'texture2d<float, access::write, memory_coherence_device>', 4: 'texture2d<float, access::read_write>',
                                        5: 'texture2d<float, access::read_write, memory_coherence_device>', 6: 'texture2d<float, access::write>'})
        self.assertEqual(by_slot(cross(spv, '20300')), {0: 'texture2d<float>', 1: 'texture2d<float>', 2: 'texture2d<float, access::write>',
                                                        3: 'texture2d<float, access::write>', 4: 'texture2d<float, access::read_write>', 5: 'texture2d<float, access::read_write>',
                                                        6: 'texture2d<float, access::write>'})
        if os.environ.get('DMSH_TEST_METAL') and shutil.which('xcrun'):
            compiles(self, msl)

    def test_a_64_bit_atomic_image_read_with_cg_still_fails(self):
        # A Maxwell 64-bit max (SUATOM.U64, Metal's 64-bit texture atomic through dmsh_atomic.wide_atomics) and a 64-bit load of the same rg32ui image: the load is an access
        # wide_atomics refuses. With .CG the image is Coherent, and before wide_atomics took memory_coherence_device the shader went through with the pair as two 32-bit atomics
        import dmsh_atomic
        for cache in (CA, CG):
            with self.subTest(cache=cache):
                msl = cross(self.translate(maxwell(mov(0, 1), mov(1, 2), mov(2, 5), mov(3, 6), suatom_max_u64(0), suld_d64(0, cache, 4), sust_d64(1, 4)), 'R32G32Uint', 2))
                coherent = ', memory_coherence_device' if cache == CG else ''
                self.assertIn(f'texture2d<uint, access::read_write{coherent}> cp_i_tcb_48_rg32ui', msl)
                with self.assertRaisesRegex(ValueError, 'cp_i_tcb_48_rg32ui: 2 accesses of a 64-bit atomic image'):
                    dmsh_atomic.check_msl(msl)


if __name__ == '__main__':
    unittest.main()
