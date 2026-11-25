"""Pass-as-compute kernels (dm/gfx/tools/dmsh_pcomp.py): the sample rewrite, the refusals, and a synthetic vertex / pixel pair in the translator's output shape composed and compiled with
the chain's own compile commands for the Mac and the iPhone (docs/reference/rendering.md, "One-draw passes as compute dispatches")."""
import ast
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'dm/gfx/tools'
sys.path.insert(0, str(TOOLS)); sys.path.insert(0, str(ROOT / 'dm/ios/tools'))
import dmsh_pcomp  # noqa: E402

VS = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;
constant bool dm_border_off [[function_constant(216)]];

struct spvDescriptorSetBuffer0
{
    constant float4* ub [[id(0)]];
};

struct main0_out
{
    float4 m_1 [[user(locn0)]];
    float4 m_2 [[user(locn1)]];
    float4 gl_Position [[position, invariant]];
};

struct main0_in
{
    float4 m_0 [[attribute(0)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.m_0.xy, 0.0, 1.0);
    out.m_1 = float4(in.m_0.zw, 0.0, 1.0) * spvDescriptorSet0.ub[0];
    out.m_2 = in.m_0;
    return out;
}

vertex main0_out main0_z(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.m_0.xy, 0.5, 1.0);
    out.m_1 = float4(in.m_0.zw, 0.0, 1.0);
    out.m_2 = in.m_0;
    return out;
}
'''

FS = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;
constant bool dm_border_off [[function_constant(216)]];
constant bool dm_border_live = !is_function_constant_defined(dm_border_off) || !dm_border_off;

struct spvDescriptorSetBuffer0
{
    texture2d<float> t0 [[id(0)]];
    sampler s0 [[id(1)]];
    texture2d_array<float> t1 [[id(2)]];
};

struct main0_out
{
    float4 m_9 [[color(0)]];
    float4 m_10 [[color(1)]];
};

struct main0_in
{
    float4 m_7 [[user(locn0)]];
    float4 m_8 [[user(locn1), flat]];
};

struct dm_blend_state { uint zero; };

static __attribute__((always_inline)) main0_out dm_body_main0(main0_in in, constant spvDescriptorSetBuffer0& spvDescriptorSet0, float4 gl_FragCoord, constant dm_blend_state& dm_blend)
{
    main0_out out = {};
    float2 uv = in.m_7.xy / gl_FragCoord.w;
    out.m_9 = spvDescriptorSet0.t0.sample(spvDescriptorSet0.s0, uv) + spvDescriptorSet0.t0.sample(spvDescriptorSet0.s0, uv, bias(1.0)) + spvDescriptorSet0.t0.sample(spvDescriptorSet0.s0, uv, level(2.0));
    out.m_10 = spvDescriptorSet0.t1.sample(spvDescriptorSet0.s0, uv, 1u) * in.m_8 + float4(float(dm_blend.zero));
    return out;
}
fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]], constant dm_blend_state& dm_blend [[buffer(28)]])
{
    main0_out out = dm_body_main0(in, spvDescriptorSet0, gl_FragCoord, dm_blend);
    return out;
}
'''


def mac_metal():   # dmsh_build.py's MAC_METAL, read without running the script (as test_dmsh_wrapv.py does)
    for n in ast.parse((TOOLS / 'dmsh_build.py').read_text()).body:
        if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'MAC_METAL' for t in n.targets):
            import dmsh_chain
            return eval(compile(ast.Expression(n.value), 'dmsh_build.py', 'eval'), {'dmsh_chain': dmsh_chain})
    raise AssertionError('no MAC_METAL in dmsh_build.py')


class PassCompute(unittest.TestCase):
    def test_samples_take_gradients(self):
        out = dmsh_pcomp.gradient_samples('a = spvDescriptorSet0.t0.sample(s, uv); b = (*x.y)[i].sample(s, f(uv, 2), bias(1.0)); c = t.sample(w, a...);')
        self.assertEqual(out, 'a = dm_qs(spvDescriptorSet0.t0, s, uv); b = dm_qs((*x.y)[i], s, f(uv, 2), bias(1.0)); c = dm_qs(t, w, a...);')

    def test_refusals(self):
        for body in ('x = dfdx(y);', 'x = fwidth(y);', 'discard_fragment();', 'x = t.sample_compare(s, uv, z);', 'x = simd_sum(y);', 'x = t.calculate_clamped_lod(s, uv);'):
            with self.assertRaises(ValueError, msg=body): dmsh_pcomp.gradient_samples(body)
        self.assertEqual(dmsh_pcomp.gradient_samples('x = t.sample_compare(s, uv, z, level(0));'), 'x = t.sample_compare(s, uv, z, level(0));')

    def test_compose(self):
        msl, info = dmsh_pcomp.compose(VS, FS)
        self.assertEqual(info['colors'], 2); self.assertEqual(info['entry'], 'dm_pc'); self.assertEqual(info['fconsts'], [216])
        self.assertEqual(msl.count('[[function_constant(216)]]'), 1)   # one declaration for both sides
        for needle in ('kernel void dm_pc(', f'[[buffer({dmsh_pcomp.FS_SLOT})]]', f'[[buffer({dmsh_pcomp.DRAW_SLOT})]]', '[[buffer(16)]]', '[[texture(0)]]', '[[texture(9)]]', '[[texture(16)]]',
                       'dm_in.m_8 = dm_o0.m_2;',   # flat: vertex 0's
                       'dm_bp.x * dm_o0.m_1',      # perspective
                       'dm_qs(spvDescriptorSet0.t1, spvDescriptorSet0.s0, uv, 1u)'):
            self.assertIn(needle, msl)

    def test_refused_pairs(self):
        with self.assertRaises(ValueError): dmsh_pcomp.compose(VS, FS.replace('float2 uv = ', 'float2 uv = dfdx(in.m_7.xy) + '))
        with self.assertRaises(ValueError): dmsh_pcomp.compose(VS.replace('struct main0_in\n{\n    float4 m_0 [[attribute(0)]];\n};\n', ''), FS)   # no stage input: no pulling entry

    @unittest.skipUnless(shutil.which('xcrun'), 'needs Xcode and Metal')
    def test_compiles_for_both(self):
        import ios_metal
        msl, _ = dmsh_pcomp.compose(VS, FS)
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 'k.metal'; src.write_text(msl)
            for cmd in (mac_metal(), ios_metal.METAL):
                r = subprocess.run(cmd + [str(src), '-o', str(Path(tmp) / 'k.air')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr[-2000:])


if __name__ == '__main__':
    unittest.main()
