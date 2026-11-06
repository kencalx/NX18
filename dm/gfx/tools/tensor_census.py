#!/usr/bin/env python3
"""The HMMA census: what the LDSM, MOVM and HMMA of a translated Switch 2 compute shader are made of, read from the Metal source the shader build wrote for it, <key>_b.metal (the chain's
default XLATE_DEBUG=1 leaves one temporary per operation, which is what this reads). It tells, from a game's real shaders, which of upstream's paths for the HMMA helper each call
takes already (TensorPass's flags, upstream's bd9f422d: docs/reference/shaders.md, HMMA chains keep their matrices in the SIMD-group) and where the planned stages of removing
what is left of the subgroup shuffles and scratch round trips around HMMA would apply (shaders.md, Ampere HMMA through simdgroup_matrix, Open; how to run it on a game:
docs/development.md, HMMA census):
  upstream  each call's flags, read as the translator passes them (constants): A kept from the call before (FlagAReuse), loaded where its LDSM read it (FlagADirect, FlagATrans;
            only where hmma_msl passed the caller's one shared memory array) or through the scratch; C from an accumulator slot (FlagCSlot), zero (FlagCZero) or through the
            scratch; D left in its slot (FlagDSlot) or back through the scratch; B through the scratch always. An LDSM whose words go only to A of calls that load A themselves
            keeps its per-lane code in the Metal text, which the Metal compiler drops (the helper is inlined, its flags constants): counted apart, not as work left. A call in
            no chain (neither CSlot nor DSlot) that comes while a chain is open in slot 0 is counted: this checkout's body works it in a pair of its own; a library whose
            functions declare dm_acc[16] has NXNative's body, which works it in slot 0's matrices over that chain's sum ([RED], and not counted as served). A library's call of
            the translator's 19 arguments (hmma_msl did not rewrite its helper) runs the translator's own body, which reads no flag: [RED], and left out of these paths
  stage 1   an LDSM still read lane by lane whose row address each lane could compute instead of shuffling it: a function of the lane (SubgroupInvocationID, or
            LocalInvocationID.x with a local size x that is a multiple of 32) and of warp-uniform values (constants, the workgroup ID, LocalInvocationID.y / z, constant-buffer
            reads) only
  stage 2   MOVM folded into the HMMA's B: both B words of an HMMA come from MOVM
  stage 3   what upstream's paths do not cover, in calls with flags: A through the scratch although it is one LDSM's matrices (behind a shared store, an atomic on shared
            memory, a barrier or a call; its LDSM in another block; or nothing the census sees in between: rows the translator did not prove strided, or a block boundary the
            Metal text does not show), accumulators through the scratch (C an earlier HMMA's D carried by a phi, from another block, read elsewhere too, or from a chain that
            started with all 8 slots taken), and B words from LDSMs that could be tiles, which upstream left in the scratch on purpose (B as matrices slowed an NDVE shader by
            13 %; not measured for NDSR)
  tiles     an LDSM whose rows a tile load could read: a stage-1 address whose 8 rows are one constant pitch apart (16 to 65535 bytes, a multiple of 16) in every matrix of every
            warp, nothing between the LDSM's loads and each HMMA it feeds that writes or orders memory, calls a function other than the HMMA helper, or leaves the block, and no
            other use of the words it loads (else the LDSM and its shuffles stay)
A library built before the flags (12-argument calls; its chain says which form to expect) takes every operand through the scratch: the census reads its LDSMs, MOVMs and calls as
before, and says that upstream's paths and stage 3 are not known for it until it is built again.
Read only: it writes nothing but its reports, decides no build output and is not part of the translation chain (not in dmsh_chain.FILES, not imported by dmsh_build.py).

Per shader it reports every spvSubgroupShuffle, classified by the lane each lane reads from (evaluated) and where its value goes: an LDSM row address (InstEmitAmpereTensor.cs's
lanes, its value only reaching an index into the game's shared memory), MOVM, the per-lane HMMA gathers (m16n8k8, an F32 accumulator; their value used as data), REDUX / MATCH (one
lane at a time), or other (the game's own SHFL, anything else). Per LDSM: the leaves of its address (lane, tid.x, tid.y, tid.z, const, workgroup, cbuf, sbuf, buffer, shared, phi,
shuffle, call, texture, float, param, 'buffer index varies' / 'buffer index: <leaf>' for a buffer word read at an index that is not warp-uniform or not a constant-buffer one ...),
plain or transposed, its matrices and the row pitch: the address evaluated in 32-bit C arithmetic for every lane of every warp of a workgroup, with four random sets of uniform
values (buffer words of 32 or 16 random bits, not aligned: an OR or XOR with one is linear only where their bits cannot overlap; the workgroup ID). The pitch is a number when it is
the same in every matrix, warp and sample; else 'varies' (rows not a constant pitch apart: a swizzle, an OR whose bits overlap), 'uniform' (changes with the uniform values),
'per warp' or 'per matrix'; 0 for a warp-uniform address. Row alignment is reported apart: 16 when the arithmetic alone makes every row 16-byte aligned. For an address whose only
blocker is a phi whose values hold nothing that varies, also the pitch the rows would have if the phi were warp-uniform. Per dmsh_hmma16816_f16 call (12 arguments before the
flags, 19 as the translator writes them, 21 or 22 after hmma_msl; any other form is counted and said, never read): where A, B and C come from (ldsm, ldsm.T, movm(x), Dk.j: D of
the k-th HMMA, zero, phi(...), lds: a plain shared-memory read, other), what uses D, whether it is in a loop, its flags and the path each operand takes, and why A or an
accumulator goes through the scratch. Counts of barriers, shared stores and atomics, and the verdict lines. A report holds counts and structure, no source text: variable names
(_123) and line numbers at most.

Usage:
  tensor_census.py <shader.metal> [--local X,Y,Z] [--json]   one shader: the summary, or with --json the whole report. The local size comes from <key>_b.json beside the source when
                                                              there is one; without either, local size x is taken to be a multiple of 32 (the summary says so)
  tensor_census.py --library <lib> [--out DIR] [--metal]      every shader of a built library whose Metal source defines dmsh_hmma16816_f16, found by searching the library (not from a
                                                              profile's tables), and every other one whose shuffles include LDSM, MOVM or the per-lane HMMA (the helper takes only
                                                              HMMA.16816 with an f16 accumulator): DIR/<key>.census for each (its report, JSON, with its summary), DIR/summary.census
                                                              (all of them, JSON) and DIR/summary.txt; --metal also writes each source, DIR/<key>.metal, to read by hand (game-derived:
                                                              not to be sent)
  <lib>: a shader library (b-<chain>, its folder or its .img, which dm/tools/shader_lib.py reads in place) or a folder that holds one: <NSP folder>/<id>_build, its shader/ or
  shader/cache/ (shader/partial/ after a --seen-shaders build). Of all those there, this checkout's chain's (dm/gfx/nvn/dmsh_chain.h), else the newest. DIR defaults to
  tensor_census-<chain> beside the library, and is never inside this repository. Exit status 1 when the library has no such shader."""
from __future__ import annotations

import argparse
import bisect
import collections
import functools
import json
import math
import os
import random
import re
import struct
import sys
from pathlib import Path
from typing import Any, Callable, Iterator

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import shader_lib  # noqa: E402   (the library reader: a folder or the one-file image)

FORMAT = 3   # of the .census files
HMMA_NAME = 'dmsh_hmma16816_f16'
# The helper's calls, by their number of arguments: where D1 (the out argument), the scratch and TensorPass's flags are. lane, block, A (4), B (2), C (2) come first in every form
CALL_FORMS = {
    12: dict(d1=10, scratch=11, flags=None, direct=None),   # before TensorPass's flags (upstream's bd9f422d): then out D1, the scratch
    19: dict(d1=17, scratch=18, flags=10, direct=None),     # the translator's: flags, A's LDSM row address, A's four offsets, A's row stride, out D1, the scratch
    21: dict(d1=17, scratch=18, flags=10, direct=False),    # as dmsh_build.py hmma_msl rewrites them: the caller's matrices (dm_acc, dm_am) added
    22: dict(d1=17, scratch=18, flags=10, direct=True),     # and the caller's shared memory array, which turns direct A on
}
FLAG_A_REUSE, FLAG_C_SLOT, FLAG_D_SLOT, FLAG_C_ZERO, FLAG_A_DIRECT, FLAG_A_TRANS = 1, 2, 4, 8, 16, 32   # TensorPass.cs Flag*; the accumulator slot is flags >> 8
SLOTS = 8   # TensorPass.cs Slots: accumulator slots a function; a chain that starts with all of them taken goes through the scratch
SHARED_PAIR = 16   # the size of hmma_msl's dm_acc whose body makes a call in no chain in slot 0's matrices (NXNative's); this checkout's has a pair of its own past the slots (18)
B_NOTE = "upstream left B in the scratch on purpose: in Ocarina of Time's NDVE networks, B kept as matrices slowed one shader by 13 %; not measured for NDSR"
M32 = 0xffffffff
SAMPLES = 4   # random sets of uniform values: buffer words of 32 random bits in the first two, of 16 (an offset in shared memory) in the others; never aligned
UNKNOWN_LOCAL = [128, 2, 2]   # the local size when none is known: x a multiple of 32, and warps that differ in tid.x >> 5, tid.y and tid.z
WARP_FREE = frozenset({'lane', 'const', 'workgroup', 'cbuf', 'sbuf', 'buffer', 'float'})   # leaves whose values are the same in every warp of a sample: one warp tells
Node = tuple[Any, ...]   # ('num', text) ('name', id) ('tmpl', id, type) ('call', callee, [args]) ('index', base, i) ('member', base, field) ('un', op, x) ('bin', op, a, b) ('tern', c, a, b)
Value = tuple[str, int]   # (kind, 32-bit value): 'i' int, 'u' uint, 'b' bool, 'f' float (its bits)


class Unreadable(ValueError):
    """Text the expression reader does not take"""


class Refused(ValueError):
    """An expression the evaluator does not take; the message is a reason, never source text"""


# ---- C expressions as spirv-cross writes them -------------------------------------------------------------------------------------------------------------------------------
TOKEN = re.compile(r'\s*(?:(?P<num>0[xX][0-9a-fA-F]+[uUlL]*|(?:\d+\.\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)[fFhH]?|\d+[uUlL]*)'
                   r'|(?P<id>[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)|(?P<op><<=|>>=|<<|>>|<=|>=|==|!=|&&|\|\||->|[-+*/%&|^]=|[-+*/%&|^~!<>?:()\[\],.=]))')
BINARY = {'||': 1, '&&': 2, '|': 3, '^': 4, '&': 5, '==': 6, '!=': 6, '<': 7, '>': 7, '<=': 7, '>=': 7, '<<': 8, '>>': 8, '+': 9, '-': 9, '*': 10, '/': 10, '%': 10}
COMPARE = {'==', '!=', '<', '>', '<=', '>='}
TEMPLATED = {'as_type', 'static_cast', 'reinterpret_cast', 'spvUnsafeArray', 'vec', 'array'}
ASSIGN_OPS = {'=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>='}


def tokenize(text: str) -> list[str]:
    out, i = [], 0
    while i < len(text):
        m = TOKEN.match(text, i)
        if not m or m.end() == i:
            if not text[i:].strip(): break
            raise Unreadable('token')
        out.append(m.group(m.lastgroup or 'op')); i = m.end()
    return out


class Parser:
    def __init__(self, tokens: list[str]): self.t, self.i = tokens, 0

    def peek(self) -> str | None: return self.t[self.i] if self.i < len(self.t) else None

    def take(self, want: str | None = None) -> str:
        t = self.peek()
        if t is None or (want is not None and t != want): raise Unreadable('syntax')
        self.i += 1
        return t

    def whole(self) -> Node:
        e = self.expr(0)
        if self.peek() is not None: raise Unreadable('syntax')
        return e

    def expr(self, least: int) -> Node:
        left = self.unary()
        while True:
            t = self.peek()
            if t == '?' and least == 0:
                self.take(); a = self.expr(0); self.take(':'); b = self.expr(0)
                left = ('tern', left, a, b); continue
            p = BINARY.get(t or '')
            if t is None or p is None or p < least: return left
            self.take()
            left = ('bin', t, left, self.expr(p + 1))

    def unary(self) -> Node:
        t = self.peek()
        if t in ('-', '+', '~', '!', '*', '&'): self.take(); return ('un', t, self.unary())
        if t == '(':
            self.take(); e = self.expr(0); self.take(')')
            return self.postfix(e)
        t = self.take()
        if t[0].isdigit() or t[0] == '.': return self.postfix(('num', t))
        if not (t[0].isalpha() or t[0] == '_'): raise Unreadable('syntax')
        if (t in TEMPLATED or t.startswith('spv')) and self.peek() == '<':
            self.take(); depth, parts = 1, []
            while depth > 0:
                x = self.take()
                depth += {'<': 1, '>': -1, '>>': -2}.get(x, 0)
                if depth > 0: parts.append(x)
            return self.postfix(('tmpl', t, ' '.join(parts)))
        return self.postfix(('name', t))

    def postfix(self, node: Node) -> Node:
        while True:
            t = self.peek()
            if t == '(':
                self.take(); args = []
                if self.peek() != ')':
                    args.append(self.expr(0))
                    while self.peek() == ',': self.take(); args.append(self.expr(0))
                self.take(')'); node = ('call', node, args)
            elif t == '[':
                self.take(); idx = self.expr(0); self.take(']'); node = ('index', node, idx)
            elif t in ('.', '->'):
                self.take(); node = ('member', node, self.take())
            else: return node


def parse(text: str) -> Node: return Parser(tokenize(text)).whole()


def callee_name(node: Node) -> str:
    """The name a call is known by: 'extract_bits', 'as_type<int>', '.read' (a member function)"""
    c = node[1]
    if c[0] == 'name': return c[1]
    if c[0] == 'tmpl': return f'{c[1]}<{c[2]}>'
    if c[0] == 'member': return '.' + c[2]
    return '?'


CASTS = {'int', 'uint', 'float', 'bool', 'short', 'ushort', 'char', 'uchar', 'long', 'ulong', 'as_type<int>', 'as_type<uint>', 'as_type<float>'}
INT_CALLS = {'extract_bits', 'insert_bits', 'min', 'max', 'clamp', 'abs', 'select', 'popcount', 'clz', 'ctz', 'reverse_bits', 'mulhi', 'absdiff'}
SHUFFLES = re.compile(r'^(?:spvSubgroup\w*|simd_\w+|quad_\w+)$')
PURE = re.compile(r'^(?:(?:packed_)?(?:u?int|float|half|bool|u?short|u?char)[234]?(?:x[234])?|as_type<.*>|fma|fast::\w+|precise::\w+|metal::\w+|sqrt|rsqrt|floor|ceil|fract|trunc|round|rint|'
                  r'exp2?|log2?|pow|powr|sin|cos|tan|mix|step|smoothstep|sign|dot|length|normalize|isnan|isinf|fmin|fmax|saturate|any|all|copysign|spvF[A-Z]\w*|spvFind[SU]?[LM]SB|spvUnsafeArray<.*>|'
                  r'level|bias|gradient2d|gradient3d|gradientcube|min_lod_clamp)$')
