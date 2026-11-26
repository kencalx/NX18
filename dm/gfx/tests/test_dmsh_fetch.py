"""Projective samples in the readable-tile version (dmsh_fetch.py): a sample at in.m_X.xy / in.m_X.w is rewritten like one at an interpolated output and marked 'proj', in its
spellings (a product with 1.0 / w either way round, a quotient) and not when a name is assigned twice or the components come from different outputs; screen_varyings finds the
clip → screen varying ((x + w) / 2, (w − y) / 2, ·, w) of gl_Position in every vertex entry point, after branches, and not with a flipped y, another w, an assignment in a branch,
an early return or a uniform coefficient; a sample at gl_FragCoord.xy [/ render scale] times a uniform is marked 'frag_pos' with its uniform references, and not at another
position, scale or uniform; the readable-tile version main0_f compiles for the Mac and the iPhone, beside the other entry points calling main0's body (main0_d, a compile unit's), with
only the body rewritten and main0 without function constants. With --fixture <dir>, writes t_feedback.m's tile-read shaders: fb_vs.metal, fb_fs.metal, the readable-tile library
fedcba9876543210_bf.metallib (main0_f, cut from the shader's compile as the build cuts it) and facts.json (the vertex shader's screen varyings and the fragment shader's calls), the
pixel-position shader fb_pos.metal with fedcba9876543211_bf.metallib and pos.json, the output-mapping-only fedcba9876543212_bf.metallib with om.json, and the NDC pair
fb_vs_pos.metal, fb_ndc.metal with fedcba9876543213_bf.metallib and ndc.json (S2Arm 4804ac50)"""
import json, pathlib, subprocess, sys, tempfile, unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'tools'))
import dmsh_abi, dmsh_fetch, dmsh_rewrite, dmsh_side, pso_offline

