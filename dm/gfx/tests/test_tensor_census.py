"""The HMMA census (dm/gfx/tools/tensor_census.py), pure Python: on the committed translator's Metal source for six synthetic Ampere programs (fixtures/tensor_census, cut
down: no game's code), the class of each shuffle, each LDSM's address leaves, matrices and row pitch, where each HMMA's operands come from and what reads its D, and the
three stage verdicts; then variants of them made by small edits (a barrier, a loop, a phi, buffer reads, another local size, shared memory in a device buffer), among them
the forms a verdict must not be fooled by (a buffer word's low bits in an OR, a pitch that differs between warps or matrices, a buffer index that is no constant-buffer one,
names the reader does not know, the game's own shuffles, LDSM words with other uses); the C arithmetic the pitch is evaluated with; and the library finder on a library
folder packed into its one-file image (dm/tools/shader_lib.py)."""
import ast
import contextlib
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
TOOLS = REPO / 'dm/gfx/tools'
FIXTURES = Path(__file__).resolve().parent / 'fixtures/tensor_census'
sys.path.insert(0, str(TOOLS)); sys.path.insert(0, str(REPO / 'dm/tools'))
import shader_lib  # noqa: E402
import tensor_census as tc  # noqa: E402

# the shader build's HMMA rewrite, as test_dmsh_hmma.py takes it: a library's <key>_b.metal has the helper's body replaced, the kernel as it was
tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
selected = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name == 'hmma_msl')
            or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) == 'HMMA_BODY' for t in n.targets))]
scope = {'re': re}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), scope)
hmma_msl = scope['hmma_msl']

BUFFERS = ('struct _16\n{\n    float4 _m0[4096];\n};\n\nstruct _23\n{\n    uint _m0[1];\n};\n\nstruct spvDescriptorSetBuffer0\n{\n    constant _16* cp_c1 [[id(0)]];\n'
           '    const device _23* cp_s2 [[id(1)]];\n};\n\n')   # as spirv-cross declares the translator's constant buffers (float4 words) and storage buffers (uint words)
SHUFFLE_HELPER = 'template<typename T>\ninline T spvSubgroupShuffle(T value, ushort lane)\n{\n    return simd_shuffle(value, lane);\n}\n\n'   # as spirv-cross defines it
LOCAL = {'cutlass': [64, 2, 1], 'swizzle': [32, 1, 1], 'opaque': [32, 1, 1], 'const': [32, 1, 1], 'chain': [32, 1, 1], 'net': [32, 1, 1]}


def source(name):
    src = (FIXTURES / f'{name}.metal').read_text()
    return hmma_msl(src) if 'dmsh_hmma16816_f16(' in src else src


def census(src, local=None, name='t'):
    return tc.Census(src, local or [32, 1, 1], name).report()


def kinds(rep):
    return {k: v for k, v in rep['shuffles'].items() if k != 'total' and v}


def ldsm(rep):
    return [(g['transposed'], g['matrices'], g['leaves'], g['pitch']) for g in rep['ldsm']]


def edit(src, old, new):
    assert src.count(old) == 1, old
    return src.replace(old, new)


def with_buffers(src):   # the buffers' declarations the cut-down fixtures leave out, for what is read from their types
    return edit(src, 'kernel void main0(', BUFFERS + 'kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], ')


def address(name, expr, local=None):   # the program with its first LDSM's address replaced: that LDSM's report
    old = {'cutlass': '    int _46 = _44 + _42;', 'chain': '    int _42 = as_type<int>(_40) * 16;'}[name]
    return census(edit(source(name), old, old.split('=')[0] + f'= {expr};'), local or LOCAL[name])['ldsm'][0]


