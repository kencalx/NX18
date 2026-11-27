#!/usr/bin/env python3
"""dmsh_metalwa.py: automatic MSL rewrites around Apple Metal GPU compiler bugs, after KosmicKrisp's workarounds.

KosmicKrisp (LunarG's Vulkan-on-Metal driver in Mesa, MIT licence) documents the Metal compiler bugs its CTS runs found in docs/drivers/kosmickrisp/workarounds.rst and works
around them in src/kosmickrisp/compiler/nir_to_msl.c. The numbers below are theirs (KK_WORKAROUND_<n>).

Where the bugs live: the offline front end (metal -O1) keeps ballots inside their branches in the AIR; the GPU back end of the running OS (the compiler service that turns AIR into
GPU code when a pipeline is made) miscompiles them. So KK3 depends on the OS the game runs on. Upstream puts KK3 behind a bool function constant the host sets per OS (upstream
b89b2feed: off on macOS 27+, on below it and on iOS). NX 18's libraries run on macOS 27.2 and iOS 27.2 and later only, and one MSL text goes to both compiles, so the gate is the compile's
deployment target instead (gate='target', the default): dm_mwa3 is false where __ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__ is defined (dmsh_build.py MAC_METAL; KK3 is fixed in
macOS 27, checked on macOS 27.3 with an M4 Max: t_metalwa's ballot kernels right as built; macOS 27.2 is within KosmicKrisp's
fixed range and upstream's macOS 27+ gate, not run here) and true otherwise (the iPhone library: Apple's fix is not shown for iOS 27, so the
rewrite stays on there, as upstream keeps it). A compile-time constant: no host specialization, no pipeline archive key, and the Mac's code is the plain ballot. KK9 has no Apple fix
(reproduced on macOS 27.2.1, M4 Pro, and 27.3, M4 Max) and is written unconditionally.

  KK3  simd_ballot under divergent control flow returns every active lane of the SIMD group, not the lanes in the branch (KosmicKrisp: macOS 15.4–26, FB20113490, fixed in macOS 27).
       Rewrites each spvSubgroupBallot call as simd_or(uint(value) << lane) (KosmicKrisp's lower_ballot, avoiding select feeding the reduction), bringing the lane ID by value
       (uint, never thread uint&, avoiding Apple's #2825 out-of-line scalarization bug) to every function that needs it.
  KK9  a ballot before the only break of a loop sees all lanes, at -O0 and on macOS 27.2.1 as well (dEQP-VK.reconvergence.maximal.*). Guards every loop break (never a switch break)
       in functions that use subgroup operations (directly or through callees) with `if ((ulong)simd_active_threads_mask()) break;`.

apply(msl, enable=ALL, gate='target') returns (msl, stats). A source without subgroup operations or matching patterns is returned unchanged (the same object), and a source already marked is
returned unchanged. Vertex functions (including post-tessellation domain shaders, whose subgroups dmsh_build rewrites to one lane) are skipped. Where KK3 would leave a ballot call
unrewritten, apply raises ValueError so the shader fails closed instead of silently compiling the bug.
"""
import re
import sys

NAMES = {'kk3': 3, 'kk9': 9}
ALL = frozenset(NAMES.values())
MARK = '// dmsh_metalwa:'
LANE = 'gl_SubgroupInvocationID'
_SUBGROUP = re.compile(r'\b(?:simd_\w+|quad_\w+|spvSubgroup\w+|dm_mwa_ballot)\s*\(')
_ATTR = re.compile(r'__attribute__\s*\(\((?:[^()]|\([^()]*\))*\)\)')
_BRACK = re.compile(r'\[\[[^\]]*\]\]')
_ENTRY_RE = re.compile(r'^(?:\[\[[^\]]*\]\]\s*)*(?:kernel|fragment|vertex)\b|^\[\[(?:mesh|object)\]\]\b')
_VERTEX_RE = re.compile(r'^(?:\[\[[^\]]*\]\]\s*)*vertex\s', re.M)
_LANE_ATTR = re.compile(r'\b(\w+)\s*\[\[thread_index_in_simdgroup\]\]')
_COMMENT = re.compile(r'//[^\n]*|/\*.*?\*/', re.S)
_KK9_TOK = re.compile(r'\b(?:for|while|switch)\s*\(|\bdo\b(?!\s*\w)|[{}]|;|\bbreak\s*;')