# Breath of the Wild's decal vertex shader 095cd6ad97fd779a as spirv-cross writes it, cut down (a full-screen triangle with w = 2 in place of the decal box), and a branch first,
# as Tears of the Kingdom's bb19fab2f950e587 has
VS = '''#include <metal_stdlib>
using namespace metal;

struct main0_out
{
    float4 m_45 [[user(locn4)]];
    float4 m_47 [[user(locn5)]];
    float4 gl_Position [[position]];
};

vertex main0_out main0(uint gl_VertexIndex [[vertex_id]])
{
    main0_out out = {};
    out.m_45 = float4(0.0, 0.0, 0.0, 1.0);
    out.m_47 = float4(0.0, 0.0, 0.0, 1.0);
    out.gl_Position.x = 0.0;
    out.gl_Position.y = 0.0;
    out.gl_Position.z = 0.0;
    out.gl_Position.w = 1.0;
    bool _81 = gl_VertexIndex == 1u;
    float _90 = -1.0;
    if (_81)
    {
        _90 = 3.0;
        out.m_47.x = 1.0;
    }
    float _92 = (gl_VertexIndex == 2u) ? 3.0 : -1.0;
    float _313 = 2.0;
    float _309 = _90 * _313;
    float _311 = _92 * _313;
    out.gl_Position.x = _309;
    out.gl_Position.y = _311;
    out.gl_Position.w = _313;
    out.m_45.w = _313;
    float _327 = _309 + _313;
    float _329 = -_311;
    float _331 = _329 + _313;
    float _361 = _327 * 0.5;
    float _363 = _331 * 0.5;
    out.m_45.x = _361;
    out.m_45.y = _363;
    out.m_47.w = _313;
    out.m_47.x = fma(out.gl_Position.x, 0.5, out.gl_Position.w * 0.5);
    out.m_47.y = fma(-out.gl_Position.y, 0.5, out.gl_Position.w * 0.5);
    out.gl_Position.z = fma(out.gl_Position.z, 0.5, out.gl_Position.w * 0.5);
    return out;
}
'''
# The decal fragment shader's G-buffer read (4d3d5a4408c2e8d9), its colours rotated into its output: green from blue, blue from red, red from green
FS = '''#include <metal_stdlib>
using namespace metal;

struct spvDescriptorSetBuffer0
{
    texture2d<float> fp_t_tcb_8 [[id(0)]];
    sampler fp_t_tcb_8Smplr [[id(1)]];
};

struct main0_out
{
    float4 m_46 [[color(0)]];
};

struct main0_in
{
    float4 m_35 [[user(locn4)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    float _57 = in.m_35.w;
    float _59 = in.m_35.x;
    float _61 = in.m_35.y;
    float _67 = 1.0 / _57;
    float _69 = _59 * _67;
    float _71 = _61 * _67;
    float2 _309 = float2(_69, _71);
    float4 _84 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_309, float2(0.0), isnan(_309))).xyzw;
    out.m_46 = float4(_84.y, _84.z, _84.x, 1.0);
    return out;
}
'''
BINDINGS = [{'kind': dmsh_abi.KIND_TEX, 'msl_name': 'fp_t_tcb_8', 'reg': 0}]
FS_KEY = 'fedcba9876543210'
# Splatoon Raiders' ink stamp (6a5b76a60670e513), cut down: its ink map sampled at gl_FragCoord over the render scale times c[6].xy (1 / the map's size), through the border colour
# correction; the read's channels rotated into its output (red from green, green from blue plus one minus alpha): red where it read green, black where it read red, and green
# wherever a missing channel of an R or RG map read other than 0, 0, 1
FS_POS = """#include <metal_stdlib>
using namespace metal;

template<typename V, typename T, typename... A> static inline __attribute__((always_inline)) V dm_bs(V r, constant uint* b, uint i, T t, sampler w, A... a) { return r; }

struct _10
{
    float4 _m0[5];
    float4 _m5[1];
};

struct _16
{
    float4 _m0[16];
};

struct spvDescriptorSetBuffer0
{
    texture2d<float> fp_t_tcb_8 [[id(0)]];
    sampler fp_t_tcb_8Smplr [[id(1)]];
    constant _10* support_buffer [[id(2)]];
    constant _16* fp_c3 [[id(3)]];
    constant uint* dm_border [[id(4)]];
    sampler fp_t_tcb_8Smplr_w [[id(5)]];
};

struct main0_out
{
    float4 m_46 [[color(0)]];
};

fragment main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    float _43 = gl_FragCoord.x;
    float _45 = (*spvDescriptorSet0.support_buffer)._m5[0].x;
    float _47 = _43 / _45;
    float _49 = gl_FragCoord.y;
    float _51 = (*spvDescriptorSet0.support_buffer)._m5[0].x;
    float _53 = _49 / _51;
    float _55 = _47 * (*spvDescriptorSet0.fp_c3)._m0[6].x;
    float _57 = _53 * (*spvDescriptorSet0.fp_c3)._m0[6].y;
    float2 _286 = float2(_55, _57);
    float4 _59 = dm_bs(spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_286, float2(0.0), isnan(_286))), spvDescriptorSet0.dm_border, 0u, spvDescriptorSet0.fp_t_tcb_8, spvDescriptorSet0.fp_t_tcb_8Smplr_w, select(_286, float2(0.0), isnan(_286))).xyzw;
    out.m_46 = float4(_59.y, _59.z + (1.0 - _59.w), _59.x, 1.0);
    return out;
}
"""
POS_KEY = 'fedcba9876543211'

# Output-mapping-only: no rewritable sample, but the host still needs a readable-tile version so colour
# outputs can move (bf_want.tsv / om_only_ok). Magenta on color(0); main0_f remaps it through OM_0_k.
FS_OM = """#include <metal_stdlib>
using namespace metal;

struct main0_out
{
    float4 m_46 [[color(0)]];
};

fragment main0_out main0()
{
    main0_out out = {};
    out.m_46 = float4(1.0, 0.0, 1.0, 1.0);
    return out;
}
"""
OM_KEY = 'fedcba9876543212'



def compile_lib(src, root, name, sdk='macosx'):   # → the library path; CalledProcessError with the compiler's message
    msl = root / (name + '.metal'); msl.write_text(src); air = root / (name + '.' + sdk + '.air'); lib = root / (name + '.metallib')
    for cmd in (['xcrun', '-sdk', sdk, 'metal', '-c', '-fmodules-cache-path=' + str(root / 'mc'), str(msl), '-o', str(air)], ['xcrun', '-sdk', sdk, 'metallib', str(air), '-o', str(lib)]):
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode: raise subprocess.CalledProcessError(r.returncode, cmd, r.stdout, r.stderr)
    return lib


