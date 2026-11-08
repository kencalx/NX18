#!/usr/bin/env python3
"""The kernels of the HMMA.16816 self-test (DM_SELFTEST=hmma, dm/gfx/nvn/selftest.m) and their compiles. Each kernel is a compute shader around the translator's helper
dmsh_hmma16816_f16 as spirv-cross writes it, rewritten by dmsh_build.py's own hmma_msl (read from that file here, not copied), so the self-test runs the body games get. Two
libraries, one a kernel (LIBRARIES):
  hmma_selftest        KERNEL: four calls a lane in a row on one scratch block with TensorPass's flags 0, each D the next call's C through the registers: every operand through
                       the block, the path of every call the translator gives no flag
  hmma_selftest_flags  FLAGS_KERNEL: eight calls with the flags TensorPass gives the calls of one block (CALLS): two accumulator chains open at once in slots 0 and 7, a call in
                       no chain while they are open, A kept from the call before, C = 0, and A loaded from shared memory where an LDSM read it, plain and transposed. A
                       library of its own: hmma_msl loads A from shared memory only when every function in the source that calls the helper declares the same one
                       threadgroup array besides the scratch, which KERNEL does not, so next to it this kernel would compile with A through the scratch everywhere
host_msl.py compiles them when the host is built, with the game chain's own compile for the SDK: dmsh_build.py's mac_compile (MAC_METAL + METAL_DEPTH) for macosx,
ios_metal.compile (ios_metal.METAL + DEPTH, with its fallback language) for iphoneos, the code and flags every game shader of that platform is compiled with.
dm/gfx/tests/test_dmsh_hmma.py runs the same kernels on the Mac's GPU with both chains' flags (the iOS ones on the macosx SDK: build_ios_on_mac), and both runs compare with one
reference, dm/gfx/nvn/hmma_check.h. Not part of the chain version (dmsh_chain.py): it reads the chain's files and changes none of their outputs.
Usage: hmma_selftest.py --msl [<library>]: print a kernel's Metal source (default hmma_selftest)"""
import ast, bisect, builtins, inspect, os, re, subprocess, symtable, sys
from pathlib import Path
from typing import Any
from unittest import mock

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS)); import dmsh_pch   # the compile both chains go through
sys.path.insert(0, str(TOOLS.parents[1] / 'ios/tools')); import ios_metal   # the iOS chain's compile convention
BUILD = TOOLS / 'dmsh_build.py'
# What this takes from dmsh_build.py, whose import would start a build: these definitions and every top-level definition they use, found from the file itself (symtable), so a
# helper hmma_msl or mac_compile starts to use comes along without a change here (split_params, block_end, HMMA_ARGS, HMMA_CALL and TG_ARRAY came with the flagged calls,
# METAL_DEPTH with the bracket depth)
ROOTS = ('hmma_msl', 'mac_compile', 'MAC_METAL', 'MAC_RECORD', 'HMMA_BODY')
SCOPE = {'re': re, 'bisect': bisect, 'subprocess': subprocess, 'dmsh_pch': dmsh_pch}   # the modules those definitions use


def _uses(text: str, node: ast.stmt) -> set[str]:
    """The module-level names a top-level statement of dmsh_build.py reads (its functions' globals, nested functions' included)"""
    top = symtable.symtable(ast.get_source_segment(text, node) or '', str(BUILD), 'exec')
    names, todo = set(), [top]
    while todo:
        t = todo.pop()
        names |= {s.get_name() for s in t.get_symbols() if s.is_referenced() and (t is top or s.is_global())}
        todo += t.get_children()
    return names


