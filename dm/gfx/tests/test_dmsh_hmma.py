"""Ampere HMMA.16816 with an f16 accumulator through simdgroup_matrix (dmsh_build.py hmma_msl): the rewrite of the translator's helper dmsh_hmma16816_f16 as spirv-cross
writes it, its arguments and scratch array, the matrices and shared memory it gives the functions that call it, the compile with the chain's Metal flags; the start-up
self-test's kernels (DM_SELFTEST=hmma: hmma_selftest.py, selftest.m) as exactly that rewrite, compiled as each platform's game shaders are and checked against the one
reference (hmma_check.h), with its switch wired as the host's other diagnostics are; and on this Mac's GPU the rewritten body against a CPU reference of PTX mma.m16n8k16 (f16
sources and accumulator): one call on random fragments, four SIMD-groups a threadgroup, and a run of calls with TensorPass's flags (an accumulator kept in its slot between
calls, A kept from the call before, C = 0, A loaded from shared memory where an LDSM read it, plain and transposed), compiled with the macOS chain's flags and with the iOS
chain's, and the same run with its shared memory past Metal's 32 KB in a device buffer (dmsh_build.py tg_spill after hmma_msl); then the self-test's two kernels, four
calls a lane in a row on one scratch block (each D the next call's C) and eight calls with the flags, eight runs each, compiled once with the macOS chain's Metal flags and
once with the iOS chain's (on the macosx SDK), printing for each the GPU, how close the worst output came to its bound, the largest absolute and relative error and the
flags. With DMSH_TEST_XLATE (the translator), the flags it gives two chained HMMAs on an LDSM's matrices, and an HMMA outside the chain between them."""
import ast
from collections import Counter
from fractions import Fraction
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

GFX = Path(__file__).resolve().parents[1]
TOOLS, NVN, REPO = GFX / 'tools', GFX / 'nvn', GFX.parents[1]
# hmma_msl read from dmsh_build.py here, apart from hmma_selftest.py's own reading of it, so the self-test's kernel is checked against the build's function itself
NAMES = {'hmma_msl', 'split_params', 'block_end', 'HMMA_BODY', 'HMMA_ARGS', 'HMMA_CALL', 'TG_ARRAY'}
tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
selected = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in NAMES)
            or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in NAMES for t in n.targets))]
scope = {'re': re}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), scope)
hmma_msl = scope['hmma_msl']
sys.path.insert(0, str(TOOLS)); import hmma_selftest   # the self-test's kernels: the helper as spirv-cross writes it, in check kernels; both chains' compiles
import dmsh_abi   # noqa: E402
SPILL = {'tg_spill', 'TG_DECL', 'TG_BYTES'}   # dmsh_build.py's rewrite of shared memory past 32 KB, which runs after hmma_msl
spill_scope = {'re': re, 'abi': dmsh_abi}
exec(compile(ast.Module(body=[n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in SPILL) or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in SPILL for t in n.targets))],
                        type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), spill_scope)
tg_spill = spill_scope['tg_spill']

# The self-test's GPU check: a kernel's library from argv[1] through hmma_check.h's run, the code the start-up self-test runs (64 threadgroups of 128 lanes, eight runs, the
# inputs, the reference and its bound, the summary line): the four chained calls (hmma_check_run), or with argv[2] `flags` the flagged calls (hmma_flags_run). Exit 0 within the
# bound, 1 over it, with runs that differ, or not run, 2 without a Metal device
SELFTEST_RUNNER = r'''#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "hmma_check.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        if (!dev || argc < 2) { printf("no Metal device\n"); return 2; }
        NSData *lib_data = [NSData dataWithContentsOfFile:@(argv[1])];
        id<MTLLibrary> lib = lib_data ? [dev newLibraryWithData:dispatch_data_create(lib_data.bytes, lib_data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e] : nil;
        if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); return 1; }
        char line[768]; struct hmma_check_result r;
        int flagged = argc > 2 && !strcmp(argv[2], "flags");
        int ran = flagged ? hmma_flags_run(dev, lib, &r, line, sizeof line) : hmma_check_run(dev, lib, &r, line, sizeof line);
        printf("%s\n", line);
        return !ran || hmma_check_failed(&r);
    }
}
'''