class ProjectiveSample(unittest.TestCase):
    def calls(self, src):
        v, meta = dmsh_fetch.fold(src, BINDINGS)
        return meta if v is None else meta['calls']

    def test_product_with_reciprocal(self):
        self.assertEqual(self.calls(FS), [{'fc': 0, 'tex_reg': 0, 'varying_locn': 4, 'proj': 1}])

    def test_reciprocal_first_and_quotient(self):
        self.assertEqual(self.calls(FS.replace('_59 * _67', '_67 * _59'))[0].get('proj'), 1)
        self.assertEqual(self.calls(FS.replace('float _69 = _59 * _67;', 'float _69 = _59 / _57;').replace('float _71 = _61 * _67;', 'float _71 = _61 / _57;'))[0].get('proj'), 1)

    def test_rewritten_like_a_plain_sample(self):
        v, _ = dmsh_fetch.fold(FS, BINDINGS)
        self.assertIn('(fx0 == 0 ? fb0 : ', v)
        self.assertIn('float4 fb0 [[color(0), function_constant(FB_0)]]', v)
        self.assertIn('fragment main0_out_f main0_f(', v)
        self.assertIn('static __attribute__((always_inline)) main0_out dm_body_main0(', v)

    def test_not_rewritten(self):
        for why, src in (('a name assigned twice', FS.replace('    float2 _309', '    _69 = 0.5;\n    float2 _309')),
                         ('w from another output', FS.replace('float _57 = in.m_35.w;', 'float _57 = in.m_35.z;')),
                         ('x from another output', FS.replace('float4 m_35 [[user(locn4)]];', 'float4 m_35 [[user(locn4)]];\n    float4 m_36 [[user(locn5)]];').replace('float _59 = in.m_35.x;', 'float _59 = in.m_36.x;')),
                         ('not divided by w', FS.replace('float _67 = 1.0 / _57;', 'float _67 = 2.0 / _57;'))):
            with self.subTest(why=why): self.assertEqual(self.calls(src), 'no rewritable sample')

    def test_compiles_on_both_platforms(self):
        v, _ = dmsh_fetch.fold(FS, BINDINGS)
        with tempfile.TemporaryDirectory() as d:
            for sdk in ('macosx', 'iphoneos'):
                with self.subTest(sdk=sdk):
                    try: compile_lib(v, pathlib.Path(d), 'fs_' + sdk, sdk)
                    except subprocess.CalledProcessError as e: self.fail(e.stderr)


# The clip position's NDC turned into the screen UV by the pixel shader itself, as Xenoblade Chronicles 3's G-buffer decals and lights do (S2Arm 4804ac50): FS with its projective
# components through fma(·, 0.5, 0.5) and fma(·, -0.5, 0.5)
FS_NDC = FS.replace('    float2 _309 = float2(_69, _71);', '    float _73 = fma(_69, 0.5, 0.5);\n    float _75 = fma(_71, -0.5, 0.5);\n    float2 _309 = float2(_73, _75);')
# A vertex shader whose output 4 is gl_Position itself (the vertex side of an NDC sample), written per component from the position's variables and once from the position read back
NDC_KEY = 'fedcba9876543213'
VS_POS = VS.replace('    out.m_45.x = _361;\n    out.m_45.y = _363;\n', '    out.m_45.x = _309;\n    out.m_45.y = out.gl_Position.y;\n')


# A refraction read (checked against MacNativeGames 3657c12f (MIT): Tears of the Kingdom's Rauru ghost in Ukouh Shrine samples the HDR target it draws into at its screen position
# plus an offset read from a normal map): FS with a second texture read at the screen position, its x and y scaled into the offset of the target's read. The target's read is not this
# pixel's, so it is no rewritable sample and its slot is mixed: nvn_mtl.m fb_tile_plan takes no tile read for it, and fb_prepare gives the draw a snapshot (t_feedback.m tile_case)
FS_REFRACT = FS.replace('    texture2d<float> fp_t_tcb_8 [[id(0)]];\n    sampler fp_t_tcb_8Smplr [[id(1)]];\n',
                        '    texture2d<float> fp_t_tcb_8 [[id(0)]];\n    sampler fp_t_tcb_8Smplr [[id(1)]];\n    texture2d<float> fp_t_tcb_9 [[id(2)]];\n    sampler fp_t_tcb_9Smplr [[id(3)]];\n'
               ).replace('    float4 _84 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_309, float2(0.0), isnan(_309))).xyzw;\n',
                         '    float4 _80 = spvDescriptorSet0.fp_t_tcb_9.sample(spvDescriptorSet0.fp_t_tcb_9Smplr, select(_309, float2(0.0), isnan(_309))).xyzw;\n'
                         '    float _86 = fma(_80.x, 0.05, _69);\n    float _88 = fma(_80.y, 0.05, _71);\n    float2 _90 = float2(_86, _88);\n'
                         '    float4 _84 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_90, float2(0.0), isnan(_90))).xyzw;\n')
BINDINGS_REFRACT = BINDINGS + [{'kind': dmsh_abi.KIND_TEX, 'msl_name': 'fp_t_tcb_9', 'reg': 1}]