def _chain() -> tuple[dict[str, Any], str]:
    text = BUILD.read_text()
    tree = ast.parse(text)
    defs: dict[str, list[ast.stmt]] = {}   # each top-level name, with the statements that define it
    for n in tree.body:
        targets = [n.name] if isinstance(n, ast.FunctionDef) else [t.id for t in n.targets if isinstance(t, ast.Name)] if isinstance(n, ast.Assign) else []
        for name in targets: defs.setdefault(name, []).append(n)
    missing = [name for name in ROOTS if name not in defs]
    if missing: raise RuntimeError(f'{BUILD} no longer defines {", ".join(missing)} at its top level')
    taken: set[str] = set(); todo: list[str] = list(ROOTS); unknown: set[str] = set()
    while todo:
        name = todo.pop()
        if name in taken: continue
        if name not in defs:
            if name not in SCOPE and not hasattr(builtins, name): unknown.add(name)
            continue
        taken.add(name)
        for n in defs[name]: todo.extend(_uses(text, n))
    if unknown: raise RuntimeError(f'{BUILD}: what the HMMA body is made with uses {", ".join(sorted(unknown))}, which hmma_selftest.py does not give it')
    module = ast.Module(body=[n for n in tree.body if any(n in defs[name] for name in taken)], type_ignores=[])   # in the file's order
    scope: dict[str, Any] = dict(SCOPE)
    # dmsh_build.py finds the Mac's Metal tools once when it loads (MAC_RUN, MAC_LINK: the paths xcrun names, which save a lookup a compile). Here they are the xcrun commands
    # MAC_RECORD names, which run the same compiler: the self-test's record is the game chain's, and the definitions load where there is no xcrun (the Linux tests)
    run = {'MAC_RUN', 'MAC_LINK'}
    exec(compile(ast.Module(body=[n for n in module.body if not (isinstance(n, ast.Assign) and {getattr(t, 'id', None) for t in n.targets} & run)], type_ignores=[]),
                 str(BUILD), 'exec'), scope)
    if 'mac_compile' in scope:
        scope['MAC_RUN'] = list(scope['MAC_METAL']); scope['MAC_LINK'] = scope['MAC_RECORD'].split('; ', 1)[1].split()
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
# The helper as spirv-cross writes it, with the line before it that has the Metal compiler inline it (Ocarina of Time's e6be82d835fbe4d3, cut down to its signature and a body
# of the same shape; test_dmsh_hmma.py's HELPER): lane, block, A (4), B (2), C (2), flags, A's LDSM address, A's four offsets, A's row stride, out D1, the scratch
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
# STEPS calls of the helper a lane in a row on the same 256 words of the scratch, each call's D the next one's C, as games make the calls TensorPass gives no flag (flags 0
# and the six arguments that place A in shared memory 0, as the translator passes them): each step's A0..A3, B0, B1 from `in`, step 0's C0, C1 after them, each step's D0, D1
# to `out` (hmma_check.h's layout; it runs 64 threadgroups of 128 lanes, n lanes in all)
STEPS = 4   # hmma_check.h HMMA_CHECK_STEPS
STEP = '''    {
        device const uint *f = in + (%(k)d * n + gid) * 6;
        int a0 = int(f[0]), a1 = int(f[1]), a2 = int(f[2]), a3 = int(f[3]), b0 = int(f[4]), b1 = int(f[5]);
        int d1;
        int d0 = dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, z, z, z, z, z, z, z, d1, scr);
        out[(%(k)d * n + gid) * 2] = uint(d0); out[(%(k)d * n + gid) * 2 + 1] = uint(d1);
        c0 = d0; c1 = d1;
    }
'''
KERNEL = '''
kernel void check(device const uint *in [[buffer(0)]], device uint *out [[buffer(1)]], uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                  uint gid [[thread_position_in_grid]], uint n [[threads_per_grid]])
{
    threadgroup spvUnsafeArray<uint, 1024> scr;
    int l = int(lane), blk = int(sg * 256), z = 0;
    int c0 = int(in[%(c)d * n + gid * 2]), c1 = int(in[%(c)d * n + gid * 2 + 1]);
%(steps)s}
''' % {'c': STEPS * 6, 'steps': ''.join(STEP % {'k': k} for k in range(STEPS))}

