#!/usr/bin/env python3
"""The kernel of the HMMA.16816 self-test (DM_SELFTEST=hmma, dm/gfx/nvn/selftest.m) and its compiles. The kernel is a compute shader around the translator's helper
dmsh_hmma16816_f16 as spirv-cross writes it, rewritten by dmsh_build.py's own hmma_msl (read from that file here, not copied), so the self-test runs the body games get.
host_msl.py compiles it when the host is built, with the game chain's own compile for the SDK: dmsh_build.py's mac_compile (MAC_METAL) for macosx, ios_metal.compile
(ios_metal.METAL, with its fallback language) for iphoneos, the code and flags every game shader of that platform is compiled with. dm/gfx/tests/test_dmsh_hmma.py runs the
same kernel on the Mac's GPU with both chains' flags (the iOS ones on the macosx SDK: build_ios_on_mac), and both runs compare with one reference, dm/gfx/nvn/hmma_check.h.
Not part of the chain version (dmsh_chain.py): it reads the chain's files and changes none of their outputs.
Usage: hmma_selftest.py --msl: print the kernel's Metal source"""
import ast, inspect, os, re, subprocess, sys
from pathlib import Path
from typing import Any
from unittest import mock

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS)); import dmsh_pch   # the compile both chains go through
sys.path.insert(0, str(TOOLS.parents[1] / 'ios/tools')); import ios_metal   # the iOS chain's compile convention
BUILD = TOOLS / 'dmsh_build.py'
NAMES = ('HMMA_BODY', 'hmma_msl', 'MAC_METAL', 'MAC_RECORD', 'mac_compile')   # what this takes from dmsh_build.py, whose import would start a build


def _chain() -> tuple[dict[str, Any], str]:
    tree = ast.parse(BUILD.read_text())
    picked: list[ast.stmt] = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in NAMES)
              or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in NAMES for t in n.targets))]
    found = {n.name if isinstance(n, ast.FunctionDef) else getattr(n.targets[0], 'id', '') for n in picked if isinstance(n, (ast.FunctionDef, ast.Assign))}
    if found != set(NAMES): raise RuntimeError(f'{BUILD} no longer defines {", ".join(sorted(set(NAMES) - found))} at its top level')
    module = ast.Module(body=picked, type_ignores=[])
    scope: dict[str, Any] = {'re': re, 'subprocess': subprocess, 'dmsh_pch': dmsh_pch}
    exec(compile(module, str(BUILD), 'exec'), scope)
    return scope, ast.dump(module)


CHAIN, CHAIN_FORM = _chain()
hmma_msl = CHAIN['hmma_msl']

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
# The helper as spirv-cross writes it (Donkey Kong Bananza's 7629d857a0a93833, cut down to its signature and a body of the same shape)
HELPER = '''
int dmsh_hmma16816_f16(thread const int& _42961, thread const int& _42962, thread const int& _42963, thread const int& _42964, thread const int& _42965, thread const int& _42966, thread const int& _42967, thread const int& _42968, thread const int& _42969, thread const int& _42970, thread int& _42971, threadgroup spvUnsafeArray<uint, 1024>& _34)
{
    uint _42974 = uint(int(uint(_42961) >> uint(2)));
    _34[_42962 + int(_42974)] = uint(_42963);
    if (_42974 > 3u)
    {
        _42971 = 0;
    }
    simdgroup_barrier(mem_flags::mem_threadgroup);
    _42971 = int(_34[_42962]);
    return int(_34[_42962 + 1]);
}
'''
# STEPS calls of the helper a lane in a row on the same 256 words of the scratch, each call's D the next one's C, as games make them one after another (144 a thread in the
# upscaler): each step's A0..A3, B0, B1 from `in`, step 0's C0, C1 after them, each step's D0, D1 to `out` (hmma_check.h's layout; it runs 64 threadgroups of 128 lanes, n lanes in all)
STEPS = 4   # hmma_check.h HMMA_CHECK_STEPS
STEP = '''    {
        device const uint *f = in + (%(k)d * n + gid) * 6;
        int a0 = int(f[0]), a1 = int(f[1]), a2 = int(f[2]), a3 = int(f[3]), b0 = int(f[4]), b1 = int(f[5]);
        int d1;
        int d0 = dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, d1, scr);
        out[(%(k)d * n + gid) * 2] = uint(d0); out[(%(k)d * n + gid) * 2 + 1] = uint(d1);
        c0 = d0; c1 = d1;
    }
'''
KERNEL = '''
kernel void check(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                  uint gid [[thread_position_in_grid]], uint n [[threads_per_grid]])
{
    threadgroup spvUnsafeArray<uint, 1024> scr;
    int l = int(lane), blk = int(sg * 256);
    int c0 = int(in[%(c)d * n + gid * 2]), c1 = int(in[%(c)d * n + gid * 2 + 1]);
%(steps)s}
''' % {'c': STEPS * 6, 'steps': ''.join(STEP % {'k': k} for k in range(STEPS))}