class OffsetSample(unittest.TestCase):
    def test_the_fixture_reads_at_an_offset(self):
        self.assertIn('select(_90, float2(0.0), isnan(_90))', FS_REFRACT); self.assertIn('fp_t_tcb_9.sample(', FS_REFRACT)

    def test_an_offset_read_is_no_tile_read(self):   # only the normal map's read at the screen position is rewritable; the target's slot is mixed
        v, meta = dmsh_fetch.fold(FS_REFRACT, BINDINGS_REFRACT)
        self.assertIsNotNone(v, meta)
        self.assertEqual([c['tex_reg'] for c in meta['calls']], [1])
        self.assertEqual(meta['mixed_regs'], [0])

    def test_with_a_read_at_its_own_pixel_too(self):   # the same target also read at the screen position: that read is rewritable, but its slot stays mixed
        src = FS_REFRACT.replace('    out.m_46 = ', '    float4 _92 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_309, float2(0.0), isnan(_309))).xyzw;\n    out.m_46 = _92 + ')
        v, meta = dmsh_fetch.fold(src, BINDINGS_REFRACT)
        self.assertIsNotNone(v, meta)
        self.assertIn(0, [c['tex_reg'] for c in meta['calls']])
        self.assertIn(0, meta['mixed_regs'])


class NdcSample(unittest.TestCase):
    def calls(self, src):
        v, meta = dmsh_fetch.fold(src, BINDINGS)
        return meta if v is None else meta['calls']

    def test_fma_to_screen_uv(self):
        self.assertEqual(self.calls(FS_NDC), [{'fc': 0, 'tex_reg': 0, 'varying_locn': 4, 'proj': 1, 'ndc': 1}])
        self.assertEqual(self.calls(FS_NDC.replace('fma(_71, -0.5, 0.5)', 'fma(_71, (-0.5), 0.5)'))[0].get('ndc'), 1)

    def test_not_rewritten(self):
        for why, src in (('y not flipped', FS_NDC.replace('fma(_71, -0.5, 0.5)', 'fma(_71, 0.5, 0.5)')),
                         ('x flipped', FS_NDC.replace('fma(_69, 0.5, 0.5)', 'fma(_69, -0.5, 0.5)')),
                         ('another offset', FS_NDC.replace('fma(_69, 0.5, 0.5)', 'fma(_69, 0.5, 0.25)')),
                         ('another scale', FS_NDC.replace('fma(_71, -0.5, 0.5)', 'fma(_71, -0.25, 0.5)')),
                         ('not divided by w', FS_NDC.replace('float _67 = 1.0 / _57;', 'float _67 = 2.0 / _57;')),
                         ('components swapped', FS_NDC.replace('float2(_73, _75)', 'float2(_75, _73)')),
                         ('a name assigned twice', FS_NDC.replace('    float2 _309', '    _73 = 0.5;\n    float2 _309'))):
            with self.subTest(why=why): self.assertEqual(self.calls(src), 'no rewritable sample')

    def test_compiles_on_both_platforms(self):
        v, _ = dmsh_fetch.fold(FS_NDC, BINDINGS)
        with tempfile.TemporaryDirectory() as d:
            for sdk in ('macosx', 'iphoneos'):
                with self.subTest(sdk=sdk):
                    try: compile_lib(v, pathlib.Path(d), 'ndc_' + sdk, sdk)
                    except subprocess.CalledProcessError as e: self.fail(e.stderr)