def _close(s, i):
    """index of the ')' matching the '(' at s[i]"""
    d = 0
    for j in range(i, len(s)):
        c = s[j]
        if c == '(': d += 1
        elif c == ')':
            d -= 1
            if d == 0: return j
    raise ValueError('unbalanced parentheses')


def _sig(line):
    """(name, params) of a one-line function signature `<qualifiers and type> name(params)`, None for anything else"""
    s = line.strip()
    m = _ATTR.sub(' ', s)
    # Strip leading [[...]] attributes (e.g. [[ early_fragment_tests ]], [[mesh]], [[object]]) without touching parameter attributes inside (...)
    while True:
        b = re.match(r'^\[\[[^\]]*\]\]\s*', m)
        if not b: break
        m = m[b.end():]
    hd = re.match(r'^(?:template\s*<[^>]*>\s*)?([^()]*?)\b(\w+)\s*\(', m)
    if not hd or not hd.group(1).strip() or hd.group(2) in ('if', 'for', 'while', 'switch', 'return'): return None
    try: j = _close(m, hd.end() - 1)
    except ValueError: return None
    if m[j + 1:].strip(): return None
    return hd.group(2), m[hd.end():j]


def functions(msl):
    """[(sig_line, open_line, close_line, name, params, entry)] of SPIRV-Cross's top-level functions (signature on one line, braces alone in column 0)"""
    lines, out, i = msl.split('\n'), [], 0
    while i < len(lines):
        if lines[i] == '{' and i and lines[i - 1].rstrip().endswith(')'):
            s = i - 1
            m = _sig(lines[s])
            if m:
                j = i + 1
                while j < len(lines) and lines[j] != '}': j += 1
                head = lines[s - 1].strip() if s else ''
                entry = bool(_ENTRY_RE.match(lines[s].strip()) or _ENTRY_RE.match(head))
                out.append((s, i, j, m[0], m[1], entry))
                i = j
        i += 1
    return out


def _helper(name): return name.startswith(('spv', 'dm_mwa'))   # SPIRV-Cross's helpers and ours are left as they are


HELPER3 = """// KK_WORKAROUND_3 (KosmicKrisp lower_ballot): a ballot as simd_or of the lane bit, shifted from the predicate (no select feeding the reduction)
inline uint4 dm_mwa_ballot(bool value, uint lane)
{
    if (dm_mwa3) return uint4(simd_or(uint(value) << lane), 0u, 0u, 0u);
    simd_vote vote = simd_ballot(value);
    return uint4(as_type<uint2>((simd_vote::vote_t)vote), 0u, 0u);
}
"""


MAC_TARGET = '__ENVIRONMENT_MAC_OS_X_VERSION_MIN_REQUIRED__'   # defined by a compile with -mmacosx-version-min (dmsh_build.py MAC_METAL), not by the iPhone's


def _gate3(gate):
    if gate == 'static': return 'constant bool dm_mwa3 = true;\n'
    if gate != 'target': raise ValueError(f'dmsh_metalwa: gate {gate!r} (target or static)')
    return (f'#ifdef {MAC_TARGET}\nconstant bool dm_mwa3 = false;   // macOS 27.2 and later: Apple fixed KK3 in macOS 27\n'
            '#else\nconstant bool dm_mwa3 = true;   // iOS: not shown fixed\n#endif\n')


def _rewrite_calls(body, fname, new, lane):
    """fname(ARGS) -> new(ARGS, lane) in body"""
    out, i, n = '', 0, 0
    pat = re.compile(r'\b' + re.escape(fname) + r'\s*\(')
    while True:
        m = pat.search(body, i)
        if not m: return out + body[i:], n
        j = _close(body, m.end() - 1)
        out += body[i:m.start()] + new + '(' + body[m.end():j] + ', ' + lane + ')'
        i = j + 1; n += 1


