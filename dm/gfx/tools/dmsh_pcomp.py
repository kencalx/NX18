"""A one-triangle render pass as one compute dispatch (<vertex key>_<pixel key>_pc).

On Apple GPUs a render pass costs a fixed 25-40 us however little it draws, a compute dispatch 3-7 us (NX18-X2.0 tinybench). Breath of the
Wild and Tears of the Kingdom run about 80 passes a frame that hold one full-screen triangle into a colour target (blur, luminance and mip
ladders). The host runs such a pass as this kernel instead (nvn_mtl.m pcm_*):

- every lane runs the vertex shader's pulling entry (dmsh_pull) for the three vertices (cheap: a full-screen triangle's vertex shader is a
  few instructions), maps their positions through the viewport, and takes its pixel's barycentrics, perspective-correct for the
  perspective inputs, linear for center_no_perspective ones, vertex 0's for flat ones;
- a threadgroup is 64 lanes over an 8x8 block of pixels, each quad of lanes a 2x2 block (bit 0: x, bit 1: y), so a quad shuffle gives the
  neighbour's value as the fragment stage's derivative would. Every implicit-LOD sample in the pixel shader (its own and the border
  helper's) goes through dm_qs, which takes its gradients so; only their size matters for the level and anisotropy, so the sign is not
  needed. A pixel shader that takes derivatives itself (dfdx, dfdy, fwidth) or calls a sampling function this does not cover is refused;
- the pixel shader's body (dm_body_main0, dmsh_side.shared_body) runs in every lane, a lane off the pass's rectangle or the triangle as
  a helper, and the lanes that cover a pixel write their colour outputs to the attachments, bound as textures 0 and 1.

Buffers: the vertex entry's own (its argument buffer at 0, the layout block at dmsh_pull.SLOT), the pixel shader's argument buffer at
FS_SLOT, its blend state at 28 (dmsh_abi.h DMSH_BLEND_BUFFER) and the draw record at DRAW_SLOT. Usage: compose(vs_src, fs_src) -> MSL,
raises ValueError with the reason a pair is refused.
"""
import re
import dmsh_pull, dmsh_side

DRAW_SLOT, FS_SLOT = 12, 13   # argument-table slots a pulling vertex entry leaves free (dmsh_mesh.py takes the same two)
BLEND_SLOT = 28
ENTRY = 'dm_pc'
_PARAMS = re.compile(r'(.+?) (\w+) \[\[(\w+)(?:\((\d+)\))?\]\]')
_BUILTIN_V = {'vertex_id': 'dm_vid', 'instance_id': 'dm_iid', 'base_instance': 'dm_bi', 'base_vertex': 'dm_bv'}