class EightOutputs(unittest.TestCase):   # S2Arm 69f75818: Xenoblade Chronicles 3's decals and lights write 5 and 6 targets
    @staticmethod
    def outputs(n):
        members = ''.join(f'    float4 m_{46 + q} [[color({q})]];\n' for q in range(n))
        stores = ''.join(f'    out.m_{46 + q} = _84;\n' for q in range(1, n))
        return FS.replace('    float4 m_46 [[color(0)]];\n', members).replace('    return out;', stores + '    return out;')

    def test_up_to_eight(self):
        for n in (5, 6, 8):
            with self.subTest(outputs=n):
                v, meta = dmsh_fetch.fold(self.outputs(n), BINDINGS)
                self.assertIsNotNone(v, meta)
                self.assertEqual([o['color'] for o in meta['outputs']], list(range(n)))
                self.assertIn(f'constant bool OM_{n - 1}_7 [[function_constant({64 + 8 * (n - 1) + 7})]]', v)

    def test_past_four_only_with_a_provable_sample(self):
        plain = self.outputs(5).replace('float2 _309 = float2(_69, _71);', 'float2 _309 = float2(_59, _61);')
        self.assertEqual(dmsh_fetch.fold(plain, BINDINGS), (None, 'more than 4 outputs and no sample a tile read can prove'))
        self.assertIsNotNone(dmsh_fetch.fold(plain, BINDINGS, om_only_ok=True)[0], 'a bf_want row')
        four = self.outputs(4).replace('float2 _309 = float2(_69, _71);', 'float2 _309 = float2(_59, _61);')
        self.assertIsNotNone(dmsh_fetch.fold(four, BINDINGS)[0], 'up to 4 outputs as before')

    def test_nine_refused(self):
        self.assertEqual(dmsh_fetch.fold(self.outputs(9), BINDINGS), (None, 'the output struct is not plain color outputs (or has more than 8)'))

    def test_a_sample_mask_member_refused(self):   # a game's own sample mask output: the readable-tile version would not write it
        src = FS.replace('    float4 m_46 [[color(0)]];\n', '    float4 m_46 [[color(0)]];\n    uint gl_SampleMask [[sample_mask]];\n')
        self.assertIsNone(dmsh_fetch.fold(src, BINDINGS)[0])

    def test_eight_compile_on_both_platforms(self):
        v, _ = dmsh_fetch.fold(self.outputs(8), BINDINGS)
        with tempfile.TemporaryDirectory() as d:
            for sdk in ('macosx', 'iphoneos'):
                with self.subTest(sdk=sdk):
                    try: compile_lib(v, pathlib.Path(d), 'eight_' + sdk, sdk)
                    except subprocess.CalledProcessError as e: self.fail(e.stderr)


class PixelPositionSample(unittest.TestCase):
    def calls(self, src):
        v, meta = dmsh_fetch.fold(src, BINDINGS)
        return meta if v is None else meta['calls']

    def test_over_the_render_scale(self):
        self.assertEqual(self.calls(FS_POS), [{'fc': 0, 'tex_reg': 0, 'frag_pos': [[0, 6, 0], [0, 6, 1]]}])

    def test_without_the_render_scale_and_uniform_first(self):
        src = FS_POS.replace('    float _47 = _43 / _45;\n', '').replace('_47 * (*spvDescriptorSet0.fp_c3)._m0[6].x', '(*spvDescriptorSet0.fp_c3)._m0[6].x * _43')
        self.assertEqual(self.calls(src)[0]['frag_pos'], [[0, 6, 0], [0, 6, 1]])

    def test_not_rewritten(self):
        for why, src in (('y from x', FS_POS.replace('float _49 = gl_FragCoord.y;', 'float _49 = gl_FragCoord.x;')),
                         ('divided by a uniform', FS_POS.replace('float _45 = (*spvDescriptorSet0.support_buffer)._m5[0].x;', 'float _45 = (*spvDescriptorSet0.fp_c3)._m0[1].x;')),
                         ('a constant scale', FS_POS.replace('_47 * (*spvDescriptorSet0.fp_c3)._m0[6].x', '_47 * 0.25')),
                         ('a driver constant bank', FS_POS.replace('(*spvDescriptorSet0.fp_c3)._m0[6].x', '(*spvDescriptorSet0.fp_c2)._m0[6].x')),
                         ('an offset', FS_POS.replace('float2 _286 = float2(_55, _57);', 'float _58 = _55 + 0.5;\n    float2 _286 = float2(_58, _57);')),
                         ('a name assigned twice', FS_POS.replace('    float2 _286', '    _55 = 0.5;\n    float2 _286'))):
            with self.subTest(why=why): self.assertEqual(self.calls(src), 'no rewritable sample')

    def test_compiles_on_both_platforms(self):
        v, _ = dmsh_fetch.fold(FS_POS, BINDINGS)
        with tempfile.TemporaryDirectory() as d:
            for sdk in ('macosx', 'iphoneos'):
                with self.subTest(sdk=sdk):
                    try: compile_lib(v, pathlib.Path(d), 'pos_' + sdk, sdk)
                    except subprocess.CalledProcessError as e: self.fail(e.stderr)


# A read at a computed offset, as spirv-cross writes the translator's: the size comparison (with the slot's size in words from the size table, bank DMSH_CBSIZE_BANK) a value of its
# own, which chooses row 0 for the index and 0 for the value when out of bounds. Reads at fixed offsets are not bounded in the shader (the host's zeros, GitHub issue #2066)
COMPUTED = ('bool _5 = ((uint(_3) << 2u) | uint(_4)) < ((*spvDescriptorSet0.fp_c%d)._m0[2].w >> 2u);\n'
            'float _6 = _5 ? (*spvDescriptorSet0.fp_c14)._m0[_5 ? _3 : 0][_4] : 0.0;' % dmsh_abi.CBSIZE_BANK)