class Programs(unittest.TestCase):
    """The six programs, and what their sources show: the address arithmetic, which LDSM feeds which HMMA operand, the MOVMs"""

    def rep(self, name): return census(source(name), LOCAL[name], name)

    def test_cutlass(self):   # the CUTLASS form: from tid.x, x4, rows 64 bytes apart
        r = self.rep('cutlass')
        self.assertEqual(kinds(r), {'ldsm_address': 4})
        self.assertEqual(ldsm(r), [(False, 4, ['tid.x'], 64)])
        self.assertEqual(r['ldsm'][0]['matrix_bases'], [0, 512, 16, 528])
        self.assertFalse(r['ldsm'][0]['uniform_part_varies'])
        self.assertEqual(r['verdict']['stage1'], dict(ldsm=1, of=1, shuffles=4, of_shuffles=4, blockers={}, phi_only_uniform_inputs=0))
        self.assertEqual(r['verdict']['stage3'], dict(ldsm=0, of=1, why_not={'feeds no HMMA A or B': 1}, if_phi_uniform=0))   # nothing to tile into
        self.assertEqual((r['ldsm'][0]['row_alignment'], r['ldsm'][0]['words_used_elsewhere']), (16, 4))   # its words are stored
        self.assertEqual(r['counts']['shared_stores'], 4)

    def test_swizzle(self):   # an XOR swizzle: a lane function (stage 1), but no constant pitch (no stage 3)
        r = self.rep('swizzle')
        self.assertEqual(kinds(r), {'ldsm_address': 8})
        self.assertEqual(ldsm(r), [(True, 4, ['tid.x'], 'varies')])
        self.assertEqual(r['verdict']['stage1']['ldsm'], 1)
        self.assertIn('pitch varies', r['verdict']['stage3']['why_not'])

    def test_opaque(self):   # an address read from shared memory: refused, and its pitch not guessed
        r = self.rep('opaque')
        self.assertEqual(ldsm(r), [(False, 1, ['shared'], None)])
        self.assertEqual(r['ldsm'][0]['why'], 'shared')
        self.assertEqual(r['verdict']['stage1'], dict(ldsm=0, of=1, shuffles=0, of_shuffles=1, blockers={'shared': 1}, phi_only_uniform_inputs=0))

    def test_const(self):   # Ra = RZ: one LDSM a constant source, the plain and the transposed apart, pitch 0
        r = self.rep('const')
        self.assertEqual(kinds(r), {'ldsm_address': 6})
        self.assertEqual(ldsm(r), [(False, 2, ['const'], 0), (True, 2, ['const'], 0)])
        self.assertEqual([g['address'] for g in r['ldsm']], ['constant', 'constant'])
        self.assertEqual(r['verdict']['stage3']['why_not'], {'pitch 0': 2, 'feeds no HMMA A or B': 2})

    def test_chain(self):
        r = self.rep('chain')
        self.assertEqual(kinds(r), {'ldsm_address': 8, 'movm': 2})
        self.assertEqual(ldsm(r), [(False, 4, ['lane'], 16), (True, 2, ['lane'], 16)])
        self.assertEqual(r['ldsm'][0]['matrix_bases'], [0, 128, 256, 384])
        a, b = r['hmma']
        self.assertEqual(a['operands'], dict(A0='ldsm', A1='ldsm', A2='ldsm', A3='ldsm', B0='ldsm.T', B1='movm(ldsm.T)', C0='zero', C1='zero'))
        self.assertEqual((b['operands']['C0'], b['operands']['C1']), ('D0.0', 'D0.1'))
        self.assertEqual((a['d_uses'], b['d_uses']), ({'hmma.C': 2}, {'store': 2}))
        self.assertEqual(r['verdict']['stage2'], dict(hmma=0, of=2, b_words=2, of_b_words=4))   # only one B word is a MOVM's
        self.assertEqual(r['verdict']['stage3'], dict(ldsm=2, of=2, why_not={}, if_phi_uniform=0))
        self.assertEqual(set(a['windows'].values()), {'clean'})
        self.assertEqual([g['words_used_elsewhere'] for g in r['ldsm']], [0, 0])   # A, B, and B through MOVM only
        self.assertEqual(r['arrays']['_23']['role'], 'hmma scratch')

    def test_net(self):
        r = self.rep('net')
        self.assertEqual(kinds(r), {'ldsm_address': 12, 'movm': 4})
        self.assertEqual(ldsm(r), [(False, 4, ['tid.x'], 64), (True, 2, ['tid.x'], 64), (True, 2, ['tid.x'], 64)])
        self.assertEqual([h['operands']['B0'] + ' ' + h['operands']['B1'] for h in r['hmma']], ['ldsm.T ldsm.T', 'ldsm.T ldsm.T', 'movm(D1.0) movm(D1.1)'])
        self.assertEqual([h['d_uses'] for h in r['hmma']], [{'hmma.C': 2}, {'movm': 4, 'store': 1}, {'store': 2}])
        self.assertEqual(r['verdict']['stage2'], dict(hmma=1, of=3, b_words=2, of_b_words=6))
        self.assertEqual(r['verdict']['stage3']['ldsm'], 3)
        self.assertEqual(r['operand_sources']['B:movm(D)'], 2)

    def test_the_build_rewrite_changes_nothing_read(self):   # the helper's body as the translator writes it and as dmsh_build.py rewrites it
        raw, rewritten = (FIXTURES / 'net.metal').read_text(), source('net')
        self.assertNotEqual(raw, rewritten)
        a, b = census(raw), census(rewritten)
        for k in ('shuffles', 'counts', 'operand_sources', 'verdict', 'text'): self.assertEqual(a[k], b[k], k)
        unplaced = lambda r: [{k: v for k, v in x.items() if k != 'line'} for x in r['ldsm'] + r['hmma']]   # the longer body moves the kernel's lines
        self.assertEqual(unplaced(a), unplaced(b))

    def test_text_summary(self):
        text = '\n'.join(self.rep('net')['text'])
        self.assertIn('stage 1 (row addresses per lane): 3 of 3 LDSMs, 12 of 12 address shuffles', text)
        self.assertIn('stage 2 (MOVM into B): 1 of 3 HMMAs take both B words from MOVM (2 of 6 B words)', text)
        self.assertIn('stage 3 (tiles from shared memory): 3 of 3 LDSMs', text)
        self.assertNotIn('as_type', text)   # structure, no source text