# Gradient sampling for the lanes of a 2x2 quad (see the module comment); one overload per coordinate kind the translator emits
BLEND = r'''
// A target's blending and write mask, as the render pipeline's colour attachment would apply them (nvn_mtl.m pso_desc): a: source and destination colour factors, colour operation,
// source alpha factor; b: destination alpha factor, alpha operation, write mask (bit 0 red .. 3 alpha), flags (1 blending, 2 unorm target, 4 snorm target, 8 unsigned float target). Factors and operations in
// Metal's numbering (MTLBlendFactor, MTLBlendOperation)
struct dm_pc_blend { uint4 a; uint4 b; };
static inline float4 dm_bf(uint f, float4 s, float4 d, float4 c) {
    switch (f) {
        case 0u: return float4(0.0); case 1u: return float4(1.0); case 2u: return s; case 3u: return 1.0 - s; case 4u: return float4(s.a); case 5u: return float4(1.0 - s.a);
        case 6u: return d; case 7u: return 1.0 - d; case 8u: return float4(d.a); case 9u: return float4(1.0 - d.a); case 10u: return float4(float3(min(s.a, 1.0 - d.a)), 1.0);
        case 11u: return c; case 12u: return 1.0 - c; case 13u: return float4(c.a); case 14u: return float4(1.0 - c.a); default: return float4(1.0);
    }
}
template<typename T> static inline T dm_bo(uint o, T s, T d, T sf, T df) {
    switch (o) { case 1u: return s * sf - d * df; case 2u: return d * df - s * sf; case 3u: return min(s, d); case 4u: return max(s, d); default: return s * sf + d * df; }
}
static inline void dm_put(texture2d<float, access::write> t, texture2d<float, access::read> r, dm_pc_blend b, float4 bc, float4 s, uint2 p) {
    uint m = b.b.z, fl = b.b.w;
    if (!m) return;
    if (fl & 8u) s = max(s, 0.0);   // an unsigned float target (RG11B10, RGB9E5): the render pipeline stores a negative value or a NaN as 0, a compute write promises nothing
    if (!(fl & 1u) && m == 15u) { t.write(s, p); return; }
    float4 d = r.read(p);
    if (fl & 1u) {
        if (fl & 2u) s = saturate(s); else if (fl & 4u) s = clamp(s, -1.0, 1.0);
        float4 c = float4(dm_bo(b.a.z, s.rgb, d.rgb, dm_bf(b.a.x, s, d, bc).rgb, dm_bf(b.a.y, s, d, bc).rgb), dm_bo(b.b.y, s.a, d.a, dm_bf(b.a.w, s, d, bc).a, dm_bf(b.b.x, s, d, bc).a));
        s = (fl & 2u) ? saturate(c) : (fl & 4u) ? clamp(c, -1.0, 1.0) : (fl & 8u) ? max(c, 0.0) : c;
    }
    t.write(select(d, s, bool4((m & 1u) != 0u, (m & 2u) != 0u, (m & 4u) != 0u, (m & 8u) != 0u)), p);
}
'''

HELPERS = r'''
template<typename C> static inline __attribute__((always_inline)) C dm_ddx(C c) { return quad_shuffle_xor(c, 1u) - c; }
template<typename C> static inline __attribute__((always_inline)) C dm_ddy(C c) { return quad_shuffle_xor(c, 2u) - c; }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c) { return t.sample(s, c, gradient2d(dm_ddx(c), dm_ddy(c))); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, int2 o) { return t.sample(s, c, gradient2d(dm_ddx(c), dm_ddy(c)), o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, bias b) { float k = exp2(float(b.value)); return t.sample(s, c, gradient2d(dm_ddx(c) * k, dm_ddy(c) * k)); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, level l) { return t.sample(s, c, l); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, level l, int2 o) { return t.sample(s, c, l, o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, gradient2d g) { return t.sample(s, c, g); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, gradient2d g, int2 o) { return t.sample(s, c, g, o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d_array<T> t, sampler s, float2 c, uint a) { return t.sample(s, c, a, gradient2d(dm_ddx(c), dm_ddy(c))); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d_array<T> t, sampler s, float2 c, uint a, level l) { return t.sample(s, c, a, l); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture3d<T> t, sampler s, float3 c) { return t.sample(s, c, gradient3d(dm_ddx(c), dm_ddy(c))); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture3d<T> t, sampler s, float3 c, level l) { return t.sample(s, c, l); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texturecube<T> t, sampler s, float3 c) { return t.sample(s, c, gradientcube(dm_ddx(c), dm_ddy(c))); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texturecube<T> t, sampler s, float3 c, level l) { return t.sample(s, c, l); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texturecube<T> t, sampler s, float3 c, bias b) { float k = exp2(float(b.value)); return t.sample(s, c, gradientcube(dm_ddx(c) * k, dm_ddy(c) * k)); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texturecube_array<T> t, sampler s, float3 c, uint a) { return t.sample(s, c, a, gradientcube(dm_ddx(c), dm_ddy(c))); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texturecube_array<T> t, sampler s, float3 c, uint a, level l) { return t.sample(s, c, a, l); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texturecube_array<T> t, sampler s, float3 c, uint a, bias b) { float k = exp2(float(b.value)); return t.sample(s, c, a, gradientcube(dm_ddx(c) * k, dm_ddy(c) * k)); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d_array<T> t, sampler s, float2 c, uint a, bias b) { float k = exp2(float(b.value)); return t.sample(s, c, a, gradient2d(dm_ddx(c) * k, dm_ddy(c) * k)); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d_array<T> t, sampler s, float2 c, uint a, int2 o) { return t.sample(s, c, a, gradient2d(dm_ddx(c), dm_ddy(c)), o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d_array<T> t, sampler s, float2 c, uint a, level l, int2 o) { return t.sample(s, c, a, l, o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture2d<T> t, sampler s, float2 c, bias b, int2 o) { float k = exp2(float(b.value)); return t.sample(s, c, gradient2d(dm_ddx(c) * k, dm_ddy(c) * k), o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture3d<T> t, sampler s, float3 c, int3 o) { return t.sample(s, c, gradient3d(dm_ddx(c), dm_ddy(c)), o); }
template<typename T> static inline __attribute__((always_inline)) vec<T, 4> dm_qs(texture3d<T> t, sampler s, float3 c, level l, int3 o) { return t.sample(s, c, l, o); }
'''