class UniformBounds(unittest.TestCase):
    def test_select_guards_at_a_computed_offset(self):   # a load and a select (GitHub PR #2127); the index keeps its row-0 choice, so the load is inside the binding without a branch
        row = '(*spvDescriptorSet0.fp_c14)._m0[_5 ? _3 : 0]'
        got = dmsh_rewrite.select_guards(COMPUTED)
        self.assertEqual(got.split('\n')[1], 'float _6 = select(0.0, %s[_4], _5);' % row)
        self.assertEqual(dmsh_rewrite.select_guards(got), got, 'a second pass changes nothing')
        for why, a, b in (('in parentheses', 'float _6 = _5 ? %s[_4] : 0.0;' % row, 'float _6 = _7 * (_5 ? %s[_4] : 0.0);' % row),
                          ('a fixed component', '[_4] : 0.0;', '.z : 0.0;'), ('an unsigned word', '[_4] : 0.0;', '[_4] : 0u;')):
            with self.subTest(why=why):
                got = dmsh_rewrite.select_guards(COMPUTED.replace(a, b))
                self.assertNotIn(' : 0.0', got); self.assertNotIn(' : 0u', got); self.assertEqual(got.count('select('), 1)
        other = COMPUTED + '\nfloat _9 = _8 ? (*spvDescriptorSet0.fp_c14)._m0[_8 ? _3 : 0][_4] : 0.0;'   # _8 is no size comparison: the game's own choice
        self.assertTrue(dmsh_rewrite.select_guards(other).endswith(other.split('\n')[2]))

    def test_select_guards_leaves_none(self):   # a bounded read in a form it does not know is an error, not a branch left in the shader
        fixed = '((117u < ((*spvDescriptorSet0.fp_c%d)._m0[0].x >> 2u)) ? (*spvDescriptorSet0.fp_c5)._m0[29].y : 0.0)' % dmsh_abi.CBSIZE_BANK   # the translator bounds no fixed offset now
        for why, src in (('a fixed offset compared in the shader', 'float _1 = %s;' % fixed),
                         ('a computed offset with another index', COMPUTED.replace('[_5 ? _3 : 0]', '[_3]')),
                         ('another zero', COMPUTED.replace(': 0.0', ': -0.0')),
                         ('a size comparison used as a choice elsewhere', COMPUTED + '\nfloat _9 = _5 ? _7 : 0.0;')):
            with self.subTest(why=why):
                with self.assertRaisesRegex(ValueError, 'not written as a select'): dmsh_rewrite.select_guards(src)
        self.assertEqual(dmsh_rewrite.select_guards('float _1 = _2 ? _3 : 0.0;'), 'float _1 = _2 ? _3 : 0.0;', 'no descriptor set')
        bare = 'float _1 = (*spvDescriptorSet0.fp_c5)._m0[29].y;'
        self.assertEqual(dmsh_rewrite.select_guards(bare), bare, 'a read at a fixed offset is left as it is')
        other = bare + '\nfloat _9 = _8 ? _1 : 0.0;'
        self.assertEqual(dmsh_rewrite.select_guards(other), other, 'an ordinary choice without any size comparison is left as it is')

class ScreenVaryings(unittest.TestCase):
    def test_both_spellings_after_a_branch(self):
        self.assertEqual(dmsh_fetch.screen_varyings(VS), [4, 5])

    def test_every_entry_point(self):
        z = VS.split('vertex main0_out main0(')[1].replace('out.m_45.x = _361;', 'out.m_45.x = _363;')
        self.assertEqual(dmsh_fetch.screen_varyings(VS + '\nvertex main0_out main0_z(' + z), [5])

    def test_not_a_screen_varying(self):
        for why, src in (('y not flipped', VS.replace('float _329 = -_311;', 'float _329 = _311;')),
                         ('another w', VS.replace('out.m_45.w = _313;', 'out.m_45.w = 1.0;')),
                         ('assigned in a branch', VS.replace('    out.m_45.y = _363;\n', '    if (_81)\n    {\n        out.m_45.y = _363;\n    }\n')),
                         ('a uniform coefficient', VS.replace('float _361 = _327 * 0.5;', 'float _361 = _327 * spvDescriptorSet0.s;')),
                         ('a position read before its final value', VS.replace('float _327 = _309 + _313;', 'float _327 = out.gl_Position.x + _313;').replace('    out.gl_Position.x = _309;\n', '').replace('    out.m_45.x = _361;\n', '    out.m_45.x = _361;\n    out.gl_Position.x = _309;\n'))):
            with self.subTest(why=why): self.assertNotIn(4, dmsh_fetch.screen_varyings(src))
        early = VS.replace('    float _92', '    if (_81)\n    {\n        return out;\n    }\n    float _92')
        self.assertEqual(dmsh_fetch.screen_varyings(early), [], 'an early return')