class Variants(unittest.TestCase):
    """The programs edited where a real shader may differ"""

    def test_barrier_between_ldsm_and_hmma(self):
        src = edit(source('chain'), '    int _708 = dmsh_hmma16816_f16(', '    threadgroup_barrier(mem_flags::mem_threadgroup);\n    int _708 = dmsh_hmma16816_f16(')
        r = census(src)
        self.assertEqual(r['verdict']['stage3'], dict(ldsm=0, of=2, why_not={'window: barrier': 2}, if_phi_uniform=0))
        self.assertEqual(r['counts']['barriers'], 1)
        self.assertEqual(r['verdict']['stage1']['ldsm'], 2)   # stage 1 does not care

    def test_hmma_in_a_loop(self):
        src = edit(source('chain'), '    float _281 = as_type<float>(gl_LocalInvocationID.x);', '    for (;;)\n    {\n    float _281 = as_type<float>(gl_LocalInvocationID.x);')
        src = edit(src, '    int _323 = _754;\n', '    int _323 = _754;\n        break;\n    }\n')
        r = census(src)
        self.assertEqual([h['in_loop'] for h in r['hmma']], [False, True])
        self.assertEqual(set(r['hmma'][1]['windows'].values()), {'block'})   # the loads are before the loop
        self.assertEqual(r['verdict']['stage3']['ldsm'], 0)

    def test_accumulator_carried_by_a_loop(self):   # C of the first HMMA is the second's D of the iteration before: a phi of zero and D
        src = edit(source('chain'), '    int _273 = 0;\n    int _275 = 0;\n', '    int _273 = _8000;\n    int _275 = _8001;\n')
        src = edit(src, '    float _40 = as_type<float>(gl_SubgroupInvocationID);\n', '    int _8000 = 0;\n    int _8001 = 0;\n    for (;;)\n    {\n    float _40 = as_type<float>(gl_SubgroupInvocationID);\n')
        src = edit(src, '    _18[8] = uint(_323);\n', '    _8000 = _323;\n    _8001 = _321;\n    if (_8000 > 5)\n    {\n        break;\n    }\n    }\n    _18[8] = uint(_323);\n')
        r = census(src)
        self.assertEqual([(h['operands']['C0'], h['operands']['C1'], h['in_loop']) for h in r['hmma']], [('phi(D1.0|zero)', 'phi(D1.1|zero)', True), ('D0.0', 'D0.1', True)])
        self.assertEqual(r['hmma'][1]['d_uses'], {'phi': 2, 'store': 2})
        self.assertEqual(r['verdict']['stage3']['ldsm'], 2)   # loads and HMMAs in the same block of the loop

    def test_loop_carried_base(self):   # a phi: refused by stage 1 as planned; its values take nothing that varies but the phi itself
        src = edit(source('cutlass'), '    int _46 = _44 + _42;', '    int _9 = 0;\n    int _46 = (_44 + _42) + _9;\n    int _10 = _9 + 64;\n    _9 = _10;')
        r = census(src, LOCAL['cutlass'])
        g = r['ldsm'][0]
        self.assertEqual((g['leaves'], g['blockers'], g['phi_inputs'], g['pitch']), (['phi', 'tid.x'], ['phi'], ['phi'], None))
        self.assertEqual(g['why'], 'phi')
        self.assertEqual(r['verdict']['stage1']['phi_only_uniform_inputs'], 1)
        self.assertEqual(g['pitch_if_phi_uniform'], 64)   # the pitch, were the phi warp-uniform
        stepped = census(edit(src, '    int _10 = _9 + 64;', '    int _10 = _9 + int(gl_SubgroupInvocationID);'), LOCAL['cutlass'])   # a step that varies: no such phi
        self.assertEqual((stepped['ldsm'][0]['phi_inputs'], stepped['verdict']['stage1']['phi_only_uniform_inputs']), (['lane', 'phi'], 0))
        self.assertNotIn('pitch_if_phi_uniform', stepped['ldsm'][0])

    def test_loop_carried_base_of_hmma_operands(self):   # the GEMM loop: stage 3 not now, and how many LDSMs it would take with the phi proved uniform
        src = edit(source('chain'), '    int _42 = as_type<int>(_40) * 16;', '    int _9 = 0;\n    int _42 = (as_type<int>(_40) * 16) + _9;\n    int _10 = _9 + 512;\n    _9 = _10;')
        r = census(src)
        self.assertEqual([(g['blockers'], g['pitch_if_phi_uniform'], g['stage3_if_phi_uniform']) for g in r['ldsm']], [(['phi'], 16, True)] * 2)
        self.assertEqual((r['verdict']['stage3']['ldsm'], r['verdict']['stage3']['if_phi_uniform']), (0, 2))
        self.assertIn('2 more if their phi is warp-uniform', r['text'][-1])

    def test_constant_buffer_base(self):   # a uniform base: still a lane function with the same pitch; the base moves with the uniform values
        src = edit(source('cutlass'), '    int _46 = _44 + _42;', '    int _46 = (_44 + _42) + as_type<int>(spvDescriptorSet0.cp_c1->_m0[3].x);')
        g = census(src, LOCAL['cutlass'])['ldsm'][0]
        self.assertEqual((g['leaves'], g['lane_function'], g['pitch'], g['matrix_bases'], g['uniform_part_varies']), (['cbuf', 'tid.x'], True, 64, [0, 512, 16, 528], True))

    def test_storage_buffer_and_varying_index(self):
        sb = census(edit(source('cutlass'), '    int _46 = _44 + _42;', '    int _46 = (_44 + _42) + as_type<int>((*spvDescriptorSet0.cp_s2)._m0[0]);'), LOCAL['cutlass'])
        self.assertEqual(sb['ldsm'][0]['blockers'], ['sbuf'])
        vi = census(edit(source('cutlass'), '    int _46 = _44 + _42;', '    int _46 = (_44 + _42) + as_type<int>((*spvDescriptorSet0.cp_c1)._m0[int(_35)].x);'), LOCAL['cutlass'])
        self.assertEqual(vi['ldsm'][0]['blockers'], ['buffer index varies'])

    def test_pitch_from_a_constant_buffer(self):   # rows a uniform pitch apart: linear in every sample, but not one number
        src = edit(source('cutlass'), '    int _42 = _35 * 64;', '    int _42 = _35 * as_type<int>(spvDescriptorSet0.cp_c1->_m0[0].y);')
        g = census(src, LOCAL['cutlass'])['ldsm'][0]
        self.assertEqual((g['pitch'], g['lane_function']), ('uniform', True))
        self.assertIn('pitch uniform', g['stage3_why'])

    def test_local_size_x_not_a_multiple_of_32(self):   # tid.x is then no lane function stage 1 would take
        r = census(source('cutlass'), [16, 8, 1])
        self.assertEqual(r['ldsm'][0]['blockers'], ['tid.x (local size x 16)'])
        self.assertEqual(r['verdict']['stage1']['ldsm'], 0)
        unknown = tc.Census(source('cutlass'), None, 'c').report()   # no local size: x taken as a multiple of 32, and said so
        self.assertIsNone(unknown['local_size']); self.assertIn('unknown', unknown['text'][0]); self.assertEqual(unknown['ldsm'][0]['pitch'], 64)

    def test_shared_memory_in_a_device_buffer(self):   # dmsh_build.py tg_spill's form of a large shared memory
        src = edit(source('net'), '    threadgroup spvUnsafeArray<uint, 2048> _18;', '    device spvUnsafeArray<uint, 2048>& _18 = *(device spvUnsafeArray<uint, 2048>*)(dm_tg + dm_tgbase + 0);')
        a, b = census(source('net')), census(src)
        self.assertEqual((a['verdict'], a['shuffles'], ldsm(a)), (b['verdict'], b['shuffles'], ldsm(b)))

    def test_other_shuffle_forms(self):   # told by the lanes they read: REDUX / MATCH read each lane in turn, the per-lane HMMA's A gather 4 g + j, a broadcast is other
        redux = ''.join(f'    float _{900 + k} = spvSubgroupShuffle(_74, {k}u);\n' for k in range(32))
        add = (redux + '    int _950 = as_type<int>(_900) + as_type<int>(_931);\n    float _951 = spvSubgroupShuffle(_62, 5u);\n'
               '    int _961 = int(_50) << 2;\n    int _962 = _961 + 1;\n    float _963 = spvSubgroupShuffle(_62, uint(_962));\n'
               '    float _964 = float2(as_type<half2>(as_type<uint>(_963))).x;\n    _18[8] = as_type<uint>(_62);')
        r = census(edit(source('cutlass'), '    _18[8] = as_type<uint>(_62);', add), LOCAL['cutlass'])
        self.assertEqual(kinds(r), {'ldsm_address': 4, 'redux_match': 32, 'hmma_lane': 1, 'other': 1})
        self.assertEqual(ldsm(r), [(False, 4, ['tid.x'], 64)])