def _close(s, i, o, c):
    """the index just past the bracket that closes the one opened before i"""
    depth = 1
    while i < len(s) and depth:
        depth += (s[i] == o) - (s[i] == c); i += 1
    if depth: raise ValueError('pc: unbalanced ' + o)
    return i


def _receiver(s, end):
    """the start of the expression that ends at end (an identifier chain with members, indices and a parenthesized dereference)"""
    i = end
    while i > 0:
        ch = s[i - 1]
        if ch.isalnum() or ch in '_.': i -= 1
        elif ch in '])':
            o, c = ('[', ']') if ch == ']' else ('(', ')')
            depth, j = 1, i - 1
            while j > 0 and depth:
                j -= 1; depth += (s[j] == c) - (s[j] == o)
            i = j
        elif ch == '>' and s[i - 2:i] == '->': i -= 2
        else: break
    if i == end: raise ValueError('pc: a sample call with no texture before it')
    return i


def gradient_samples(src):
    """every X.sample(args) as dm_qs(X, args); refuses derivatives and the sampling calls a kernel cannot take as they are"""
    if re.search(r'\b(dfdx|dfdy|fwidth|discard_fragment|calculate_clamped_lod|calculate_unclamped_lod|simd_\w+|quad_\w+)\s*\(', src):
        raise ValueError('pc: the pixel shader takes derivatives, discards or uses SIMD-group functions')
    if re.search(r'\.sample_compare\s*\((?![^;]*\blevel\()', src): raise ValueError('pc: an implicit-LOD depth compare')
    out, pos = [], 0
    for m in re.finditer(r'\.sample\s*\(', src):
        if m.start() < pos: continue
        r = _receiver(src, m.start())
        out.append(src[pos:r]); out.append(f'dm_qs({src[r:m.start()]}, '); pos = m.end()
    out.append(src[pos:])
    return ''.join(out)


def _struct(src, name):
    m = re.search(r'\nstruct %s\n\{\n(.*?)\n\};' % name, src, re.S)
    if not m: raise ValueError('pc: no struct ' + name)
    rows = []
    for ln in m.group(1).split('\n'):
        a = re.fullmatch(r'\s*(\w+) (\w+)(?: \[(\d+)\])? \[\[([^\]]*)\]\];', ln)
        if not a: raise ValueError('pc: a member not understood: ' + ln.strip()[:60])
        rows.append((a[1], a[2], a[3], [x.strip() for x in a[4].split(',')]))
    return rows


def _drop_fragment_entries(src):
    """src without its fragment entry points (a function runs from a line 'fragment ...' to the next line '}')"""
    out, lines, i = [], src.split('\n'), 0
    while i < len(lines):
        if re.match(r'(\[\[[^\]]*\]\] )?fragment ', lines[i]):
            while i < len(lines) and lines[i] != '}': i += 1
            i += 1; continue
        out.append(lines[i]); i += 1
    return '\n'.join(out)


def _strip_head(src):
    return '\n'.join(l for l in src.split('\n') if not re.match(r'\s*#include\b|\s*using namespace metal;', l))