# TensorPass's flags (TensorPass.cs Flag*), and a call's accumulator slot at flags >> 8 when it has CSlot or DSlot
A_REUSE, C_SLOT, D_SLOT, C_ZERO, A_DIRECT, A_TRANS = 1, 2, 4, 8, 16, 32
# The flagged run: eight calls a SIMD-group in one block, with the flags TensorPass gives such calls. Each: (its A, its B, the result it adds to, its flags, its slot, the A whose
# registers it is given). A0's tile lies in shared memory row-major, 48 bytes a row, read as an LDSM.x4's matrices (rows 0 and 8, columns 0 and 8: offsets 0, 384, 16, 400 from
# lane 0's row); A1's lies there transposed, 32 bytes a row, as an LDSM.MT88.x4 reads it (offsets 0, 16, 256, 272). Results 0 and 1 are accumulator chains of three calls, open
# at the same time in slots 0 and 7 (slot 0 the first chain of a block takes; slot 7 the last, which TensorPass gives the eighth chain open at once; a call in no chain works in
# matrices of its own); result 0 starts from the tile's C, result 1 from C = 0. Result 3 is one call in no chain while both are open, C from the registers (as TensorPass flags an HMMA
# outside a chain between two calls of one), which the body before NXNative's 13b432b4 made in slot 0's matrices, over result 0's running sum. Result 2 is one call with C = 0 and D to the registers,
# after both chains end. hmma_check.h hmma_flags_calls holds (A, B, result) of each, and hmma_flags_from_c the results that start from the tile's C (FROM_C): its reference.
CALLS = (
    (0, 0, 0, A_DIRECT | D_SLOT, 0, 1),                      # A where the LDSM read it; C from the registers; D left in slot 0
    (0, 1, 1, A_REUSE | A_DIRECT | C_ZERO | D_SLOT, 7, 1),   # A kept (TensorPass sets both when one LDSM's matrices feed both calls; kept wins); C = 0; D left in slot 7
    (0, 2, 0, A_REUSE | C_SLOT | D_SLOT, 0, 1),              # a chain's middle call: A kept, C from slot 0, D left there
    (0, 7, 3, A_REUSE, 0, 1),                                # no chain, both open: A kept; C from the registers; D to them: result 3, in matrices of its own
    (1, 3, 1, C_SLOT | D_SLOT, 7, 1),                        # A through the scratch, from its registers; slot 7's middle call
    (1, 4, 0, A_REUSE | C_SLOT, 0, 0),                       # A kept from the scratch's; slot 0's chain ends: result 0 to the registers
    (1, 5, 1, A_DIRECT | A_TRANS | C_SLOT, 7, 0),            # A where the LDSM.MT88 read it, transposed; slot 7's chain ends: result 1
    (1, 6, 2, A_REUSE | C_ZERO, 0, 0),                       # A kept from the transposed load; C = 0; D to the registers: result 2
)
FIRST = {res: flags for _, _, res, flags, _, _ in reversed(CALLS)}   # each result's first call's flags
FROM_C = tuple(res for res in sorted(FIRST) if not FIRST[res] & (C_SLOT | C_ZERO))   # the results whose first call takes the tile's C: 0 and 3
TILE = 1664   # halves a tile in `in`: A0, A1 (16 x 16, row-major), B0..B7 (16 x 8, row k), C (16 x 8, row-major) (hmma_check.h HMMA_FLAGS_TILE)