HEAD = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];

    thread T& operator [] (size_t pos) thread { return elements[pos]; }
    constexpr const thread T& operator [] (size_t pos) const thread { return elements[pos]; }
    threadgroup T& operator [] (size_t pos) threadgroup { return elements[pos]; }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup { return elements[pos]; }
};
'''
# The helper as spirv-cross writes it (Ocarina of Time's e6be82d835fbe4d3, cut down to its signature and a body of the same shape): lane, block, A (4), B (2), C (2), flags,
# A's LDSM address, A's four offsets, A's row stride, out D1, the scratch
HELPER = '''
static inline __attribute__((always_inline))
int dmsh_hmma16816_f16(thread const int& _10, thread const int& _11, thread const int& _12, thread const int& _13, thread const int& _14, thread const int& _15, thread const int& _16, thread const int& _17, thread const int& _18, thread const int& _19, thread const int& _20, thread const int& _21, thread const int& _22, thread const int& _23, thread const int& _24, thread const int& _25, thread const int& _26, thread int& _27, threadgroup spvUnsafeArray<uint, 1024>& _34)
{
    uint _40 = uint(int(uint(_10) >> uint(2)));
    _34[_11 + int(_40)] = uint(_12);
    if (_40 > 3u)
    {
        _27 = 0;
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
    _27 = int(_34[_11]);
    return int(_34[_11 + 1]);
}
'''
KERNEL = '''
kernel void check(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                  uint gid [[thread_position_in_grid]])
{
    threadgroup spvUnsafeArray<uint, 1024> scr;
    int l = int(lane), blk = int(sg * 256), z = 0;
    int a0 = int(in[gid * 8 + 0]), a1 = int(in[gid * 8 + 1]), a2 = int(in[gid * 8 + 2]), a3 = int(in[gid * 8 + 3]);
    int b0 = int(in[gid * 8 + 4]), b1 = int(in[gid * 8 + 5]), c0 = int(in[gid * 8 + 6]), c1 = int(in[gid * 8 + 7]);
    int d1;
    int d0 = dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, z, z, z, z, z, z, z, d1, scr);
    out[gid * 2] = uint(d0); out[gid * 2 + 1] = uint(d1);
}
'''
# A run of four calls a SIMD-group, with the flags TensorPass gives them (TensorPass.Flag*): A0's tile lies in shared memory row-major, 48 bytes a row, read as an LDSM's
# matrices 0..3 at rows 0, 8 and columns 0, 8 (offsets 0, 384, 16, 400); A1 lies there transposed (A1's columns are the rows, 32 bytes apart: matrices at 0, 16, 256, 272).
#   1. A0 B0 + C       A where the LDSM read it, D left in slot 0          (flags 16 | 4)
#   2. A0 B1 + slot 0  A kept from call 1, C from slot 0: E0               (1 | 2 | 16)
#   3. A1 B2           C = 0, A through the scratch, D left in slot 1      (8 | 4 | 1 << 8)
#   4. A1 B3 + slot 1  A transposed where the LDSM read it, C slot 1: E1   (2 | 16 | 32 | 1 << 8)
# The registers each call is given are what the translator's body would compute with (a stale A or C included), so the run also checks that the flags are what is read.
# Input a SIMD-group: halves A0 (16 x 16, row-major), A1, B0..B3 (16 x 8, k-major), C (16 x 8): 1152 halves
SEQ_KERNEL = '''
static uint pk(device const ushort* p, int i, int j) { return uint(p[i]) | uint(p[j]) << 16; }
kernel void check_seq(device const ushort *in [[buffer(0)]], device uint *out [[buffer(1)]], uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                      uint gid [[thread_position_in_grid]])
{
    threadgroup spvUnsafeArray<uint, 1280> shm;
    threadgroup spvUnsafeArray<uint, 1024> scr;
    device const ushort* x = in + sg * 1152 + (gid / 128) * 4 * 1152;
    device const ushort *A0 = x, *A1 = x + 256, *B0 = x + 512, *B1 = x + 640, *B2 = x + 768, *B3 = x + 896, *C = x + 1024;
    threadgroup ushort* sh = (threadgroup ushort*)&shm[0];
    int base0 = int(sg) * 1280, base1 = base0 + 768;   // bytes: 16 rows of 48, then 16 rows of 32
    for (int i = int(lane); i < 256; i += 32) { int r = i / 16, c = i % 16; sh[base0 / 2 + r * 24 + c] = A0[i]; sh[base1 / 2 + c * 16 + r] = A1[i]; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int l = int(lane), g = l / 4, t = l % 4, blk = int(sg) * 256;
    int a00 = int(pk(A0, g * 16 + 2 * t, g * 16 + 2 * t + 1)), a01 = int(pk(A0, (g + 8) * 16 + 2 * t, (g + 8) * 16 + 2 * t + 1));
    int a02 = int(pk(A0, g * 16 + 8 + 2 * t, g * 16 + 9 + 2 * t)), a03 = int(pk(A0, (g + 8) * 16 + 8 + 2 * t, (g + 8) * 16 + 9 + 2 * t));
    int a10 = int(pk(A1, g * 16 + 2 * t, g * 16 + 2 * t + 1)), a11 = int(pk(A1, (g + 8) * 16 + 2 * t, (g + 8) * 16 + 2 * t + 1));
    int a12 = int(pk(A1, g * 16 + 8 + 2 * t, g * 16 + 9 + 2 * t)), a13 = int(pk(A1, (g + 8) * 16 + 8 + 2 * t, (g + 8) * 16 + 9 + 2 * t));
    int b00 = int(pk(B0, (2 * t) * 8 + g, (2 * t + 1) * 8 + g)), b01 = int(pk(B0, (2 * t + 8) * 8 + g, (2 * t + 9) * 8 + g));
    int b10 = int(pk(B1, (2 * t) * 8 + g, (2 * t + 1) * 8 + g)), b11 = int(pk(B1, (2 * t + 8) * 8 + g, (2 * t + 9) * 8 + g));
    int b20 = int(pk(B2, (2 * t) * 8 + g, (2 * t + 1) * 8 + g)), b21 = int(pk(B2, (2 * t + 8) * 8 + g, (2 * t + 9) * 8 + g));
    int b30 = int(pk(B3, (2 * t) * 8 + g, (2 * t + 1) * 8 + g)), b31 = int(pk(B3, (2 * t + 8) * 8 + g, (2 * t + 9) * 8 + g));
    int c0 = int(pk(C, g * 8 + 2 * t, g * 8 + 2 * t + 1)), c1 = int(pk(C, (g + 8) * 8 + 2 * t, (g + 8) * 8 + 2 * t + 1));
    int addr0 = base0 + ((l & 7) + 8 * ((l >> 3) & 1)) * 48 + 16 * (l >> 4), addr1 = base1 + (l & 7) * 32 + ((l >> 3) & 1) * 16 + (l >> 4) * 256;
    int f1 = 16 | 4, f2 = 1 | 2 | 16, f3 = 8 | 4 | 1 << 8, f4 = 2 | 16 | 32 | 1 << 8, z = 0;
    int o0 = 0, o1 = 384, o2 = 16, o3 = 400, s0 = 48, p0 = 0, p1 = 16, p2 = 256, p3 = 272, s1 = 32;
    int e1, e2, e3, e4;
    int d1 = dmsh_hmma16816_f16(l, blk, a00, a01, a02, a03, b00, b01, c0, c1, f1, addr0, o0, o1, o2, o3, s0, e1, scr);
    int d2 = dmsh_hmma16816_f16(l, blk, a00, a01, a02, a03, b10, b11, d1, e1, f2, addr0, o0, o1, o2, o3, s0, e2, scr);
    int d3 = dmsh_hmma16816_f16(l, blk, a10, a11, a12, a13, b20, b21, z, z, f3, z, z, z, z, z, z, e3, scr);
    int d4 = dmsh_hmma16816_f16(l, blk, a00, a01, a02, a03, b30, b31, d3, e3, f4, addr1, p0, p1, p2, p3, s1, e4, scr);
    out[gid * 4] = uint(d2); out[gid * 4 + 1] = uint(e2); out[gid * 4 + 2] = uint(d4); out[gid * 4 + 3] = uint(e4);
}
'''
# Call 4 is given A0's registers on purpose: A1 must come from shared memory (FlagADirect), transposed (FlagATrans)
HALF = r'''#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static float h2f(uint16_t h) { __fp16 v; memcpy(&v, &h, 2); return (float)v; }
static uint16_t f2h(float f) { __fp16 v = (__fp16)f; uint16_t h; memcpy(&h, &v, 2); return h; }
static id<MTLComputePipelineState> pipeline(id<MTLDevice> dev, const char *path, NSString *name) {
    NSError *e = nil; NSData *lib_data = [NSData dataWithContentsOfFile:@(path)];
    id<MTLLibrary> lib = [dev newLibraryWithData:dispatch_data_create(lib_data.bytes, lib_data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e];
    if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); exit(1); }
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:name] error:&e];
    if (!ps) { printf("pipeline: %s\n", e.localizedDescription.UTF8String); exit(1); }
    return ps;
}
static void run(id<MTLDevice> dev, id<MTLComputePipelineState> ps, id<MTLBuffer> in, id<MTLBuffer> out, int groups) {
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:in offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
'''
# The GPU check: 64 threadgroups of 128 lanes, random halves in [-1, 1]; the reference sums in float and rounds once; the matrix hardware rounds the f16 accumulator as
# it goes, as Ampere's f16 accumulator does, so the tolerance is 0.01 + 0.4 % of the value
RUNNER = HALF + r'''
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 2; }
        id<MTLComputePipelineState> ps = pipeline(dev, argv[1], @"check");
        const int groups = 64, tg = 128, n = groups * tg;
        id<MTLBuffer> in = [dev newBufferWithLength:n * 32 options:MTLResourceStorageModeShared], out = [dev newBufferWithLength:n * 8 options:MTLResourceStorageModeShared];
        uint32_t *w = in.contents; srand(11);
        for (int i = 0; i < n * 8; i++) w[i] = f2h((rand() % 2001 - 1000) / 1000.0f) | (uint32_t)f2h((rand() % 2001 - 1000) / 1000.0f) << 16;
        run(dev, ps, in, out, groups);
        uint32_t *o = out.contents; long bad = 0; double worst = 0;
        for (int warp = 0; warp < n / 32; warp++) {
            float A[16][16], B[16][8], C[16][8];
            for (int L = 0; L < 32; L++) {
                const uint32_t *f = w + (warp * 32 + L) * 8; int g = L / 4, t = L % 4;
                for (int r = 0; r < 4; r++) { int row = g + 8 * (r & 1), k = 2 * t + 8 * (r >> 1); A[row][k] = h2f(f[r] & 0xffff); A[row][k + 1] = h2f(f[r] >> 16); }
                for (int r = 0; r < 2; r++) { int k = 2 * t + 8 * r; B[k][g] = h2f(f[4 + r] & 0xffff); B[k + 1][g] = h2f(f[4 + r] >> 16); }
                for (int r = 0; r < 2; r++) { int row = g + 8 * r; C[row][2 * t] = h2f(f[6 + r] & 0xffff); C[row][2 * t + 1] = h2f(f[6 + r] >> 16); }
            }
            for (int L = 0; L < 32; L++) {
                int g = L / 4, t = L % 4; const uint32_t *r = o + (warp * 32 + L) * 2;
                for (int q2 = 0; q2 < 2; q2++) for (int j = 0; j < 2; j++) {
                    int row = g + 8 * q2, col = 2 * t + j; float ref = C[row][col];
                    for (int k = 0; k < 16; k++) ref += A[row][k] * B[k][col];
                    double d = fabs(h2f((r[q2] >> (16 * j)) & 0xffff) - ref);
                    if (d > worst) worst = d;
                    bad += d > 0.01 + fabs(ref) * 0.004;
                }
            }
        }
        printf("%d SIMD-groups, max abs error %.4g, %ld outputs over tolerance\n", n / 32, worst, bad);
        return bad != 0;
    }
}
'''
# The run of calls: E0 = A0 (B0 + B1) + C and E1 = A1 (B2 + B3), each two HMMAs with an f16 accumulator in between: the tolerance is twice the single call's
SEQ_RUNNER = HALF + r'''
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 2; }
        id<MTLComputePipelineState> ps = pipeline(dev, argv[1], @"check_seq");
        const int groups = 16, warps = groups * 4;
        id<MTLBuffer> in = [dev newBufferWithLength:warps * 1152 * 2 options:MTLResourceStorageModeShared], out = [dev newBufferWithLength:warps * 32 * 16 options:MTLResourceStorageModeShared];
        uint16_t *h = in.contents; srand(7);
        for (int i = 0; i < warps * 1152; i++) h[i] = f2h((rand() % 2001 - 1000) / 1000.0f);
        run(dev, ps, in, out, groups);
        uint32_t *o = out.contents; long bad = 0; double worst = 0;
        for (int w = 0; w < warps; w++) {
            const uint16_t *x = h + w * 1152;
            for (int L = 0; L < 32; L++) {
                int g = L / 4, t = L % 4; const uint32_t *r = o + (w * 32 + L) * 4;
                for (int e = 0; e < 2; e++) for (int q2 = 0; q2 < 2; q2++) for (int j = 0; j < 2; j++) {
                    int row = g + 8 * q2, col = 2 * t + j;
                    const uint16_t *A = x + 256 * e, *Ba = x + 512 + 256 * e, *Bb = Ba + 128;
                    float ref = e == 0 ? h2f(x[1024 + row * 8 + col]) : 0;
                    for (int k = 0; k < 16; k++) ref += h2f(A[row * 16 + k]) * (h2f(Ba[k * 8 + col]) + h2f(Bb[k * 8 + col]));
                    double d = fabs(h2f((r[e * 2 + q2] >> (16 * j)) & 0xffff) - ref);
                    if (d > worst) worst = d;
                    bad += d > 0.02 + fabs(ref) * 0.008;
                }
            }
        }
        printf("%d SIMD-groups, max abs error %.4g, %ld outputs over tolerance\n", warps, worst, bad);
        return bad != 0;
    }
}
'''

# The run of calls with its shared memory past Metal's 32 KB, as a kernel that declares more gets it (dmsh_build.py tg_spill, after hmma_msl): SEQ_KERNEL as main0, the one
# tg_spill takes, with a shared array of 32 KB beside the scratch; spirv-cross's array template also has the device overloads the spilled arrays use. Every threadgroup array,
# the helper's scratch and shared memory parameters and its pointers become a slice of the device buffer at abi.TG_SLOT, and its barriers order device memory too
SPILL_HEAD = HEAD.replace('    threadgroup T& operator [] (size_t pos) threadgroup', '    device T& operator [] (size_t pos) device { return elements[pos]; }\n'
                          '    constexpr const device T& operator [] (size_t pos) const device { return elements[pos]; }\n    threadgroup T& operator [] (size_t pos) threadgroup', 1)
# Metal takes the grid position, the workgroup ID and the workgroup count all scalar or all vectors of one size, and tg_spill adds the last two as uint3, as spirv-cross
# declares every one of them in a game's compute shader; so the run's kernel takes its grid position as uint3 too
SPILL_KERNEL = (SEQ_KERNEL.replace('kernel void check_seq(', 'kernel void main0(').replace('threadgroup spvUnsafeArray<uint, 1280> shm;', 'threadgroup spvUnsafeArray<uint, 8192> shm;')
                .replace('uint gid [[thread_position_in_grid]])\n{\n', 'uint3 gid3 [[thread_position_in_grid]])\n{\n    uint gid = gid3.x;\n'))
assert 'uint3 gid3 [[thread_position_in_grid]]' in SPILL_KERNEL and 'uint gid [[' not in SPILL_KERNEL


def spilled():   # the run's source as the build gives it, and the bytes a workgroup takes from the device buffer
    return tg_spill(hmma_msl(SPILL_HEAD + HELPER + SPILL_KERNEL))


def spill_runner(n):   # SEQ_RUNNER for main0, with the device buffer that holds its shared memory: n bytes a workgroup at abi.TG_SLOT
    dispatch = ('        id<MTLBuffer> tg = [dev newBufferWithLength:(NSUInteger)groups * %d options:MTLResourceStorageModePrivate];\n'
                '        id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];\n'
                '        [ce setComputePipelineState:ps]; [ce setBuffer:in offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1]; [ce setBuffer:tg offset:0 atIndex:%d];\n'
                '        [ce dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];\n'
                ) % (n, dmsh_abi.TG_SLOT)
    runner = SEQ_RUNNER.replace('@"check_seq"', '@"main0"').replace('        run(dev, ps, in, out, groups);\n', dispatch)
    assert '@"main0"' in runner and 'run(dev, ps' not in runner
    return runner


def compile_and_run(test, msl, runner, build=None, label=None):
    """msl compiled with -O1 -fpreserve-invariance on the macosx SDK, or by build(msl, folder) → the metallib's path, then runner on it; with label, its line is printed"""
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        if build: lib = build(msl, d)
        else:
            (d / 'h.metal').write_text(msl)
            subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-O1', '-fpreserve-invariance', str(d / 'h.metal'), '-o', str(d / 'h.air')], check=True)
            subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(d / 'h.air'), '-o', str(d / 'h.metallib')], check=True)
            lib = d / 'h.metallib'
        (d / 'run.m').write_text(runner)
        subprocess.run(['clang', '-fobjc-arc', '-O1', str(d / 'run.m'), '-framework', 'Metal', '-framework', 'Foundation', '-o', str(d / 'run')], check=True)
        r = subprocess.run([str(d / 'run'), str(lib)], capture_output=True, text=True)
        if r.returncode == 2: test.skipTest(r.stdout.strip())
        if label: print(f'\n{label}: {r.stdout.strip()}', flush=True)
        test.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class HmmaRewrite(unittest.TestCase):
    def test_body_replaced_with_its_arguments(self):
        out = hmma_msl(HEAD + HELPER + KERNEL)
        body = out[out.index('int dmsh_hmma16816_f16('):out.index('kernel void check')]
        self.assertEqual(body.count('simdgroup_multiply_accumulate('), 4)
        self.assertIn('threadgroup uint* s = &_34[uint(_11)];', body)        # the scratch array at the block offset
        self.assertIn('uint g = uint(_10) >> 2', body)                        # the lane
        self.assertIn('s[g * 8 + t] = uint(_12)', body)                       # A0
        self.assertIn('s[192 + (g + 8) * 4 + t] = uint(_19)', body)           # C1
        self.assertIn('const int f = int(_20)', body)                         # the flags
        self.assertIn('_27 = as_type<int>(d1);', body)                        # the out argument
        self.assertIn('return as_type<int>(d0);', body)
        self.assertNotIn('_40', body)                                         # the translator's body is gone, the braces of its blocks too
        self.assertEqual(out.count('static inline __attribute__((always_inline))'), 1)   # spirv-cross's line before it stays, alone

    def test_callers_get_their_matrices_and_shared_memory(self):
        out = hmma_msl(HEAD + HELPER + SEQ_KERNEL)
        kernel = out[out.index('kernel void check_seq'):]
        self.assertIn('{\n    simdgroup_half8x8 dm_acc[18], dm_am[4];\n', kernel)   # first in the body
        self.assertEqual(kernel.count(', scr, dm_acc, dm_am, shm)'), 4)              # every call: the matrices, then the one other threadgroup array
        self.assertIn('thread simdgroup_half8x8 (&acc)[18], thread simdgroup_half8x8 (&am)[4], threadgroup spvUnsafeArray<uint, 1280>& dm_shm)', out)
        self.assertIn('adirect = (f & 16) != 0', out)

    def test_two_other_arrays_load_a_through_the_scratch(self):
        src = SEQ_KERNEL.replace('    threadgroup spvUnsafeArray<uint, 1024> scr;\n', '    threadgroup spvUnsafeArray<uint, 1024> scr;\n    threadgroup spvUnsafeArray<uint, 16> other;\n')
        out = hmma_msl(HEAD + HELPER + src)
        self.assertNotIn('dm_shm', out)
        self.assertIn('adirect = false', out)
        self.assertEqual(out.count(', scr, dm_acc, dm_am)'), 4)

    def test_kernel_unchanged_but_its_calls(self):
        out = hmma_msl(HEAD + HELPER + KERNEL)
        self.assertIn(KERNEL.strip().replace('d1, scr)', 'd1, scr, dm_acc, dm_am)').replace('{\n    threadgroup', '{\n    simdgroup_half8x8 dm_acc[18], dm_am[4];\n    threadgroup', 1), out)

    def test_a_call_in_no_chain_works_in_a_pair_of_its_own(self):
        # TensorPass gives a slot (flags >> 8) only to a chain's calls, and the first chain of a block takes slot 0: a call with neither CSlot nor DSlot may come while that chain
        # is open (between its calls, or a chain that found all 8 slots taken), so it works in the two matrices past the 8 slots, not in slot 0's, whose sum it would overwrite
        out = hmma_msl(HEAD + HELPER + SEQ_KERNEL)
        k = re.search(r'const int k = cslot \|\| dslot \? \(f >> 8\) \* 2 : (\d+);', out)
        self.assertIsNotNone(k)
        pair = int(k.group(1))
        self.assertEqual(pair, 2 * 8)   # past slot 7's acc[14], acc[15]
        self.assertIn(f'(&acc)[{pair + 2}]', out); self.assertIn(f'dm_acc[{pair + 2}], dm_am[4];', out)
        self.assertNotRegex(out, r'const int f = [^;]*, k = ')   # NXNative's form, k = (f >> 8) * 2 for every call

    def test_shared_memory_in_a_device_buffer(self):   # tg_spill after hmma_msl: the body's scratch, shared memory and pointers in the device buffer, direct A still on
        out, n = spilled()
        self.assertEqual(n, (8192 + 1024) * 4)
        self.assertIn(f'device uchar* dm_tg [[buffer({dmsh_abi.TG_SLOT})]]', out)
        self.assertIn('threadgroup spvUnsafeArray<uint, 1024>& _34', HELPER)
        self.assertIn('device spvUnsafeArray<uint, 1024>& _34, thread simdgroup_half8x8 (&acc)[18], thread simdgroup_half8x8 (&am)[4], device spvUnsafeArray<uint, 8192>& dm_shm)', out)
        self.assertIn('adirect = (f & 16) != 0', out)   # hmma_msl saw the one shared array before it moved
        for line in ('device uint* s = &_34[uint(_11)];', 'device half* h = (device half*)s;', 'device half* x = (device half*)&dm_shm[0] + '):
            self.assertIn(line, out)
        self.assertEqual(out.count('simdgroup_barrier(mem_flags::mem_device | mem_flags::mem_threadgroup);'), scope['HMMA_BODY'].count('simdgroup_barrier(mem_flags::mem_threadgroup);'))
        self.assertEqual(out[out.index('kernel void main0'):].count(', scr, dm_acc, dm_am, shm);'), 4)
        self.assertEqual([ln for ln in out.split('\n') if re.search(r'\bthreadgroup\s', ln) and 'operator [] (size_t pos)' not in ln], [])   # only the template's overloads keep it

    def test_other_shaders_unchanged(self):
        src = HEAD + KERNEL.replace('dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, z, z, z, z, z, z, z, d1, scr)', 'a0')
        self.assertEqual(hmma_msl(src), src)

    def test_unexpected_signature_refused(self):
        with self.assertRaises(ValueError):
            hmma_msl(HEAD + HELPER.replace('thread const int& _26, ', ''))


class SelfTest(unittest.TestCase):
    """The start-up self-test DM_SELFTEST=hmma: the body it runs, the reference it compares with, and where the host starts and waits for it"""
    def test_kernel_is_the_rewrite_games_get(self):
        msl = lambda *name: subprocess.run([sys.executable, str(TOOLS / 'hmma_selftest.py'), '--msl', *name], capture_output=True, text=True, check=True).stdout   # noqa: E731
        for name, kernel in hmma_selftest.LIBRARIES.items():   # both kernels, each a library of its own
            self.assertEqual(hmma_selftest.msl(name), hmma_msl(hmma_selftest.HEAD + hmma_selftest.HELPER + kernel))
            self.assertEqual(msl(name), hmma_selftest.msl(name))
        self.assertEqual(msl(), hmma_selftest.msl('hmma_selftest'))
        self.assertEqual((hmma_selftest.HEAD, hmma_selftest.HELPER), (HEAD, HELPER))   # the helper as the rewrite's tests above have it: 19 parameters, spirv-cross's always-inline line
        self.assertEqual(hmma_selftest.hmma_msl.__code__.co_filename, str(TOOLS / 'dmsh_build.py'))   # dmsh_build.py's function, not a copy
        self.assertLessEqual(NAMES | {'MAC_METAL', 'METAL_DEPTH', 'MAC_RECORD', 'mac_compile'}, set(hmma_selftest.CHAIN))   # what they use, which it finds by itself
        own = (TOOLS / 'hmma_selftest.py').read_text()
        self.assertNotIn('simdgroup_multiply_accumulate', own)   # no body of its own

    def test_compiled_with_each_platforms_game_shader_flags(self):
        import ios_metal
        self.assertEqual(hmma_selftest.CHAIN['MAC_METAL'][:4], ['xcrun', '-sdk', 'macosx', 'metal'])
        metal, fallback, metallib = hmma_selftest.ios_flags_on_mac()
        self.assertEqual([a for a in ios_metal.METAL if not a.startswith('-mios-version-min=')], [('iphoneos' if a == 'macosx' else a) for a in metal])
        self.assertIn('-std=metal4.1', metal); self.assertIn('-fmetal-math-mode=relaxed', metal)
        self.assertEqual(fallback, [ios_metal.FALLBACK_STD if a == ios_metal.STD else a for a in metal])
        self.assertEqual(metallib, ['xcrun', '-sdk', 'macosx', 'metallib'])
        self.assertNotEqual(hmma_selftest.inputs('iphoneos'), hmma_selftest.inputs('macosx'))

    def test_one_reference_for_the_mac_test_and_the_self_test(self):
        selftest = (NVN / 'selftest.m').read_text()
        for src in (SELFTEST_RUNNER, selftest):
            self.assertIn('#include "hmma_check.h"', src)
            self.assertIn('hmma_check_failed(&r)', src)   # over the bound, or runs that differ
            self.assertNotIn('h2f', src); self.assertNotIn('srand', src); self.assertNotIn('0.004', src)   # no fragments, inputs or bound of their own
        for run in ('hmma_check_run', 'hmma_flags_run'): self.assertIn(f'{run}(dev, lib, &r, line, sizeof line)', SELFTEST_RUNNER)
        self.assertIn('    selftest_hmma_kernel(dev, gpu, "hmma_selftest", "", hmma_check_run);\n'   # each kernel from its own library, in that order: two lines
                      '    selftest_hmma_kernel(dev, gpu, "hmma_selftest_flags", "flagged calls: ", hmma_flags_run);\n', selftest)
        self.assertIn('int ran = run(dev, lib, &r, line, sizeof line);', selftest)
        check = (NVN / 'hmma_check.h').read_text()
        self.assertIn('hmma_check_dispatch(dev, lib, @"check", "", ', check); self.assertIn('hmma_check_dispatch(dev, lib, @"check_flags", "flagged calls: ", ', check)
        self.assertIn('HMMA_CHECK_GROUPS = 64, HMMA_CHECK_LANES = 128', check)
        self.assertIn(f'HMMA_CHECK_STEPS = {hmma_selftest.STEPS}, HMMA_CHECK_RUNS = 8', check)   # the kernel's calls a lane, the header's steps
        self.assertIn('"OVER BOUND"', check); self.assertNotIn('[RED]', check)   # the verdict; the self-test's line, not the summary, starts with the red mark (AGENTS.md)
        self.assertIn('STLOG("%sself-test hmma: %s; compiled by %s", !ran || hmma_check_failed(&r) ? "[RED] " : "", line, record);', selftest)   # and names its compile

    def test_the_kernel_chains_its_calls_on_one_scratch_block(self):   # as games make the calls with no flag: the scratch reused across calls (the body's last barrier), D fed back as C
        kernel = hmma_selftest.KERNEL
        call = 'int d0 = dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, z, z, z, z, z, z, z, d1, scr);'   # flags 0, A's place in shared memory 0
        self.assertEqual(kernel.count(call), hmma_selftest.STEPS); self.assertEqual(kernel.count('threadgroup spvUnsafeArray<uint, 1024> scr;'), 1)
        self.assertIn('int l = int(lane), blk = int(sg * 256), z = 0;', kernel)
        self.assertEqual(kernel.count('c0 = d0; c1 = d1;'), hmma_selftest.STEPS)
        for k in range(hmma_selftest.STEPS):
            self.assertIn(f'device const uint *f = in + ({k} * n + gid) * 6;', kernel); self.assertIn(f'out[({k} * n + gid) * 2] = uint(d0)', kernel)
        self.assertIn(f'int c0 = int(in[{6 * hmma_selftest.STEPS} * n + gid * 2])', kernel)   # step 0's C after every step's A and B (hmma_check_c0)
        self.assertIn('adirect = false', hmma_selftest.msl())   # one threadgroup array: A through the scratch, as every call with flags 0 takes it anyway

    @unittest.skipUnless(shutil.which('cc'), 'needs a C compiler')
    def test_reference_is_ptx_mma_m16n8k16(self):
        # hmma_check.h's C part, built here: its tiles against PTX's fragment layout worked out in Python, then the check's verdicts for an ideal GPU's runs (each step rounded
        # once to f16 and fed to the next as C), one output far off, two NaN outputs, and one output an f16 step off in one run (within the bound, but not the first run's)
        driver = r'''#include "hmma_check.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t in[HMMA_CHECK_IN];