def _fconsts(src):
    """the function constant declarations (name -> (index, line)) at the top level"""
    return {m[2]: (int(m[3]), m[0]) for m in re.finditer(r'(?m)^constant (\w+) (\w+) \[\[function_constant\((\d+)\)\]\];$', src)}


def compose(vs_src, fs_src):
    # The vertex side: the pulling entry main0 as a function of its resources and the draw's numbers
    pulled, info = dmsh_pull.variant(vs_src)
    if pulled is None or not isinstance(info, dict): raise ValueError(f'pc: no pulling entry: {info}')
    if re.search(r'\[\[(clip_distance|render_target_array_index|viewport_array_index)\]\]', pulled): raise ValueError('pc: the vertex shader writes clip distances or a layer')
    vouts = _struct(pulled, 'main0_out')
    pos = [n for t, n, a, at in vouts if 'position' in at]
    if len(pos) != 1: raise ValueError('pc: no position')
    vloc = {}
    for t, n, a, at in vouts:
        for x in at:
            u = re.fullmatch(r'user\(locn(\d+)\)', x)
            if u:
                if t != 'float4' or a: raise ValueError('pc: a vertex output not a float4: ' + n)
                vloc[int(u[1])] = n
    m = re.search(r'\nvertex main0_out main0\(([^\n]*)\)\n\{\n', pulled)
    if not m: raise ValueError('pc: no vertex main0')
    vargs, vparams, vres = [], [], []
    for p in dmsh_side_params(m[1]):
        a = _PARAMS.fullmatch(p)
        if not a: raise ValueError('pc: vertex parameter ' + p)
        vparams.append(f'{a[1]} {a[2]}')
        if a[3] in _BUILTIN_V: vargs.append(_BUILTIN_V[a[3]])
        elif a[3] == 'buffer' and int(a[4]) not in (DRAW_SLOT, FS_SLOT, BLEND_SLOT): vargs.append(a[2]); vres.append(re.sub(r'\b(spvDescriptorSetBuffer0|dm_vlayout)\b', r'dm_v::\1', p))
        else: raise ValueError('pc: vertex parameter ' + p)
    pulled = pulled[:m.start()] + '\nstatic inline main0_out dm_vs(' + ', '.join(vparams) + ')\n{\n' + pulled[m.end():]
    pulled = re.sub(r'\nvertex main0_out main0_z\([^\n]*\)\n\{\n.*?\n\}\n', '\n', pulled, flags=re.S)
    if re.search(r'(?m)^vertex ', pulled): raise ValueError('pc: a vertex entry left over')

    # The pixel side: dm_body_main0 with its samples through dm_qs
    fsb = dmsh_side.shared_body(fs_src)
    if fsb is None: raise ValueError('pc: no shared body')
    fins = _struct(fsb, 'main0_in') if re.search(r'\nstruct main0_in\n\{', fsb) else None   # None: the pixel shader takes no inputs
    fouts = _struct(fsb, 'main0_out')
    for t, n, a, at in fouts:
        if t != 'float4' or a or not re.fullmatch(r'color\(\d\)', at[0]) or len(at) != 1: raise ValueError('pc: a colour output not understood: ' + n)
    b = dmsh_side.body(fsb)
    if not b: raise ValueError('pc: no body')
    bparams = dmsh_side_params(fsb[fsb.index('(', b[0]) + 1:b[1] - 1])
    fsb = _drop_fragment_entries(fsb)
    fsb = gradient_samples(fsb)
    bargs = []
    for p in bparams:
        a = re.fullmatch(r'(.+?)\s*(\w+)', p)
        name = a[2]
        if name == 'in': bargs.append('dm_in')
        elif 'spvDescriptorSetBuffer0' in p: bargs.append('dm_fset')
        elif 'dm_blend_state' in p: bargs.append('dm_fblend')
        elif name == 'gl_FragCoord': bargs.append('dm_fc')
        elif name == 'gl_FrontFacing': bargs.append('dm_front')
        else: raise ValueError('pc: body parameter ' + p)

    # Function constants: one declaration per index across both sides (the host sets each once)
    fc_v, fc_f = _fconsts(pulled), _fconsts(fsb)
    hoist = {}
    for d in (fc_v, fc_f):
        for name, (idx, line) in d.items():
            if name in hoist and hoist[name][0] != idx: raise ValueError('pc: function constant ' + name + ' at two indices')
            if any(i == idx and n != name for n, (i, _) in hoist.items()): raise ValueError(f'pc: function constant {idx} under two names')
            hoist[name] = (idx, line)
    for name, (idx, line) in hoist.items():
        pulled = pulled.replace(line + '\n', ''); fsb = fsb.replace(line + '\n', '')

    # The inputs: each from the vertex output at its location
    interp = []
    for t, n, a, at in fins or []:
        u = [re.fullmatch(r'user\(locn(\d+)\)', x) for x in at]; u = [x for x in u if x]
        if t not in ('float4', 'float3', 'float2', 'float') or a or len(u) != 1: raise ValueError('pc: an input not understood: ' + n)
        loc = int(u[0][1]); src = f'dm_o{{}}.{vloc[loc]}' if loc in vloc else None
        comps = {'float4': '', 'float3': '.xyz', 'float2': '.xy', 'float': '.x'}[t]
        if src is None: interp.append(f'    dm_in.{n} = {t}(0.0);'); continue
        kind = 'flat' if 'flat' in at else 'lin' if any('no_perspective' in x for x in at) else 'persp'
        if kind == 'flat': interp.append(f'    dm_in.{n} = dm_o0.{vloc[loc]}{comps};')
        else:
            w = 'dm_bp' if kind == 'persp' else 'dm_bl'
            interp.append(f'    dm_in.{n} = ({w}.x * dm_o0.{vloc[loc]} + {w}.y * dm_o1.{vloc[loc]} + {w}.z * dm_o2.{vloc[loc]}){comps};')
    fin_decl = '\n'.join(f'    {t} {n};' for t, n, a, at in fins or [])
    if fins is not None: fsb = re.sub(r'\nstruct main0_in\n\{\n.*?\n\};', '\nstruct main0_in\n{\n' + fin_decl + '\n};', fsb, count=1, flags=re.S)

    ncol = max(int(re.fullmatch(r'color\((\d)\)', at[0])[1]) for t, n, a, at in fouts) + 1
    writes = '\n'.join(f'        dm_put(dm_t{re.fullmatch(r"color\((\d)\)", at[0])[1]}, dm_s{re.fullmatch(r"color\((\d)\)", at[0])[1]}, dm_d.bl[{re.fullmatch(r"color\((\d)\)", at[0])[1]}], dm_d.bc, dm_r.{n}, dm_px);' for t, n, a, at in fouts)
    tex = ''.join(f', texture2d<float, access::write> dm_t{i} [[texture({i})]], texture2d<float, access::read> dm_s{i} [[texture({8 + i})]]' for i in range(ncol))
    vcall = ', '.join(vargs)
    out = ['#include <metal_stdlib>', '#include <simd/simd.h>', '#include <metal_atomic>', 'using namespace metal;',
           *[line for _, (_, line) in sorted(hoist.items(), key=lambda kv: kv[1][0])],
           HELPERS,
           'namespace dm_v {', _strip_head(pulled), '}', 'namespace dm_f {', _strip_head(fsb), '}',
           # vp: the viewport (x, y, width, height: a negative height flips it); dr: its depth range; rect: the pixels written (x0, y0, x1, y1);
           # zf: the depth test's compare function + 1 (Metal's numbering; 0 none), zq: the depth format's unorm bits to round the pixel's depth to (0: float); bc: the blend constant; bl: each target's blending and write mask (dm_put);
           # base: the dispatch's first pixel; vtx: first vertex, base vertex, base instance, index type (0 none, 1-3: 8, 16, 32 bits) and buffer; count: 3, 4 (strip) or 6; vis: the occlusion query slot the covered pixels are added to (null: none); face: cull mode (0 none, 1 front, 2 back) and front winding (0 clockwise, 1 counter-clockwise)
           BLEND, 'struct dm_pc_draw { float4 vp; float2 dr; uint4 rect; uint2 base; uint first; int base_vertex; uint base_instance; uint itype; device const uchar* ib; uint cull; uint ccw; uint count; uint strip; device atomic_uint* vis; uint zf; uint zq; float4 bc; dm_pc_blend bl[8]; };',
           f'''kernel void {ENTRY}({', '.join(vres)}, constant dm_f::spvDescriptorSetBuffer0& dm_fset [[buffer({FS_SLOT})]], constant dm_f::dm_blend_state& dm_fblend [[buffer({BLEND_SLOT})]],
    constant dm_pc_draw& dm_d [[buffer({DRAW_SLOT})]]{tex}, depth2d<float, access::read> dm_dz [[texture(16)]], uint dm_l [[thread_index_in_threadgroup]], uint2 dm_tg [[threadgroup_position_in_grid]])
{{
    uint dm_q = dm_l >> 2, dm_i = dm_l & 3u;
    uint2 dm_px = dm_d.base + dm_tg * 8u + uint2((dm_q & 3u) * 2u + (dm_i & 1u), (dm_q >> 2) * 2u + (dm_i >> 1));
    uint dm_bv = uint(dm_d.base_vertex), dm_bi = dm_d.base_instance, dm_iid = dm_bi;
    // The vertex shader once per vertex: lanes 0 to count - 1, shared through threadgroup memory
    threadgroup dm_v::main0_out dm_ov[6];
    uint dm_n = min(dm_d.count, 6u);
    if (dm_l < dm_n) {{
        uint k = dm_l, dm_ix = dm_d.first + k;
        if (dm_d.itype == 1u) dm_ix = uint(dm_d.ib[dm_ix]); else if (dm_d.itype == 2u) dm_ix = uint(((device const ushort*)dm_d.ib)[dm_ix]); else if (dm_d.itype == 3u) dm_ix = ((device const uint*)dm_d.ib)[dm_ix];
        uint dm_vid = dm_ix + uint(dm_d.base_vertex);
        dm_ov[k] = dm_v::dm_vs({vcall});
    }}
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float2 dm_p = float2(dm_px) + 0.5;
    // The triangle that covers the pixel (the first; a lane no triangle covers runs as a helper with triangle 0's interpolants): a list's 3k..3k+2, a strip's k, k+1, k+2 with odd ones turned to keep the winding
    uint dm_nt = dm_d.strip ? (dm_n >= 3u ? dm_n - 2u : 0u) : dm_n / 3u;
    uint3 dm_tv = uint3(0u, 1u, 2u); bool dm_hit = false;
    float3 dm_bl = float3(1.0, 0.0, 0.0), dm_iw = float3(1.0); float dm_area = 0.0; float4 dm_c0 = float4(0.0), dm_c1 = float4(0.0), dm_c2 = float4(0.0);
    for (uint t = 0u; t < dm_nt && !dm_hit; t++) {{
        uint3 tv = dm_d.strip ? ((t & 1u) ? uint3(t + 1u, t, t + 2u) : uint3(t, t + 1u, t + 2u)) : uint3(3u * t, 3u * t + 1u, 3u * t + 2u);
        float4 c0 = dm_ov[tv.x].{pos[0]}, c1 = dm_ov[tv.y].{pos[0]}, c2 = dm_ov[tv.z].{pos[0]};
        float3 iw = 1.0 / float3(c0.w, c1.w, c2.w);
        float2 w0 = dm_d.vp.xy + (float2(0.5, -0.5) * c0.xy * iw.x + 0.5) * dm_d.vp.zw;
        float2 w1 = dm_d.vp.xy + (float2(0.5, -0.5) * c1.xy * iw.y + 0.5) * dm_d.vp.zw;
        float2 w2 = dm_d.vp.xy + (float2(0.5, -0.5) * c2.xy * iw.z + 0.5) * dm_d.vp.zw;
        float area = (w1.x - w0.x) * (w2.y - w0.y) - (w2.x - w0.x) * (w1.y - w0.y);
        float3 e = float3((w2.x - w1.x) * (dm_p.y - w1.y) - (w2.y - w1.y) * (dm_p.x - w1.x),
                          (w0.x - w2.x) * (dm_p.y - w2.y) - (w0.y - w2.y) * (dm_p.x - w2.x),
                          (w1.x - w0.x) * (dm_p.y - w0.y) - (w1.y - w0.y) * (dm_p.x - w0.x));
        float3 bl = area != 0.0 ? e / area : float3(1.0, 0.0, 0.0);
        bool hit = area != 0.0 && all(bl >= 0.0);
        if (hit || t == 0u) {{ dm_tv = tv; dm_bl = bl; dm_iw = iw; dm_area = area; dm_c0 = c0; dm_c1 = c1; dm_c2 = c2; dm_hit = hit; }}
    }}
    dm_v::main0_out dm_o0 = dm_ov[dm_tv.x], dm_o1 = dm_ov[dm_tv.y], dm_o2 = dm_ov[dm_tv.z];
    bool dm_front = (dm_area < 0.0) == (dm_d.ccw != 0u);
    bool dm_cov = dm_hit && !(dm_d.cull == 1u && dm_front) && !(dm_d.cull == 2u && !dm_front) && all(dm_px >= dm_d.rect.xy) && all(dm_px < dm_d.rect.zw);
    float3 dm_bw = dm_bl * dm_iw; float dm_sw = dm_bw.x + dm_bw.y + dm_bw.z;
    float3 dm_bp = dm_bw / dm_sw;
    float dm_z = dot(dm_bl, float3(dm_c0.z * dm_iw.x, dm_c1.z * dm_iw.y, dm_c2.z * dm_iw.z));
    float4 dm_fc = float4(dm_p, dm_d.dr.x + dm_z * (dm_d.dr.y - dm_d.dr.x), dm_sw);
{'    dm_f::main0_in dm_in;' if fins is not None else ''}
{chr(10).join(interp)}
    dm_f::main0_out dm_r = dm_f::dm_body_main0({', '.join(bargs)});
    bool dm_pass = dm_cov;
    if (dm_d.zf && dm_cov) {{   // the depth test (no write): the pixel's depth, rounded as the target stores it, against the stored one
        float zf = saturate(dm_fc.z), zs = dm_dz.read(dm_px);
        if (dm_d.zq) {{ float q = float((1u << dm_d.zq) - 1u); zf = rint(zf * q) / q; }}
        switch (dm_d.zf - 1u) {{ case 0u: dm_pass = false; break; case 1u: dm_pass = zf < zs; break; case 2u: dm_pass = zf == zs; break; case 3u: dm_pass = zf <= zs; break;
                                 case 4u: dm_pass = zf > zs; break; case 5u: dm_pass = zf != zs; break; case 6u: dm_pass = zf >= zs; break; default: break; }}
    }}
    if (dm_pass) {{
{writes}
    }}
    if (dm_d.vis) {{ uint n = simd_sum(dm_pass ? 1u : 0u); if (simd_is_first() && n) atomic_fetch_add_explicit(dm_d.vis, n, memory_order_relaxed); }}   // samples passed, as the pass's counting mode would count them
}}''']
    return '\n'.join(out) + '\n', {'colors': ncol, 'entry': ENTRY, 'fconsts': sorted(i for i, _ in hoist.values())}


def dmsh_side_params(s):
    """a parameter list split at its top-level commas"""
    out, depth, cur = [], 0, ''
    for ch in s:
        depth += ch in '<([' ; depth -= ch in '>)]'
        if ch == ',' and not depth: out.append(cur.strip()); cur = ''
        else: cur += ch
    return out + ([cur.strip()] if cur.strip() else [])


if __name__ == '__main__':
    import sys
    msl, info = compose(open(sys.argv[1]).read(), open(sys.argv[2]).read())
    open(sys.argv[3], 'w').write(msl); print(info)