def _pass_lane(body, fname, lane):
    """every call fname(ARGS) in body, nested ones too, with lane as a last argument"""
    pat = re.compile(r'\b' + re.escape(fname) + r'\s*\(')
    out, i = '', 0
    while True:
        m = pat.search(body, i)
        if not m: return out + body[i:]
        j = _close(body, m.end() - 1); a = _pass_lane(body[m.end():j], fname, lane)
        out += body[i:m.end()] + a + (', ' if a.strip() else '') + lane + ')'; i = j + 1


def _kk9(body):
    """KK_WORKAROUND_9: every `break;` of a loop (never a switch's) in a function that uses subgroup operations.
    Tracks enclosing loop/switch blocks across both multiline SPIRV-Cross blocks and compact single-line blocks while ignoring comments."""
    masked = _COMMENT.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), body)
    stack, pending, edits = [], None, []
    pos = 0
    while pos < len(masked):
        m = _KK9_TOK.search(masked, pos)
        if not m: break
        tok = m.group(0)
        if tok.startswith(('for', 'while', 'switch')):
            j = _close(masked, m.end() - 1)
            pending = 'switch' if tok.startswith('switch') else 'loop'
            pos = j + 1
            continue
        pos = m.end()
        if tok == 'do': pending = 'loop'
        elif tok == '{': stack.append(pending or 'blk'); pending = None
        elif tok == '}':
            if stack: stack.pop()
            pending = None
        elif tok == ';': pending = None
        else:   # break;
            in_loop = pending == 'loop' or next((k for k in reversed(stack) if k in ('loop', 'switch')), None) == 'loop'
            pending = None
            if in_loop:
                ls = body.rfind('\n', 0, m.start()) + 1
                le = body.find('\n', m.end())
                le = len(body) if le < 0 else le
                alone = not body[ls:m.start()].strip() and not masked[m.end():le].strip()
                rep = 'if ((ulong)simd_active_threads_mask()) break;   // KK_WORKAROUND_9' if alone else '{ if ((ulong)simd_active_threads_mask()) break; }'
                edits.append((m.start(), m.end(), rep))
    if not edits: return body, 0
    out, i = [], 0
    for a, b, rep in edits:
        out.append(body[i:a]); out.append(rep); i = b
    out.append(body[i:])
    return ''.join(out), len(edits)


def _lane_name(f):
    """The lane ID parameter name already in f's parameter list, or None."""
    if f[5]:
        m = _LANE_ATTR.search(f[4])
        if m: return m.group(1)
    if re.search(r'\b' + LANE + r'\b', f[4]): return LANE
    return None