static void say(const struct hmma_check_result *r) { char line[512]; hmma_check_summary(r, HMMA_CHECK_RUNS, line, sizeof line); printf("%ld %ld %d|%s\n", r->over, r->nan, r->runs_differ, line); }
int main(void) {
    uint32_t *out = malloc(sizeof *out * HMMA_CHECK_OUT * HMMA_CHECK_RUNS); if (!out) return 1;
    hmma_check_fill(in, HMMA_CHECK_SEED);
    const uint32_t *ab = hmma_check_ab(in, 0), *c0 = hmma_check_c0(in);
    for (int L = 0; L < 64; L++) printf("%u %u %u %u %u %u %u %u\n", ab[L * 6], ab[L * 6 + 1], ab[L * 6 + 2], ab[L * 6 + 3], ab[L * 6 + 4], ab[L * 6 + 5], c0[L * 2], c0[L * 2 + 1]);
    float D[16][8]; hmma_check_tile(ab, c0, 1, D);
    for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) printf("%.9g%c", D[r][c], c == 7 ? '\n' : ' ');
    for (int run = 0; run < HMMA_CHECK_RUNS; run++) for (int step = 0; step < HMMA_CHECK_STEPS; step++) {
        uint32_t *o = out + (size_t)run * HMMA_CHECK_OUT, *d = o + step * HMMA_CHECK_THREADS * 2; const uint32_t *c = step ? hmma_check_d(o, step - 1) : c0;
        for (int w = 0; w < HMMA_CHECK_TILES; w++) {
            hmma_check_tile(hmma_check_ab(in, step), c, w, D);
            for (int L = 0; L < 32; L++) for (int q = 0; q < 2; q++)
                d[(w * 32 + L) * 2 + q] = hmma_check_f2h(D[L / 4 + 8 * q][2 * (L % 4)]) | (uint32_t)hmma_check_f2h(D[L / 4 + 8 * q][2 * (L % 4) + 1]) << 16;
        }
    }
    struct hmma_check_result r; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r);
    printf("%ld %ld %ld %d %.6f %.6f %.6f\n", r.over, r.nan, r.outputs, r.runs_differ, r.worst, r.abs, r.abs_at); say(&r);
    uint32_t *last = out + (size_t)(HMMA_CHECK_RUNS - 1) * HMMA_CHECK_OUT + (HMMA_CHECK_STEPS - 1) * HMMA_CHECK_THREADS * 2, keep = last[5];   // the last run's last step
    last[5] ^= 0x4000; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r); say(&r);
    last[5] = 0x7e007e00; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r); say(&r);
    last[5] = keep ^ 1; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r); say(&r);
    free(out);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'ref.c').write_text(driver)
            subprocess.run(['cc', '-O1', '-std=c11', f'-I{NVN}', str(Path(d) / 'ref.c'), '-o', str(Path(d) / 'ref'), '-lm'], check=True)
            lines = subprocess.run([str(Path(d) / 'ref')], capture_output=True, text=True, check=True).stdout.split('\n')
        words = [[int(w) for w in lines[i].split()] for i in range(64)]   # lanes 0..63 (warps 0 and 1), step 0: A0..A3, B0, B1, then step 0's C0, C1
        def half(w, hi): return struct.unpack('<e', struct.pack('<H', (w >> (16 * hi)) & 0xffff))[0]
        self.assertTrue(all(-1 <= half(w, h) <= 1 for lane in words for w in lane for h in (0, 1)))
        A = [[0.0] * 16 for _ in range(16)]; B = [[0.0] * 8 for _ in range(16)]; C = [[0.0] * 8 for _ in range(16)]
        for lane in range(32):   # warp 1: PTX ISA, mma.m16n8k16 .f16 fragments (a0..a7, b0..b3, c0..c3 by groupID = lane / 4 and threadID_in_group = lane % 4)
            f, g, t = words[32 + lane], lane // 4, lane % 4
            for i in range(8): A[g + 8 * ((i // 2) % 2)][2 * t + i % 2 + 8 * (i // 4)] = half(f[i // 2], i % 2)
            for i in range(4): B[2 * t + i % 2 + 8 * (i // 2)][g] = half(f[4 + i // 2], i % 2)
            for i in range(4): C[g + 8 * (i // 2)][2 * t + i % 2] = half(f[6 + i // 2], i % 2)
        tile = [[float(x) for x in lines[64 + r].split()] for r in range(16)]
        for r in range(16):
            for c in range(8):
                self.assertAlmostEqual(tile[r][c], C[r][c] + sum(A[r][k] * B[k][c] for k in range(16)), places=4)   # summed in float there
        over, nan, outputs, differ, worst, err, _ = lines[80].split()
        self.assertEqual((over, nan, outputs, differ), ('0', '0', str(256 * 128 * hmma_selftest.STEPS * 8), '0'))
        self.assertLess(float(worst), 0.15)   # rounded once to f16 at each step: half an f16 step at most, about a tenth of the bound
        self.assertLess(float(err), 0.01)
        verdict = lambda i: lines[i].split('|')   # noqa: E731
        self.assertEqual(verdict(81)[0], '0 0 0')
        self.assertRegex(verdict(81)[1], r'^256 tiles x 4 chained calls, 8 runs: worst output at \d+% of its bound 0\.01 \+ 0\.4% of its value; max error [\d.e-]+ abs '
                                         r'\(at an output of [\d.]+\), [\d.e-]+% rel: ok$')
        self.assertEqual(verdict(82), ['1 0 1', verdict(82)[1]]); self.assertTrue(verdict(82)[1].endswith(': OVER BOUND (1 of 1048576 outputs, 1 of 8 runs differ from the first)'))   # one output far off
        self.assertEqual(verdict(83)[0], '2 2 1'); self.assertIn('OVER BOUND (2 of 1048576 outputs, NaN among them, 1 of 8 runs differ from the first)', verdict(83)[1])   # two NaN outputs
        self.assertEqual(verdict(84)[0], '0 0 1'); self.assertTrue(verdict(84)[1].endswith(': RUNS DIFFER (1 of 8 runs differ from the first)'))   # within the bound, but not the first run's

    def test_switch_starts_it_once_off_the_game_threads_before_the_first_instruction(self):
        main = (REPO / 'dm/host/main.c').read_text()
        body = main[main.index('int main(int argc, char **argv) {'):]
        body = body[:body.index('\n}\n')]
        self.assertIn('const char *selftest = getenv("DM_SELFTEST");', body)
        self.assertIn('if (selftest && (!*selftest || !strcmp(selftest, "0"))) selftest = NULL;', body)   # empty or 0: off, as other switches
        uses = [line.strip() for line in body.split('\n') if 'dm_selftest_' in line and not line.strip().startswith('void ')]
        self.assertEqual(uses, ['if (selftest) dm_selftest_start(selftest);', 'if (selftest) dm_selftest_wait();'])   # only with the switch
        self.assertLess(body.index('dm_selftest_start(selftest)'), body.index('host_preload(argc, argv)'))   # it runs while the host loads,
        self.assertIn('if (selftest) dm_selftest_wait();\n    front_run(guest_main);', body)                # and ends before the game's first instruction
        st = (NVN / 'selftest.m').read_text()
        start_fn = st[st.index('void dm_selftest_start('):st.index('void dm_selftest_wait(')]
        self.assertIn('atomic_exchange(&once, 1)', start_fn)                  # once a process
        self.assertIn('pthread_create(&th, &a, selftest_thread, arg)', start_fn)   # on its own thread
        self.assertNotIn('selftest_hmma()', start_fn)                         # never on main.c's, which becomes the game's
        self.assertIn('dispatch_semaphore_wait(g_selftest_done', st)
        self.assertRegex(st, r'void dm_selftest_wait\(void\) \{\n    if \(!g_selftest_done\) return;')
        self.assertNotIn('getenv(', st)   # the switch is read in one place, main.c
        rows = {l.split('\t')[0]: l.split('\t') for l in (REPO / 'docs/env_switches.tsv').read_text().split('\n') if l.startswith('DM_')}
        self.assertEqual(rows['DM_SELFTEST'][1], 'diagnostic')
        self.assertIn('hmma', rows['DM_SELFTEST'][2])

    def test_the_flagged_kernel_takes_each_flags_path(self):   # its own library, one threadgroup array beside the scratch, the flags TensorPass gives as constants
        S = hmma_selftest
        tensor = (REPO / 'dm/third_party/ryujinx/src/Ryujinx.Graphics.Shader/Translation/Transforms/TensorPass.cs').read_text()
        self.assertEqual({k: int(v) for k, v in re.findall(r'public const int Flag(\w+) = (\d+);', tensor)},
                         dict(AReuse=S.A_REUSE, CSlot=S.C_SLOT, DSlot=S.D_SLOT, CZero=S.C_ZERO, ADirect=S.A_DIRECT, ATrans=S.A_TRANS))
        out = S.msl('hmma_selftest_flags')
        self.assertIn('adirect = (f & 16) != 0', out)   # A from shared memory where FlagADirect says so
        self.assertIn('thread simdgroup_half8x8 (&acc)[18], thread simdgroup_half8x8 (&am)[4], threadgroup spvUnsafeArray<uint, 1280>& dm_shm)', out)
        self.assertIn('{\n    simdgroup_half8x8 dm_acc[18], dm_am[4];\n    threadgroup spvUnsafeArray<uint, 1280> shm;\n', out)
        self.assertEqual(out.count(', scr, dm_acc, dm_am, shm);'), len(S.CALLS))
        self.assertIn('adirect = false', hmma_msl(S.HEAD + S.HELPER + S.KERNEL + S.FLAGS_KERNEL))   # beside `check`, which has no such array: A through the scratch everywhere
        consts = dict(re.findall(r'\b(f\d+) = (\d+)', re.search(r'    int (f1 = [^;]*);', S.FLAGS_KERNEL).group(1)))
        self.assertEqual([int(consts[f'f{i}']) for i in range(1, len(S.CALLS) + 1)], [f | (slot << 8 if f & (S.C_SLOT | S.D_SLOT) else 0) for _, _, _, f, slot, _ in S.CALLS])
        for i in range(1, len(S.CALLS) + 1): self.assertEqual(S.FLAGS_KERNEL.count(f', f{i}, '), 1)
        check = (NVN / 'hmma_check.h').read_text()   # the reference's layout and calls are the kernel's
        enum = {k: int(v) for k, v in re.findall(r'\b(HMMA_FLAGS_[A-Z]+) = (\d+)\b', check)}
        n_b = 1 + max(c[1] for c in S.CALLS)
        self.assertEqual((enum['HMMA_FLAGS_CALLS'], enum['HMMA_FLAGS_ENDS'], enum['HMMA_FLAGS_TILE'], enum['HMMA_FLAGS_B'], enum['HMMA_FLAGS_C']),
                         (len(S.CALLS), len({c[2] for c in S.CALLS}), S.TILE, 512, 512 + 128 * n_b))
        self.assertEqual(S.TILE, 512 + 128 * n_b + 128)
        table = re.search(r'hmma_flags_calls\[HMMA_FLAGS_CALLS\] = \{(.*)\};', check).group(1)
        self.assertEqual([tuple(map(int, t)) for t in re.findall(r'\{(\d+), (\d+), (\d+)\}', table)], [c[:3] for c in S.CALLS])
        from_c = re.search(r'hmma_flags_from_c\[HMMA_FLAGS_ENDS\] = \{([\d, ]*)\};', check).group(1)
        self.assertEqual([int(v) for v in from_c.split(',')], [int(r in S.FROM_C) for r in range(enum['HMMA_FLAGS_ENDS'])])
        self.assertEqual(S.FROM_C, (0, 3))
        # the call in no chain comes while both chains are open, one of them in slot 0, and the chains take the first and the last slot
        open_slots, outside = set(), []
        for i, (_, _, _, f, slot, _) in enumerate(S.CALLS, 1):
            if not f & (S.C_SLOT | S.D_SLOT): outside.append((i, sorted(open_slots)))
            elif f & S.D_SLOT: open_slots.add(slot)
            else: open_slots.discard(slot)
        self.assertEqual(outside, [(4, [0, 7]), (8, [])])
        self.assertIn(f'in + (gid / 32) * {S.TILE};', S.FLAGS_KERNEL); self.assertIn(f'*C = x + {enum["HMMA_FLAGS_C"]};', S.FLAGS_KERNEL)
        for r in range(enum['HMMA_FLAGS_ENDS']): self.assertIn(f'out[gid * {2 * enum["HMMA_FLAGS_ENDS"]} + {2 * r}] = ', S.FLAGS_KERNEL)

    def test_a_flag_the_body_does_not_follow_gives_a_wrong_result(self):
        # FLAGS_KERNEL's calls through the body's tests of the flags (HMMA_BODY: A kept, else from shared memory, else from the registers; C from the slot, else 0, else the
        # registers; D left in the slot), each result a sum of products: what each call reads where, with the registers and addresses the kernel gives it. Then each call
        # with one of the flags that decide where A or C comes from not seen: the result must change, so a GPU whose compile lost a flag's path fails the bound
        S = hmma_selftest

        def results(drop=(0, 0), pair='own'):   # pair: where a call in no chain works (HMMA_BODY: a pair of its own; NXNative's body: slot 0's matrices, pair=0)
            am, acc, d, last = None, {}, {}, {}
            for i, (a, b, res, given, slot, regs) in enumerate(S.CALLS, 1):
                f = given & ~drop[1] if drop[0] == i else given
                k = slot if given & (S.C_SLOT | S.D_SLOT) else pair   # flags >> 8
                if not f & S.A_REUSE:
                    if f & S.A_DIRECT:   # at the address the kernel gives: A0 row-major, or A1 transposed
                        held, transposed = ('A1', True) if given & S.A_TRANS else ('A0', False)
                        am = held if bool(f & S.A_TRANS) == transposed else held + ' transposed'
                    else: am = f'A{regs}'
                regs_c = d[last[res]] if given & S.C_SLOT else Counter() if given & S.C_ZERO else Counter(['C'])   # the C registers the kernel gives
                c = acc[k] if f & S.C_SLOT else Counter() if f & S.C_ZERO else regs_c
                acc[k] = c + Counter([(am, f'B{b}')])
                d[i] = Counter() if f & S.D_SLOT else acc[k]   # the registers: 0 where D stayed in the slot
                last[res] = i
            return {res: d[i] for res, i in last.items()}

        want: dict[int, Counter] = {}
        for a, b, res, *_ in S.CALLS: want.setdefault(res, Counter(['C'] if res in S.FROM_C else []))[(f'A{a}', f'B{b}')] += 1   # hmma_check.h's reference: results 0, 3 from C
        self.assertEqual(results(), want)
        wrong = results(pair=0)   # the call in no chain in slot 0's matrices, over the chain open there: that chain's end reads its sum as C
        self.assertNotEqual(wrong[0], want[0]); self.assertEqual({r: v for r, v in wrong.items() if r}, {r: v for r, v in want.items() if r})
        unseen = [(i, flag) for i, c in enumerate(S.CALLS, 1) for flag in (S.A_REUSE, S.A_DIRECT, S.A_TRANS, S.C_SLOT) if c[3] & flag and results((i, flag)) == want]
        self.assertEqual(unseen, [(2, S.A_REUSE), (2, S.A_DIRECT)])   # only call 2's A is the same either way: A0 kept, or A0 loaded again where the LDSM read it

    @unittest.skipUnless(shutil.which('cc'), 'needs a C compiler')
    def test_flagged_reference_and_its_bound(self):
        # hmma_check.h's reference for the flagged run, built here: tile 1's results against the halves summed exactly here, each bound against its rule; then the verdicts for
        # a CPU model of the calls (each call rounded to f16 once, or after every step of k, a chain's D kept in f16 between its calls), for one whose call 1 took its stale
        # registers' A instead of A from shared memory, for one NaN output, for one run with one output an f16 step off, and for NXNative's body, whose call in no chain
        # (call 4) works in slot 0's matrices, where result 0's chain keeps its sum
        driver = r'''#include "hmma_check.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t in[HMMA_FLAGS_IN];
static void model(uint32_t *out, int per_step, int a_of_call_1, int slot0) {   // the same outputs in every run
    for (int tile = 0; tile < HMMA_CHECK_TILES; tile++) {
        float R[HMMA_FLAGS_ENDS][16][8];
        for (int e = 0; e < HMMA_FLAGS_ENDS; e++) for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) R[e][r][c] = hmma_flags_from_c[e] ? hmma_flags_half(in, tile, HMMA_FLAGS_C + r * 8 + c) : 0;
        for (int i = 0; i < HMMA_FLAGS_CALLS; i++) {
            int a = (i ? hmma_flags_calls[i].a : a_of_call_1) * 256, b = HMMA_FLAGS_B + hmma_flags_calls[i].b * 128, e = hmma_flags_calls[i].end;
            for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) {
                float s = R[e][r][c];
                for (int k = 0; k < 16; k++) {
                    s += hmma_flags_half(in, tile, a + r * 16 + k) * hmma_flags_half(in, tile, b + k * 8 + c);
                    if (per_step) s = hmma_check_h2f(hmma_check_f2h(s));
                }
                R[e][r][c] = hmma_check_h2f(hmma_check_f2h(s));
            }
            if (slot0 && i == 3) memcpy(R[0], R[3], sizeof R[0]);   // call 4 left its D in slot 0's matrices: the chain's next call reads it as C
        }
        for (int L = 0; L < 32; L++) for (int e = 0; e < HMMA_FLAGS_ENDS; e++) for (int q = 0; q < 2; q++) {
            int g = L / 4, t = L % 4;
            out[(tile * 32 + L) * HMMA_FLAGS_ENDS * 2 + e * 2 + q] = hmma_check_f2h(R[e][g + 8 * q][2 * t]) | (uint32_t)hmma_check_f2h(R[e][g + 8 * q][2 * t + 1]) << 16;
        }
    }
    for (int run = 1; run < HMMA_CHECK_RUNS; run++) memcpy(out + (size_t)run * HMMA_FLAGS_OUT, out, sizeof *out * HMMA_FLAGS_OUT);
}
static void say(const uint32_t *out) {
    struct hmma_check_result r; char line[768]; hmma_flags_runs(in, out, HMMA_CHECK_RUNS, &r); hmma_flags_summary(&r, HMMA_CHECK_RUNS, line, sizeof line);
    printf("%ld %ld %d %.6f|%s\n", r.over, r.nan, r.runs_differ, r.worst, line);
}
int main(void) {
    uint32_t *out = malloc(sizeof *out * HMMA_FLAGS_OUT * HMMA_CHECK_RUNS); if (!out) return 1;
    hmma_flags_fill(in, HMMA_CHECK_SEED);
    for (int i = 0; i < HMMA_FLAGS_TILE; i++) printf("%u%c", (unsigned)(in[(HMMA_FLAGS_TILE + i) / 2] >> (16 * (i & 1)) & 0xffff), i % 32 == 31 ? '\n' : ' ');   // tile 1's halves
    double P[HMMA_FLAGS_ENDS][16][8], E[HMMA_FLAGS_ENDS][16][8]; hmma_flags_tile(in, 1, P, E);
    for (int e = 0; e < HMMA_FLAGS_ENDS; e++) for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) printf("%.17g %.17g\n", P[e][r][c], E[e][r][c]);
    model(out, 0, 0, 0); say(out);
    model(out, 1, 0, 0); say(out);
    model(out, 1, 1, 0); say(out);
    model(out, 0, 0, 0); out[(size_t)5 * HMMA_FLAGS_OUT + 7] = 0x7e00 | (out[(size_t)5 * HMMA_FLAGS_OUT + 7] & 0xffff0000u); say(out);
    model(out, 0, 0, 0); out[(size_t)6 * HMMA_FLAGS_OUT + 3] ^= 1; say(out);
    model(out, 0, 0, 1); say(out);
    free(out);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'ref.c').write_text(driver)
            subprocess.run(['cc', '-O1', '-std=c11', f'-I{NVN}', str(Path(d) / 'ref.c'), '-o', str(Path(d) / 'ref'), '-lm'], check=True)
            lines = subprocess.run([str(Path(d) / 'ref')], capture_output=True, text=True, check=True).stdout.split('\n')
        S = hmma_selftest
        th, ends, at_c = S.TILE // 32, 1 + max(c[2] for c in S.CALLS), S.TILE - 128   # lines of tile halves, results, where C starts in a tile
        tile = [int(w) for line in lines[:th] for w in line.split()]
        x = [Fraction(struct.unpack('<e', struct.pack('<H', h))[0]) for h in tile]
        self.assertEqual(len(x), S.TILE); self.assertTrue(all(-1 <= v <= 1 for v in x))
        refs = [tuple(float(v) for v in line.split()) for line in lines[th:th + ends * 128]]
        for e in range(ends):
            for r in range(16):
                for c in range(8):
                    p, bound = x[at_c + r * 8 + c] if e in S.FROM_C else Fraction(0), 0.0
                    for a, b, res, *_ in S.CALLS:
                        if res != e: continue
                        p += sum(x[256 * a + r * 16 + k] * x[512 + 128 * b + k * 8 + c] for k in range(16))
                        bound += 0.01 + 0.004 * (abs(float(p)) + bound)   # each call's own bound, on the value it makes with the error its C already holds
                    self.assertEqual(Fraction(refs[e * 128 + r * 8 + c][0]), p)   # exact in double
                    self.assertAlmostEqual(refs[e * 128 + r * 8 + c][1], bound, delta=bound * 1e-12)
        verdicts = [line.split('|') for line in lines[th + ends * 128:th + ends * 128 + 6]]
        once, step, stale, nan, differ, slot0 = ([*v[0].split(), v[1]] for v in verdicts)
        self.assertEqual(once[:3], ['0', '0', '0']); self.assertLess(float(once[3]), 0.3)   # rounded once a call: well within the bound
        self.assertRegex(once[4], r'^256 tiles x 8 flagged calls \(accumulators in two slots, a call in no chain in between, A kept, C = 0, A from shared memory plain and '
                                  r'transposed\), 8 runs: worst result at '
                                  r"\d+% of its bound \(0\.01 \+ 0\.4% of each call's value, added up its chain\); max error [\d.e-]+ abs \(at an output of [\d.]+\), [\d.e-]+% rel: ok$")
        self.assertEqual(step[:3], ['0', '0', '0']); self.assertLess(float(step[3]), 1)   # rounded after every step of k: within the bound too
        self.assertGreater(int(stale[0]), 256 * 128 * 8 // 2); self.assertIn(': OVER BOUND (', stale[4])   # call 1 not loading A where the LDSM read it: most of result 0 over
        self.assertEqual(nan[:3], ['1', '1', '1']); self.assertTrue(nan[4].endswith(f': OVER BOUND (1 of {256 * 32 * ends * 4 * 8} outputs, NaN among them, 1 of 8 runs differ from the first)'))
        self.assertEqual(differ[:3], ['0', '0', '1']); self.assertTrue(differ[4].endswith(': RUNS DIFFER (1 of 8 runs differ from the first)'))
        self.assertGreater(int(slot0[0]), 256 * 128 * 8 // 2); self.assertIn(': OVER BOUND (', slot0[4])   # NXNative's body: most of result 0 over


def have_sdk(sdk):
    return bool(shutil.which('xcrun')) and subprocess.run(['xcrun', '-sdk', sdk, '--show-sdk-path'], capture_output=True).returncode == 0


@unittest.skipUnless(shutil.which('xcrun') and shutil.which('clang'), 'needs Xcode')
class HmmaOnGpu(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.tmp.name)
        (cls.dir / 'run.m').write_text(SELFTEST_RUNNER)
        subprocess.run(['clang', '-fobjc-arc', '-O1', f'-I{NVN}', str(cls.dir / 'run.m'), '-framework', 'Metal', '-framework', 'Foundation', '-o', str(cls.dir / 'run')], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_on_gpu(self, flags, built, *kernel):   # kernel: () for the chained calls, ('flags',) for the flagged ones
        lib, record = built
        r = subprocess.run([str(self.dir / 'run'), lib, *kernel], capture_output=True, text=True)
        if r.returncode == 2: self.skipTest(r.stdout.strip())
        print(f'\n{flags}: {r.stdout.strip()}\n  compiled by: {record}', flush=True)   # the numbers and the GPU they were measured on, not just pass or fail
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def work(self, name):
        d = self.dir / name; d.mkdir(exist_ok=True)
        return str(d)

    def test_macos_chain_flags(self):   # dmsh_build.py's mac_compile (MAC_METAL): the compile of every Mac game shader
        self.run_on_gpu('macOS chain', hmma_selftest.build('macosx', self.work('mac')))

    def test_ios_chain_flags_on_the_mac(self):   # ios_metal.compile with ios_metal.METAL's language, math and optimisation flags on the macosx SDK (its fallback language if 4.1 refuses)
        self.run_on_gpu('iOS chain on the macosx SDK', hmma_selftest.build_ios_on_mac(self.work('ios_on_mac')))

    def test_macos_chain_flagged_calls(self):   # the self-test's second kernel, in its own library: the calls with TensorPass's flags (hmma_selftest.CALLS)
        self.run_on_gpu('macOS chain, flagged calls', hmma_selftest.build('macosx', self.work('mac_flags'), 'hmma_selftest_flags'), 'flags')

    def test_ios_chain_flagged_calls_on_the_mac(self):
        self.run_on_gpu('iOS chain on the macosx SDK, flagged calls', hmma_selftest.build_ios_on_mac(self.work('ios_on_mac_flags'), 'hmma_selftest_flags'), 'flags')

    @unittest.skipUnless(have_sdk('iphoneos'), 'needs the iOS SDK')
    def test_ios_library_builds(self):   # the iphoneos libraries the iOS host embeds, which a Mac cannot run
        for name in hmma_selftest.LIBRARIES:
            lib, record = hmma_selftest.build('iphoneos', self.work('ios_' + name), name)
            self.assertGreater(os.path.getsize(lib), 0)
            print(f'\niOS chain, {name}: compiled by {record}', flush=True)

    def test_matches_reference(self):
        compile_and_run(self, hmma_msl(HEAD + HELPER + KERNEL), RUNNER)

    def test_flagged_run_matches_reference(self):
        compile_and_run(self, hmma_msl(HEAD + HELPER + SEQ_KERNEL), SEQ_RUNNER)

    def test_flagged_run_with_shared_memory_in_a_device_buffer(self):   # the same run after tg_spill: A loaded from device memory, the scratch there too
        out, n = spilled()
        compile_and_run(self, out, spill_runner(n), label='flagged run, shared memory in a device buffer')

    def test_flagged_run_matches_reference_with_the_ios_chain_flags(self):   # the same run compiled by ios_metal.compile with the iOS chain's flags on the macosx SDK
        def ios_on_mac(msl, d):
            lib, record = hmma_selftest.build_ios_on_mac(str(d), 'seq_kernel', msl)
            print(f'\nflagged run, iOS chain on the macosx SDK: compiled by {record}', flush=True)
            return lib
        compile_and_run(self, hmma_msl(HEAD + HELPER + SEQ_KERNEL), SEQ_RUNNER, build=ios_on_mac, label='flagged run, iOS chain on the macosx SDK')


def inst(hi, lo): return struct.pack('<QQ', lo, hi)
def waiting(i): return (i[0] | 0x3f << 52, i[1])   # waits on every scoreboard (control bits 116..121)


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class TranslatorFlags(unittest.TestCase):
    """R2 = thread x * 16 (local size 32: the lane), LDSM.16.M88.4 R36, [R2]: rows 16 bytes apart, matrix m at 128 m. HMMA R46 = R36..39 x R4 + 0, then HMMA R46 = R36..39 x R6 +
    R46, whose result is stored: the first gets C = 0, A from where the LDSM read it, D left in slot 0; the second A kept, C from slot 0, D to the registers.
    Encodings: Ocarina of Time's NDVE network (cs_movie.bin), with the registers changed"""
    S2R = (0x000e260000002100, 0x0000000000097919)    # S2R R9, SR_TID.X
    IMAD = (0x000fe200078e02ff, 0x0000001009027824)   # IMAD R2, R9, 16, RZ
    LDSM = (0x000e220000000200, 0x000000000224783b)   # LDSM.16.M88.4 R36, [R2]
    HMMA0 = (0x041ff000000008ff, 0x00000004242e723c)  # HMMA.16816.F16 R46, R36, R4, RZ
    HMMA1 = (0x000fe2000000082e, 0x00000006242e723c)  # HMMA.16816.F16 R46, R36, R6, R46
    STS = (0x000fe8000000c800, 0x0000082e09008388)    # STS.U32 [R9 * 16 + 8], R46
    STS1 = (0x000fe8000000c800, 0x00000c2f09008388)   # STS.U32 [R9 * 16 + 12], R47: D's two words, as a network stores them
    EXIT = (0x000fea0003800000, 0x000000000000794d)
    IMAD8 = (0x000fe200078e02ff, 0x0000001009087824)  # IMAD R8, R9, 16, RZ: a C that is no HMMA's D
    HMMAX = (0x000fe20000000808, 0x000000062432723c)  # HMMA.16816.F16 R50, R36, R6, R8: in no chain
    STSX = (0x000fe8000000c800, 0x0000003209008388)   # STS.U32 [R9 * 16], R50
    STSX1 = (0x000fe8000000c800, 0x0000043309008388)  # STS.U32 [R9 * 16 + 4], R51

    def flags(self, seq):   # the program through the translator and spirv-cross: each HMMA call's flags, in order
        code = b''.join(inst(*waiting(i)) for i in seq) + inst(*self.EXIT)
        with tempfile.TemporaryDirectory(prefix='tensor_') as d:
            work = Path(d); (work / 'k.bin').write_bytes(code)
            job = [dict(key='k', stage='cs', arch='sm86', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={}, local=[32, 1, 1], debug=True, nvn2_cs=[0, 0, 3, 0x40, 0], shared=0x1000)]
            (work / 'jobs.json').write_text(json.dumps(job))
            r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            sys.path.insert(0, str(TOOLS)); import dmsh_geometry
            dmsh_geometry.flatten_sets(work / 'k.spv')
            r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', '20300', str(work / 'k.spv')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        msl = r.stdout[r.stdout.index('kernel void main0'):]
        consts = dict(re.findall(r'int (_\d+) = (-?\d+);', msl))
        return [int(consts.get(a, a)) for a in (c.split(',')[10].strip() for c in re.findall(r'dmsh_hmma16816_f16\(([^()]*)\)', msl))]

    def test_a_call_outside_the_chain_between_its_calls(self):
        # HMMA R46 = A x R4 + 0, then HMMA R50 = A x R6 + R8 (its C no HMMA's D), then HMMA R46 = A x R6 + R46: the chain opens slot 0, the call between has no slot and keeps
        # A, the chain's end reads slot 0. That call's flags name no slot, so it works in the body's pair of its own (test_a_call_in_no_chain_works_in_a_pair_of_its_own);
        # in slot 0's matrices it would have overwritten the chain's sum
        got = self.flags([self.S2R, self.IMAD, self.IMAD8, self.LDSM, self.HMMA0, self.HMMAX, self.HMMA1, self.STS, self.STS1, self.STSX, self.STSX1])
        self.assertEqual(got, [8 | 4 | 16, 1 | 16, 1 | 2 | 16])   # slot 0 for the chain (flags >> 8 = 0); no CSlot or DSlot for the call between

    def test_chain_reuse_and_direct_a(self):
        code = b''.join(inst(*waiting(i)) for i in (self.S2R, self.IMAD, self.LDSM, self.HMMA0, self.HMMA1, self.STS, self.STS1)) + inst(*self.EXIT)
        with tempfile.TemporaryDirectory(prefix='tensor_') as d:
            work = Path(d); (work / 'k.bin').write_bytes(code)
            job = [dict(key='k', stage='cs', arch='sm86', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={}, local=[32, 1, 1], debug=True, nvn2_cs=[0, 0, 3, 0x40, 0], shared=0x1000)]
            (work / 'jobs.json').write_text(json.dumps(job))
            r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            sys.path.insert(0, str(TOOLS)); import dmsh_geometry
            dmsh_geometry.flatten_sets(work / 'k.spv')
            r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', '20300', str(work / 'k.spv')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        msl = r.stdout[r.stdout.index('kernel void main0'):]
        consts = dict(re.findall(r'int (_\d+) = (-?\d+);', msl))
        calls = [[a.strip() for a in c.split(',')] for c in re.findall(r'dmsh_hmma16816_f16\(([^()]*)\)', msl)]
        self.assertEqual(len(calls), 2)
        value = lambda a: int(consts.get(a, a))
        self.assertEqual([value(a) for a in calls[0][10:17] if a != calls[0][11]], [8 | 4 | 16, 0, 128, 256, 384, 16])   # C = 0, D to slot 0, A direct; offsets, stride
        self.assertEqual(value(calls[1][10]), 1 | 2 | 16)                                                               # A kept, C from slot 0
        copies = dict(re.findall(r'int (_\d+) = (_\d+);', msl))   # spirv-cross passes each argument through a copy of its own
        root = lambda a: root(copies[a]) if a in copies else a
        self.assertEqual(root(calls[0][11]), root(calls[1][11]))                                                        # the LDSM's row address
        self.assertRegex(msl, r'int %s = as_type<int>\(\w+\) \* 16;' % root(calls[0][11]))                              # R2


if __name__ == '__main__':
    unittest.main()