FLOAT_CALLS = re.compile(r'^(?:(?:packed_)?(?:float|half)[234]?(?:x[234])?|fma|fast::\w+|precise::\w+|sqrt|rsqrt|floor|ceil|fract|trunc|round|rint|exp2?|log2?|pow|powr|sin|cos|tan|'
                         r'mix|step|smoothstep|sign|dot|length|normalize|fmin|fmax|saturate|copysign|spvF(?:Add|Sub|Mul|Div|Fma)\w*)$')
SCALAR_KIND = {'int': 'i', 'short': 'i', 'char': 'i', 'long': 'i', 'uint': 'u', 'ushort': 'u', 'uchar': 'u', 'ulong': 'u', 'bool': 'b', 'float': 'f', 'half': 'f'}
BUILTINS = {'gl_SubgroupInvocationID': 'lane', 'gl_LocalInvocationIndex': 'tid.index', 'gl_SubgroupSize': 'const'}
BUILTIN_VECTORS = {'gl_LocalInvocationID': 'tid.', 'gl_WorkGroupID': 'workgroup', 'gl_NumWorkGroups': 'workgroup', 'gl_GlobalInvocationID': 'gid', 'gl_WorkGroupSize': 'const'}
CONSTANT_NAME = re.compile(r'^(?:true|false|memory_order_\w+|\w+::\w+)$')   # names that are no value of the shader's: enumerators (mem_flags::..., component::x), true, false
INT_CONVERSIONS = {'int', 'uint', 'short', 'ushort', 'char', 'uchar', 'long', 'ulong', 'bool'}
STRUCT = re.compile(r'\bstruct\s+(\w+)\s*\{([^{}]*)\}\s*;')
FIELD = re.compile(r'([A-Za-z_][\w:<>, ]*?)\s*[*&]?\s*\b(\w+)\s*((?:\[\s*\d*\s*\])*)\s*(?:\[\[[^\]]*\]\])?\s*;')
BUFFER_PARAM = re.compile(r'([A-Za-z_][\w:<> ]*?)\s*[*&]\s*(\w+)\s*\[\[buffer\(')
QUALIFIERS = re.compile(r'\b(?:const|constant|device|threadgroup|thread|volatile)\s+')
VECTOR = re.compile(r'(?:packed_)?(float|half|u?int|u?short|u?char|bool)[234]')


def strip_casts(node: Node) -> Node:
    """The operand of a chain of conversions and bit casts (int(x), uint(x), as_type<float>(x)): what a copy copies"""
    while node[0] == 'call' and len(node[2]) == 1 and callee_name(node) in CASTS: node = node[2][0]
    return node


def children(n: Node) -> list[Node]:
    k = n[0]
    if k == 'call': return [n[1], *n[2]]
    if k == 'index': return [n[1], n[2]]
    if k == 'member': return [n[1]]
    if k == 'un': return [n[2]]
    if k == 'bin': return [n[2], n[3]]
    if k == 'tern': return [n[1], n[2], n[3]]
    return []


def is_access(n: Node) -> bool: return n[0] in ('index', 'member') or (n[0] == 'un' and n[1] == '*')   # a[i], a.f, a->f, *a


def base_of(n: Node) -> Node: return n[2] if n[0] == 'un' else n[1]   # what an access reads from


@functools.lru_cache(maxsize=None)
def kind_of_type(t: str) -> str:
    """'i' / 'u' / 'b' / 'f' of a scalar type, 'v' of a vector, an array or anything else"""
    return SCALAR_KIND.get(t.replace('const ', '').strip(), 'v')


def wrap(kind: str, x: int) -> int:
    if kind == 'i':
        x &= M32
        return x - (1 << 32) if x & 0x80000000 else x
    if kind == 'b': return 1 if x else 0
    return x & M32


@functools.lru_cache(maxsize=None)
def num_kind(text: str) -> str:
    t = text.lower()
    if t.startswith('0x') or re.fullmatch(r'\d+[ul]*', t): return 'u' if 'u' in t else 'i'
    return 'f'


@functools.lru_cache(maxsize=None)
def num_value(text: str) -> Value:
    t = text.lower()
    k = num_kind(t)
    if k != 'f': return (k, wrap(k, int(t.rstrip('ul'), 0)))
    try: bits = struct.unpack('<I', struct.pack('<f', float(t.rstrip('fh'))))[0]
    except (OverflowError, ValueError) as e: raise Refused('float constant') from e
    return ('f', bits)


def as_float(bits: int) -> float: return struct.unpack('<f', struct.pack('<I', bits & M32))[0]


def convert(name: str, v: Value) -> Value:
    """int(x), uint(x), short(x) ..., as_type<T>(x): C's conversions of a 32-bit value (a float's value, or for as_type its bits)"""
    k, x = v
    if name.startswith('as_type<'):
        t = name[8:-1].strip()
        if t not in ('int', 'uint', 'float') or k == 'b': raise Refused('vector bit cast')
        nk = SCALAR_KIND[t]
        return (nk, wrap(nk, x))
    if name == 'float':
        return v if k == 'f' else ('f', struct.unpack('<I', struct.pack('<f', float(x)))[0])
    if k == 'f':
        f = as_float(x)
        if not math.isfinite(f): raise Refused('float conversion')
        x = int(f)
    if name in ('int', 'long'): return ('i', wrap('i', x))
    if name in ('uint', 'ulong'): return ('u', wrap('u', x))
    if name == 'bool': return ('b', 1 if x else 0)
    if name in ('short', 'ushort', 'char', 'uchar'):
        n = 16 if 'short' in name else 8
        x &= (1 << n) - 1
        if not name.startswith('u') and x >> (n - 1): x -= 1 << n
        return ('i', x)   # promoted to int, as C does
    raise Refused('conversion')


def binary(op: str, a: Value, b: Value) -> Value:
    (ka, x), (kb, y) = a, b
    if 'f' in (ka, kb): raise Refused('float arithmetic')
    if op == '&&': return ('b', int(bool(x) and bool(y)))
    if op == '||': return ('b', int(bool(x) or bool(y)))
    if op in ('<<', '>>'):   # the left operand's type; a shift count wraps at 32, as the GPU's does
        k = 'i' if ka == 'b' else ka
        n = y & 31
        return (k, wrap(k, x << n if op == '<<' else (x if k == 'i' else x & M32) >> n))
    k = 'u' if 'u' in (ka, kb) else 'i'
    x, y = wrap(k, x), wrap(k, y)
    if op in COMPARE: return ('b', int({'==': x == y, '!=': x != y, '<': x < y, '>': x > y, '<=': x <= y, '>=': x >= y}[op]))
    if op in ('/', '%'):
        if y == 0: raise Refused('division by zero')
        q = abs(x) // abs(y) * (1 if (x < 0) == (y < 0) else -1)
        return (k, wrap(k, q if op == '/' else x - q * y))
    r = {'+': x + y, '-': x - y, '*': x * y, '&': x & y, '|': x | y, '^': x ^ y}.get(op)
    if r is None: raise Refused('operator')
    return (k, wrap(k, r))


def int_call(name: str, args: list[Value]) -> Value:
    if any(k == 'f' for k, _ in args): raise Refused('float arithmetic')
    if name == 'select' and len(args) == 3: return args[1] if args[2][1] else args[0]   # Metal's select(a, b, c): c ? b : a
    k = 'i' if not args or args[0][0] == 'b' else args[0][0]
    v = [wrap(k, x) for _, x in args]
    if name == 'extract_bits' and len(v) == 3:
        off, n = args[1][1] & 31, args[2][1] & 63
        r = ((v[0] & M32) >> off) & ((1 << n) - 1) if n else 0
        if k == 'i' and n and r >> (n - 1): r -= 1 << n
        return (k, wrap(k, r))
    if name == 'insert_bits' and len(v) == 4:
        off, n = args[2][1] & 31, args[3][1] & 63
        mask = (((1 << n) - 1) << off) & M32
        return (k, wrap(k, (v[0] & ~mask) | ((v[1] << off) & mask)))
    if name == 'min' and len(v) == 2: return (k, min(v))
    if name == 'max' and len(v) == 2: return (k, max(v))
    if name == 'clamp' and len(v) == 3: return (k, min(max(v[0], v[1]), v[2]))
    if name == 'abs' and len(v) == 1: return (k, wrap(k, abs(v[0])))
    if name == 'absdiff' and len(v) == 2: return ('u', wrap('u', abs(v[0] - v[1])))
    if name == 'popcount' and len(v) == 1: return (k, bin(v[0] & M32).count('1'))
    if name == 'clz' and len(v) == 1: return (k, 32 - (v[0] & M32).bit_length())
    if name == 'ctz' and len(v) == 1: return (k, ((v[0] & -v[0]) & M32).bit_length() - 1 if v[0] & M32 else 32)
    if name == 'reverse_bits' and len(v) == 1: return (k, wrap(k, int(f'{v[0] & M32:032b}'[::-1], 2)))
    if name == 'mulhi' and len(v) == 2: return (k, wrap(k, (v[0] * v[1]) >> 32))
    raise Refused('call')


# ---- the kernel's statements ---------------------------------------------------------------------------------------------------------------------------------------------------
TYPE = r'(?:(?:thread|threadgroup|device|constant)\s+)?(?:packed_)?(?:u?int|float|half|bool|u?short|u?char|u?long)(?:[234](?:x[234])?)?|spvUnsafeArray<[^;=]*?>'
DECL = re.compile(r'^(?:const\s+)?(%s)\s+([A-Za-z_]\w*)\s*(?:=\s*(.*))?;$' % TYPE)
TG_DECL = re.compile(r'^threadgroup\s+(?:spvUnsafeArray<(\w+),\s*(\d+)>|(\w+))\s+(\w+)(?:\[(\d+)\])?;$')
TG_SPILLED = re.compile(r'^device\s+(?:spvUnsafeArray<(\w+),\s*(\d+)>|(\w+))\s*(?:&\s*(\w+)|\(&(\w+)\)\[(\d+)\])\s*=\s*\*\(device\b.*\bdm_tg\b')   # dmsh_build.py tg_spill
POINTER_CAST = re.compile(r'\((?:(?:const|volatile)\s+)?(?:device|threadgroup|thread|constant)\s+[\w ]+\*\s*\)(?=\s*&)')
WIDE = re.compile(r'^\*\((?:const\s+)?device\s+\w+\s*\*\)\s*&(.*)$')   # dmsh_wide.py: words of a buffer read as one vector
MATRICES = re.compile(r'^simdgroup_\w+\s+dm_acc\[(\d+)\],\s*dm_am\[\d+\];$')   # hmma_msl's own declaration in each function that calls the helper: no line of the game's
CONTROL = re.compile(r'^(if|else|for|while|do|switch|case|default|break|continue|return|discard_fragment)\b')
LOOP_HEAD = re.compile(r'^(for|while|do)\b')
WORD_BYTES = {'uint': 4, 'int': 4, 'float': 4, 'half': 2, 'ushort': 2, 'short': 2, 'uchar': 1, 'char': 1}
BLOCKING = ('barrier', 'fence', 'atomic', 'device atomic', 'shared store', 'device store', 'texture write', 'call', 'block', 'other')   # what a stage-3 window must not hold