class ScreenPositions(unittest.TestCase):   # the vertex side of an NDC sample (S2Arm 4804ac50)
    def test_the_position_itself(self):
        self.assertEqual(dmsh_fetch.screen_positions(VS_POS), [4])
        self.assertEqual(dmsh_fetch.screen_varyings(VS_POS), [5], 'no longer a screen varying')
        self.assertEqual(dmsh_fetch.screen_positions(VS), [], 'screen varyings are not positions')

    def test_every_entry_point(self):
        z = VS_POS.split('vertex main0_out main0(')[1].replace('out.m_45.x = _309;', 'out.m_45.x = _311;')
        self.assertEqual(dmsh_fetch.screen_positions(VS_POS + '\nvertex main0_out main0_z(' + z), [])

    def test_not_the_position(self):
        for why, src in (('y flipped', VS_POS.replace('out.m_45.y = out.gl_Position.y;', 'out.m_45.y = -_311;')),
                         ('another w', VS_POS.replace('out.m_45.w = _313;', 'out.m_45.w = 1.0;')),
                         ('x and y swapped', VS_POS.replace('out.m_45.x = _309;', 'out.m_45.x = _311;')),
                         ('assigned in a branch', VS_POS.replace('    out.m_45.x = _309;\n', '    if (_81)\n    {\n        out.m_45.x = _309;\n    }\n'))):
            with self.subTest(why=why): self.assertEqual(dmsh_fetch.screen_positions(src), [])


class OutputMappingOnly(unittest.TestCase):
    def test_refused_without_the_flag(self):
        v, meta = dmsh_fetch.fold(FS_OM, [])
        self.assertIsNone(v)
        self.assertEqual(meta, 'no rewritable sample')

    def test_folded_with_the_flag(self):
        v, meta = dmsh_fetch.fold(FS_OM, [], om_only_ok=True)
        self.assertIsNotNone(v)
        self.assertEqual(meta['calls'], [])
        self.assertEqual(meta['outputs'], [{'color': 0, 'type': 'float4'}])
        self.assertIn('fragment main0_out_f main0_f(', v)
        self.assertIn('static __attribute__((always_inline)) main0_out dm_body_main0(', v)
        self.assertIn('constant bool OM_0_0 [[function_constant(64)]]', v)
        self.assertIn('constant bool OM_0_1 [[function_constant(65)]]', v)
        self.assertIn('if (OM_0_1) out.m_46_at1 = r.m_46;', v)
        self.assertNotIn('constant int FX_0', v)

    def test_compiles_on_both_platforms(self):
        v, _ = dmsh_fetch.fold(FS_OM, [], om_only_ok=True)
        with tempfile.TemporaryDirectory() as d:
            for sdk in ('macosx', 'iphoneos'):
                with self.subTest(sdk=sdk):
                    try: compile_lib(v, pathlib.Path(d), 'om_' + sdk, sdk)
                    except subprocess.CalledProcessError as e: self.fail(e.stderr)


def tile_library(src, root, name, side=frozenset(), sdk='macosx'):
    """The libraries ps_libraries cuts from a folded source: (base, side..., main0_f) as files root/<name>_<i>.metallib; raises AssertionError unless main0_f, alone in the last, declares
    function constants and the base's entry points none (the logic operation entry points have their own)"""
    lib = compile_lib(src, root, name, sdk); libs = []
    for i, piece in enumerate(dmsh_side.cut(lib.read_bytes(), *([side] if side else []), {'main0_f'})):
        libs.append(root / f'{name}_{i}.metallib'); libs[-1].write_bytes(piece)
    base, tile = pso_offline.functions(libs[0]), pso_offline.functions(libs[-1])
    assert list(tile) == ['main0_f'] and tile['main0_f'], f'{name}: the readable-tile library {tile}'
    assert 'main0' in base and not any(base.values()), f'{name}: the base library {base}'
    return libs