def apply(msl, enable: 'set[int] | frozenset[int]' = ALL, gate='target'):
    """enable: KosmicKrisp numbers (3: spvSubgroupBallot calls; 9: loop breaks in subgroup functions). gate: 'target' (KK3 off in the Mac library, on in the iPhone's) or 'static' (always on).
    Returns (msl, stats {n: rewrites}). Vertex functions are skipped (dmsh_build rewrites their subgroups to one lane via spv_single_lane)."""
    stats = {n: 0 for n in enable}
    if MARK in msl or not enable or _VERTEX_RE.search(msl) or not _SUBGROUP.search(msl): return msl, stats
    lines = msl.split('\n')
    fns = functions(msl)
    names = [f[3] for f in fns if not _helper(f[3])]
    if len(names) != len(set(names)): raise ValueError('dmsh_metalwa: two functions of one name (overloads are not handled)')
    bodies = {f[3]: '\n'.join(lines[f[1] + 1:f[2]]) for f in fns}
    sg = {n for n, b in bodies.items() if _SUBGROUP.search(b) or n.startswith('spvSubgroup')}
    while True:
        more = {n for n, b in bodies.items() if n not in sg and any(re.search(r'\b' + re.escape(m) + r'\s*\(', b) for m in sg)}
        if not more: break
        sg |= more
    need_lane, edits = set(), {}
    # pass 1: rewrite bodies
    for (s, o, c, name, params, entry) in fns:
        if _helper(name): continue
        body = bodies[name]
        b = body
        if 3 in enable:
            lane = _lane_name((s, o, c, name, params, entry)) or LANE
            b, k = _rewrite_calls(b, 'spvSubgroupBallot', 'dm_mwa_ballot', lane); stats[3] += k
            if k: need_lane.add(name)
        if 9 in enable and name in sg:
            b, k = _kk9(b); stats[9] += k
        if b != body: edits[o] = b
    if 3 in enable:   # a ballot in a function functions() did not parse would be left as it is: fail closed rather than build the bug
        left = re.sub(r'^inline uint4 spvSubgroupBallot\(bool value\)$', '', msl, flags=re.M).count('spvSubgroupBallot(') - sum(bodies[f[3]].count('spvSubgroupBallot(') for f in fns if _helper(f[3]))
        if left != stats[3]: raise ValueError(f'dmsh_metalwa: {left - stats[3]} ballot call(s) outside the functions it parses')
    if not edits: return msl, stats
    # pass 2: bring the lane id to every function that now uses it (entry point: builtin; helper: by-value `uint`, never `thread uint&`, to avoid Apple's #2825 backend bug).
    # Only a parameter counts as in scope: a local of that name could be declared after the call or hold another value
    byname = {f[3]: f for f in fns}
    todo, sig_new, seen = [n for n in need_lane if not _lane_name(byname[n])], {}, set()
    while todo:
        n = todo.pop()
        if n in seen: continue
        seen.add(n); f = byname[n]
        p = f[4].strip()
        if f[5]:
            if re.search(r'\b' + LANE + r'\b', bodies[n]): raise ValueError(f'dmsh_metalwa: entry point {n} names {LANE} in its body')
            sig_new[f[0]] = lines[f[0]].rstrip()[:-1] + (', ' if p else '') + f'uint {LANE} [[thread_index_in_simdgroup]])'
            continue
        sig_new[f[0]] = lines[f[0]].rstrip()[:-1] + (', ' if p else '') + f'uint {LANE})'
        for g in fns:   # callers pass it on
            if g[3] == n: continue
            gb = edits.get(g[1], bodies[g[3]])
            if not re.search(r'\b' + re.escape(n) + r'\s*\(', gb): continue
            glane = _lane_name(g) or LANE
            edits[g[1]] = _pass_lane(gb, n, glane)
            if not _lane_name(g): todo.append(g[3])
    # pass 3: assemble
    out, skip_to = [], -1
    starts = {f[1]: f[2] for f in fns}
    for i, l in enumerate(lines):
        if i < skip_to: continue
        if i in sig_new: out.append(sig_new[i]); continue
        if i in edits:
            out.append(l); out.extend(edits[i].split('\n')); skip_to = starts[i]; continue
        out.append(l)
    msl = '\n'.join(out)
    applied = [n for n in sorted(enable) if stats.get(n)]
    hdr = MARK + ' ' + ' '.join(f'KK{n}' for n in applied) + ' (Metal compiler workarounds after KosmicKrisp, Mesa, MIT: docs/drivers/kosmickrisp/workarounds.rst)\n'
    if stats.get(3): hdr += _gate3(gate) + HELPER3
    m = re.search(r'^using namespace metal;\n', msl, flags=re.M)
    if not m: raise ValueError('dmsh_metalwa: no `using namespace metal;`')
    return msl[:m.end()] + '\n' + hdr + msl[m.end():], stats


if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit('usage: dmsh_metalwa.py <in.metal> <out.metal> [kk3,kk9] [target|static]')
    en = {NAMES[w] for w in sys.argv[3].lower().split(',')} if len(sys.argv) > 3 else ALL
    dst, st = apply(open(sys.argv[1]).read(), en, sys.argv[4] if len(sys.argv) > 4 else 'target')
    open(sys.argv[2], 'w').write(dst); print({f'kk{n}': k for n, k in st.items()})