class Misleading(unittest.TestCase):
    """Forms that must not pass for a constant pitch, a lane function or an LDSM"""

    def test_or_with_a_buffer_word(self):   # a buffer word's low bits are not known: an OR with it is an add only where their bits cannot overlap
        overlap = address('chain', '((as_type<int>(_40) & 7) << 4) | (as_type<int>(spvDescriptorSet0.cp_c1->_m0[4].x) << 4)', [32, 1, 1])
        self.assertEqual((overlap['pitch'], overlap['lane_function'], overlap['stage3']), ('varies', True, False))
        apart = address('chain', '(as_type<int>(spvDescriptorSet0.cp_c1->_m0[4].x) << 7) | ((as_type<int>(_40) & 7) << 4)', [32, 1, 1])
        self.assertEqual((apart['pitch'], apart['row_alignment'], apart['stage3']), (16, 16, True))
        shifted = address('chain', 'as_type<int>(_40) * (16 << (as_type<int>(spvDescriptorSet0.cp_c1->_m0[0].y) & 3))', [32, 1, 1])
        self.assertEqual((shifted['pitch'], shifted['pitch_depends_on'], shifted['stage3']), ('uniform', ['uniform values'], False))
        based = address('cutlass', '(_44 + _42) + as_type<int>(spvDescriptorSet0.cp_c1->_m0[3].x)')   # an added base: the pitch holds, the rows' alignment is the word's
        self.assertEqual(based['pitch'], 64); self.assertLess(based['row_alignment'], 16)

    def test_pitch_that_differs_between_warps(self):   # every warp of the workgroup is evaluated, not one
        expr = '((as_type<int>(_32) & 7) * ((as_type<int>(_32) >> 5) + 1)) << 4'   # warp 0 rows 16 apart, warp 1 32 (local size x 64)
        for local in ([64, 1, 1], [64, 2, 1]):
            g = address('cutlass', expr, local)
            self.assertEqual((g['pitch'], g['pitch_depends_on'], g['pitches_seen'], g['lane_function']), ('per warp', ['warp'], [16, 32], True), local)
            self.assertIn('pitch per warp', g['stage3_why'])
        self.assertEqual(address('cutlass', expr, [32, 4, 1])['pitch'], 16)   # tid.x >> 5 is 0 in every warp there
        by_y = address('cutlass', '((as_type<int>(_32) & 7) * (int(gl_LocalInvocationID.y) + 1)) << 4', [32, 2, 1])
        self.assertEqual((by_y['pitch'], by_y['lane_function']), ('per warp', True))

    def test_pitch_that_differs_between_matrices(self):
        g = address('cutlass', '(as_type<int>(_48) & 7) * (16 + ((as_type<int>(_48) >> 3) & 1) * 16)')
        self.assertEqual((g['pitch'], g['pitch_depends_on'], g['pitches_seen']), ('per matrix', ['matrix'], [16, 32]))

    def test_buffer_index_and_names(self):   # what a buffer word is read at, and names this reader does not know
        def blockers(expr, local=None, src=None):
            g = address('cutlass', f'(_44 + _42) + {expr}', local) if src is None else census(edit(src, '    int _46 = _44 + _42;', f'    int _46 = (_44 + _42) + {expr};'), LOCAL['cutlass'])['ldsm'][0]
            self.assertEqual(g['lane_function'], not g['blockers'])
            return g['blockers']
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[as_type<int>((*spvDescriptorSet0.cp_s2)._m0[0])].x)'), ['buffer index: sbuf'])
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[gl_LocalInvocationID.x].x)'), ['buffer index varies'])
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[gl_SubgroupInvocationID].x)'), ['buffer index varies'])
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[gl_LocalInvocationID.y].x)'), [])   # tid.y is the warp's: a uniform word
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[gl_LocalInvocationID.y].x)', [16, 8, 1]), ['buffer index varies', 'tid.x (local size x 16)'])
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[as_type<int>((*spvDescriptorSet0.cp_c1)._m0[1].x)].x)'), [])   # cbuf at a cbuf index
        self.assertEqual(blockers('int(dm_x)'), ['param'])
        self.assertEqual(blockers('int(spvDispatchBase.x)'), ['param'])
        self.assertEqual(blockers('(true ? 16 : 0)'), [])
        self.assertEqual(blockers('int((*spvDescriptorSet0.cp_c1)._m0[3].x)', src=with_buffers(source('cutlass'))), ['float'])   # a float word converted
        self.assertEqual(blockers('as_type<int>((*spvDescriptorSet0.cp_c1)._m0[3].x)', src=with_buffers(source('cutlass'))), [])   # its bits

    def test_refused_evaluation_is_no_lane_function(self):   # whatever the leaves say, an address the evaluator could not follow is not counted for stage 1
        src = edit(source('cutlass'), '    int _46 = _44 + _42;', '    int _46 = (_44 + _42) + _45;')   # a variable never defined: a parameter
        g = census(src, LOCAL['cutlass'])['ldsm'][0]
        self.assertEqual((g['blockers'], g['lane_function']), (['param'], False))
        g = address('cutlass', 'int2(_44, _42).x + _42')   # leaves the pass would take, in a form the evaluator does not follow (a vector)
        self.assertEqual((g['leaves'], g['why'], g['blockers'], g['lane_function']), (['tid.x'], 'vector or array', ['not evaluated: vector or array'], False))

    def test_game_shuffles_into_shared_memory_indices(self):   # lanes the translator never reads: the game's own SHFL, whatever its value indexes
        for lanes in ('gl_SubgroupInvocationID ^ 1u', 'gl_SubgroupInvocationID & 4294967292u'):   # BFLY 1; a quad broadcast, which the per-lane HMMA's A gather also reads
            add = (f'    uint _950 = {lanes};\n    float _951 = spvSubgroupShuffle(as_type<float>(_46), _950);\n    uint _952 = uint(as_type<int>(_951)) >> uint(2);\n'
                   '    float _953 = as_type<float>(_18[int(_952)]);\n    _18[12] = as_type<uint>(_953);\n    _18[8] = as_type<uint>(_62);')
            r = census(edit(source('cutlass'), '    _18[8] = as_type<uint>(_62);', add), LOCAL['cutlass'])
            self.assertEqual((kinds(r), r['counts']['ldsm']), ({'ldsm_address': 4, 'other': 1}, 1), lanes)

    def test_ldsm_words_with_other_uses(self):   # a word stored as well as fed to the HMMA: the LDSM and its shuffles would stay
        r = census(edit(source('chain'), '    _18[8] = uint(_323);', '    _18[8] = uint(_323);\n    _18[10] = as_type<uint>(_59);'))
        a, b = r['ldsm']
        self.assertEqual((a['words_used_elsewhere'], a['stage3'], a['stage3_why']), (1, False, ['words used outside HMMA A / B']))
        self.assertEqual((b['words_used_elsewhere'], b['stage3']), (0, True))
        self.assertEqual(r['verdict']['stage3']['ldsm'], 1)


