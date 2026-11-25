"""NoContraction helpers inline (dmsh_rewrite.py nocontraction_inline, ported from S2Arm 7cfd7be8): spirv-cross's six optnone helpers (spvFMul, spvFAdd, spvFSub and the three
matrix products), which relaxed precision keeps on the gl_Position chain, become always inline with each fma's 0 / 1 read from a thread volatile float. The text: every helper
replaced, nothing else, any other text left alone. The compile, with the iPhone's flags (relaxed math) and the Mac's, for both SDKs: no call of a helper is left and no fma has a
literal 0 addend or 1 multiplier. On this Mac's GPU: random and edge inputs (signed zeros, denormals, the largest floats, half-ulp neighbours, infinities, NaN) give results
identical word for word to spirv-cross's own helpers under both flag sets, while the unprotected form (l * r, l + r, l - r inline) differs from them, so the comparison can see a
fused or folded step. No game files."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
from dmsh_rewrite import nocontraction_inline   # noqa: E402

# what the pinned spirv-cross (dm/gfx/tools/spirv_cross_bin, vulkan-sdk-1.4.363.0) writes for a compute shader with precise x * y + z, x * y - z, m * x + y, x * m - z, m * m and
# mm * y + x * z (glslang's precise: NoContraction on each operation), with --msl --msl-version 20300 --msl-argument-buffers
HELPERS = '''template<typename T>
[[clang::optnone]] T spvFMul(T l, T r)
{
    return fma(l, r, T(0));
}

template<typename T, int Cols, int Rows>
[[clang::optnone]] vec<T, Cols> spvFMulVectorMatrix(vec<T, Rows> v, matrix<T, Cols, Rows> m)
{
    vec<T, Cols> res = vec<T, Cols>(0);
    for (uint i = Rows; i > 0; --i)
    {
        vec<T, Cols> tmp(0);
        for (uint j = 0; j < Cols; ++j)
        {
            tmp[j] = m[j][i - 1];
        }
        res = fma(tmp, vec<T, Cols>(v[i - 1]), res);
    }
    return res;
}

template<typename T, int Cols, int Rows>
[[clang::optnone]] vec<T, Rows> spvFMulMatrixVector(matrix<T, Cols, Rows> m, vec<T, Cols> v)
{
    vec<T, Rows> res = vec<T, Rows>(0);
    for (uint i = Cols; i > 0; --i)
    {
        res = fma(m[i - 1], vec<T, Rows>(v[i - 1]), res);
    }
    return res;
}

template<typename T, int LCols, int LRows, int RCols, int RRows>
[[clang::optnone]] matrix<T, RCols, LRows> spvFMulMatrixMatrix(matrix<T, LCols, LRows> l, matrix<T, RCols, RRows> r)
{
    static_assert(LCols == RRows, "column-row configuration mismatch");
    matrix<T, RCols, LRows> res;
    for (uint i = 0; i < RCols; i++)
    {
        vec<T, LRows> tmp(0);
        for (uint j = 0; j < LCols; j++)
        {
            tmp = fma(vec<T, LRows>(r[i][j]), l[j], tmp);
        }
        res[i] = tmp;
    }
    return res;
}

template<typename T>
[[clang::optnone]] T spvFAdd(T l, T r)
{
    return fma(T(1), l, r);
}

template<typename T>
[[clang::optnone]] T spvFSub(T l, T r)
{
    return fma(T(-1), r, l);
}

'''
HEAD = '#pragma clang diagnostic ignored "-Wmissing-prototypes"\n\n#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
BODY = '''struct In
{
    float4 a[1];
};

struct M
{
    float4x4 m;
};

struct Out
{
    float4 o[1];
};

struct spvDescriptorSetBuffer0
{
    device In* m_23 [[id(0)]];
    device M* m_62 [[id(1)]];
    device Out* m_95 [[id(2)]];
};

kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    uint i = gl_GlobalInvocationID.x;
    float4 x = (*spvDescriptorSet0.m_23).a[i * 3u];
    float4 y = (*spvDescriptorSet0.m_23).a[(i * 3u) + 1u];
    float4 z = (*spvDescriptorSet0.m_23).a[(i * 3u) + 2u];
    float4 p = spvFAdd(spvFMul(x, y), z);
    float4 q = spvFSub(spvFMul(x, y), z);
    float4 r = spvFAdd(spvFMulMatrixVector((*spvDescriptorSet0.m_62).m, x), y);
    float4 s = spvFSub(spvFMulVectorMatrix(x, (*spvDescriptorSet0.m_62).m), z);
    float4x4 mm = spvFMulMatrixMatrix((*spvDescriptorSet0.m_62).m, (*spvDescriptorSet0.m_62).m);
    float4 t = spvFAdd(spvFMulMatrixVector(mm, y), spvFMul(x, z));
    (*spvDescriptorSet0.m_95).o[i * 5u] = p;
    (*spvDescriptorSet0.m_95).o[(i * 5u) + 1u] = q;
    (*spvDescriptorSet0.m_95).o[(i * 5u) + 2u] = r;
    (*spvDescriptorSet0.m_95).o[(i * 5u) + 3u] = s;
    (*spvDescriptorSet0.m_95).o[(i * 5u) + 4u] = t;
}
'''
SRC = HEAD + HELPERS + BODY
# the production compile lines' flags (dmsh_build.py MAC_METAL, ios_metal.py METAL), without the SDK and deployment target
MAC_FLAGS = ['-O1', '-std=metal4.1', '-fpreserve-invariance', '-fwrapv']
IOS_FLAGS = ['-O1', '-std=metal4.1', '-fmetal-math-mode=relaxed', '-fpreserve-invariance', '-fwrapv']
T4_DIR = str(Path(__file__).resolve().parent)
# runs main0 of each library on the same inputs and writes how many output words differ from the first library's: "<library> <differing words> <words>" a line
RUNNER = r'''#import <Metal/Metal.h>
#include "t_mtl4.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
 @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) return 2;
    enum { N = 65536 };
    const uint32_t edge[] = {0x00000000, 0x80000000, 0x00000001, 0x80000001, 0x007fffff, 0x00800000, 0x3effffff, 0x3f000001, 0x3f7fffff, 0x3f800001,
                             0x4b000000, 0x4b000001, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0x34000000, 0xb4000000, 0x33800001, 0x3f800000, 0xbf800000};
    const unsigned ne = sizeof edge / sizeof *edge;
    id<MTLBuffer> in = [d newBufferWithLength:(size_t)N * 3 * 16 options:MTLResourceStorageModeShared], mb = [d newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> ab = [d newBufferWithLength:64 options:MTLResourceStorageModeShared];
    uint32_t *u = in.contents, state = 0x12345678; float *f = in.contents;
    for (size_t k = 0; k < (size_t)N * 12; k++) {
        state ^= state << 13; state ^= state >> 17; state ^= state << 5;
        f[k] = ((int)(state % 2000001u) - 1000000) / 977.0f * (state >> 29 ? 1.0f : 1e-30f);
    }
    for (size_t i = 0; i < N; i += 4) for (unsigned c = 0; c < 12; c++) u[i * 12 + c] = edge[(i / 4 * 5 + c * 7) % ne];
    float *m = mb.contents; for (int k = 0; k < 16; k++) { state ^= state << 13; state ^= state >> 17; state ^= state << 5; m[k] = ((int)(state % 2001u) - 1000) / 333.0f; }
    uint32_t *ref = NULL; const size_t nw = (size_t)N * 20;
    for (int a = 1; a < argc; a++) {
        NSError *err = nil;
        id<MTLLibrary> lib = [d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[a])] error:&err];
        id<MTLComputePipelineState> ps = lib ? t4_cps(t4_fn(lib, @"main0"), &err) : nil;
        if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLBuffer> out = [d newBufferWithLength:nw * 4 options:MTLResourceStorageModeShared]; memset(out.contents, 0xcd, nw * 4);
        uint64_t *args = ab.contents; args[0] = in.gpuAddress; args[1] = mb.gpuAddress; args[2] = out.gpuAddress;
        T4 *cb = t4_begin();
        id<MTL4ComputeCommandEncoder> en = t4_compute(cb);
        [en setComputePipelineState:t4_keep(cb, ps)]; t4_use(cb, in); t4_use(cb, mb); t4_use(cb, out); t4_buf(cb, en, T4_CS, ab, 0, 0);
        [en dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        t4_end(cb, en); t4_wait(cb);
        if (cb->status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "GPU error\n"); return 1; }
        const uint32_t *o = out.contents;
        if (!ref) { ref = malloc(nw * 4); memcpy(ref, o, nw * 4); }
        size_t diff = 0; for (size_t k = 0; k < nw; k++) diff += o[k] != ref[k];
        printf("%s %zu %zu\n", argv[a], diff, nw);
    }
    return 0;
 }
}
'''


def plain(src):   # the unprotected form: the helpers' fma steps as plain arithmetic, inline, which the compiler may fold and fuse
    return (src.replace('return fma(T(1), l, r);', 'return l + r;').replace('return fma(T(-1), r, l);', 'return l - r;').replace('return fma(l, r, T(0));', 'return l * r;')
            .replace('[[clang::optnone]] ', 'inline '))


class Text(unittest.TestCase):
    def test_every_helper_inline_with_volatile_operands(self):
        out = nocontraction_inline(SRC)
        self.assertNotIn('optnone', out)
        self.assertEqual(out.count('static inline __attribute__((always_inline))'), 6)
        self.assertEqual(out.count('    thread volatile float z = 0.0f;\n'), 4)
        self.assertEqual(out.count('    thread volatile float o = 1.0f;\n'), 2)
        for call in ('return fma(l, r, T(z));', 'return fma(T(o), l, r);', 'return fma(T(-o), r, l);', 'vec<T, Cols> res = vec<T, Cols>(T(z));',
                     'vec<T, Rows> res = vec<T, Rows>(T(z));', 'vec<T, LRows> tmp = vec<T, LRows>(T(z));'):
            self.assertEqual(out.count(call), 1, call)
        self.assertNotRegex(out, r'fma\(T\(-?1\)|T\(0\)\)|vec<T, \w+>\(0\);')
        self.assertTrue(out.endswith(BODY))   # the calls stay as they are
        self.assertEqual(out.count('fma('), SRC.count('fma('))   # the same steps, one fma each
        self.assertEqual(nocontraction_inline(out), out)

    def test_other_text_unchanged(self):
        self.assertEqual(nocontraction_inline(HEAD + BODY), HEAD + BODY)
        changed = SRC.replace('return fma(T(1), l, r);', 'return fma(T(1), l, r) + T(0);')
        out = nocontraction_inline(changed)
        self.assertIn('[[clang::optnone]] T spvFAdd(T l, T r)\n{\n    return fma(T(1), l, r) + T(0);', out)   # a helper not as written stays, the others go inline
        self.assertEqual(out.count('optnone'), 1)
        twice = HEAD + HELPERS + HELPERS + BODY
        self.assertEqual(nocontraction_inline(twice), twice)


@unittest.skipUnless(shutil.which('xcrun') and subprocess.run(['xcrun', '-sdk', 'macosx', '-f', 'metal'], capture_output=True).returncode == 0, 'no Metal compiler')
class Compiled(unittest.TestCase):
    ZERO = re.compile(r'@air\.fma\.[^(]*\([^)]*(?:float|half)>? (?:-?0\.000000e\+00|zeroinitializer)\)')   # a literal 0 addend
    ONE = re.compile(r'@air\.fma\.[^(]*\((?:float|half|<\d+ x (?:float|half)>) (?:-?1\.000000e\+00|<(?:float|half) -?1\.0)')   # a literal 1 or -1 multiplier

    def test_no_call_and_no_literal_operand(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            # lit: the helpers inline with their literal operands, which the checks must see (the reference keeps its calls, so it shows none)
            for name, src in (('ref', SRC), ('new', nocontraction_inline(SRC)), ('lit', SRC.replace('[[clang::optnone]] ', 'inline '))):
                (root / f'{name}.metal').write_text(src)
                for sdk, flags in (('macosx', MAC_FLAGS), ('iphoneos', IOS_FLAGS)):
                    ll = root / f'{name}_{sdk}.ll'
                    subprocess.run(['xcrun', '-sdk', sdk, 'metal', *flags, '-S', '-emit-llvm', str(root / f'{name}.metal'), '-o', str(ll)], check=True, capture_output=True)
                    text = ll.read_text()
                    calls = len(re.findall(r'call [^\n]*@_Z\d+spvF', text))
                    if name == 'ref': self.assertGreater(calls, 0, sdk)   # the reference keeps its calls: the check can see one
                    elif name == 'lit': self.assertTrue(self.ZERO.search(text) and self.ONE.search(text), sdk)
                    else:
                        self.assertEqual(calls, 0, sdk)
                        self.assertEqual(self.ZERO.findall(text) + self.ONE.findall(text), [], sdk)


@unittest.skipUnless(shutil.which('xcrun') and shutil.which('clang'), 'needs Xcode and Metal')
class OnGpu(unittest.TestCase):
    def test_results_identical_to_spirv_cross_helpers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'run.m').write_text(RUNNER)
            subprocess.run(['clang', '-fobjc-arc', '-I', T4_DIR, '-O1', str(root / 'run.m'), '-framework', 'Metal', '-framework', 'Foundation', '-o', str(root / 'run')], check=True, capture_output=True)
            for mode, flags in (('mac', MAC_FLAGS), ('ios', IOS_FLAGS)):
                libs = []
                for name, src in (('ref', SRC), ('new', nocontraction_inline(SRC)), ('plain', plain(SRC))):
                    (root / f'{name}.metal').write_text(src)
                    subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', *flags, str(root / f'{name}.metal'), '-o', str(root / f'{mode}_{name}.air')], check=True, capture_output=True)
                    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(root / f'{mode}_{name}.air'), '-o', str(root / f'{mode}_{name}.metallib')], check=True, capture_output=True)
                    libs.append(str(root / f'{mode}_{name}.metallib'))
                r = subprocess.run([str(root / 'run'), *libs], capture_output=True, text=True)
                if r.returncode == 2: self.skipTest('no Metal device')
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                diff = {Path(p).stem.split('_', 1)[1]: int(n) for p, n, _ in (ln.split() for ln in r.stdout.splitlines())}
                print(f'{mode} flags: inline helpers {diff["new"]}, unprotected {diff["plain"]} of {r.stdout.split()[2]} words differ from the optnone helpers')
                self.assertEqual(diff['new'], 0, mode)
                self.assertGreater(diff['plain'], 0, mode)   # the comparison sees a fused or folded step


if __name__ == '__main__':
    unittest.main()