def _flags_kernel() -> str:
    """FLAGS_KERNEL's source from CALLS. Each call gets the registers the translator's body would read only where its flags say they are read: B, C where it comes from the
    registers, A where it goes through the scratch. Elsewhere it gets another matrix's: A1's or A0's registers where A is kept or loaded from shared memory, and as C the
    registers of its chain's call before, which that call left 0 (its D stayed in the slot), so a flag the body did not follow gives a wrong result"""
    calls, flag_values, prev = [], [], {}   # prev: the result → the call that last added to it
    for i, (a, b, res, flags, slot, regs) in enumerate(CALLS, 1):
        f = flags | (slot << 8 if flags & (C_SLOT | D_SLOT) else 0)
        c = f'd{prev[res]}, e{prev[res]}' if flags & C_SLOT else 'z, z' if flags & C_ZERO else 'c0, c1'
        if flags & A_DIRECT:
            assert a == (1 if flags & A_TRANS else 0), 'A0 lies in shared memory row-major, A1 transposed'
            place = 'addr1, p0, p1, p2, p3, s1' if flags & A_TRANS else 'addr0, o0, o1, o2, o3, s0'
        else: place = 'z, z, z, z, z, z'
        calls.append(f'    int d{i} = dmsh_hmma16816_f16(l, blk, a{regs}0, a{regs}1, a{regs}2, a{regs}3, b{b}0, b{b}1, {c}, f{i}, {place}, e{i}, scr);\n')
        flag_values.append(f'f{i} = {f}')
        prev[res] = i
    ends = sorted(prev.items())
    store = ''.join(f'    out[gid * {2 * len(ends)} + {2 * r}] = uint(d{i}); out[gid * {2 * len(ends)} + {2 * r + 1}] = uint(e{i});\n' for r, i in ends)
    nb = 1 + max(c[1] for c in CALLS)
    return '''
static uint pk(device const ushort* p, int i, int j) { return uint(p[i]) | uint(p[j]) << 16; }
kernel void check_flags(device const ushort *in [[buffer(0)]], device uint *out [[buffer(1)]], uint lane [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]],
                        uint gid [[thread_position_in_grid]])
{
    threadgroup spvUnsafeArray<uint, 1280> shm;
    threadgroup spvUnsafeArray<uint, 1024> scr;
    device const ushort *x = in + (gid / 32) * %(tile)d;
    device const ushort *A0 = x, *A1 = x + 256, *B = x + 512, *C = x + %(c)d;
    threadgroup ushort* sh = (threadgroup ushort*)&shm[0];
    int base0 = int(sg) * 1280, base1 = base0 + 768;   // bytes: A0 in 16 rows of 48, then A1 transposed in 16 rows of 32
    for (int i = int(lane); i < 256; i += 32) { int r = i / 16, c = i %% 16; sh[base0 / 2 + r * 24 + c] = A0[i]; sh[base1 / 2 + c * 16 + r] = A1[i]; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int l = int(lane), g = l / 4, t = l %% 4, blk = int(sg) * 256, z = 0;
%(a)s%(b)s    int c0 = int(pk(C, g * 8 + 2 * t, g * 8 + 2 * t + 1)), c1 = int(pk(C, (g + 8) * 8 + 2 * t, (g + 8) * 8 + 2 * t + 1));
    int addr0 = base0 + ((l & 7) + 8 * ((l >> 3) & 1)) * 48 + 16 * (l >> 4), addr1 = base1 + (l & 7) * 32 + ((l >> 3) & 1) * 16 + (l >> 4) * 256;   // each lane's LDSM row
    int o0 = 0, o1 = 384, o2 = 16, o3 = 400, s0 = 48, p0 = 0, p1 = 16, p2 = 256, p3 = 272, s1 = 32;
    int %(f)s;   // the flags, constants as the translator writes them
    int %(e)s;
%(calls)s%(store)s}
''' % {'tile': TILE, 'c': 512 + 128 * nb, 'calls': ''.join(calls), 'store': store, 'e': ', '.join(f'e{i}' for i in range(1, len(CALLS) + 1)), 'f': ', '.join(flag_values),
       'a': ''.join(f'    int a{m}0 = int(pk(A{m}, g * 16 + 2 * t, g * 16 + 2 * t + 1)), a{m}1 = int(pk(A{m}, (g + 8) * 16 + 2 * t, (g + 8) * 16 + 2 * t + 1));\n'
                    f'    int a{m}2 = int(pk(A{m}, g * 16 + 8 + 2 * t, g * 16 + 9 + 2 * t)), a{m}3 = int(pk(A{m}, (g + 8) * 16 + 8 + 2 * t, (g + 8) * 16 + 9 + 2 * t));\n' for m in (0, 1)),
       'b': ''.join(f'    int b{k}0 = int(pk({B}, (2 * t) * 8 + g, (2 * t + 1) * 8 + g)), b{k}1 = int(pk({B}, (2 * t + 8) * 8 + g, (2 * t + 9) * 8 + g));\n'
                    for k, B in ((k, f'B + {128 * k}' if k else 'B') for k in range(nb)))}