class Shader:
    """One kernel's statements: definitions, re-assignments (phis), stores, barriers, calls and braces in line order, and the loop of each definition"""

    def __init__(self, src: str, local: list[int] | None = None):
        self.local = local if isinstance(local, list) and len(local) == 3 and all(isinstance(n, int) and n > 0 for n in local) else None
        self.acc_size: int | None = None   # hmma_msl's dm_acc declared in the kernel (a library's source): which body the calls run; None in the translator's own text
        self.x_aligned = self.local is None or self.local[0] % 32 == 0   # each warp holds whole rows of x: tid.x is 32 k + lane, tid.y and tid.z the warp's
        self.defs: dict[str, Node | None] = {}   # None: unreadable, or D1 of an HMMA call
        self.types: dict[str, str] = {}
        self.line_of: dict[str, int] = {}
        self.loop_of: dict[str, int] = {}   # the innermost loop around a definition, 0 for none
        self.multi: set[str] = set()   # declared without a value or assigned again: a phi
        self.assigns: dict[str, list[Node | None]] = collections.defaultdict(list)
        self.arrays: dict[str, tuple[str, int]] = {}   # threadgroup arrays: element type, count
        self.uint_arrays: set[str] = set()   # those declared threadgroup spvUnsafeArray<uint, N>: what hmma_msl takes for the caller's shared memory
        self.stmts: list[tuple[int, str]] = []   # (line, kind): what a stage-3 window must not hold, the braces, the HMMA calls
        self.uses: dict[str, list[str]] = collections.defaultdict(list)   # var -> the vars that read it, or 'store:<line>' / 'ctl:<line>'
        self.buffer_params: set[str] = set()
        self.structs: dict[str, dict[str, str]] = {}   # the source's structs: field -> its type ('float4[]' for an array), qualifiers and pointers left out
        self.param_types: dict[str, str] = {}   # the kernel's buffer parameters: their struct
        self.lines = 0
        self.uniform_ok = {'const', 'workgroup', 'cbuf'} | ({'tid.y', 'tid.z'} if self.x_aligned else set())   # warp-uniform leaves stage 1's pass would take
        self._leaves: dict[str, frozenset[str]] = {}
        self._cones: dict[str, list[str]] = {}
        self._refs: dict[str, set[str]] = {}
        self._warps: dict[tuple[int, bool], list[list[dict[str, Any]]]] = {}
        self._memo: dict[tuple[int, bool, int, int], dict[str, Value]] = {}   # per (sample, phi taken as uniform, warp, lane): every value evaluated so far
        self.read(src)
        helper = {v: d for v, d in self.defs.items() if d is not None and d[0] == 'call' and callee_name(d) == HMMA_NAME}
        self.calls = [v for v, d in helper.items() if len(d[2]) in CALL_FORMS]
        self.unread_calls = len(helper) - len(self.calls)   # a form this reader does not know: counted, never guessed at
        self.call_set = set(self.calls)
        self.form = {v: CALL_FORMS[len(helper[v][2])] for v in self.calls}
        self.scratch = {a for v in self.calls for a in [self.arg_name(v, self.form[v]['scratch'])] if a}
        self.game_arrays = {a for a in self.arrays if a not in self.scratch}
        self.d1: dict[str, str] = {}   # D1 (the out parameter) -> its call
        for v in self.calls:
            d1 = self.arg_name(v, self.form[v]['d1'])
            if d1:
                self.d1[d1] = v; self.multi.discard(d1); self.defs[d1] = None; self.line_of.setdefault(d1, self.line_of[v])
        self.direct_a, self.direct_a_how = self.direct()

    def direct(self) -> tuple[bool | None, str]:
        """Whether a call's FlagADirect loads A from the caller's shared memory: hmma_msl passes that array, and turns direct A on, only when every function that calls the
        helper declares one threadgroup spvUnsafeArray<uint, N> besides the scratch, the same one; else the flag is ignored and A goes through the scratch. A rewritten call says
        which (22 arguments: on); for the translator's own form this applies hmma_msl's rule to the kernel, the only function read here"""
        forms = {f['direct'] for f in self.form.values() if f['flags'] is not None}
        if not forms: return None, 'no call with TensorPass flags'
        if True in forms: return True, 'the calls pass the shared memory array (as hmma_msl rewrites them)'
        if False in forms: return False, 'the calls pass no shared memory array (as hmma_msl rewrites them)'
        other = self.uint_arrays - self.scratch
        return len(other) == 1, f'the kernel declares {len(other)} threadgroup uint array{"s" * (len(other) != 1)} besides the scratch (as hmma_msl would decide)'

    def copy_root(self, node: Node) -> Node:
        """What a chain of copies and conversions copies (spirv-cross passes each argument through a copy of its own)"""
        node = strip_casts(node)
        for _ in range(16):
            if node[0] != 'name' or node[1] in self.multi: break
            d = self.defs.get(node[1])
            if d is None or strip_casts(d)[0] not in ('name', 'num'): break   # a constant: compared by its text
            node = strip_casts(d)
        return node

    def const_arg(self, call: str, k: int) -> int | None:
        """A call argument's value when it is a constant (spirv-cross passes each through a copy of its own), else None"""
        d = self.defs[call]
        if d is None or k >= len(d[2]): return None
        a = d[2][k]
        try:
            if self.node_leaves(a) != {'const'}: return None
            ctx = self.warp_contexts(0)[0][0]
            memo: dict[str, Value] = {}
            for r in sorted(self.refs(a)): self.evaluate(r, ctx, memo)
            return wrap('i', self.ev(a, ctx, memo)[1])
        except Refused: return None

    def arg_name(self, call: str, k: int) -> str | None:
        d = self.defs[call]
        if d is None: return None
        a = strip_casts(d[2][k])
        return a[1] if a[0] == 'name' else None

    def read(self, src: str) -> None:
        m = re.search(r'\bkernel\s+void\s+(\w+)\s*\(', src)
        if not m: raise ValueError('no kernel function in the source')
        depth, i = 1, m.end()
        while depth and i < len(src): depth += {'(': 1, ')': -1}.get(src[i], 0); i += 1   # the parameter list: its attributes hold brackets, not braces
        self.buffer_params = set(re.findall(r'\b(\w+)\s*\[\[buffer\(', src[m.end():i])) - {'spvDescriptorSet0'}
        for sm in STRUCT.finditer(src, 0, m.start()):   # the buffers' layouts: a constant buffer is float4 _m0[4096], a storage buffer uint _m0[]
            self.structs[sm.group(1)] = {f.group(2): QUALIFIERS.sub('', f.group(1)).strip() + '[]' * f.group(3).count('[') for f in FIELD.finditer(sm.group(2))}
        for pm in BUFFER_PARAM.finditer(src, m.end(), i): self.param_types[pm.group(2)] = QUALIFIERS.sub('', pm.group(1)).strip()
        start = src.index('{', i)
        depth, end = 0, -1
        for j in range(start, len(src)):
            depth += {'{': 1, '}': -1}.get(src[j], 0)
            if depth == 0: end = j; break
        if end < 0: raise ValueError('kernel body not closed')
        first = src.count('\n', 0, start) + 1
        stack: list[list[int]] = [[0, 0]]   # per open brace: [region, is a loop]; a window across a brace line leaves its block (stmts)
        regions, prev = 0, ''
        for n, raw in enumerate(src[start + 1:end].split('\n')):
            line, s = first + n, raw.strip()
            if m := MATRICES.match(s): self.acc_size = int(m.group(1))
            if not s or s.startswith(('//', '#')) or m: continue
            self.lines += 1
            if s == '{':
                regions += 1; stack.append([regions, int(bool(LOOP_HEAD.match(prev)))]); self.stmts.append((line, 'block')); prev = s; continue
            if s.startswith('}'):
                if len(stack) > 1: stack.pop()
                self.stmts.append((line, 'block'))
                if s[1:].strip().startswith('while'): self.control(s[1:].strip(), line)
                prev = s; continue
            prev = s
            loop = next((r for r, is_loop in reversed(stack) if is_loop), 0)
            self.statement(s, line, loop)

    def shared_atomic(self, s: str) -> bool:
        """Whether a statement's atomic works on shared memory (one of the kernel's threadgroup arrays, spilled ones too): TensorPass.WritesShared counts only those, as a
        shared store, between an LDSM and the HMMA; an atomic on a buffer or an image does not stop A from being loaded where the LDSM read it"""
        return any(a in self.arrays for a in re.findall(r'\batomic_\w+\(\s*&\s*\(?\s*(\w+)\b', s))   # an element of an array, or a shared variable of its own

    def control(self, s: str, line: int) -> None:
        self.stmts.append((line, 'block'))
        m = re.search(r'\((.*)\)', s)
        if m and not s.startswith('for'):
            try: refs = self.refs(parse(m.group(1)))
            except Unreadable: return
            for r in refs: self.uses[r].append(f'ctl:{line}')

    def statement(self, s: str, line: int, loop: int) -> None:
        s = POINTER_CAST.sub('', re.sub(r'/\*.*?\*/', '', s)).strip()   # comments (/* nan */), and the pointer casts of atomics: what is read stays
        if CONTROL.match(s): self.control(s, line); return
        if m := TG_DECL.match(s):
            self.arrays[m.group(4)] = (m.group(1) or m.group(3), int(m.group(2) or m.group(5) or 1))
            if m.group(1) == 'uint': self.uint_arrays.add(m.group(4))
            return
        if m := TG_SPILLED.match(s):
            self.arrays[m.group(4) or m.group(5)] = (m.group(1) or m.group(3), int(m.group(2) or m.group(6) or 1)); return
        here = []
        if re.search(r'\bthreadgroup_barrier\(', s): here.append('barrier')
        elif re.search(r'\bsimdgroup_barrier\(', s): here.append('simdgroup barrier')
        elif re.search(r'\batomic_thread_fence\(|\bspvImageFence\(', s): here.append('fence')
        if re.search(r'\batomic_\w+\(', s) and 'atomic_thread_fence' not in s: here.append('atomic' if self.shared_atomic(s) else 'device atomic')
        if re.search(r'\.write\(', s): here.append('texture write')
        self.stmts.extend((line, k) for k in here)
        if m := DECL.match(s):
            t, v, e = m.group(1), m.group(2), m.group(3)
            self.types[v] = re.sub(r'^(?:thread|threadgroup|device|constant)\s+', '', t); self.line_of[v] = line; self.loop_of[v] = loop
            if e is None: self.multi.add(v); return
            w = WIDE.match(e)
            try: node: Node | None = parse(w.group(1) if w else e)
            except Unreadable: node = None
            self.defs[v] = node
            if node is not None:
                for r in self.refs(node): self.uses[r].append(v)
                if node[0] == 'call' and callee_name(node) == HMMA_NAME: self.stmts.append((line, 'hmma'))
                elif self.has_call(node) and not here: self.stmts.append((line, 'call'))
            elif not here: self.stmts.append((line, 'other'))
            return
        try: toks = tokenize(s.rstrip(';'))
        except Unreadable:
            if not here: self.stmts.append((line, 'other'))
            return
        depth, at = 0, None
        for k, t in enumerate(toks):
            depth += {'(': 1, '[': 1, ')': -1, ']': -1}.get(t, 0)
            if depth == 0 and t in ASSIGN_OPS: at = k; break
        if at is None:   # a call on its own
            try: node = Parser(toks).whole()
            except Unreadable: node = None
            if node is not None:
                for r in self.refs(node): self.uses[r].append(f'ctl:{line}')
            if not here: self.stmts.append((line, 'call' if node is None or self.has_call(node) else 'other'))
            return
        try: lhs, rhs = Parser(toks[:at]).whole(), Parser(toks[at + 1:]).whole()
        except Unreadable:
            if not here: self.stmts.append((line, 'other'))
            return
        root = self.root(lhs)
        refs = self.refs(rhs) | (self.refs(lhs) - {root or ''})
        if root in self.arrays:
            self.stmts.append((line, 'shared store'))
            for r in refs: self.uses[r].append(f'store:{line}')
        elif root and (root.startswith('spvDescriptorSet') or root in self.buffer_params):
            self.stmts.append((line, 'device store'))
            for r in refs: self.uses[r].append(f'store:{line}')
        elif root:
            self.multi.add(root); self.assigns[root].append(rhs if lhs[0] == 'name' and toks[at] == '=' else None)
            for r in refs: self.uses[r].append(root)
            if self.has_call(rhs): self.stmts.append((line, 'call'))
        else: self.stmts.append((line, 'other'))

    @staticmethod
    def root(node: Node) -> str | None:
        while is_access(node): node = base_of(node)
        return node[1] if node[0] == 'name' else None

    def refs(self, node: Node) -> set[str]:
        """The variables an expression reads (not the threadgroup arrays it indexes)"""
        out: set[str] = set()
        stack = [node]
        while stack:
            n = stack.pop()
            if n[0] == 'name':
                if re.fullmatch(r'_\w+', n[1]) and n[1] not in self.arrays: out.add(n[1])
            elif n[0] == 'call' and n[1][0] == 'name': stack.extend(n[2])   # a helper's name (_123) is not a variable
            else: stack.extend(children(n))
        return out

    def def_refs(self, v: str) -> set[str]:
        """The variables v's definition reads"""
        if v not in self._refs:
            d = self.defs.get(v)
            self._refs[v] = set() if d is None or v in self.multi else self.refs(d)
        return self._refs[v]

    def has_call(self, node: Node) -> bool:
        """whether an expression calls a function that may do more than compute a value: a helper, an atomic. Arithmetic, conversions, shuffles and texture reads do not count"""
        stack = [node]
        while stack:
            n = stack.pop()
            if n[0] == 'call':
                name = callee_name(n)
                if not (name in CASTS or name in INT_CALLS or PURE.match(name) or SHUFFLES.match(name) or (name.startswith('.') and name != '.write')): return True
            stack.extend(children(n))
        return False

    # ---- leaves: what a value is made of -------------------------------------------------------------------------------------------------------------------------------------
    def buffer_leaf(self, node: Node) -> str | None:
        """For an access rooted at a buffer (spvDescriptorSet0.cp_c4->..., (*spvDescriptorSet0.cp_s1)._m0[i], a buffer parameter): cbuf, sbuf or buffer"""
        n = node
        while is_access(n):
            if n[0] == 'member' and n[1][0] == 'name' and n[1][1].startswith('spvDescriptorSet'):
                f = n[2]
                return 'cbuf' if re.search(r'_c\d+$|^support_buffer$', f) else 'sbuf' if re.search(r'_s\d+$', f) else 'buffer'
            n = base_of(n)
        return 'buffer' if n[0] == 'name' and n[1] in self.buffer_params else None

    def own_leaves(self, node: Node) -> tuple[set[str], set[str], set[str], set[str]]:
        """(the leaves an expression itself holds, the variables whose leaves it takes; the same two of the indices of the buffer words it reads, which index_leaf judges)"""
        leaves: set[str] = set(); refs: set[str] = set(); idx_leaves: set[str] = set(); idx_refs: set[str] = set()
        stack: list[tuple[Node, bool]] = [(node, False)]   # (node, inside a buffer index)
        while stack:
            n, in_idx = stack.pop()
            out, out_refs = (idx_leaves, idx_refs) if in_idx else (leaves, refs)
            k = n[0]
            if k == 'num' or k == 'tmpl': continue
            if k == 'name':
                nm = n[1]
                if nm in self.arrays: out.add('shared')
                elif nm in BUILTINS: out.add(BUILTINS[nm])
                elif re.fullmatch(r'_\w+', nm): out_refs.add(nm)
                elif nm.startswith('gl_'): out.add('builtin')
                elif nm in self.buffer_params: out.add('buffer')
                elif CONSTANT_NAME.match(nm): out.add('const')
                else: out.add('param')   # a name this reader does not know (a parameter, a global): nothing to say it is warp-uniform
                continue
            if is_access(n):
                b = self.buffer_leaf(n)
                if b:
                    out.add(b)
                    m = n
                    while is_access(m):   # the chain's indices: is the word the same for every lane, and one stage 1 could read?
                        if m[0] == 'index': stack.append((m[2], True))
                        m = base_of(m)
                    continue
                if k == 'member' and n[1][0] == 'name' and n[1][1] in BUILTIN_VECTORS:
                    leaf = BUILTIN_VECTORS[n[1][1]]
                    out.add(leaf + n[2] if leaf.endswith('.') else leaf); continue
                if k == 'index' and n[1][0] == 'name' and n[1][1] in self.arrays: out.add('shared'); continue
                stack.extend((c, in_idx) for c in children(n)); continue
            if k == 'call':
                name = callee_name(n)
                if SHUFFLES.match(name): out.add('shuffle'); continue
                if name.startswith('atomic_'): out.add('atomic'); continue
                if name.startswith('dmsh_'): out.add('call'); continue
                if name.startswith('.'): out.add('texture'); continue
                arg = self.static_kind(n[2][0]) if len(n[2]) == 1 else None
                if FLOAT_CALLS.match(name) or (name == 'float' and arg != 'f') or (name in INT_CONVERSIONS and arg == 'f'): out.add('float')   # to or from a float
                elif not (name in CASTS or name in INT_CALLS or PURE.match(name)): out.add('call'); continue
                stack.extend((a, in_idx) for a in n[2]); continue
            if k == 'bin' and n[1] not in ('&&', '||') and 'f' in (self.static_kind(n[2]), self.static_kind(n[3])): out.add('float')
            if k == 'un' and n[1] == '-' and self.static_kind(n[2]) == 'f': out.add('float')
            stack.extend((c, in_idx) for c in children(n))
        return leaves, refs, idx_leaves, idx_refs

    def index_leaf(self, leaf: str) -> str:
        """What a leaf of a buffer word's index makes of the word: the leaf itself when it is warp-uniform and stage 1 could read it (a constant-buffer word at an index of
        constants, the workgroup ID, constant-buffer words, tid.y / z), else a blocker: 'buffer index varies' (the lanes read different words), 'buffer index: <leaf>'"""
        if leaf in self.uniform_ok or leaf.startswith('buffer index'): return leaf
        return 'buffer index varies' if leaf in self.varying() else f'buffer index: {leaf}'

    def type_of(self, n: Node) -> str | None:
        """The declared type of a buffer access, from the source's structs ((*spvDescriptorSet0.cp_c1)._m0[i].x: float); None when not known"""
        k = n[0]
        if k == 'name': return self.param_types.get(n[1])
        if k == 'un' and n[1] == '*': return self.type_of(n[2])
        if k not in ('member', 'index'): return None
        t = self.type_of(n[1])
        if t is None: return None
        if k == 'member' and t in self.structs: return self.structs[t].get(n[2])
        if k == 'index' and t.endswith('[]'): return t[:-2]
        v = VECTOR.fullmatch(t)
        return v.group(1) if v and (k == 'index' or re.fullmatch(r'[xyzw]', n[2])) else None

    def static_kind(self, n: Node) -> str | None:
        """The type C gives an expression, as far as this reader needs it: 'f' marks float arithmetic"""
        k = n[0]
        if k == 'num': return num_kind(n[1])
        if k == 'name': return kind_of_type(self.types[n[1]]) if n[1] in self.types else 'u' if n[1] in BUILTINS else None
        if is_access(n) and (t := self.type_of(n)): return kind_of_type(t)
        if k == 'call':
            name = callee_name(n)
            if name.startswith('as_type<'): return SCALAR_KIND.get(name[8:-1].strip(), 'v')
            if name in SCALAR_KIND: return SCALAR_KIND[name]
            if name in INT_CALLS and n[2]: return self.static_kind(n[2][1] if name == 'select' and len(n[2]) > 1 else n[2][0])
            return 'f' if FLOAT_CALLS.match(name) else None
        if k == 'member':
            if n[1][0] == 'name' and n[1][1] in BUILTIN_VECTORS: return 'u'
            if n[1][0] == 'name' and n[1][1] in self.types: return SCALAR_KIND.get(re.sub(r'^packed_|[234](?:x[234])?$', '', self.types[n[1][1]]), 'v')
            return None
        if k == 'bin':
            if n[1] in COMPARE or n[1] in ('&&', '||'): return 'b'
            a, b = self.static_kind(n[2]), self.static_kind(n[3])
            return 'f' if 'f' in (a, b) else 'u' if 'u' in (a, b) else a or b
        if k == 'un': return 'b' if n[1] == '!' else self.static_kind(n[2])
        if k == 'tern': return self.static_kind(n[2])
        return None

    def varying(self) -> set[str]:
        """Leaves whose value can differ between the lanes of a warp"""
        v = {'lane', 'tid.x', 'tid.index', 'gid', 'phi', 'shared', 'shuffle', 'call', 'atomic', 'texture', 'param', 'unreadable', 'buffer index varies', 'builtin'}
        return v if self.x_aligned else v | {'tid.y', 'tid.z'}

    def leaves(self, v: str) -> frozenset[str]:
        if v in self._leaves: return self._leaves[v]
        order: list[str] = []
        seen: set[str] = set()
        stack: list[tuple[str, bool]] = [(v, False)]
        info: dict[str, tuple[set[str], set[str], set[str], set[str]]] = {}
        none: set[str] = set()
        while stack:   # depth first, without recursion: a game shader's chains run deeper than Python's stack
            u, done = stack.pop()
            if done: order.append(u); continue
            if u in seen or u in self._leaves: continue
            seen.add(u)
            d = self.defs.get(u)
            if u in self.multi: info[u] = ({'phi'}, none, none, none)
            elif u in self.call_set or u in self.d1: info[u] = ({'call'}, none, none, none)
            elif u not in self.defs: info[u] = ({'param'}, none, none, none)
            elif d is None: info[u] = ({'unreadable'}, none, none, none)
            else: info[u] = self.own_leaves(d)
            stack.append((u, True))
            stack.extend((r, False) for r in info[u][1] | info[u][3] if r not in seen and r not in self._leaves)
        for u in order:
            own, refs, idx_own, idx_refs = info[u]
            out, idx = set(own), set(idx_own)
            for r in refs: out |= self._leaves.get(r, frozenset())
            for r in idx_refs: idx |= self._leaves.get(r, frozenset())
            out |= {self.index_leaf(x) for x in idx}
            out = out - {'const'} if len(out - {'const'}) else {'const'}
            self._leaves[u] = frozenset(out)
        return self._leaves.get(v, frozenset({'param'}))

    def node_leaves(self, node: Node) -> set[str]:
        """An expression's leaves, as leaves() gives a variable's"""
        own, refs, idx_own, idx_refs = self.own_leaves(node)
        out, idx = set(own), set(idx_own)
        for r in refs: out |= self.leaves(r)
        for r in idx_refs: idx |= self.leaves(r)
        return out | {self.index_leaf(x) for x in idx}

    def phi_inputs(self, v: str) -> set[str]:
        """The leaves of the values the phis v is computed from take (a loop's start and step: 'phi' where a step reads the phi itself). Without a varying leaf but 'phi',
        such a phi could be warp-uniform, which the planned uniform-phi extension of stage 1 would have to prove (its branches uniform too)"""
        out: set[str] = set()
        for u in self.cone(v):
            if u not in self.multi: continue
            for e in [*self.assigns.get(u, []), self.defs.get(u)]:
                if e is None: continue
                own, refs, idx_own, idx_refs = self.own_leaves(e)
                idx = set(idx_own)
                out |= own
                for r in refs: out |= {'phi'} if r in self.multi else self.leaves(r)
                for r in idx_refs: idx |= {'phi'} if r in self.multi else self.leaves(r)
                out |= {self.index_leaf(x) for x in idx}
            if None in self.assigns.get(u, []): out.add('other')
        return out - {'const'} if out - {'const'} else out

    # ---- evaluation: 32-bit C arithmetic, one lane at a time ---------------------------------------------------------------------------------------------------------------
    def cone(self, v: str) -> list[str]:
        """v and the variables it is computed from, each after those it reads"""
        if v in self._cones: return self._cones[v]
        order: list[str] = []
        seen: set[str] = set()
        stack: list[tuple[str, bool]] = [(v, False)]
        while stack:
            u, done = stack.pop()
            if done: order.append(u); continue
            if u in seen: continue
            seen.add(u)
            stack.append((u, True))
            stack.extend((r, False) for r in self.def_refs(u) if r not in seen)
        self._cones[v] = order
        return order

    def evaluate(self, v: str, ctx: dict[str, Any], memo: dict[str, Value] | None = None) -> Value:
        memo = {} if memo is None else memo
        for u in self.cone(v):
            if u in memo: continue
            if u in self.multi:
                if not ctx['phi']: raise Refused('phi')
                memo[u] = self.uniform_value(ctx, ('phi', u), kind_of_type(self.types.get(u, '')))   # taken as warp-uniform: one random value a sample
                continue
            if u in self.call_set or u in self.d1: raise Refused('HMMA result')
            d = self.defs.get(u)
            if d is None: raise Refused('param' if u not in self.defs else 'unreadable')
            val = self.ev(d, ctx, memo)
            k = kind_of_type(self.types.get(u, ''))
            if k in ('i', 'u', 'b') and val[0] != k: val = convert({'i': 'int', 'u': 'uint', 'b': 'bool'}[k], val)
            elif k == 'f' and val[0] != 'f': val = convert('float', val)
            memo[u] = val
        return memo[v]

    def ev(self, n: Node, ctx: dict[str, Any], memo: dict[str, Value]) -> Value:
        k = n[0]
        if k == 'num': return num_value(n[1])
        if k == 'name':
            nm = n[1]
            if nm in memo: return memo[nm]
            if nm == 'gl_SubgroupInvocationID': return ('u', ctx['lane'])
            if nm == 'gl_LocalInvocationIndex': return ('u', ctx['flat'])
            if nm == 'gl_SubgroupSize': return ('u', 32)
            if nm in ('true', 'false'): return ('b', int(nm == 'true'))
            raise Refused('shared' if nm in self.arrays else 'name')
        if is_access(n):
            if self.buffer_leaf(n): return self.buffer_value(n, ctx, memo)
            if k == 'member' and n[1][0] == 'name':
                base, c = n[1][1], n[2]
                if base in BUILTIN_VECTORS and c in ('x', 'y', 'z'):
                    i = 'xyz'.index(c)
                    if base == 'gl_LocalInvocationID': return ('u', ctx['tid'][i])
                    if base == 'gl_WorkGroupID': return ('u', ctx['wg'][i])
                    if base == 'gl_NumWorkGroups': return ('u', ctx['nwg'][i])
                    if base == 'gl_WorkGroupSize': return ('u', ctx['size'][i])
                    return ('u', wrap('u', ctx['wg'][i] * ctx['size'][i] + ctx['tid'][i]))
                if base in memo and c in ('x', 'y', 'z', 'w'):   # a word of a buffer read as a vector (dmsh_wide.py): one more random word
                    kk, x = memo[base]
                    return (kk, wrap(kk, x ^ (0x9E3779B0 * ('xyzw'.index(c) + 1))))
            raise Refused('shared' if k == 'index' and n[1][0] == 'name' and n[1][1] in self.arrays else 'vector or array')
        if k == 'un':
            x = self.ev(n[2], ctx, memo)
            if n[1] == '!': return ('b', int(not x[1]))
            if x[0] == 'f': raise Refused('float arithmetic')
            kk = 'i' if x[0] == 'b' else x[0]
            if n[1] == '-': return (kk, wrap(kk, -x[1]))
            if n[1] == '~': return (kk, wrap(kk, ~x[1]))
            if n[1] == '+': return (kk, x[1])
            raise Refused('operator')
        if k == 'bin': return binary(n[1], self.ev(n[2], ctx, memo), self.ev(n[3], ctx, memo))
        if k == 'tern': return self.ev(n[2] if self.ev(n[1], ctx, memo)[1] else n[3], ctx, memo)
        if k == 'call':
            name = callee_name(n)
            if name in CASTS:
                if len(n[2]) != 1: raise Refused('vector')
                return convert(name, self.ev(n[2][0], ctx, memo))
            if name in INT_CALLS: return int_call(name, [self.ev(a, ctx, memo) for a in n[2]])
            raise Refused('shuffle' if SHUFFLES.match(name) else 'float arithmetic' if FLOAT_CALLS.match(name) else 'call')
        raise Refused('expression')

    def buffer_value(self, n: Node, ctx: dict[str, Any], memo: dict[str, Value]) -> Value:
        """A buffer word: a random value of the sample, the same wherever any lane of any warp reads that word (its indices are evaluated). Its low bits are as random as the
        others: an offset read from a buffer is not known to be aligned, so an OR or XOR with it is linear only where their bits cannot overlap"""
        key, m = [], n
        while is_access(m):
            if m[0] == 'index': key.append(str(self.ev(m[2], ctx, memo)[1]))
            elif m[0] == 'member': key.append(m[2])
            m = base_of(m)
        k = self.static_kind(n)
        return self.uniform_value(ctx, ('buffer', *key), k if k in ('i', 'u', 'f') else 'u')

    @staticmethod
    def uniform_value(ctx: dict[str, Any], key: tuple[str, ...], kind: str) -> Value:
        """A random value of the sample, the same in every lane of every warp: 32 bits, or 16 in the samples of small offsets"""
        r = random.Random('/'.join((str(ctx['seed']), *key))).getrandbits(ctx['bits'])
        k = kind if kind in ('i', 'u', 'f') else 'u'
        return (k, wrap(k, r))

    def warp_contexts(self, sample: int, phi: bool = False) -> list[list[dict[str, Any]]]:
        """Every warp of a workgroup, each its 32 lanes (lane = flat thread index % 32, as the translator takes it), with this sample's uniform values; phi: take each phi as one
        more uniform value instead of refusing it"""
        if (sample, phi) in self._warps: return self._warps[sample, phi]
        rng = random.Random(7919 * (sample + 1))
        size = self.local or UNKNOWN_LOCAL
        total = size[0] * size[1] * size[2]
        wg, nwg = [rng.randrange(64) for _ in range(3)], [rng.randrange(64, 128) for _ in range(3)]
        out = []
        for warp in range(max(1, -(-total // 32))):
            lanes = []
            for lane in range(32):
                flat = (32 * warp + lane) % total   # a last warp that is not full: its missing lanes read as the first ones
                tid = [flat % size[0], (flat // size[0]) % size[1], flat // (size[0] * size[1])]
                lanes.append(dict(lane=lane, warp=warp, flat=flat, tid=tid, wg=wg, nwg=nwg, size=size, seed=sample, bits=32 if sample < 2 else 16, phi=phi))
            out.append(lanes)
        self._warps[sample, phi] = out
        return out

    def lane_tables(self, v: str | None, node: Node | None, sample: int, every_warp: bool = True, phi: bool = False) -> list[list[int]]:
        """A variable's (or an expression's) value in each lane of each warp: [warp][lane]. Only the first warp unless every_warp"""
        out = []
        for lanes in self.warp_contexts(sample, phi)[:None if every_warp else 1]:
            tab = []
            for ctx in lanes:
                memo = self._memo.setdefault((sample, phi, ctx['warp'], ctx['lane']), {})
                if v is not None: val = self.evaluate(v, ctx, memo)
                elif node is not None:
                    for r in sorted(self.refs(node)): self.evaluate(r, ctx, memo)
                    val = self.ev(node, ctx, memo)
                else: raise Refused('nothing to evaluate')
                tab.append(val[1] & M32)
            out.append(tab)
        return out

    def warp_free(self, v: str | None, node: Node | None) -> bool:
        """Whether every warp computes the same lane table: nothing in it differs between warps (tid, a phi, anything not evaluated)"""
        leaves = self.leaves(v) if v is not None else self.node_leaves(node) if node is not None else frozenset()
        return set(leaves) <= WARP_FREE


def s32(x: int) -> int: return wrap('i', x)


def pitch_why(p: Any) -> list[str]:
    """Why a pitch is none stage 3 takes: one constant of 16 to 65535 bytes, a multiple of 16 (LDSM's rows), the same in every matrix and warp"""
    if not isinstance(p, int): return [f'pitch {p}' if p is not None else 'pitch not evaluated']
    return [] if 16 <= p < 65536 and p % 16 == 0 else [f'pitch {p}']


D_LABEL = re.compile(r'D\d+\.\d')   # D of the k-th HMMA, in the totals: D


def from_d(label: str) -> bool:
    """Whether an operand's source is an earlier HMMA's D: Dk.j, or a phi with one among its values (an accumulator a loop carries)"""
    if label.startswith('phi('): return any(D_LABEL.fullmatch(x) for x in label[4:-1].split('|'))
    return bool(D_LABEL.fullmatch(label))


# ---- the census of one shader --------------------------------------------------------------------------------------------------------------------------------------------------
def lane_pattern(idx: list[int]) -> tuple[str, int, int] | None:
    """Which emulation a shuffle belongs to, from the lane each lane reads (InstEmitAmpereTensor.cs): (kind, matrix or register, half or column)"""
    lanes = range(32)
    if len(set(idx)) == 1: return ('one lane', idx[0], 0)
    for m in range(4):
        if all(idx[x] == (x >> 2) + 8 * m for x in lanes): return ('ldsm', m, 0)
        for j in range(2):
            if all(idx[x] == 2 * (x & 3) + j + 8 * m for x in lanes): return ('ldsm.T', m, j)
    for j in range(2):
        if all(idx[x] == 8 * (x & 3) + 4 * j + (x >> 3) for x in lanes): return ('movm', j, 0)
    for j in range(4):
        if all(idx[x] == 4 * (x >> 2) + j for x in lanes): return ('hmma.A', j, 0)
        for c in range(2):
            if all(idx[x] == 4 * (2 * (x & 3) + c) + j for x in lanes): return ('hmma.B', c, j)
    return None


def rows(tabs: list[list[list[int]]], matrices: int) -> dict[str, Any]:
    """What an LDSM's row addresses ([sample][warp][lane]; lanes 8m .. 8m + 7 give matrix m's rows) show: the pitch (a number only when one in every matrix, warp and sample;
    else 'varies', 'uniform', 'per warp' or 'per matrix', and what it depends on), the matrices' bases from the warp's first row, whether that row moves with the uniform values,
    and the rows' alignment (at most 16)"""
    n_mat = min(matrices, 4)
    pitch: dict[tuple[int, int, int], int] = {}
    linear = True
    for s, warps in enumerate(tabs):
        for w, tab in enumerate(warps):
            for m in range(n_mat):
                d = [s32(tab[8 * m + r] - tab[8 * m]) for r in range(8)]
                if any(s32(d[r] - r * d[1]) for r in range(8)): linear = False   # modulo 2^32, as the GPU adds
                else: pitch[s, w, m] = d[1]
    out: dict[str, Any] = {}
    seen = set(pitch.values())
    if not linear: out['pitch'] = 'varies'
    elif len(seen) == 1: out['pitch'] = seen.pop()
    else:
        on = set()
        for (s, w, m), p in pitch.items():
            if any(pitch[s, w, k] != p for k in range(n_mat)): on.add('matrix')
            if any(pitch[s, k, m] != p for k in range(len(tabs[s]))): on.add('warp')
            if any(pitch[k, w, m] != p for k in range(len(tabs))): on.add('uniform values')
        out['pitch'] = 'uniform' if 'uniform values' in on else 'per warp' if 'warp' in on else 'per matrix'
        out['pitch_depends_on'], out['pitches_seen'] = sorted(on), sorted(seen)
    bases = {(s, w): [s32(tab[8 * m] - tab[0]) for m in range(n_mat)] for s, warps in enumerate(tabs) for w, tab in enumerate(warps)}
    first = bases[0, 0]
    out['matrix_bases'] = (first if all(b == first for b in bases.values()) else 'uniform' if all(b == bases[s, 0] for (s, _), b in bases.items()) else 'per warp')
    out['uniform_part_varies'] = len({warps[0][0] for warps in tabs}) > 1
    bits = 0
    for warps in tabs:
        for tab in warps:
            for x in tab[:8 * n_mat]: bits |= x
    out['row_alignment'] = min(16, bits & -bits) if bits else 16   # 16: the arithmetic alone keeps each row 16-byte aligned, whatever the uniform values
    return out


class Census:
    def __init__(self, src: str, local: list[int] | None = None, name: str = '', library: bool = False):
        self.sh = Shader(src, local)
        self.name = name
        self.library = library   # a built library's source: hmma_msl rewrote every call it could, so a call of the translator's 19 arguments runs the translator's own body
        self.allowed = self.sh.uniform_ok | {'lane'} | ({'tid.x'} if self.sh.x_aligned else set())   # the leaves stage 1's pass would take
        self.shuffles = self.find_shuffles()
        self.shuffle_of = {s['var']: s for s in self.shuffles}
        self.groups = self.ldsm_groups()
        self.word_of: dict[str, tuple[int, int]] = {}   # a word (or half) an LDSM loads -> (its LDSM, matrix)
        for g in self.groups:
            for var, m in g['_loads']: self.word_of[var] = (g['index'], m)
        self.d_of: dict[str, str] = {}
        self._prov: dict[str, tuple[str, list[tuple[int, int, str]]]] = {}   # what a variable is, found once (outside a phi's own loop)
        self._steps = 0
        self._blocking: list[tuple[int, str]] | None = None   # the statements a window must not hold, by line
        self._blocking_lines: list[int] = []
        for k, v in enumerate(self.sh.calls):
            self.d_of[v] = f'D{k}.0'
            d1 = self.sh.arg_name(v, self.sh.form[v]['d1'])
            if d1: self.d_of[d1] = f'D{k}.1'
        self.hmmas = [self.hmma(k, v) for k, v in enumerate(self.sh.calls)]
        self.hmma_of = dict(zip(self.sh.calls, self.hmmas))
        self.verdicts()

    # ---- every shuffle: the lanes it reads and where its value goes
    def find_shuffles(self) -> list[dict[str, Any]]:
        sh, out = self.sh, []
        for v, d in sh.defs.items():
            if d is None: continue
            inner = strip_casts(d)
            if not (inner[0] == 'call' and SHUFFLES.match(callee_name(inner)) and 'Shuffle' in callee_name(inner) and len(inner[2]) == 2):
                if any(c[0] == 'call' and 'Shuffle' in callee_name(c) for c in self.walk(d)): out.append(dict(var=v, line=sh.line_of[v], kind='other', pattern=None, source=None, const=None))
                continue
            src = strip_casts(inner[2][0])
            refused = False
            try:
                tabs = sh.lane_tables(None, inner[2][1], 0, not sh.warp_free(None, inner[2][1]))
                pat = lane_pattern(tabs[0]) if all(t == tabs[0] for t in tabs) else None   # the translator's lanes are the same in every warp
            except Refused: pat, refused = None, True
            flow = self.flow(v)
            kind = 'other'   # a lane pattern of none of the translator's emulations: the game's own SHFL
            if pat and pat[0] in ('ldsm', 'ldsm.T'): kind = 'ldsm_address' if flow == 'address' else 'other'
            elif pat and pat[0] == 'movm': kind = 'movm' if flow == 'extract' else 'other'
            elif pat and pat[0] in ('hmma.A', 'hmma.B'): kind = 'hmma_lane' if flow == 'data' else 'other'   # its halves unpacked and multiplied, never an address
            elif refused and flow == 'address': kind = 'ldsm_address'   # lanes not evaluated: told by where the value goes alone
            out.append(dict(var=v, line=sh.line_of[v], kind=kind, pattern=pat, lanes_evaluated=not refused, source=src[1] if src[0] == 'name' else None,
                            const=src if src[0] == 'num' else None))
        lanes: dict[str | None, set[int]] = collections.defaultdict(set)   # REDUX and MATCH read their value from each of the 32 lanes in turn; one lane read alone is other
        for s in out:
            if s['pattern'] and s['pattern'][0] == 'one lane': lanes[s['source']].add(s['pattern'][1])
        for s in out:
            if s['pattern'] and s['pattern'][0] == 'one lane' and s['source'] and lanes[s['source']] >= set(range(32)): s['kind'] = 'redux_match'
        out.sort(key=lambda s: s['line'])
        return out

    @staticmethod
    def walk(node: Node) -> Iterator[Node]:
        stack = [node]
        while stack:
            n = stack.pop()
            yield n
            stack.extend(children(n))

    def use_kind(self, d: Node, u: str) -> str:
        """How the expression d reads u: 'index' (in an index into the game's shared memory, or as the bit offset of an extract: an address), 'extract' (as the value extract_bits
        takes bits of), 'data' (anything else that is not integer arithmetic), 'arith' (integer arithmetic: follow it)"""
        sh, rank, found = self.sh, {'arith': 0, 'data': 1, 'extract': 2, 'index': 3}, 'arith'
        stack: list[tuple[Node, str]] = [(d, 'arith')]
        while stack:
            n, ctx = stack.pop()
            k = n[0]
            if k == 'name':
                if n[1] == u and rank[ctx] > rank[found]: found = ctx
                continue
            sub = 'data' if ctx == 'arith' else ctx
            if k == 'index':
                if n[1][0] == 'name' and n[1][1] in sh.game_arrays: stack.append((n[2], 'index'))
                else: stack.extend([(n[1], sub), (n[2], sub)])
            elif k == 'call':
                name = callee_name(n)
                if name == 'extract_bits' and len(n[2]) == 3:
                    stack.append((n[2][0], 'extract' if ctx == 'arith' else ctx)); stack.extend((a, 'index' if ctx == 'arith' else ctx) for a in n[2][1:])
                elif (name in CASTS and name != 'float') or name in INT_CALLS: stack.extend((a, ctx) for a in n[2])
                else: stack.extend((a, sub) for a in n[2])
            elif k == 'bin': stack.extend((x, sub if 'f' in (sh.static_kind(n[2]), sh.static_kind(n[3])) else ctx) for x in (n[2], n[3]))
            elif k in ('un', 'tern'): stack.extend((x, ctx) for x in children(n))
            elif k == 'member': stack.append((n[1], sub))
        return found

    def flow(self, v: str, depth: int = 8) -> str:
        """Where a shuffle's value goes: 'address' (only into indices of the game's shared memory, through integer arithmetic), 'extract' (bits of it taken: MOVM), 'data'"""
        sh = self.sh
        frontier, seen, got = [v], {v}, set()
        for _ in range(depth):
            nxt = []
            for u in frontier:
                for w in sh.uses.get(u, []):
                    d = sh.defs.get(w)
                    if ':' in w or w in sh.multi or d is None: got.add('data'); continue
                    how = self.use_kind(d, u)
                    if how != 'arith': got.add(how)
                    elif w not in seen: seen.add(w); nxt.append(w)
            frontier = nxt
            if not frontier: break
        if 'extract' in got and 'index' not in got: return 'extract'
        if 'index' in got and 'data' not in got: return 'address'
        return 'data'

    # ---- LDSM: a run of address shuffles of one source, each matrix (and half) once
    def ldsm_groups(self) -> list[dict[str, Any]]:
        sh, groups = self.sh, []
        cur: dict[str, Any] | None = None
        for s in self.shuffles:
            if s['kind'] != 'ldsm_address': continue
            pat = s['pattern']
            trans = bool(pat and pat[0] == 'ldsm.T')
            mj = (pat[1], pat[2]) if pat else None
            src = s['source'] or ('const:' + s['const'][1] if s['const'] else None)
            if cur is None or mj is None or src != cur['_src'] or trans != cur['transposed'] or mj in cur['_mj']:
                cur = dict(index=len(groups), line=s['line'], address=s['source'] or ('constant' if s['const'] else 'expression'), transposed=trans, shuffles=0,
                           _src=src, _mj=set(), _members=[], _const=s['const'])
                groups.append(cur)
            cur['shuffles'] += 1; cur['_members'].append(s)
            if mj is not None: cur['_mj'].add(mj)
        for g in groups:
            g['matrices'] = len({m for m, _ in g['_mj']}) or g['shuffles']
            g['lanes_evaluated'] = all(s['lanes_evaluated'] for s in g['_members'])
            g['in_loop'] = bool(sh.loop_of.get(g['_members'][0]['var'], 0))
            g['_loads'] = [(w, s['pattern'][1] if s['pattern'] else 0) for s in g['_members'] for w in self.loads_of(s['var'])]
            g['leaves'] = sorted(sh.leaves(g['_src'])) if g['_src'] and not g['_src'].startswith('const:') else ['const'] if g['_const'] else ['other']
            if 'phi' in g['leaves']: g['phi_inputs'] = sorted(sh.phi_inputs(g['_src']))
            self.pitch(g)
        return groups

    def loads_of(self, v: str, depth: int = 6) -> list[str]:
        """The shared-memory reads an LDSM row address reaches: the variables that hold the loaded words"""
        sh, out, frontier, seen = self.sh, [], [v], {v}
        for _ in range(depth):
            nxt = []
            for u in frontier:
                for w in sh.uses.get(u, []):
                    d = sh.defs.get(w)
                    if ':' in w or w in seen or d is None: continue
                    seen.add(w)
                    inner = strip_casts(d)
                    if inner[0] == 'index' and inner[1][0] == 'name' and inner[1][1] in sh.game_arrays: out.append(w)
                    elif self.use_kind(d, u) == 'arith': nxt.append(w)
            frontier = nxt
        return out

    def phi_only(self, g: dict[str, Any]) -> bool:
        """Whether a phi is all that keeps an LDSM's address from stage 1, and the values that phi takes hold nothing that varies in a warp (not the lane, not tid.x): a phi
        the planned uniform-phi extension could prove warp-uniform, if its branches are uniform too, which this does not check"""
        return set(g['leaves']) - self.allowed == {'phi'} and set(g.get('phi_inputs', ())) <= self.sh.uniform_ok | {'phi'}

    def address_tables(self, g: dict[str, Any], phi: bool) -> list[list[list[int]]]:
        """An LDSM's row address in every lane of every warp, in each sample: [sample][warp][lane]"""
        sh = self.sh
        v, node = (None, g['_const']) if g['_const'] is not None else (g['_src'], None)
        if v is None and node is None: raise Refused('no address')
        every = not sh.warp_free(v, node)
        return [sh.lane_tables(v, node, s, every, phi) for s in range(SAMPLES)]

    def pitch(self, g: dict[str, Any]) -> None:
        """The rows' addresses (lanes 8m .. 8m + 7 give matrix m's) in every warp and sample: their pitch, the matrices' bases; for an address held up only by a phi whose
        values hold nothing that varies, also the pitch if that phi is warp-uniform"""
        g.update(pitch=None, why=None, matrix_bases=None, uniform_part_varies=None, row_alignment=None)
        try: g.update(rows(self.address_tables(g, False), g['matrices']))
        except Refused as e: g['why'] = str(e)
        except (RecursionError, OverflowError, KeyError, IndexError, TypeError) as e: g['why'] = 'not evaluated: ' + type(e).__name__
        if g['why'] == 'phi' and self.phi_only(g):
            try: g['pitch_if_phi_uniform'] = rows(self.address_tables(g, True), g['matrices'])['pitch']
            except Refused as e: g['pitch_if_phi_uniform'] = f'not evaluated: {e}'
            except (RecursionError, OverflowError, KeyError, IndexError, TypeError) as e: g['pitch_if_phi_uniform'] = 'not evaluated: ' + type(e).__name__

    def words_elsewhere(self, w: str) -> int:
        """How many uses of a word an LDSM loads lead anywhere but an HMMA's A or B: followed through copies, a transposed word's halves and their join, and MOVM"""
        sh, n = self.sh, 0
        frontier, seen = [w], {w}
        while frontier:
            u = frontier.pop()
            for x in sh.uses.get(u, []):
                if x in seen: continue
                d = sh.defs.get(x)
                if ':' in x or x in sh.multi or d is None: n += 1; continue
                if x in sh.call_set:
                    pos = [k for k, a in enumerate(d[2]) if strip_casts(a) == ('name', u)]
                    if not pos or any(not 2 <= k < 8 for k in pos): n += 1
                    continue
                s = self.shuffle_of.get(x)
                if (s and s['kind'] == 'movm') or (not s and self.carries(d, u)): seen.add(x); frontier.append(x)
                else: n += 1
        return n

    def carries(self, d: Node, u: str) -> bool:
        """Whether d passes u's bits on as an operand word does: a copy, a half taken (extract_bits(u, offset, 16)), a half shifted into place, two halves joined"""
        d, me = strip_casts(d), ('name', u)
        if d == me: return True
        if d[0] == 'call' and callee_name(d) == 'extract_bits' and len(d[2]) == 3: return strip_casts(d[2][0]) == me and u not in self.sh.refs(d[2][1]) | self.sh.refs(d[2][2])
        if d[0] == 'bin' and d[1] == '<<': return strip_casts(d[2]) == me and u not in self.sh.refs(d[3])
        if d[0] == 'bin' and d[1] == '|': return me in (strip_casts(d[2]), strip_casts(d[3]))
        return False

    # ---- HMMA calls: where their operands come from and what uses their results
    def hmma(self, k: int, v: str) -> dict[str, Any]:
        sh = self.sh
        d = sh.defs[v]
        assert d is not None
        ops, groups = {}, {}
        for nm, a in zip(('A0', 'A1', 'A2', 'A3', 'B0', 'B1', 'C0', 'C1'), d[2][2:10]):
            self._steps = 0
            label, grp = self.provenance(a, 0, frozenset())
            ops[nm] = label
            if grp: groups[nm] = grp
        form = sh.form[v]
        flags = sh.const_arg(v, form['flags']) if form['flags'] is not None else None
        # a library's 19-argument call: hmma_msl's signature did not match and left the helper as the translator wrote it, whose body reads every operand from the registers
        # lane by lane and no flag; its paths are not upstream's
        kind = 'unflagged' if form['flags'] is None else 'not rewritten' if self.library and form['direct'] is None else 'flagged'
        return dict(index=k, line=sh.line_of[v], in_loop=bool(sh.loop_of.get(v, 0)), loop=sh.loop_of.get(v, 0), operands=ops, d_uses=self.d_uses(v, sh.arg_name(v, form['d1'])),
                    form=kind, flags=flags, **self.paths(None if kind == 'not rewritten' else flags), _groups=groups)

    def paths(self, flags: int | None) -> dict[str, Any]:
        """The path each operand takes in dmsh_build.py's HMMA_BODY under a call's TensorPass flags: A kept from the call before, loaded where its LDSM read it (direct,
        perhaps transposed) or through the scratch; C from an accumulator slot, zero (a multiply) or through the scratch; D left in its slot or back through the scratch; B
        through the scratch always. None without flags (a library built before them, whose body takes every operand through the scratch)"""
        if flags is None: return dict(paths=None, slot=None)
        if flags & FLAG_A_REUSE: a = 'kept'
        elif flags & FLAG_A_DIRECT and self.sh.direct_a: a = 'direct, transposed' if flags & FLAG_A_TRANS else 'direct'
        else: a = 'scratch'
        c = 'zero' if flags & FLAG_C_ZERO else 'slot' if flags & FLAG_C_SLOT else 'scratch'
        return dict(paths=dict(A=a, B='scratch', C=c, D='slot' if flags & FLAG_D_SLOT else 'scratch'), slot=flags >> 8 if flags & (FLAG_C_SLOT | FLAG_D_SLOT) else None)

    def provenance(self, node: Node, depth: int, seen: frozenset[str]) -> tuple[str, list[tuple[int, int, str]]]:
        """What an HMMA operand is, and the LDSM words it comes from: [(LDSM, matrix, load variable)]"""
        sh = self.sh
        node = strip_casts(node)
        if node[0] == 'num':
            try: return ('zero' if num_value(node[1])[1] == 0 else 'const'), []
            except Refused: return 'const', []
        if node[0] != 'name': return self.provenance_expr(node, depth, seen)
        v = node[1]
        if v in self.d_of: return self.d_of[v], []
        self._steps += 1
        if depth > 24 or self._steps > 5000: return 'deep', []   # phis of phis: a bound, not an answer
        if not seen and v in self._prov: return self._prov[v]
        r = self.provenance_name(v, depth, seen)
        if v not in sh.multi and not seen and 'deep' not in r[0]: self._prov[v] = r
        return r

    def provenance_name(self, v: str, depth: int, seen: frozenset[str] = frozenset()) -> tuple[str, list[tuple[int, int, str]]]:
        sh = self.sh
        if v in sh.multi:
            if v in seen: return '', []
            labels: set[str] = set()
            groups: list[tuple[int, int, str]] = []
            for e in [*sh.assigns.get(v, []), sh.defs.get(v)]:
                if e is None: continue
                lab, gr = self.provenance(e, depth + 1, seen | {v})
                if lab: labels.add(lab)
                groups += gr
            if len(sh.assigns.get(v, [])) != sum(1 for e in sh.assigns.get(v, []) if e is not None): labels.add('other')
            return 'phi(' + '|'.join(sorted(labels)) + ')', groups
        if v in self.word_of:
            g, m = self.word_of[v]
            return 'ldsm', [(g, m, v)]
        d = sh.defs.get(v)
        if d is None: return 'param', []
        return self.provenance_expr(d, depth + 1, seen)

    def half_of(self, part: Node) -> str | None:
        """The variable whose 16 bits a half of a joined word was taken from: x in extract_bits(x, ...) behind copies and a shift"""
        sh = self.sh
        p = strip_casts(part)
        for _ in range(4):
            if p[0] == 'bin' and p[1] == '<<': p = strip_casts(p[2])
            elif p[0] == 'name' and p[1] not in sh.multi and (d := sh.defs.get(p[1])) is not None: p = strip_casts(d)
            else: break
        if p[0] == 'call' and callee_name(p) == 'extract_bits' and len(p[2]) == 3:
            x = strip_casts(p[2][0])
            if x[0] == 'name': return x[1]
        return None

    def provenance_expr(self, d: Node, depth: int, seen: frozenset[str]) -> tuple[str, list[tuple[int, int, str]]]:
        sh = self.sh
        d = strip_casts(d)
        if d[0] in ('name', 'num'): return self.provenance(d, depth, seen)
        if d[0] == 'index' and d[1][0] == 'name' and d[1][1] in sh.game_arrays: return 'lds', []
        if d[0] == 'bin' and d[1] == '|':   # two halves joined: an LDSM.T word, or a MOVM result
            halves = [self.half_of(d[2]), self.half_of(d[3])]
            if all(halves):
                srcs: set[str] = set()
                groups: list[tuple[int, int, str]] = []
                for x in halves:
                    assert x is not None
                    s = self.shuffle_of.get(x)
                    if x in self.word_of:
                        g, m = self.word_of[x]
                        srcs.add('ldsm.T'); groups.append((g, m, x))
                    elif s and s['kind'] == 'movm' and s['source']:
                        lab, gr = self.provenance(('name', s['source']), depth + 1, seen)
                        srcs.add(f'movm({lab})'); groups += gr
                    else: srcs.add('other')
                return '|'.join(sorted(srcs)), groups
        return 'other', []

    def d_uses(self, v: str, d1: str | None) -> dict[str, int]:
        """What reads D0 and D1, behind copies: hmma.C (C of an HMMA), hmma.AB, movm, shuffle, store, phi, other"""
        sh, uses = self.sh, collections.Counter()
        for d in (v, d1):
            if not d: continue
            frontier, seen = [d], {d}
            while frontier:
                u = frontier.pop()
                for w in sh.uses.get(u, []):
                    if w.startswith('store:'): uses['store'] += 1; continue
                    if w.startswith('ctl:'): uses['other'] += 1; continue
                    if w in sh.multi: uses['phi'] += 1; continue
                    if w in self.shuffle_of: uses['movm' if self.shuffle_of[w]['kind'] == 'movm' else 'shuffle'] += 1; continue
                    dd = sh.defs.get(w)
                    if dd is None: uses['other'] += 1; continue
                    if strip_casts(dd) == ('name', u):   # a copy: follow it
                        if w not in seen: seen.add(w); frontier.append(w)
                        continue
                    if w in sh.call_set:
                        pos = [k for k, a in enumerate(dd[2]) if strip_casts(a) == ('name', u) and k != sh.form[w]['d1']]   # D1, the out parameter, is written there, not read
                        if pos: uses['hmma.C' if any(p in (8, 9) for p in pos) else 'hmma.AB' if any(2 <= p < 8 for p in pos) else 'other'] += 1
                        continue
                    uses['other'] += 1
        return dict(uses)

    # ---- the stages
    def window(self, load_lines: list[int], call_line: int) -> str:
        """'clean', or the first thing between an LDSM's loads and the HMMA they feed that stage 3 cannot move a read across"""
        if not load_lines: return 'no load'
        start = min(load_lines)
        if start > call_line: return 'load after the call'
        for line, kind in self.sh.stmts:
            if start < line < call_line and kind in BLOCKING: return kind
        return 'clean'

    def between(self, first: int, last: int) -> set[str]:
        """Every kind of statement strictly between two lines that a tile's window must not hold"""
        if self._blocking is None:
            self._blocking = sorted((line, kind) for line, kind in self.sh.stmts if kind in BLOCKING)
            self._blocking_lines = [line for line, _ in self._blocking]
        return {kind for _, kind in self._blocking[bisect.bisect_right(self._blocking_lines, first):bisect.bisect_left(self._blocking_lines, last)]}

    def reads_a(self, call: str) -> bool:
        """Whether a call's body reads its A registers: not when A is kept or loaded where its LDSM read it"""
        p = self.hmma_of[call]['paths']
        return p is None or p['A'] == 'scratch'

    def word_dropped(self, w: str) -> bool:
        """Whether a word an LDSM loads goes only, behind copies and a transposed word's halves, to A of calls whose body does not read A. The helper is inlined and its flags
        are constants there, so the Metal compiler drops that word's load and address shuffle (TensorPass.cs); the Metal text still holds them"""
        sh, reached = self.sh, False
        frontier, seen = [w], {w}
        while frontier:
            u = frontier.pop()
            for x in sh.uses.get(u, []):
                if x in seen: continue
                d = sh.defs.get(x)
                if ':' in x or x in sh.multi or d is None: return False
                if x in sh.call_set:
                    pos = [k for k, a in enumerate(d[2]) if strip_casts(a) == ('name', u)]
                    if not pos or any(not 2 <= k < 6 for k in pos) or self.reads_a(x): return False
                    reached = True; continue
                if x in self.shuffle_of or not self.carries(d, u): return False
                seen.add(x); frontier.append(x)
        return reached

    def after_block(self, h: dict[str, Any]) -> bool:
        """Whether a flagged call is in another block of the translator's IR than the call before it: TensorPass keeps A (FlagAReuse) whenever the call before it in the
        same block has the same A, and this one did not. spirv-cross writes blocks that follow each other as one run of statements, so the Metal text may not show it"""
        if not h['index'] or h['flags'] & FLAG_A_REUSE: return False
        call, prev = self.sh.calls[h['index']], self.sh.calls[h['index'] - 1]
        a, b = self.sh.defs[call], self.sh.defs[prev]
        return a is not None and b is not None and all(self.sh.copy_root(a[2][k]) == self.sh.copy_root(b[2][k]) for k in range(2, 6))

    def a_why(self, h: dict[str, Any]) -> str:
        """Why a flagged call's A goes through the scratch: what TensorPass's FlagADirect needs (A four matrices of one LDSM of the block, no shared memory write, atomic,
        barrier or call between, rows U + f(lane) strided) or hmma_msl (one shared memory array) that the census sees missing"""
        if h['flags'] & FLAG_A_DIRECT: return 'direct A off in the shader'   # hmma_msl found no one shared memory array besides the scratch
        refs = [h['_groups'].get(f'A{k}', []) for k in range(4)]
        groups = {gi for r in refs for gi, _, _ in r}
        if len(groups) != 1 or any(h['operands'][f'A{k}'] not in ('ldsm', 'ldsm.T') for k in range(4)): return 'not one LDSM'
        g = self.groups[groups.pop()]
        lines = [self.sh.line_of.get(w, 0) for r in refs for _, _, w in r]
        kinds = self.between(min(lines), h['line']) if lines and min(lines) < h['line'] else {'block'}
        if 'block' in kinds or self.after_block(h): return 'its LDSM in another block'
        if kinds & {'shared store', 'atomic', 'barrier', 'fence', 'call'}: return 'behind a shared store, atomic, barrier or call'
        if 'other' in kinds: return 'a statement the census does not read in between'
        # the translator did not prove the rows U + f(lane) strided, or the LDSM is in another block of its IR that the Metal text does not show (DMSH_TENSOR_TRACE=1 tells)
        return 'nothing seen in between' + ('; the census finds one pitch' if g['lane_function'] and not pitch_why(g['pitch']) else '')

    def acc_why(self, h: dict[str, Any]) -> str | None:
        """For a flagged call that takes C through the scratch: why, when that C is an earlier HMMA's D (an accumulator that leaves the SIMD-group's matrices); else None"""
        c0, c1 = h['operands']['C0'], h['operands']['C1']
        if not (from_d(c0) or from_d(c1)): return None
        if c0.startswith('phi(') or c1.startswith('phi('): return 'a phi (a loop, or paths meeting)'
        m0, m1 = re.fullmatch(r'D(\d+)\.(\d)', c0), re.fullmatch(r'D(\d+)\.(\d)', c1)
        if not (m0 and m1 and m0.group(1) == m1.group(1) and (m0.group(2), m1.group(2)) == ('0', '1')): return "C not one HMMA's D in order"
        k = int(m0.group(1))
        p = self.hmmas[k]
        if 'block' in self.between(p['line'], h['line']) or (k == h['index'] - 1 and self.after_block(h)): return 'D of an HMMA in another block'
        if p['d_uses'] != {'hmma.C': 2}: return 'that D is read elsewhere too'
        if p.get('open_before') == SLOTS: return f'all {SLOTS} slots taken'   # TensorPass found no free slot where this chain starts: it goes through the registers
        return 'nothing seen in between'   # another block of the translator's IR that the Metal text does not show

    def verdicts(self) -> None:
        sh = self.sh
        for g in self.groups: g['hmma_uses'], g['_windows'] = 0, collections.Counter()
        for h in self.hmmas:
            h['windows'] = {}
            for op, refs in h['_groups'].items():
                if op[0] not in 'AB': continue
                lines: dict[int, list[int]] = collections.defaultdict(list)
                for gi, _, w in refs: lines[gi].append(sh.line_of.get(w, 0))
                res = set()
                for gi, ls in lines.items():
                    win = self.window(ls, h['line'])
                    self.groups[gi]['hmma_uses'] += 1; self.groups[gi]['_windows'][win] += 1
                    res.add(win)
                h['windows'][op] = ','.join(sorted(res))
        x = sh.local[0] if sh.local else None
        for g in self.groups:
            g['blockers'] = [f'{b} (local size x {x})' if b in ('tid.x', 'tid.y', 'tid.z') else b for b in sorted(set(g['leaves']) - self.allowed)]
            if not g['blockers'] and g['why'] is not None: g['blockers'] = [f"not evaluated: {g['why']}"]   # what the pass could not follow either
            g['lane_function'] = not g['blockers']
            g['words_used_elsewhere'] = sum(1 for w, _ in g['_loads'] if self.words_elsewhere(w))
            rest = []   # what a tile needs besides the address
            if not g['hmma_uses']: rest.append('feeds no HMMA A or B')
            elif g['words_used_elsewhere']: rest.append('words used outside HMMA A / B')   # the LDSM and its shuffles would stay for them
            rest += [f'window: {w}' for w in sorted(g['_windows']) if w != 'clean']
            why = (['not a lane function'] if not g['lane_function'] else []) + pitch_why(g['pitch']) + rest
            g['windows'] = dict(g['_windows'])
            g['tile'], g['tile_why'] = not why, why
            g['tile_if_phi_uniform'] = g['blockers'] == ['phi'] and 'pitch_if_phi_uniform' in g and not pitch_why(g['pitch_if_phi_uniform']) and not rest
            loads = [self.loads_of(s['var']) for s in g['_members']]   # each address shuffle's words: dropped with them
            g['dropped_shuffles'] = sum(1 for ws in loads if ws and all(self.word_dropped(w) for w in ws))
            g['dropped'] = g['dropped_shuffles'] == g['shuffles']
        # The slots in text order (a chain stays in one block, and blocks are not interleaved): a DSlot call opens or keeps its slot (flags >> 8), a CSlot call without DSlot ends
        # its chain. A call with neither while slot 0 is open is in no chain (TensorPass gives slots to chains only) and comes while the first chain of its block holds its sum
        # there: this checkout's body works it in a pair of its own; NXNative's (dm_acc[16]) works it in slot 0's matrices, over that sum, and the chain's end reads it as C
        open_slots: dict[int, int] = {}
        self.shared_pair = self.sh.acc_size == SHARED_PAIR
        for h in self.hmmas:
            if h['paths'] is None: continue
            f = h['flags']
            h['open_before'] = len(open_slots)
            if not f & (FLAG_C_SLOT | FLAG_D_SLOT):
                h['in_no_chain_slot0_open'] = 0 in open_slots
            elif f & FLAG_D_SLOT: open_slots[f >> 8] = h['index']
            else: open_slots.pop(f >> 8, None)
        for h in self.hmmas:
            p = h['paths']
            if p is None: continue
            if p['A'] == 'scratch': h['a_scratch_why'] = self.a_why(h)
            if p['C'] == 'scratch' and (why := self.acc_why(h)): h['acc_scratch_why'] = why
            h['c_from_d'] = from_d(h['operands']['C0']) or from_d(h['operands']['C1'])
            h['b_tile'] = all(h['operands'][op] in ('ldsm', 'ldsm.T') and h['windows'].get(op) == 'clean' and
                              all(self.groups[gi]['lane_function'] and not pitch_why(self.groups[gi]['pitch']) and not self.groups[gi]['words_used_elsewhere']
                                  for gi, _, _ in h['_groups'].get(op, [])) for op in ('B0', 'B1'))

    def report(self) -> dict[str, Any]:
        sh = self.sh
        kinds = collections.Counter(s['kind'] for s in self.shuffles)
        stmt = collections.Counter(k for _, k in sh.stmts)
        live = [g for g in self.groups if not g['dropped']]   # the LDSMs whose per-lane code stays: stage 1's
        st1 = [g for g in live if g['lane_function']]
        tiles = [g for g in self.groups if g['tile']]
        flagged = [h for h in self.hmmas if h['paths'] is not None]
        a_ldsm = [h for h in flagged if h.get('a_scratch_why', 'not one LDSM') != 'not one LDSM']   # A through the scratch from one LDSM's matrices
        in_no_chain = [h for h in flagged if h.get('in_no_chain_slot0_open')]
        over_slot0 = {h['index'] for h in in_no_chain} if self.shared_pair else set()   # the calls that overwrite the sum of the chain open in slot 0
        paths = collections.Counter(f'{op}:{p}' for h in flagged for op, p in h['paths'].items())
        verdict = {
            'stage1': dict(ldsm=len(st1), of=len(live), shuffles=sum(g['shuffles'] - g['dropped_shuffles'] for g in st1),
                           of_shuffles=sum(g['shuffles'] - g['dropped_shuffles'] for g in live), blockers=dict(collections.Counter(b for g in live for b in g['blockers'])),
                           phi_only_uniform_inputs=sum(1 for g in live if g['blockers'] == ['phi'] and self.phi_only(g)),
                           dropped=len(self.groups) - len(live), dropped_shuffles=sum(g['dropped_shuffles'] for g in self.groups)),
            'stage2': dict(hmma=sum(1 for h in self.hmmas if h['operands']['B0'].startswith('movm(') and h['operands']['B1'].startswith('movm(')), of=len(self.hmmas),
                           b_words=sum(1 for h in self.hmmas for op in ('B0', 'B1') if h['operands'][op].startswith('movm(')), of_b_words=2 * len(self.hmmas)),
            'upstream': dict(flagged=len(flagged), unflagged=sum(1 for h in self.hmmas if h['form'] == 'unflagged'),
                             not_rewritten=sum(1 for h in self.hmmas if h['form'] == 'not rewritten'),
                             in_no_chain_slot0_open=len(in_no_chain), slot0_overwritten=len(over_slot0),
                             flags_not_read=sum(1 for h in self.hmmas if h['form'] == 'flagged' and h['flags'] is None), direct_a=sh.direct_a,
                             a_kept=paths['A:kept'], a_direct=paths['A:direct'] + paths['A:direct, transposed'], a_direct_transposed=paths['A:direct, transposed'],
                             a_scratch=paths['A:scratch'], c_slot=paths['C:slot'], c_zero=paths['C:zero'], c_scratch=paths['C:scratch'], d_slot=paths['D:slot'],
                             d_scratch=paths['D:scratch'], b_scratch=paths['B:scratch'],
                             served=sum(1 for h in flagged if h['paths']['A'] != 'scratch' and h['paths']['C'] != 'scratch' and h['index'] not in over_slot0)),
            'stage3': dict(known=len(flagged) == len(self.hmmas), hmma=len(flagged),
                           a=len(a_ldsm), a_why=dict(collections.Counter(h['a_scratch_why'] for h in a_ldsm)),
                           a_not_ldsm=sum(1 for h in flagged if h.get('a_scratch_why') == 'not one LDSM'),
                           acc=sum(1 for h in flagged if 'acc_scratch_why' in h), of_acc=sum(1 for h in flagged if h['c_from_d']),
                           acc_why=dict(collections.Counter(h['acc_scratch_why'] for h in flagged if 'acc_scratch_why' in h)),
                           b=sum(1 for h in flagged if h['b_tile']), b_from_ldsm=sum(1 for h in flagged if all(h['operands'][op] in ('ldsm', 'ldsm.T') for op in ('B0', 'B1')))),
            'tiles': dict(ldsm=len(tiles), of=len(self.groups), why_not=dict(collections.Counter(w for g in self.groups for w in g['tile_why'])),
                          if_phi_uniform=sum(1 for g in self.groups if g['tile_if_phi_uniform'])),
        }
        rep: dict[str, Any] = dict(
            census=FORMAT, shader=self.name, local_size=sh.local, lines=sh.lines,
            arrays={a: dict(type=t, count=n, bytes=WORD_BYTES.get(t, 4) * n, role='hmma scratch' if a in sh.scratch else 'shared') for a, (t, n) in sh.arrays.items()},
            shuffles=dict(total=len(self.shuffles), **{k: kinds.get(k, 0) for k in ('ldsm_address', 'movm', 'hmma_lane', 'redux_match', 'other')}),
            counts=dict(ldsm=len(self.groups), hmma=len(self.hmmas), hmma_in_loops=sum(1 for h in self.hmmas if h['in_loop']), barriers=stmt.get('barrier', 0),
                        simdgroup_barriers=stmt.get('simdgroup barrier', 0), shared_stores=stmt.get('shared store', 0),
                        atomics=stmt.get('atomic', 0) + stmt.get('device atomic', 0), shared_atomics=stmt.get('atomic', 0),
                        device_stores=stmt.get('device store', 0), texture_writes=stmt.get('texture write', 0), hmma_unread=sh.unread_calls),
            operand_sources=dict(sorted(collections.Counter(f'{op[0]}:{D_LABEL.sub("D", lab)}' for h in self.hmmas for op, lab in h['operands'].items()).items())),
            direct_a=sh.direct_a_how if sh.direct_a is not None else None,
            verdict=verdict,
            ldsm=[{k: v for k, v in g.items() if not k.startswith('_')} for g in self.groups],
            hmma=[{k: v for k, v in h.items() if not k.startswith('_')} for h in self.hmmas])
        rep['text'] = summary_lines(rep)
        return rep


def tally(c: dict[str, int], limit: int = 8) -> str:
    items = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))
    if not items: return 'none'
    return ', '.join(f'{k} {n}' for k, n in items[:limit]) + (f', {len(items) - limit} more' if len(items) > limit else '')


def summary_lines(rep: dict[str, Any]) -> list[str]:
    s, c, v = rep['shuffles'], rep['counts'], rep['verdict']
    local = 'x'.join(map(str, rep['local_size'])) if rep['local_size'] else 'unknown (x taken as a multiple of 32)'
    out = [f"{rep['shader'] or 'shader'}: {rep['lines']} lines, local size {local}",
           f"  shuffles {s['total']}: LDSM row address {s['ldsm_address']}, MOVM {s['movm']}, per-lane HMMA {s['hmma_lane']}, REDUX / MATCH {s['redux_match']}, other {s['other']}"]
    groups = rep['ldsm']
    if groups:
        plain = sum(1 for g in groups if not g['transposed'])
        out.append(f"  LDSM {len(groups)}: {plain} plain, {len(groups) - plain} transposed; {sum(g['matrices'] for g in groups)} matrices; {sum(1 for g in groups if g['in_loop'])} in a loop")
        out.append('    leaves: ' + tally(collections.Counter('+'.join(g['leaves']) for g in groups)))
        out.append('    pitch: ' + tally(collections.Counter(str(g['pitch']) if g['pitch'] is not None else f"not evaluated ({g['why']})" for g in groups)))
    out.append(f"  HMMA {c['hmma']} ({c['hmma_in_loops']} in a loop); barriers {c['barriers']}, shared stores {c['shared_stores']}, atomics {c['atomics']}")
    for k in 'ABC':
        part = {src[2:]: n for src, n in rep['operand_sources'].items() if src[0] == k}
        if part: out.append(f'    {k}: ' + tally(part))
    if rep['hmma']:
        du: collections.Counter[str] = collections.Counter()
        for h in rep['hmma']: du.update(h['d_uses'])
        out.append('    D read by: ' + tally(du))
    if c.get('hmma_unread'):
        out.append(f"  [RED] {c['hmma_unread']} calls of {HMMA_NAME} in a form the census does not read (not 12, 19, 21 or 22 arguments): left out of every count")
    return out + verdict_lines(v, c['hmma'])


def slot0_lines(up: dict[str, Any]) -> list[str]:
    """The calls in no chain that come while a chain is open in slot 0: a [RED] line where the body works them in slot 0's matrices"""
    if up.get('slot0_overwritten'):
        return [f"  [RED] {up['slot0_overwritten']} calls in no chain work in slot 0's matrices while a chain keeps its sum there (NXNative's body, dm_acc[{SHARED_PAIR}]): that "
                "chain's end reads a wrong C. Build with this checkout, whose body gives such a call a pair of its own"]
    if up.get('in_no_chain_slot0_open'):
        return [f"    {up['in_no_chain_slot0_open']} calls in no chain come while a chain is open in slot 0: each works in a pair of its own"]
    return []


def verdict_lines(v: dict[str, Any], hmma: int) -> list[str]:
    """Upstream's paths and the stage verdicts, of one shader or of the totals (whose stage 1 has no blockers)"""
    up, s1, s2, s3, ti = v['upstream'], v['stage1'], v['stage2'], v['stage3'], v['tiles']
    out = []
    if up.get('not_rewritten'):
        out.append(f"  [RED] {up['not_rewritten']} calls of the translator's 19 arguments in a library: hmma_msl did not rewrite the helper, so the translator's per-lane body runs "
                   "and their flags are unused: left out of upstream's paths")
    if up['flagged']:
        out.append(f"  upstream's paths (TensorPass's flags): {up['served']} of {up['flagged']} HMMAs take neither A nor C through the scratch (B goes through it in every call)"
                   + (f"; {up['unflagged'] + up['flags_not_read']} more without flags it reads" if up['unflagged'] + up['flags_not_read'] else ''))
        out.append(f"    A kept {up['a_kept']}, loaded where its LDSM read it {up['a_direct']} ({up['a_direct_transposed']} transposed), through the scratch {up['a_scratch']}; "
                   f"C from a slot {up['c_slot']}, zero {up['c_zero']}, through the scratch {up['c_scratch']}; D left in a slot {up['d_slot']}, through the scratch {up['d_scratch']}"
                   + ('; direct A on' if up['direct_a'] else '; direct A off: not one shared memory array besides the scratch'))
        out += slot0_lines(up)
    elif up['unflagged'] or up['flags_not_read']:
        out.append(f"  upstream's paths: none known: {up['unflagged'] + up['flags_not_read']} HMMA calls without TensorPass's flags (a library built before them takes every operand "
                   "through the scratch); build with this checkout and run the census again")
    out.append(f"  stage 1 (row addresses per lane): {s1['ldsm']} of {s1['of']} LDSMs still read lane by lane, {s1['shuffles']} of {s1['of_shuffles']} address shuffles"
               + (f"; blocked by {tally(s1['blockers'])}" if s1.get('blockers') else '')
               + (f"; {s1['phi_only_uniform_inputs']} blocked by a phi alone whose values have no varying leaf" if s1['phi_only_uniform_inputs'] else '')
               + (f"; the Metal compiler drops {s1['dropped_shuffles']} more address shuffles ({s1['dropped']} whole LDSM{'s' * (s1['dropped'] != 1)}): their words "
                  "go only to calls that load A themselves" if s1['dropped_shuffles'] else ''))
    out.append(f"  stage 2 (MOVM into B): {s2['hmma']} of {s2['of']} HMMAs take both B words from MOVM ({s2['b_words']} of {s2['of_b_words']} B words)")
    if not hmma: out.append('  stage 3 (what upstream does not cover): no HMMA')
    elif not s3['hmma']: out.append("  stage 3 (what upstream does not cover): not known without TensorPass's flags")
    else:
        out.append(f"  stage 3 (what upstream does not cover, of {s3['hmma']} HMMAs with flags{'' if s3['hmma'] == hmma else f' of {hmma}'}): "
                   f"A through the scratch from an LDSM {s3['a']}" + (f" ({tally(s3['a_why'])})" if s3['a_why'] else '')
                   + (f", {s3['a_not_ldsm']} more not from one LDSM" if s3['a_not_ldsm'] else '')
                   + f"; accumulators through the scratch {s3['acc']} of the {s3['of_acc']} whose C is an earlier D" + (f" ({tally(s3['acc_why'])})" if s3['acc_why'] else '')
                   + f"; B as tiles {s3['b']} of the {s3['b_from_ldsm']} whose B words both come from an LDSM ({B_NOTE})")
    out.append(f"  tiles (LDSM rows one pitch apart, nothing between them and the HMMA): {ti['ldsm']} of {ti['of']} LDSMs" + (f"; not: {tally(ti['why_not'])}" if ti.get('why_not') else '')
               + (f"; {ti['if_phi_uniform']} more if their phi is warp-uniform" if ti['if_phi_uniform'] else ''))
    return out


# ---- a library: every shader that defines the HMMA helper --------------------------------------------------------------------------------------------------------------------
LIB_NAME = re.compile(r'b-[0-9a-f]{12}$')


def this_chain() -> str | None:
    try: m = re.search(r'#define DMSH_CHAIN "([0-9a-f]{12})"', (REPO / 'dm/gfx/nvn/dmsh_chain.h').read_text())
    except OSError: return None
    return m.group(1) if m else None


def find_library(given: str) -> tuple[str, str]:
    """(the library, how it was chosen), from a library or a folder that holds one"""
    p = Path(os.path.expanduser(given)).resolve()
    if LIB_NAME.match(Path(shader_lib.folder_of(str(p))).name):
        lib = shader_lib.folder_of(str(p))
        if not shader_lib.exists(lib): raise SystemExit(f'[RED] no shader library at {p}')
        return lib, 'as given'
    names: set[Path] = set()
    for d in (p, p / 'cache', p / 'shader' / 'cache', p / 'partial', p / 'shader' / 'partial'):   # every one: an older chain in cache/ must not hide this one's in partial/
        if d.is_dir(): names |= {Path(shader_lib.folder_of(str(x))) for x in d.iterdir()}
    found = sorted(x for x in names if LIB_NAME.match(x.name) and shader_lib.exists(str(x)))
    if not found: raise SystemExit(f'[RED] no shader library (b-<chain>, a folder or its .img) in {p}, its cache/ or partial/, or its shader/cache/ or shader/partial/')
    chain = this_chain()

    def mtime(x: Path) -> float:
        for q in (Path(shader_lib.image_of(str(x))), x):
            try: return q.stat().st_mtime
            except OSError: continue
        return 0.0
    mine = [x for x in found if x.name == f'b-{chain}']
    if mine: return str(max(mine, key=mtime)), f"this checkout's chain, {chain}" + (f' (the newest of {len(mine)})' if len(mine) > 1 else '')
    if len(found) == 1: return str(found[0]), f'the only library there; this checkout builds b-{chain}'
    return str(max(found, key=mtime)), f"the newest of {', '.join(x.name for x in found)}; this checkout builds b-{chain}"


def inside(path: Path, root: Path) -> bool:
    try: path.resolve().relative_to(root.resolve())
    except ValueError: return False
    return True


DEFINES_HMMA = re.compile(rb'\n\w+ ' + HMMA_NAME.encode() + rb'\(')
SHUFFLE_HELPER = b'spvSubgroupShuffle('   # spirv-cross defines it before the kernel only for a shader that shuffles
TENSOR_KINDS = ('ldsm_address', 'movm', 'hmma_lane')   # the shuffles of the translator's LDSM, MOVM and per-lane HMMA


def head_of(p: Any) -> bytes:
    """A source up to its kernel function: the helpers spirv-cross and the translator define before it"""
    buf = b''
    with p.open('rb') as f:
        while chunk := f.read(1 << 16):
            start = max(0, len(buf) - 16)
            buf += chunk
            k = buf.find(b'kernel void', start)
            if k >= 0: return buf[:k]
    return buf


def scan(lib: str, say: Callable[[str], None]) -> tuple[int, list[str], list[str]]:
    """(the number of <key>_b.metal sources in the library; the keys of those that define the HMMA helper; the keys of the others that shuffle), from the text before each
    kernel"""
    paths = sorted(shader_lib.view(lib).glob('*_b.metal'), key=lambda q: q.name)
    hmma, shuffling = [], []
    for i, p in enumerate(paths, 1):
        head, key = head_of(p), p.name[:-len('_b.metal')]
        if DEFINES_HMMA.search(head): hmma.append(key)
        elif SHUFFLE_HELPER in head: shuffling.append(key)
        if i % 5000 == 0 and i < len(paths): say(f'  read {i} of {len(paths)} sources')
    return len(paths), hmma, shuffling


def reflection(lib: str, key: str) -> dict[str, Any]:
    try: r = json.loads((shader_lib.view(lib) / f'{key}_b.json').read_text())
    except (OSError, ValueError): return {}
    return r if isinstance(r, dict) else {}


def census_of(src: str, local: Any, key: str, library: bool = False) -> dict[str, Any]:
    try: return Census(src, local if isinstance(local, list) else None, key, library).report()
    except (ValueError, RecursionError, KeyError, IndexError, TypeError, AttributeError, AssertionError) as e:   # one shader the reader does not take stops nothing else
        return dict(census=FORMAT, shader=key, error=type(e).__name__, text=[f'{key}: [RED] not read ({type(e).__name__})'])


def source_file(source: Any) -> str:
    """The file a shader came from, as its reflection's source names it (the shader map's column 5): its last two path parts, without the record"""
    return '/'.join([p for p in str(source).split('#', 1)[0].split('/') if p][-2:]) if source else 'unknown'


def one_line(rep: dict[str, Any]) -> str:
    if rep.get('error'): return rep['text'][0]
    c, v = rep['counts'], rep['verdict']
    up, s1, s3 = v['upstream'], v['stage1'], v['stage3']
    where = source_file(rep.get('source')) + ('' if rep.get('helper', True) else f'; no {HMMA_NAME}')
    return (f"{rep['shader']} ({where}): LDSM {c['ldsm']}, HMMA {c['hmma']}, shuffles {rep['shuffles']['total']}; "
            + (f"upstream {up['served']}/{up['flagged']}; " if up['flagged'] else 'no flags; ' if up['unflagged'] + up['flags_not_read'] else '')
            + f"stage 1 {s1['ldsm']}/{s1['of']}" + (f" (+{s1['dropped']} dropped)" if s1['dropped'] else '') + f", stage 2 {v['stage2']['hmma']}/{v['stage2']['of']}"
            + (f", stage 3 A {s3['a']}, acc {s3['acc']}, B {s3['b']}" if s3['hmma'] else '')
            + (f"; [RED] {up['slot0_overwritten']} over slot 0's chain" if up.get('slot0_overwritten') else '')
            + (f"; [RED] {up['not_rewritten']} not rewritten" if up.get('not_rewritten') else ''))


TOTALS = (('stage1', ('ldsm', 'of', 'shuffles', 'of_shuffles', 'phi_only_uniform_inputs', 'dropped', 'dropped_shuffles')), ('stage2', ('hmma', 'of', 'b_words', 'of_b_words')),
          ('upstream', ('flagged', 'unflagged', 'flags_not_read', 'not_rewritten', 'a_kept', 'a_direct', 'a_direct_transposed', 'a_scratch', 'c_slot', 'c_zero', 'c_scratch',
                        'd_slot', 'd_scratch', 'b_scratch', 'served', 'in_no_chain_slot0_open', 'slot0_overwritten')),
          ('stage3', ('hmma', 'a', 'a_why', 'a_not_ldsm', 'acc', 'of_acc', 'acc_why', 'b', 'b_from_ldsm')), ('tiles', ('ldsm', 'of', 'if_phi_uniform')))


def totals(reps: list[dict[str, Any]]) -> dict[str, Any]:
    t: dict[str, Any] = dict(shaders=len(reps), not_read=sum(1 for r in reps if r.get('error')))
    for part, keys in (('shuffles', ('total', 'ldsm_address', 'movm', 'hmma_lane', 'redux_match', 'other')),
                       ('counts', ('ldsm', 'hmma', 'hmma_in_loops', 'barriers', 'shared_stores', 'hmma_unread'))):
        t[part] = {k: sum(r.get(part, {}).get(k, 0) for r in reps) for k in keys}
    for st, keys in TOTALS:
        t[st] = {}
        for k in keys:
            vals = [r.get('verdict', {}).get(st, {}).get(k, 0) for r in reps]
            if k.endswith('_why'):   # the reasons, counted over every shader
                why: collections.Counter[str] = collections.Counter()
                for x in vals: why.update(x or {})
                t[st][k] = dict(why)
            else: t[st][k] = sum(vals)
    return t


def totals_lines(t: dict[str, Any]) -> list[str]:
    s, c, s1, up, s3, ti = t['shuffles'], t['counts'], t['stage1'], t['upstream'], t['stage3'], t['tiles']
    out = [f"  in all: {s['total']} shuffles (LDSM row address {s['ldsm_address']}, MOVM {s['movm']}, per-lane HMMA {s['hmma_lane']}, REDUX / MATCH {s['redux_match']}, other {s['other']}), "
           f"{c['ldsm']} LDSMs, {c['hmma']} HMMAs" + (f"; {t['not_read']} shaders not read" if t['not_read'] else '')
           + (f"; [RED] {c['hmma_unread']} HMMA calls in a form the census does not read" if c['hmma_unread'] else '')]
    if up['flagged']:
        out.append(f"  upstream's paths: {up['served']} of {up['flagged']} HMMAs with TensorPass's flags take neither A nor C through the scratch (A kept {up['a_kept']}, "
                   f"where its LDSM read it {up['a_direct']}, through the scratch {up['a_scratch']}; C from a slot {up['c_slot']}, zero {up['c_zero']}, through the scratch "
                   f"{up['c_scratch']}; D left in a slot {up['d_slot']})")
        out += slot0_lines(up)
    if up['not_rewritten']:
        out.append(f"  [RED] {up['not_rewritten']} HMMA calls of the translator's 19 arguments: hmma_msl did not rewrite their helper, so its per-lane body runs and the flags are unused")
    if up['unflagged'] + up['flags_not_read']: out.append(f"  {up['unflagged'] + up['flags_not_read']} HMMAs without TensorPass's flags: upstream's paths and stage 3 not known for them")
    out.append(f"  stage 1: {s1['ldsm']} of {s1['of']} LDSMs still read lane by lane ({s1['shuffles']} of {s1['of_shuffles']} address shuffles"
               + (f"; {s1['phi_only_uniform_inputs']} held up by a phi alone whose values have no varying leaf" if s1['phi_only_uniform_inputs'] else '')
               + (f"; the Metal compiler drops {s1['dropped_shuffles']} more, {s1['dropped']} whole LDSM{'s' * (s1['dropped'] != 1)}" if s1['dropped_shuffles'] else '') + '); '
               f"stage 2: {t['stage2']['hmma']} of {t['stage2']['of']} HMMAs; "
               + (f"stage 3 (of {s3['hmma']} HMMAs with flags): A through the scratch from an LDSM {s3['a']}" + (f" ({tally(s3['a_why'])})" if s3['a_why'] else '')
                  + f", accumulators through the scratch {s3['acc']} of {s3['of_acc']}" + (f" ({tally(s3['acc_why'])})" if s3['acc_why'] else '')
                  + f", B as tiles {s3['b']} of {s3['b_from_ldsm']}; " if s3['hmma'] else '')
               + f"tiles: {ti['ldsm']} of {ti['of']} LDSMs" + (f" ({ti['if_phi_uniform']} more if their phi is warp-uniform)" if ti['if_phi_uniform'] else ''))
    return out


def census_entry(lib: str, key: str, data: bytes, chain: str, helper: bool) -> dict[str, Any]:
    refl = reflection(lib, key)
    rep = census_of(data.decode('utf-8', 'replace'), refl.get('threadgroup_size'), key, library=True)
    text = rep.pop('text')
    rep.update(helper=helper, source=refl.get('source'), chain=refl.get('chain') or chain, text=text)   # the summary stays last
    return rep


def run_library(given: str, out_arg: str | None, keep_metal: bool) -> int:
    lib, how = find_library(given)
    name, chain = Path(lib).name, this_chain()
    out = Path(os.path.expanduser(out_arg)).resolve() if out_arg else Path(lib).parent / f'tensor_census-{name[2:]}'
    if inside(out, REPO): raise SystemExit(f"[RED] {out} is inside this repository: a census of a game's shaders goes beside its library or in the game's work folder (--out)")
    if inside(out, Path(lib)): raise SystemExit(f'[RED] {out} is inside the library {lib}, which holds only its own files')
    print(f'library {lib} ({how})')
    total, hmma_keys, shuffling = scan(lib, print)
    print(f'{total} sources: {len(hmma_keys)} define {HMMA_NAME}; of the others, {len(shuffling)} shuffle')
    out.mkdir(parents=True, exist_ok=True)
    view = shader_lib.view(lib)
    reps: list[dict[str, Any]] = []
    others: list[dict[str, Any]] = []   # no helper, but LDSM, MOVM or per-lane HMMA shuffles: an F32 accumulator, m16n8k8, LDSM alone, or a library from before the helper
    unread: list[str] = []   # of those that shuffle without the helper, the ones the reader did not take
    for k, key in enumerate(hmma_keys + shuffling):
        helper = k < len(hmma_keys)
        if not helper and (k - len(hmma_keys)) % 200 == 199: print(f'  read {k - len(hmma_keys) + 1} of the {len(shuffling)} that shuffle')
        data = (view / f'{key}_b.metal').read_bytes()
        rep = census_entry(lib, key, data, name[2:], helper)
        if not helper and rep.get('error'): unread.append(key); continue   # whether it has any is not known: counted, not listed
        if not helper and not any(rep['shuffles'].get(x) for x in TENSOR_KINDS): continue   # the game's own shuffles only
        (out / f'{key}.census').write_text(json.dumps(rep, indent=1) + '\n')
        if keep_metal: (out / f'{key}.metal').write_bytes(data)
        (reps if helper else others).append(rep)
        print(one_line(rep))
    every = reps + others
    files = sorted({source_file(r.get('source')) for r in every})
    by_file = {f: totals([r for r in every if source_file(r.get('source')) == f]) for f in files}
    t, t_others = totals(reps), totals(others)
    summary = dict(census=FORMAT, library=name, chosen=how, this_chain=chain, metal_sources=total, hmma_shaders=len(reps), shuffling_shaders=len(shuffling),
                   tensor_shaders_without_helper=len(others), shuffling_not_read=unread, totals=t, totals_without_helper=t_others, by_file=by_file,
                   shaders=[{k: r.get(k) for k in ('shader', 'helper', 'source', 'local_size', 'shuffles', 'counts', 'verdict', 'error')} for r in every])
    head = [f'{name}: {len(reps)} of {total} shaders define {HMMA_NAME}; {len(others)} of the {len(shuffling)} others that shuffle have LDSM, MOVM or per-lane HMMA shuffles'
            + (f' ([RED] {len(unread)} of them not read)' if unread else '')]
    if reps: head += totals_lines(t)
    if t['upstream']['unflagged']:   # which call form a library has follows from its chain: this checkout's translator gives every call its flags
        head.append(f"  [RED] {t['upstream']['unflagged']} HMMA calls without TensorPass's flags in a library of this checkout's chain, whose translator gives every call its flags"
                    if name == f'b-{chain}' else
                    f"  a library of chain {name[2:]}, not this checkout's {chain}, built before TensorPass's flags: upstream's paths and stage 3 are not known for it. Build the "
                    'game with this checkout (scripts/build_ipa_from_nsp.py) and run the census again')
    if others: head += [f'without {HMMA_NAME}:'] + totals_lines(t_others)
    if not reps:
        if name == f'b-{chain}':
            head.append("  this checkout's chain: none of the game's HMMAs is HMMA.16816 with an f16 accumulator in a compute shader, the only one the helper takes"
                        + ('; the shaders above have the other forms' if others else ''))
        else:
            head.append(f"  [RED] a library of chain {name[2:]}, not this checkout's {chain}: one built before the simdgroup HMMA defines no helper. Build the game with this checkout "
                        + '(scripts/build_ipa_from_nsp.py) and run the census again')
    if len(files) > 1:
        for f in files: head += [f'{f}: {by_file[f]["shaders"]} shader' + 's' * (by_file[f]['shaders'] != 1)] + totals_lines(by_file[f])
    (out / 'summary.census').write_text(json.dumps(summary, indent=1) + '\n')
    (out / 'summary.txt').write_text('\n'.join(head + [''] + [one_line(r) for r in every] + [''] + [ln for r in every for ln in r['text']]) + '\n')
    print('\n'.join(head))
    print(f'wrote {len(every)} .census files, summary.census and summary.txt to {out}')
    return 0 if every else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description='The HMMA census of translated Switch 2 shaders (read only): what their LDSM, MOVM and HMMA are made of, and where each planned stage applies')
    ap.add_argument('metal', nargs='?', help="one shader's Metal source, <key>_b.metal")
    ap.add_argument('--library', help='a shader library (b-<chain>, its folder or .img) or a folder holding one: every shader whose source defines ' + HMMA_NAME)
    ap.add_argument('--out', help='with --library: the folder for the reports (default: tensor_census-<chain> beside the library; never inside this repository)')
    ap.add_argument('--metal', dest='keep_metal', action='store_true', help="with --library: also write each shader's Metal source beside its report (not to be sent)")
    ap.add_argument('--local', help='one shader: its local size X,Y,Z (default: threadgroup_size of <key>_b.json beside it)')
    ap.add_argument('--json', action='store_true', help='one shader: the whole report, as JSON')
    a = ap.parse_args(argv)
    if a.library: return run_library(a.library, a.out, a.keep_metal)
    if not a.metal: ap.error('give a Metal source or --library')
    p = Path(a.metal)
    local: Any = None
    if a.local:
        try: local = [int(x) for x in a.local.split(',')]
        except ValueError: ap.error('--local takes X,Y,Z')
    else:
        try: local = json.loads(p.with_name(p.name[:-len('.metal')] + '.json').read_text()).get('threadgroup_size') if p.name.endswith('.metal') else None
        except (OSError, ValueError, AttributeError): local = None
    rep = Census(p.read_text(errors='replace'), local if isinstance(local, list) else None, re.sub(r'(_b)?\.metal$', '', p.name)).report()
    print(json.dumps(rep, indent=1) if a.json else '\n'.join(rep['text']))
    return 0


if __name__ == '__main__': sys.exit(main())