def msl():
    """The kernel's Metal source: the helper above with the body dmsh_build.py writes for every game"""
    return hmma_msl(HEAD + HELPER + KERNEL)


def ios_flags_on_mac():
    """ios_metal.METAL, its fallback and METALLIB on the macosx SDK, without the iOS deployment target: the iOS chain's language, math and optimisation flags where a Mac runs them"""
    def mac(cmd): return ['macosx' if a == 'iphoneos' else a for a in cmd if not a.startswith('-mios-version-min=')]
    return mac(ios_metal.METAL), mac(ios_metal.METAL_FALLBACK), mac(ios_metal.METALLIB)


def _compile(work, how, metallib):
    """how(src, air, lib) in folder work → (the metallib's path, the record: the compile command that made the AIR, then metallib, the metallib command). The precompiled header is left
    out: it takes about 2 s to make for one compile and changes no output (dmsh_pch.py checks that), so the command is the one each game shader's compile runs"""
    src, air, lib = (os.path.join(work, 'hmma_selftest' + x) for x in ('.metal', '.air', '.metallib'))
    with open(src, 'w') as f: f.write(msl())
    used, real = [], dmsh_pch.compile
    def compile_and_note(metal, source, out): real(metal, source, out); used.append(list(metal))   # which convention made it: a fallback language shows here
    with mock.patch.dict(os.environ, {'DMSH_PCH': '0'}), mock.patch.object(dmsh_pch, 'compile', compile_and_note): how(src, air, lib)
    return lib, ' '.join(used[-1] + ['-x', 'metal', '-']) + '; ' + metallib


def build(sdk, work):
    """The kernel compiled for sdk ('macosx' or 'iphoneos') as that platform's game shaders are, in folder work → (metallib path, record)"""
    if sdk == 'iphoneos': return _compile(work, ios_metal.compile, ' '.join(ios_metal.METALLIB))
    if sdk == 'macosx': return _compile(work, CHAIN['mac_compile'], CHAIN['MAC_RECORD'].split('; ', 1)[1])   # mac_compile's metallib command, as MAC_RECORD names it
    raise ValueError(f'no game shader compile for the SDK {sdk}')


def build_ios_on_mac(work):
    """The kernel compiled by ios_metal.compile itself with the iOS chain's flags on the macosx SDK (ios_flags_on_mac), for the Mac's GPU → (metallib path, record)"""
    metal, fallback, metallib = ios_flags_on_mac()
    with mock.patch.multiple(ios_metal, METAL=metal, METAL_FALLBACK=fallback, METALLIB=metallib): return _compile(work, ios_metal.compile, ' '.join(metallib))


def inputs(sdk):
    """What the kernel's library for sdk is made from, for host_msl.py's stamp: its source, and the compile's code and commands as the chain's files define them"""
    how = (ios_metal.METAL, ios_metal.METAL_FALLBACK, ios_metal.METALLIB, inspect.getsource(ios_metal.compile)) if sdk == 'iphoneos' else CHAIN_FORM
    return repr((sdk, msl(), how, inspect.getsource(_compile)))


if __name__ == '__main__':
    if sys.argv[1:] != ['--msl']: sys.exit('usage: hmma_selftest.py --msl')
    sys.stdout.write(msl())