class Arithmetic(unittest.TestCase):
    """32-bit C as Metal has it: the pitch is only as right as this"""

    def value(self, expr, decl='int'):
        sh = tc.Shader('kernel void main0(uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])\n{\n    int _1 = -8;\n    uint _2 = 4294967295u;\n'
                       f'    {decl} _3 = {expr};\n}}\n', [32, 1, 1])
        return sh.evaluate('_3', sh.warp_contexts(0)[0][5])[1]

    def test_shifts_and_signs(self):
        self.assertEqual(self.value('_1 >> 1'), -4)   # arithmetic on int
        self.assertEqual(self.value('uint(_1) >> uint(28)', 'uint'), 15)   # logical on uint
        self.assertEqual(self.value('uint(int(uint(_1) >> uint(2)))', 'uint'), 0x3ffffffe)
        self.assertEqual(self.value('_2 + 2u', 'uint'), 1)   # wraps at 32 bits
        self.assertEqual(self.value('_1 < int(_2)', 'bool'), 1)   # -8 < -1
        self.assertEqual(self.value('_2 > uint(_1)', 'bool'), 1)   # 0xffffffff > 0xfffffff8

    def test_unsigned_comparison_and_division(self):
        self.assertEqual(self.value('uint(_1) < 1u', 'bool'), 0)
        self.assertEqual(self.value('_1 / 3'), -2)   # towards zero
        self.assertEqual(self.value('_1 % 3'), -2)

    def test_bits_and_calls(self):
        self.assertEqual(self.value('as_type<int>(3.5873240686715317015647477332222e-43)'), 256)   # a constant address spirv-cross writes as a float
        self.assertEqual(self.value('extract_bits(as_type<uint>(_1), uint(4), 4u)', 'uint'), 15)
        self.assertEqual(self.value('extract_bits(_1, 2u, 3u)'), -2)   # sign-extended for int
        self.assertEqual(self.value('int(gl_SubgroupInvocationID) * 16 + select(1, 2, _1 < 0)'), 82)
        self.assertEqual(self.value('(_1 < 0) ? 7 : 9'), 7)
        self.assertEqual(self.value('insert_bits(0, 5, 4u, 4u)'), 80)

    def test_refused(self):
        for expr, why in (('as_type<int>(as_type<float>(_1) + 1.0)', 'float arithmetic'), ('dmsh_x(_1)', 'call'), ('_1 / 0', 'division by zero')):
            with self.assertRaises(tc.Refused) as e: self.value(expr)
            self.assertEqual(str(e.exception), why)

    def test_lane_patterns(self):   # InstEmitAmpereTensor.cs's source lanes
        lanes = range(32)
        self.assertEqual(tc.lane_pattern([(x >> 2) + 16 for x in lanes]), ('ldsm', 2, 0))
        self.assertEqual(tc.lane_pattern([2 * (x & 3) + 1 + 8 for x in lanes]), ('ldsm.T', 1, 1))
        self.assertEqual(tc.lane_pattern([8 * (x & 3) + 4 + (x >> 3) for x in lanes]), ('movm', 1, 0))
        self.assertEqual(tc.lane_pattern([4 * (x >> 2) + 3 for x in lanes]), ('hmma.A', 3, 0))
        self.assertEqual(tc.lane_pattern([4 * (2 * (x & 3) + 1) + 2 for x in lanes]), ('hmma.B', 1, 2))
        self.assertEqual(tc.lane_pattern([7] * 32), ('one lane', 7, 0))
        self.assertIsNone(tc.lane_pattern([x ^ 1 for x in lanes]))