FLAGS_KERNEL = _flags_kernel()
LIBRARIES = {'hmma_selftest': KERNEL, 'hmma_selftest_flags': FLAGS_KERNEL}   # host_msl.py's chain libraries (selftest.m's names), each one kernel: check, check_flags


def msl(name='hmma_selftest'):
    """A kernel's Metal source: the helper above with the body dmsh_build.py writes for every game"""
    return hmma_msl(HEAD + HELPER + LIBRARIES[name])


def ios_flags_on_mac():
    """ios_metal.METAL, its fallback and METALLIB on the macosx SDK, without the iOS deployment target: the iOS chain's language, math and optimisation flags where a Mac runs them"""
    def mac(cmd): return ['macosx' if a == 'iphoneos' else a for a in cmd if not a.startswith('-mios-version-min=')]
    return mac(ios_metal.METAL), mac(ios_metal.METAL_FALLBACK), mac(ios_metal.METALLIB)


def _compile(work, how, metallib, name, source=None):
    """how(src, air, lib) in folder work on library name's kernel (or source) → (the metallib's path, the record: the compile command that made the AIR, then metallib, the
    metallib command). The precompiled header is left out: it takes about 2 s to make for one compile and changes no output (dmsh_pch.py checks that), so the command is the
    one each game shader's compile runs"""
    src, air, lib = (os.path.join(work, name + x) for x in ('.metal', '.air', '.metallib'))
    with open(src, 'w') as f: f.write(msl(name) if source is None else source)
    used, real = [], dmsh_pch.compile
    def compile_and_note(metal, source, out): real(metal, source, out); used.append(list(metal))   # which convention made it: a fallback language shows here
    with mock.patch.dict(os.environ, {'DMSH_PCH': '0'}), mock.patch.object(dmsh_pch, 'compile', compile_and_note): how(src, air, lib)
    return lib, ' '.join(used[-1] + ['-x', 'metal', '-']) + '; ' + metallib


def build(sdk, work, name='hmma_selftest'):
    """Library name's kernel compiled for sdk ('macosx' or 'iphoneos') as that platform's game shaders are, in folder work → (metallib path, record)"""
    if name not in LIBRARIES: raise ValueError(f'no self-test kernel {name}')
    if sdk == 'iphoneos': return _compile(work, ios_metal.compile, ' '.join(ios_metal.METALLIB), name)
    if sdk == 'macosx': return _compile(work, CHAIN['mac_compile'], CHAIN['MAC_RECORD'].split('; ', 1)[1], name)   # mac_compile's metallib command, as MAC_RECORD names it
    raise ValueError(f'no game shader compile for the SDK {sdk}')


def build_ios_on_mac(work, name='hmma_selftest', source=None):
    """Library name's kernel (or another Metal source) compiled by ios_metal.compile itself with the iOS chain's flags on the macosx SDK (ios_flags_on_mac), for the Mac's GPU
    → (metallib path, record)"""
    metal, fallback, metallib = ios_flags_on_mac()
    with mock.patch.multiple(ios_metal, METAL=metal, METAL_FALLBACK=fallback, METALLIB=metallib): return _compile(work, ios_metal.compile, ' '.join(metallib), name, source)


def inputs(sdk):
    """What the kernels' libraries for sdk are made from, for host_msl.py's stamp: their sources, and the compile's code and commands as the chain's files define them"""
    how = (ios_metal.METAL, ios_metal.METAL_FALLBACK, ios_metal.METALLIB, ios_metal.DEPTH, inspect.getsource(ios_metal.compile)) if sdk == 'iphoneos' else CHAIN_FORM
    return repr((sdk, {name: msl(name) for name in LIBRARIES}, how, inspect.getsource(_compile)))


if __name__ == '__main__':
    args = sys.argv[1:]
    if not args or args[0] != '--msl' or len(args) > 2 or (len(args) == 2 and args[1] not in LIBRARIES):
        sys.exit(f'usage: hmma_selftest.py --msl [{"|".join(LIBRARIES)}]')
    sys.stdout.write(msl(*args[1:]))