# A pixel shader with two outputs, as the dual-source entry point main0_d wants (dmsh_entry.py fs_dual), with FS's projective sample
FS2 = FS.replace('    float4 m_46 [[color(0)]];\n', '    float4 m_46 [[color(0)]];\n    float4 m_47 [[color(1)]];\n').replace('    return out;', '    out.m_47 = _84;\n    return out;')


class OtherEntryPoints(unittest.TestCase):
    def dual(self):   # as dmsh_build.py finish writes it: main0's body shared, main0_d calling it
        e = dmsh_side.entry(FS2, 'main0')
        return dmsh_side.shared_body(FS2) + '\nstruct main0_out_d\n{\n    float4 m_46 [[color(0)]];\n    float4 m_47 [[color(0), index(1)]];\n};\n\n' + \
            dmsh_side.calling(e, 'main0_d', 'main0_out_d', 'return main0_out_d{out.m_46, out.m_47};')

    def test_only_the_body_is_rewritten(self):
        v, meta = dmsh_fetch.fold(self.dual(), BINDINGS)
        self.assertIsNotNone(v, meta)
        self.assertEqual(len(meta['calls']), 1)
        self.assertEqual(v.count('fx0 == 0 ? fb0 : '), 1)
        self.assertEqual(v.count('dm_body_main0(in, spvDescriptorSet0, -1, float4(0.0)'), 2)   # main0 and main0_d turn the tile read off

    def test_a_copy_of_the_body_is_left_alone(self):   # main0_d as a copy of main0 (fs_dual before it called the body): its sample has no fb0 to read
        copy = FS2 + '\nstruct main0_out_d\n{\n    float4 m_46 [[color(0)]];\n    float4 m_47 [[color(0), index(1)]];\n};\n\n' + \
            FS2[FS2.index('fragment main0_out main0('):].replace('fragment main0_out main0(', 'fragment main0_out_d main0_d(').replace('return out;', 'return main0_out_d{out.m_46, out.m_47};')
        v, meta = dmsh_fetch.fold(copy, BINDINGS)
        self.assertEqual((len(meta['calls']), v.count('fx0 == 0 ? fb0 : ')), (1, 1))
        with tempfile.TemporaryDirectory() as d:
            try: tile_library(v, pathlib.Path(d), 'copy')
            except subprocess.CalledProcessError as e: self.fail(e.stderr)

    def test_builds_beside_a_dual_source_entry_point(self):
        v, _ = dmsh_fetch.fold(self.dual(), BINDINGS)
        with tempfile.TemporaryDirectory() as d:
            try: tile_library(v, pathlib.Path(d), 'dual')
            except subprocess.CalledProcessError as e: self.fail(e.stderr)

    def test_builds_in_a_compile_unit(self):   # the base, the alpha test and logic operation entry points and main0_f from one compile
        for name, src in (('unit', FS), ('unit_dual', self.dual())):
            with self.subTest(name):
                u, info = dmsh_side.unit(src)
                self.assertIsNotNone(u, info)
                v, meta = dmsh_fetch.fold(u, BINDINGS)
                self.assertIsNotNone(v, meta)
                with tempfile.TemporaryDirectory() as d:
                    for sdk in ('macosx', 'iphoneos'):
                        try: tile_library(v, pathlib.Path(d), name + sdk, set(info['alpha'] + info['logic']), sdk)
                        except subprocess.CalledProcessError as e: self.fail(e.stderr)


def fixture(out):
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    (out / 'fb_vs.metal').write_text(VS); (out / 'fb_fs.metal').write_text(FS); (out / 'fb_pos.metal').write_text(FS_POS)
    (out / 'fb_vs_pos.metal').write_text(VS_POS); (out / 'fb_ndc.metal').write_text(FS_NDC)
    for src, key, name, facts, om in ((FS, FS_KEY, 'v', 'facts.json', False), (FS_POS, POS_KEY, 'vp', 'pos.json', False), (FS_OM, OM_KEY, 'vom', 'om.json', True),
                                      (FS_NDC, NDC_KEY, 'vn', 'ndc.json', False)):
        v, meta = dmsh_fetch.fold(src, BINDINGS if not om else [], om_only_ok=om)
        tile_library(v, out, name)[-1].rename(out / f'{key}_bf.metallib')
        (out / facts).write_text(json.dumps({**({'screen': dmsh_fetch.screen_varyings(VS)} if src is FS else {}),
                                             **({'screen_pos': dmsh_fetch.screen_positions(VS_POS)} if src is FS_NDC else {}), 'calls': meta['calls'], 'outputs': meta['outputs']}))

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture': fixture(sys.argv[2])
    else: unittest.main()