class Library(unittest.TestCase):
    """--library: the shaders whose source defines the helper, found in the library itself; reports beside it, never in the repository"""

    def library(self, root, name='b-0123456789ab', pack=True, where='shader/cache', helper=True):
        lib = Path(root) / where / name
        lib.mkdir(parents=True)
        if helper:
            (lib / '00000000000000c1_b.metal').write_text(source('chain'))
            (lib / '00000000000000c1_b.json').write_text(json.dumps({'threadgroup_size': [32, 1, 1], 'source': '/synthetic.pck#NDSR@0x0', 'chain': name[2:]}))
        (lib / '00000000000000a1_b.metal').write_text(edit(source('cutlass'), 'kernel void', SHUFFLE_HELPER + 'kernel void'))   # LDSM, no HMMA helper
        (lib / '00000000000000a1_b.json').write_text(json.dumps({'threadgroup_size': [64, 2, 1], 'source': '/other.pck#NDSR@0x0'}))
        (lib / '00000000000000b1_b.metal').write_text(SHUFFLE_HELPER + 'kernel void main0(uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])\n{\n'
                                                      '    float _5 = as_type<float>(gl_SubgroupInvocationID);\n    float _6 = spvSubgroupShuffle(_5, gl_SubgroupInvocationID ^ 1u);\n}\n')   # a game shuffle only
        (lib / '00000000000000d1_b.metal').write_text('kernel void main0()\n{\n}\n')   # no shuffle: not read past its kernel's name
        (lib / 'inputs.tsv').write_text('game\t0000000000000000\ninputs\t000000000000\n')
        if pack: self.assertTrue(shader_lib.pack(str(lib), say=lambda m: None)); self.assertFalse(lib.exists())
        return lib

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out): rc = tc.main(list(argv))
        return rc, out.getvalue()

    def test_reads_the_image_and_writes_the_reports(self):
        with tempfile.TemporaryDirectory() as d:
            self.library(d)
            rc, text = self.run_main('--library', d, '--out', str(Path(d) / 'census'))
            self.assertEqual(rc, 0, text)
            out = Path(d) / 'census'
            self.assertEqual(sorted(p.name for p in out.iterdir()), ['00000000000000a1.census', '00000000000000c1.census', 'summary.census', 'summary.txt'])
            rep = json.loads((out / '00000000000000c1.census').read_text())
            self.assertEqual((rep['shader'], rep['helper'], rep['source'], rep['local_size'], rep['verdict']['stage3']['ldsm']), ('00000000000000c1', True, '/synthetic.pck#NDSR@0x0', [32, 1, 1], 2))
            summary = json.loads((out / 'summary.census').read_text())
            self.assertEqual((summary['metal_sources'], summary['hmma_shaders'], summary['shuffling_shaders'], summary['tensor_shaders_without_helper']), (4, 1, 2, 1))
            self.assertEqual((summary['totals']['counts']['hmma'], summary['totals_without_helper']['counts']['ldsm']), (2, 1))
            self.assertEqual(list(summary['by_file']), ['other.pck', 'synthetic.pck'])   # the file each shader came from, as its reflection's source names it
            self.assertIn('00000000000000c1 (synthetic.pck): LDSM 2, HMMA 2, shuffles 10; stage 1 2/2, stage 2 0/2, stage 3 2/2', text)
            self.assertIn('00000000000000a1 (other.pck; no dmsh_hmma16816_f16): LDSM 1, HMMA 0, shuffles 4; stage 1 1/1', text)
            self.assertIn('1 of 4 shaders define dmsh_hmma16816_f16; 1 of the 2 others that shuffle have LDSM, MOVM or per-lane HMMA shuffles', (out / 'summary.txt').read_text())
            self.assertNotIn('as_type', (out / 'summary.txt').read_text() + (out / '00000000000000c1.census').read_text())

    def test_default_folder_beside_the_library_and_never_the_repository(self):
        with tempfile.TemporaryDirectory() as d:
            self.library(d, pack=False)
            rc, _ = self.run_main('--library', str(Path(d) / 'shader/cache/b-0123456789ab'), '--metal')
            self.assertEqual(rc, 0)
            out = Path(d) / 'shader/cache/tensor_census-0123456789ab'
            self.assertTrue((out / '00000000000000c1.census').is_file()); self.assertTrue((out / '00000000000000c1.metal').is_file())
            self.assertFalse((out / '00000000000000b1.census').exists())
            with self.assertRaises(SystemExit) as e: self.run_main('--library', d, '--out', str(REPO / 'tmp-census'))
            self.assertIn('inside this repository', str(e.exception))
            self.assertFalse((REPO / 'tmp-census').exists())

    def test_picks_this_checkouts_chain(self):
        chain = tc.this_chain()
        self.assertIsNotNone(chain)
        with tempfile.TemporaryDirectory() as d:
            self.library(d, 'b-aaaaaaaaaaaa')
            self.library(d, f'b-{chain}')
            lib, how = tc.find_library(d)
            self.assertEqual((Path(lib).name, how), (f'b-{chain}', f"this checkout's chain, {chain}"))
        with tempfile.TemporaryDirectory() as d:   # an older chain's in shader/cache does not hide this one's in shader/partial
            self.library(d, 'b-aaaaaaaaaaaa')
            self.library(d, f'b-{chain}', where='shader/partial')
            lib, how = tc.find_library(str(Path(d) / 'shader'))
            self.assertEqual(Path(lib).parent.name, 'partial')

    def test_no_hmma_shader(self):
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d) / 'b-0123456789ab'
            lib.mkdir()
            (lib / '00000000000000a1_b.metal').write_text(source('cutlass'))
            rc, text = self.run_main('--library', str(lib), '--out', str(Path(d) / 'o'))
            self.assertEqual(rc, 1)
            self.assertIn('0 of 1 shaders define', text)
            self.assertIn("a library of chain 0123456789ab, not this checkout's", text)   # perhaps from before the helper: build again

    def test_no_helper_in_this_checkouts_chain(self):   # nothing to build again for: the game's HMMAs, if any, are forms the helper does not take
        chain = tc.this_chain()
        with tempfile.TemporaryDirectory() as d:
            self.library(d, f'b-{chain}', pack=False, helper=False)
            rc, text = self.run_main('--library', d, '--out', str(Path(d) / 'o'))
            self.assertEqual(rc, 0)   # the LDSM without the helper is censused
            self.assertIn("this checkout's chain: none of the game's HMMAs is HMMA.16816 with an f16 accumulator", text)
            self.assertNotIn('Build the game', text)
            self.assertTrue((Path(d) / 'o/00000000000000a1.census').is_file())

    def test_head_stops_at_the_kernel(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'k_b.metal'
            p.write_text('x' * 70000 + '\nint dmsh_hmma16816_f16(int a)\n{\n}\n\nkernel void main0()\n{\n    spvSubgroupShuffle(\n}\n')
            head = tc.head_of(p)
            self.assertTrue(head.endswith(b'}\n\n') and tc.DEFINES_HMMA.search(head) and tc.SHUFFLE_HELPER not in head)


if __name__ == '__main__':
    unittest.main()
