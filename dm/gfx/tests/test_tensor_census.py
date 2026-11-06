"""The HMMA census (dm/gfx/tools/tensor_census.py), pure Python: on the translator's Metal source for seven synthetic Ampere programs (fixtures/tensor_census, cut down: no
game's code) in the form since upstream's bd9f422d (each LDSM matrix lowered on its own, HMMA calls with TensorPass's flags), and in fixtures/tensor_census/unflagged six of
the same programs in the form before it (12-argument calls), which a library built before it still holds: the class of each shuffle, each LDSM's address leaves, matrices and
row pitch, where each HMMA's operands come from and what reads its D, the path each operand takes under the call's flags, the LDSM code the Metal compiler drops for them,
the accumulator slots (nine chains open at once: the ninth through the registers, and a call in no chain while slot 0 is open, which NXNative's body makes in slot 0's
matrices), and the verdicts; then variants of them made by small edits (a barrier, a shared store, an atomic on shared memory or on a buffer, loops, a phi, buffer reads,
another local size, shared memory in a device buffer, a second shared array, a call of a form it does not read, a library call hmma_msl did not rewrite), with the flags the
translator gives each (checked against it for the shared store and for an HMMA in another block), among them the forms a verdict must not be fooled by (a buffer word's low
bits in an OR, a pitch that differs between warps or matrices, a buffer index that is no constant-buffer one, names the reader does not know, the game's own shuffles, LDSM
words with other uses); the flags, slots and call forms against TensorPass.cs and dmsh_build.py; the C arithmetic the pitch is evaluated with; and the library finder on a
library folder packed into its one-file image (dm/tools/shader_lib.py). With DMSH_TEST_XLATE (the translator), that the fixtures are its output."""
import ast
import contextlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
TOOLS = REPO / 'dm/gfx/tools'
FIXTURES = Path(__file__).resolve().parent / 'fixtures/tensor_census'
sys.path.insert(0, str(TOOLS)); sys.path.insert(0, str(REPO / 'dm/tools'))
import shader_lib  # noqa: E402
import tensor_census as tc  # noqa: E402

# the shader build's HMMA rewrite, as test_dmsh_hmma.py takes it: a library's <key>_b.metal has the helper replaced and each call given the caller's matrices
NAMES = {'hmma_msl', 'split_params', 'block_end', 'HMMA_BODY', 'HMMA_ARGS', 'HMMA_CALL', 'TG_ARRAY'}
tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
selected = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in NAMES)
            or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in NAMES for t in n.targets))]
scope = {'re': re}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), scope)
hmma_msl = scope['hmma_msl']

BUFFERS = ('struct _16\n{\n    float4 _m0[4096];\n};\n\nstruct _23\n{\n    uint _m0[1];\n};\n\nstruct spvDescriptorSetBuffer0\n{\n    constant _16* cp_c1 [[id(0)]];\n'
           '    const device _23* cp_s2 [[id(1)]];\n};\n\n')   # as spirv-cross declares the translator's constant buffers (float4 words) and storage buffers (uint words)
SHUFFLE_HELPER = 'template<typename T>\ninline T spvSubgroupShuffle(T value, ushort lane)\n{\n    return simd_shuffle(value, lane);\n}\n\n'   # as spirv-cross defines it
LOCAL = {'cutlass': [64, 2, 1], 'swizzle': [32, 1, 1], 'opaque': [32, 1, 1], 'const': [32, 1, 1], 'chain': [32, 1, 1], 'net': [32, 1, 1], 'slots': [32, 1, 1]}
CALL0, FLAGS0, FLAGS1 = '    int _840 = dmsh_hmma16816_f16(', '    int _323 = 28;', '    int _381 = 19;'   # chain: the first call, the flags of both
OLD_FORM = ('cutlass', 'swizzle', 'opaque', 'const', 'chain', 'net')   # the programs whose form before the flags is kept (fixtures/tensor_census/unflagged)


def raw(name):   # the translator's source as spirv-cross writes it: calls of 19 arguments
    return (FIXTURES / f'{name}.metal').read_text()


def source(name):   # as a build leaves it in the library: hmma_msl's rewrite
    src = raw(name)
    return hmma_msl(src) if 'dmsh_hmma16816_f16(' in src else src


def unflagged(name):   # the same program from the translator before the flags; that hmma_msl replaced only the helper's body, so the kernel is the library's
    return (FIXTURES / 'unflagged' / f'{name}.metal').read_text()


def census(src, local=None, name='t'):
    return tc.Census(src, local or [32, 1, 1], name).report()


def kinds(rep):
    return {k: v for k, v in rep['shuffles'].items() if k != 'total' and v}


def ldsm(rep):
    return [(g['transposed'], g['matrices'], g['leaves'], g['pitch']) for g in rep['ldsm']]


def paths(rep):
    return [(h['flags'], h['paths']['A'], h['paths']['C'], h['paths']['D']) for h in rep['hmma']]


def edit(src, old, new):
    assert src.count(old) == 1, old
    return src.replace(old, new)


def with_buffers(src):   # the buffers' declarations the cut-down fixtures leave out, for what is read from their types
    return edit(src, 'kernel void main0(', BUFFERS + 'kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], ')


def address(name, expr, local=None):   # the program with its first LDSM's address replaced: that LDSM's report
    old = {'cutlass': '    int _46 = _44 + _42;', 'chain': '    int _42 = as_type<int>(_40) * 16;'}[name]
    return census(edit(source(name), old, old.split('=')[0] + f'= {expr};'), local or LOCAL[name])['ldsm'][0]


NO_HMMA = dict(known=True, hmma=0, a=0, a_why={}, a_not_ldsm=0, acc=0, of_acc=0, acc_why={}, b=0, b_from_ldsm=0)


class Programs(unittest.TestCase):
    """The seven programs, and what their sources show: the address arithmetic, which LDSM feeds which HMMA operand, the MOVMs, the flags, the slots"""

    def rep(self, name): return census(source(name), LOCAL[name], name)

    def test_cutlass(self):   # the CUTLASS form: from tid.x, x4, rows 64 bytes apart
        r = self.rep('cutlass')
        self.assertEqual(kinds(r), {'ldsm_address': 4})
        self.assertEqual(ldsm(r), [(False, 4, ['tid.x'], 64)])
        self.assertEqual(r['ldsm'][0]['matrix_bases'], [0, 512, 16, 528])
        self.assertFalse(r['ldsm'][0]['uniform_part_varies'])
        self.assertEqual(r['verdict']['stage1'], dict(ldsm=1, of=1, shuffles=4, of_shuffles=4, blockers={}, phi_only_uniform_inputs=0, dropped=0, dropped_shuffles=0))
        self.assertEqual(r['verdict']['tiles'], dict(ldsm=0, of=1, why_not={'feeds no HMMA A or B': 1}, if_phi_uniform=0))   # nothing to tile into
        self.assertEqual(r['verdict']['stage3'], NO_HMMA)
        self.assertEqual((r['ldsm'][0]['row_alignment'], r['ldsm'][0]['words_used_elsewhere']), (16, 4))   # its words are stored
        self.assertEqual(r['counts']['shared_stores'], 4)

    def test_swizzle(self):   # an XOR swizzle: a lane function (stage 1), but no constant pitch (no tile)
        r = self.rep('swizzle')
        self.assertEqual(kinds(r), {'ldsm_address': 8})
        self.assertEqual(ldsm(r), [(True, 4, ['tid.x'], 'varies')])
        self.assertEqual(r['verdict']['stage1']['ldsm'], 1)
        self.assertIn('pitch varies', r['verdict']['tiles']['why_not'])

    def test_opaque(self):   # an address read from shared memory: refused, and its pitch not guessed
        r = self.rep('opaque')
        self.assertEqual(ldsm(r), [(False, 1, ['shared'], None)])
        self.assertEqual(r['ldsm'][0]['why'], 'shared')
        self.assertEqual(r['verdict']['stage1'], dict(ldsm=0, of=1, shuffles=0, of_shuffles=1, blockers={'shared': 1}, phi_only_uniform_inputs=0, dropped=0, dropped_shuffles=0))

    def test_const(self):   # Ra = RZ: one LDSM a constant source, the plain and the transposed apart, pitch 0
        r = self.rep('const')
        self.assertEqual(kinds(r), {'ldsm_address': 6})
        self.assertEqual(ldsm(r), [(False, 2, ['const'], 0), (True, 2, ['const'], 0)])
        self.assertEqual([g['address'] for g in r['ldsm']], ['constant', 'constant'])
        self.assertEqual(r['verdict']['tiles']['why_not'], {'pitch 0': 2, 'feeds no HMMA A or B': 2})

    def test_chain(self):   # the translator chains the two calls, loads A where the LDSM read it and keeps it for the second
        r = self.rep('chain')
        self.assertEqual(kinds(r), {'ldsm_address': 8, 'movm': 2})
        self.assertEqual(ldsm(r), [(False, 4, ['lane'], 16), (True, 2, ['lane'], 16)])
        self.assertEqual(r['ldsm'][0]['matrix_bases'], [0, 128, 256, 384])
        a, b = r['hmma']
        self.assertEqual(a['operands'], dict(A0='ldsm', A1='ldsm', A2='ldsm', A3='ldsm', B0='ldsm.T', B1='movm(ldsm.T)', C0='zero', C1='zero'))
        self.assertEqual((b['operands']['C0'], b['operands']['C1']), ('D0.0', 'D0.1'))
        self.assertEqual((a['d_uses'], b['d_uses']), ({'hmma.C': 2}, {'store': 2}))
        self.assertEqual(paths(r), [(16 | 8 | 4, 'direct', 'zero', 'slot'), (16 | 2 | 1, 'kept', 'slot', 'scratch')])   # TensorPass's ADirect, CZero, DSlot; then AReuse, CSlot
        self.assertEqual((a['form'], a['slot'], b['slot']), ('flagged', 0, 0))
        up = r['verdict']['upstream']
        self.assertEqual((up['flagged'], up['served'], up['direct_a'], up['b_scratch']), (2, 2, True, 2))
        self.assertEqual(r['verdict']['stage2'], dict(hmma=0, of=2, b_words=2, of_b_words=4))   # only one B word is a MOVM's
        # A's LDSM: every word goes to A of a call that loads A itself, so the Metal compiler drops its shuffles; stage 1 is left with B's
        self.assertEqual([(g['dropped'], g['dropped_shuffles']) for g in r['ldsm']], [(True, 4), (False, 0)])
        self.assertEqual(r['verdict']['stage1'], dict(ldsm=1, of=1, shuffles=4, of_shuffles=4, blockers={}, phi_only_uniform_inputs=0, dropped=1, dropped_shuffles=4))
        self.assertEqual(r['verdict']['stage3'], dict(known=True, hmma=2, a=0, a_why={}, a_not_ldsm=0, acc=0, of_acc=1, acc_why={}, b=0, b_from_ldsm=0))
        self.assertEqual(r['verdict']['tiles'], dict(ldsm=2, of=2, why_not={}, if_phi_uniform=0))
        self.assertEqual(set(a['windows'].values()), {'clean'})
        self.assertEqual([g['words_used_elsewhere'] for g in r['ldsm']], [0, 0])   # A, B, and B through MOVM only
        self.assertEqual(r['arrays']['_23']['role'], 'hmma scratch')

    def test_net(self):   # A from tid.x & 15: TensorPass does not prove those rows strided (it takes tid.x through sums and products only), the census does
        r = self.rep('net')
        self.assertEqual(kinds(r), {'ldsm_address': 12, 'movm': 4})
        self.assertEqual(ldsm(r), [(False, 4, ['tid.x'], 64), (True, 2, ['tid.x'], 64), (True, 2, ['tid.x'], 64)])
        self.assertEqual([h['operands']['B0'] + ' ' + h['operands']['B1'] for h in r['hmma']], ['ldsm.T ldsm.T', 'ldsm.T ldsm.T', 'movm(D1.0) movm(D1.1)'])
        self.assertEqual([h['d_uses'] for h in r['hmma']], [{'hmma.C': 2}, {'movm': 4, 'store': 1}, {'store': 2}])
        self.assertEqual(paths(r), [(8 | 4, 'scratch', 'zero', 'slot'), (2 | 1, 'kept', 'slot', 'scratch'), (8 | 1, 'kept', 'zero', 'scratch')])
        self.assertEqual(r['hmma'][0]['a_scratch_why'], 'nothing seen in between; the census finds one pitch')
        self.assertEqual(r['verdict']['upstream']['served'], 2)
        self.assertEqual(r['verdict']['stage2'], dict(hmma=1, of=3, b_words=2, of_b_words=6))
        self.assertEqual(r['verdict']['stage1']['dropped'], 0)   # the first call reads A from the scratch
        self.assertEqual(r['verdict']['stage3'], dict(known=True, hmma=3, a=1, a_why={'nothing seen in between; the census finds one pitch': 1}, a_not_ldsm=0, acc=0, of_acc=1,
                                                      acc_why={}, b=2, b_from_ldsm=2))
        self.assertEqual(r['verdict']['tiles']['ldsm'], 3)
        self.assertEqual(r['operand_sources']['B:movm(D)'], 2)

    def test_slots(self):   # nine chains open at once: TensorPass's 8 slots, then the ninth through the registers, its first call in no chain while slot 0 is open
        r = self.rep('slots')
        chains = [28 | i << 8 | (1 if i else 0) for i in range(8)]   # DSlot, CZero, ADirect; A kept after the first
        self.assertEqual([h['flags'] for h in r['hmma']], chains + [25] + [(c & ~(4 | 8)) | 2 | 1 for c in chains] + [17])
        nine, end = r['hmma'][8], r['hmma'][17]
        self.assertEqual((nine['open_before'], nine['in_no_chain_slot0_open'], nine['paths']['D']), (8, True, 'scratch'))
        self.assertEqual((end['operands']['C0'], end['paths']['C'], end['acc_scratch_why']), ('D8.0', 'scratch', 'all 8 slots taken'))
        up = r['verdict']['upstream']
        self.assertEqual((up['flagged'], up['served'], up['in_no_chain_slot0_open'], up['slot0_overwritten'], up['c_slot'], up['d_slot']), (18, 17, 1, 0, 8, 8))
        self.assertEqual((r['verdict']['stage3']['acc'], r['verdict']['stage3']['acc_why']), (1, {'all 8 slots taken': 1}))
        text = '\n'.join(r['text'])
        self.assertIn('1 calls in no chain come while a chain is open in slot 0: each works in a pair of its own', text); self.assertNotIn('[RED]', text)
        self.assertEqual(census(raw('slots'))['verdict'], r['verdict'])   # the translator's text: as this checkout's build rewrites it

    def test_the_build_rewrite_changes_nothing_read(self):   # the translator's form (19 arguments) and the build's (22): the same census, direct A decided alike
        for name in ('net', 'chain'):
            a, b = census(raw(name)), census(source(name))
            self.assertNotEqual(raw(name), source(name))
            self.assertEqual((a['counts']['hmma'], b['counts']['hmma_unread']), (len(b['hmma']), 0))
            for k in ('shuffles', 'counts', 'operand_sources', 'verdict', 'text', 'lines'): self.assertEqual(a[k], b[k], (name, k))
            unplaced = lambda r: [{k: v for k, v in x.items() if k != 'line'} for x in r['ldsm'] + r['hmma']]   # the longer body moves the kernel's lines
            self.assertEqual(unplaced(a), unplaced(b))
            self.assertIn('as hmma_msl would decide', a['direct_a']); self.assertIn('as hmma_msl rewrites them', b['direct_a'])

    def test_text_summary(self):
        text = '\n'.join(self.rep('net')['text'])
        self.assertIn("upstream's paths (TensorPass's flags): 2 of 3 HMMAs take neither A nor C through the scratch", text)
        self.assertIn('A kept 2, loaded where its LDSM read it 0 (0 transposed), through the scratch 1; C from a slot 1, zero 2, through the scratch 0; D left in a slot 1', text)
        self.assertIn('stage 1 (row addresses per lane): 3 of 3 LDSMs still read lane by lane, 12 of 12 address shuffles', text)
        self.assertIn('stage 2 (MOVM into B): 1 of 3 HMMAs take both B words from MOVM (2 of 6 B words)', text)
        self.assertIn('stage 3 (what upstream does not cover, of 3 HMMAs with flags): A through the scratch from an LDSM 1 (nothing seen in between; the census finds one pitch 1)', text)
        self.assertIn('B as tiles 2 of the 2 whose B words both come from an LDSM (upstream left B in the scratch on purpose', text)
        self.assertIn('tiles (LDSM rows one pitch apart, nothing between them and the HMMA): 3 of 3 LDSMs', text)
        self.assertIn('the Metal compiler drops 4 more address shuffles (1 whole LDSM)', '\n'.join(self.rep('chain')['text']))
        self.assertNotIn('as_type', text)   # structure, no source text


class Unflagged(unittest.TestCase):
    """A library built before TensorPass's flags: 12-argument calls, every operand through the scratch, LDSM lowered all matrices at once. The census reads it as before"""

    def test_calls_and_operands(self):
        for name, ops, b, stage2, tiles in (('chain', ['ldsm.T movm(ldsm.T)'] * 2, [{'hmma.C': 2}, {'store': 2}], dict(hmma=0, of=2, b_words=2, of_b_words=4), 2),
                                            ('net', ['ldsm.T ldsm.T', 'ldsm.T ldsm.T', 'movm(D1.0) movm(D1.1)'], [{'hmma.C': 2}, {'movm': 4, 'store': 1}, {'store': 2}],
                                             dict(hmma=1, of=3, b_words=2, of_b_words=6), 3)):
            r = census(unflagged(name))
            self.assertEqual([h['operands']['B0'] + ' ' + h['operands']['B1'] for h in r['hmma']], ops, name)
            self.assertEqual([h['d_uses'] for h in r['hmma']], b, name)
            self.assertEqual(r['verdict']['stage2'], stage2, name)
            self.assertEqual(r['verdict']['tiles']['ldsm'], tiles, name)
            self.assertEqual({(h['form'], h['flags'], h['paths']) for h in r['hmma']}, {('unflagged', None, None)})
            up, s3 = r['verdict']['upstream'], r['verdict']['stage3']
            self.assertEqual((up['flagged'], up['unflagged'], up['served'], s3['known'], s3['hmma'], r['verdict']['stage1']['dropped']), (0, len(ops), 0, False, 0, 0))
            text = '\n'.join(r['text'])
            self.assertIn("upstream's paths: none known", text); self.assertIn("stage 3 (what upstream does not cover): not known without TensorPass's flags", text)

    def test_ldsm_read_alike_in_both_forms(self):   # each LDSM's leaves, pitch, bases and tile verdict; stage 1 and 2 alike but for what the flags let Metal drop
        for name in OLD_FORM:
            a, b = census(unflagged(name), LOCAL[name]), census(source(name), LOCAL[name])
            keys = ('transposed', 'matrices', 'leaves', 'pitch', 'matrix_bases', 'row_alignment', 'words_used_elsewhere', 'tile', 'tile_why', 'blockers')
            self.assertEqual([[g[k] for k in keys] for g in a['ldsm']], [[g[k] for k in keys] for g in b['ldsm']], name)
            self.assertEqual((a['shuffles'], a['verdict']['stage2'], a['verdict']['tiles']), (b['shuffles'], b['verdict']['stage2'], b['verdict']['tiles']), name)
            if name != 'chain': self.assertEqual(a['verdict']['stage1'], b['verdict']['stage1'], name)


class CallForms(unittest.TestCase):
    """What decides each operand's path: the flags, and whether hmma_msl turned direct A on"""

    def test_flags(self):   # TensorPass.Flag*: the slot is flags >> 8
        c = tc.Census(source('chain'), [32, 1, 1])
        self.assertEqual(c.paths(2 | 16 | 32 | 1 << 8), dict(paths=dict(A='direct, transposed', B='scratch', C='slot', D='scratch'), slot=1))
        self.assertEqual(c.paths(8 | 4 | 3 << 8), dict(paths=dict(A='scratch', B='scratch', C='zero', D='slot'), slot=3))
        self.assertEqual(c.paths(1 | 16)['paths']['A'], 'kept')   # A kept wins: the body loads none
        self.assertEqual(c.paths(None), dict(paths=None, slot=None))

    def test_a_second_shared_array_turns_direct_a_off(self):   # hmma_msl passes no shared array, and A goes through the scratch
        decl = '    threadgroup spvUnsafeArray<uint, 256> _23;\n'
        src = edit(raw('chain'), decl, decl + '    threadgroup spvUnsafeArray<uint, 16> _24;\n')
        for form, s in (('raw', src), ('rewritten', hmma_msl(src))):
            r = census(s)
            self.assertEqual(paths(r), [(28, 'scratch', 'zero', 'slot'), (19, 'kept', 'slot', 'scratch')], form)
            self.assertEqual(r['hmma'][0]['a_scratch_why'], 'direct A off in the shader', form)
            self.assertEqual((r['verdict']['upstream']['direct_a'], r['verdict']['upstream']['served'], r['verdict']['stage1']['dropped']), (False, 1, 0), form)   # A read again
            self.assertIn('direct A off', '\n'.join(r['text']))
        self.assertEqual(hmma_msl(src).count(', _23, dm_acc, dm_am)'), 2)

    def test_nxnative_body_works_a_call_in_no_chain_in_slot_0(self):   # its dm_acc of 16: the ninth chain's first call overwrites slot 0's sum
        src = source('slots')
        self.assertEqual(src.count('dm_acc[18], dm_am[4];'), 1)   # this checkout's
        r = census(edit(src, 'dm_acc[18], dm_am[4];', f'dm_acc[{tc.SHARED_PAIR}], dm_am[4];'))
        up = r['verdict']['upstream']
        self.assertEqual((up['in_no_chain_slot0_open'], up['slot0_overwritten'], up['served']), (1, 1, 16))
        self.assertIn("[RED] 1 calls in no chain work in slot 0's matrices while a chain keeps its sum there", '\n'.join(r['text']))
        self.assertIn("[RED] 1 over slot 0's chain", tc.one_line(r))
        self.assertEqual(census(source('chain'))['verdict']['upstream']['in_no_chain_slot0_open'], 0)   # a chain's calls only

    def test_flags_slots_and_forms_are_the_translators_and_the_builds(self):   # TensorPass.cs's constants and the argument lists of the translator and of hmma_msl
        tensor = (REPO / 'dm/third_party/ryujinx/src/Ryujinx.Graphics.Shader/Translation/Transforms/TensorPass.cs').read_text()
        self.assertEqual({k: int(v) for k, v in re.findall(r'public const int Flag(\w+) = (\d+);', tensor)},
                         dict(AReuse=tc.FLAG_A_REUSE, CSlot=tc.FLAG_C_SLOT, DSlot=tc.FLAG_D_SLOT, CZero=tc.FLAG_C_ZERO, ADirect=tc.FLAG_A_DIRECT, ATrans=tc.FLAG_A_TRANS))
        self.assertEqual(int(re.search(r'public const int Slots = (\d+);', tensor).group(1)), tc.SLOTS)
        args = scope['HMMA_ARGS']   # dmsh_build.py: the helper's parameters but the scratch
        self.assertEqual(int(re.search(r'public const int HmmaInArguments = (\d+);', tensor).group(1)) + 2, len(args) + 1)   # and out D1, the scratch
        self.assertEqual(sorted(tc.CALL_FORMS), [12, len(args) + 1, len(args) + 1 + 2, len(args) + 1 + 3])   # + dm_acc, dm_am (+ the shared memory array)
        for n in (19, 21, 22): self.assertEqual((tc.CALL_FORMS[n]['flags'], tc.CALL_FORMS[n]['d1'], tc.CALL_FORMS[n]['scratch']), (args.index('fl'), args.index('d1'), len(args)))
        rewritten = hmma_msl(raw('chain'))
        self.assertEqual({len(re.split(r',\s*', c)) for c in re.findall(r'dmsh_hmma16816_f16\(([^()]*)\)', rewritten[rewritten.index('kernel void'):])}, {22})
        self.assertRegex(rewritten, r'const int k = cslot \|\| dslot \? \(f >> 8\) \* 2 : %d;' % (2 * tc.SLOTS))   # the pair past the slots, which the census takes from dm_acc's size
        self.assertNotIn(f'dm_acc[{tc.SHARED_PAIR}]', rewritten)

    def test_a_form_it_does_not_read(self):   # counted and said, never guessed at
        src = edit(raw('chain'), '_337, _23);', '_337, _23, _18, _18, _18, _18);')
        r = census(src)
        self.assertEqual((r['counts']['hmma'], r['counts']['hmma_unread']), (1, 1))
        self.assertIn('[RED] 1 calls of dmsh_hmma16816_f16 in a form the census does not read', '\n'.join(r['text']))


class Variants(unittest.TestCase):
    """The programs edited where a real shader may differ, with the flags the translator gives that code"""

    def test_shared_store_between_ldsm_and_hmma(self):   # what the translator gives with an STS there: no direct A for either call (checked with dmsh_xlate)
        src = edit(edit(edit(source('chain'), CALL0, '    _18[16] = 0u;\n' + CALL0), FLAGS0, '    int _323 = 12;'), FLAGS1, '    int _381 = 3;')
        r = census(src)
        self.assertEqual(paths(r), [(12, 'scratch', 'zero', 'slot'), (3, 'kept', 'slot', 'scratch')])
        self.assertEqual(r['hmma'][0]['a_scratch_why'], 'behind a shared store, atomic, barrier or call')
        self.assertEqual(r['verdict']['stage3']['a_why'], {'behind a shared store, atomic, barrier or call': 1})
        self.assertEqual(r['verdict']['tiles']['why_not'], {'window: shared store': 2})
        self.assertEqual(r['verdict']['stage1']['dropped'], 0)

    def test_atomic_between_ldsm_and_hmma(self):   # TensorPass.WritesShared: an atomic on shared memory ends the epoch as a shared store does; one on a buffer does not
        flags = lambda s: edit(edit(s, FLAGS0, '    int _323 = 12;'), FLAGS1, '    int _381 = 3;')   # noqa: E731   (A through the scratch for whatever reason)
        shared = census(flags(edit(source('chain'), CALL0, '    uint _9000 = atomic_fetch_add_explicit((threadgroup atomic_uint*)&_18[16], 1u, memory_order_relaxed);\n' + CALL0)))
        self.assertEqual(shared['hmma'][0]['a_scratch_why'], 'behind a shared store, atomic, barrier or call')
        self.assertEqual((shared['counts']['atomics'], shared['counts']['shared_atomics']), (1, 1))
        device = census(flags(edit(source('chain'), CALL0, '    uint _9000 = atomic_fetch_add_explicit((device atomic_uint*)&(*spvDescriptorSet0.cp_s2)._m0[0], 1u, '
                                                             'memory_order_relaxed);\n' + CALL0)))
        self.assertEqual(device['hmma'][0]['a_scratch_why'], 'nothing seen in between; the census finds one pitch')   # not the atomic: the translator's rows, or a block
        self.assertEqual((device['counts']['atomics'], device['counts']['shared_atomics']), (1, 0))
        self.assertEqual(device['verdict']['tiles']['why_not'], {'window: device atomic': 2})   # a tile load is not moved across it

    def test_barrier_between_ldsm_and_hmma(self):   # a barrier ends the block's epoch as a shared store does (TensorPass.WritesShared)
        src = edit(edit(edit(source('chain'), CALL0, '    threadgroup_barrier(mem_flags::mem_threadgroup);\n' + CALL0), FLAGS0, '    int _323 = 12;'), FLAGS1, '    int _381 = 3;')
        r = census(src)
        self.assertEqual(r['verdict']['tiles'], dict(ldsm=0, of=2, why_not={'window: barrier': 2}, if_phi_uniform=0))
        self.assertEqual(r['counts']['barriers'], 1)
        self.assertEqual(r['verdict']['stage1']['ldsm'], 2)   # stage 1 does not care
        self.assertEqual(r['verdict']['stage3']['a'], 1)

    def test_hmma_in_a_loop(self):   # the second call in another block: no chain, no A kept, no direct A (what dmsh_xlate gives an HMMA after a branch: 24, 0)
        src = edit(source('chain'), '    float _341 = as_type<float>(gl_LocalInvocationID.x);', '    for (;;)\n    {\n    float _341 = as_type<float>(gl_LocalInvocationID.x);')
        src = edit(edit(edit(src, '    int _397 = _884;\n', '    int _397 = _884;\n        break;\n    }\n'), FLAGS0, '    int _323 = 24;'), FLAGS1, '    int _381 = 0;')
        r = census(src)
        self.assertEqual([h['in_loop'] for h in r['hmma']], [False, True])
        self.assertEqual(set(r['hmma'][1]['windows'].values()), {'block'})   # the loads are before the loop
        self.assertEqual(r['verdict']['tiles']['ldsm'], 0)
        self.assertEqual(paths(r), [(24, 'direct', 'zero', 'scratch'), (0, 'scratch', 'scratch', 'scratch')])
        self.assertEqual((r['hmma'][1]['a_scratch_why'], r['hmma'][1]['acc_scratch_why']), ('its LDSM in another block', 'D of an HMMA in another block'))
        self.assertEqual(r['verdict']['stage3'], dict(known=True, hmma=2, a=1, a_why={'its LDSM in another block': 1}, a_not_ldsm=0, acc=1, of_acc=1,
                                                      acc_why={'D of an HMMA in another block': 1}, b=0, b_from_ldsm=0))

    def test_another_block_the_metal_text_does_not_show(self):   # dmsh_xlate's flags for a branch between the calls (24, 0): spirv-cross writes both blocks as one run
        r = census(edit(edit(source('chain'), FLAGS0, '    int _323 = 24;'), FLAGS1, '    int _381 = 0;'))
        self.assertEqual((r['hmma'][1]['a_scratch_why'], r['hmma'][1]['acc_scratch_why']), ('its LDSM in another block', 'D of an HMMA in another block'))   # A not kept

    def test_accumulator_carried_by_a_loop(self):   # C of the first HMMA is the second's D of the iteration before: a phi of zero and D, which goes through the scratch
        src = edit(source('chain'), '    int _319 = 0;\n    int _321 = 0;\n', '    int _319 = _8000;\n    int _321 = _8001;\n')
        src = edit(src, '    float _40 = as_type<float>(gl_SubgroupInvocationID);\n', '    int _8000 = 0;\n    int _8001 = 0;\n    for (;;)\n    {\n    float _40 = as_type<float>(gl_SubgroupInvocationID);\n')
        src = edit(src, '    _18[8] = uint(_397);\n', '    _8000 = _397;\n    _8001 = _395;\n    if (_8000 > 5)\n    {\n        break;\n    }\n    }\n    _18[8] = uint(_397);\n')
        r = census(edit(src, FLAGS0, '    int _323 = 20;'))   # the loop's body one block: D in slot 0 and A direct, C not zero
        self.assertEqual([(h['operands']['C0'], h['operands']['C1'], h['in_loop']) for h in r['hmma']], [('phi(D1.0|zero)', 'phi(D1.1|zero)', True), ('D0.0', 'D0.1', True)])
        self.assertEqual(r['hmma'][1]['d_uses'], {'phi': 2, 'store': 2})
        self.assertEqual(r['verdict']['tiles']['ldsm'], 2)   # loads and HMMAs in the same block of the loop
        self.assertEqual(paths(r), [(20, 'direct', 'scratch', 'slot'), (19, 'kept', 'slot', 'scratch')])
        self.assertEqual(r['hmma'][0]['acc_scratch_why'], 'a phi (a loop, or paths meeting)')
        self.assertEqual((r['verdict']['stage3']['acc'], r['verdict']['stage3']['of_acc']), (1, 2))

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

    def test_loop_carried_base_of_hmma_operands(self):   # the GEMM loop: no tile now, and how many LDSMs one would take with the phi proved uniform
        src = edit(source('chain'), '    int _42 = as_type<int>(_40) * 16;', '    int _9 = 0;\n    int _42 = (as_type<int>(_40) * 16) + _9;\n    int _10 = _9 + 512;\n    _9 = _10;')
        r = census(src)
        self.assertEqual([(g['blockers'], g['pitch_if_phi_uniform'], g['tile_if_phi_uniform']) for g in r['ldsm']], [(['phi'], 16, True)] * 2)
        self.assertEqual((r['verdict']['tiles']['ldsm'], r['verdict']['tiles']['if_phi_uniform']), (0, 2))
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
        self.assertIn('pitch uniform', g['tile_why'])

    def test_local_size_x_not_a_multiple_of_32(self):   # tid.x is then no lane function stage 1 would take
        r = census(source('cutlass'), [16, 8, 1])
        self.assertEqual(r['ldsm'][0]['blockers'], ['tid.x (local size x 16)'])
        self.assertEqual(r['verdict']['stage1']['ldsm'], 0)
        unknown = tc.Census(source('cutlass'), None, 'c').report()   # no local size: x taken as a multiple of 32, and said so
        self.assertIsNone(unknown['local_size']); self.assertIn('unknown', unknown['text'][0]); self.assertEqual(unknown['ldsm'][0]['pitch'], 64)

    def test_shared_memory_in_a_device_buffer(self):   # dmsh_build.py tg_spill's form of a large shared memory, after hmma_msl
        src = edit(source('net'), '    threadgroup spvUnsafeArray<uint, 2048> _18;', '    device spvUnsafeArray<uint, 2048>& _18 = *(device spvUnsafeArray<uint, 2048>*)(dm_tg + dm_tgbase + 0);')
        a, b = census(source('net')), census(src)
        self.assertEqual((a['verdict'], a['shuffles'], ldsm(a)), (b['verdict'], b['shuffles'], ldsm(b)))

    def test_other_shuffle_forms(self):   # told by the lanes they read: REDUX / MATCH read each lane in turn, the per-lane HMMA's A gather 4 g + j, a broadcast is other
        redux = ''.join(f'    float _{900 + k} = spvSubgroupShuffle(_84, {k}u);\n' for k in range(32))
        add = (redux + '    int _950 = as_type<int>(_900) + as_type<int>(_931);\n    float _951 = spvSubgroupShuffle(_64, 5u);\n'
               '    int _961 = int(_50) << 2;\n    int _962 = _961 + 1;\n    float _963 = spvSubgroupShuffle(_64, uint(_962));\n'
               '    float _964 = float2(as_type<half2>(as_type<uint>(_963))).x;\n    _18[8] = uint(_66);')
        r = census(edit(source('cutlass'), '    _18[8] = uint(_66);', add), LOCAL['cutlass'])
        self.assertEqual(kinds(r), {'ldsm_address': 4, 'redux_match': 32, 'hmma_lane': 1, 'other': 1})
        self.assertEqual(ldsm(r), [(False, 4, ['tid.x'], 64)])


class Misleading(unittest.TestCase):
    """Forms that must not pass for a constant pitch, a lane function, an LDSM or code the Metal compiler drops"""

    def test_or_with_a_buffer_word(self):   # a buffer word's low bits are not known: an OR with it is an add only where their bits cannot overlap
        overlap = address('chain', '((as_type<int>(_40) & 7) << 4) | (as_type<int>(spvDescriptorSet0.cp_c1->_m0[4].x) << 4)', [32, 1, 1])
        self.assertEqual((overlap['pitch'], overlap['lane_function'], overlap['tile']), ('varies', True, False))
        apart = address('chain', '(as_type<int>(spvDescriptorSet0.cp_c1->_m0[4].x) << 7) | ((as_type<int>(_40) & 7) << 4)', [32, 1, 1])
        self.assertEqual((apart['pitch'], apart['row_alignment'], apart['tile']), (16, 16, True))
        shifted = address('chain', 'as_type<int>(_40) * (16 << (as_type<int>(spvDescriptorSet0.cp_c1->_m0[0].y) & 3))', [32, 1, 1])
        self.assertEqual((shifted['pitch'], shifted['pitch_depends_on'], shifted['tile']), ('uniform', ['uniform values'], False))
        based = address('cutlass', '(_44 + _42) + as_type<int>(spvDescriptorSet0.cp_c1->_m0[3].x)')   # an added base: the pitch holds, the rows' alignment is the word's
        self.assertEqual(based['pitch'], 64); self.assertLess(based['row_alignment'], 16)

    def test_pitch_that_differs_between_warps(self):   # every warp of the workgroup is evaluated, not one
        expr = '((as_type<int>(_32) & 7) * ((as_type<int>(_32) >> 5) + 1)) << 4'   # warp 0 rows 16 apart, warp 1 32 (local size x 64)
        for local in ([64, 1, 1], [64, 2, 1]):
            g = address('cutlass', expr, local)
            self.assertEqual((g['pitch'], g['pitch_depends_on'], g['pitches_seen'], g['lane_function']), ('per warp', ['warp'], [16, 32], True), local)
            self.assertIn('pitch per warp', g['tile_why'])
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
                   '    float _953 = as_type<float>(_18[int(_952)]);\n    _18[12] = as_type<uint>(_953);\n    _18[8] = uint(_66);')
            r = census(edit(source('cutlass'), '    _18[8] = uint(_66);', add), LOCAL['cutlass'])
            self.assertEqual((kinds(r), r['counts']['ldsm']), ({'ldsm_address': 4, 'other': 1}, 1), lanes)

    def test_ldsm_words_with_other_uses(self):   # a word stored as well as fed to the HMMA: that LDSM is no tile, and that word's load and shuffle stay in Metal
        r = census(edit(source('chain'), '    _18[8] = uint(_397);', '    _18[8] = uint(_397);\n    _18[10] = as_type<uint>(_61);'))
        a, b = r['ldsm']
        self.assertEqual((a['words_used_elsewhere'], a['tile'], a['tile_why']), (1, False, ['words used outside HMMA A / B']))
        self.assertEqual((b['words_used_elsewhere'], b['tile']), (0, True))
        self.assertEqual(r['verdict']['tiles']['ldsm'], 1)
        self.assertEqual((a['dropped'], a['dropped_shuffles']), (False, 3))   # the other three matrices' code goes
        self.assertEqual(r['verdict']['stage1'], dict(ldsm=2, of=2, shuffles=5, of_shuffles=5, blockers={}, phi_only_uniform_inputs=0, dropped=0, dropped_shuffles=3))

    def test_a_read_through_the_scratch_keeps_its_ldsm(self):   # one call that loads A from the scratch keeps all of A's code, whichever others load it themselves
        r = census(edit(source('chain'), FLAGS0, '    int _323 = 12;'))
        self.assertEqual((paths(r)[0][1], r['verdict']['stage1']['dropped_shuffles']), ('scratch', 0))


def inst(hi, lo): return struct.pack('<QQ', lo, hi)
def waiting(i): return (i[0] | 0x3f << 52, i[1])   # waits on every scoreboard (control bits 116..121)
SLOTS_D = [20 + 2 * j for j in range(9)]   # slots: nine accumulator chains of two calls open at once (R20..R37), one more than TensorPass's 8 slots


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class Translated(unittest.TestCase):
    """The fixtures are the translator's output: each program through DMSH_TEST_XLATE and spirv-cross with the build's flags gives the fixture's kernel and helper signature"""
    NOBAR, EXIT = 0x000fe20000000000, (0x000fea0003800000, 0x000000000000794d)

    @classmethod
    def programs(cls):
        def s2r(rd, tid): return (0x000e260000002100 if tid else 0x000e260000000000, 0x0000000000007919 | rd << 16)   # S2R Rd, SR_TID.X / SR_LANEID
        def imad(rd, ra, imm, rc=255): return (0x000fe200078e0000 | rc, imm << 32 | ra << 24 | rd << 16 | 0x7824)   # IMAD Rd, Ra, imm, Rc
        def ldsm(rd, ra, count_log2, trans, off=0): return (cls.NOBAR | trans << 14 | count_log2 << 8, (off & 0xffffff) << 40 | 0xff << 32 | ra << 24 | rd << 16 | 0x783b)
        def movm(rd, ra): return (cls.NOBAR, ra << 24 | rd << 16 | 0x723a)
        def hmma(rd, ra, rb, rc): return (cls.NOBAR | 1 << 11 | rc, rb << 32 | ra << 24 | rd << 16 | 0x723c)   # HMMA.16816.F16
        def sts(offset, rb): return (0x000fe80000000800, offset << 40 | rb << 32 | 0xff << 24 | 0x7388)
        def land(rd, ra, imm): return (0x000fe200078ec0ff, imm << 32 | ra << 24 | rd << 16 | 0x7812)   # LOP3.LUT Rd, Ra, imm (a & imm)
        def lxor(rd, ra, rb): return (0x000fe200078e3cff, rb << 32 | ra << 24 | rd << 16 | 0x7212)   # LOP3.LUT Rd, Ra, Rb, RZ, 0x3c (a ^ b)
        def shr(rd, rc, imm): return (0x000fe20000011600 | rc, imm << 32 | 0xff << 24 | rd << 16 | 0x7819)   # SHF.R.U32.HI
        cutlass = [s2r(0, True), waiting(land(1, 0, 15)), shr(2, 0, 4), land(2, 2, 1), imad(3, 1, 64), imad(3, 2, 16, 3)]
        stored = [sts(0x20, 4), sts(0x24, 5), sts(0x28, 6), sts(0x2c, 7), cls.EXIT]
        return {
            'cutlass': cutlass + [ldsm(4, 3, 2, 0)] + stored,
            'swizzle': cutlass[:4] + [land(5, 0, 7), lxor(2, 2, 5)] + cutlass[4:] + [ldsm(4, 3, 2, 1)] + stored,
            'opaque': [s2r(0, True), waiting(land(1, 0, 15)), (0x000e220000000800, 0x0000100001037984), waiting(ldsm(4, 3, 2, 0)), sts(0x20, 4), cls.EXIT],   # LDS R3, [R1 + 0x10]
            'const': [ldsm(4, 255, 1, 0, 0x100), ldsm(6, 255, 1, 1, 0x400)] + stored,
            'chain': [s2r(0, False), waiting(imad(1, 0, 16)), ldsm(4, 1, 2, 0), ldsm(12, 1, 1, 1, 0x400), movm(13, 13), hmma(8, 4, 12, 255), hmma(8, 4, 12, 8), sts(0x20, 8),
                      sts(0x24, 9), cls.EXIT],
            'net': cutlass + [ldsm(4, 3, 2, 0), ldsm(12, 3, 1, 1, 0x800), hmma(8, 4, 12, 255), ldsm(14, 3, 1, 1, 0xc00), hmma(8, 4, 14, 8), movm(16, 8), movm(17, 9),
                              hmma(20, 4, 16, 255), sts(0x20, 20), sts(0x24, 21), sts(0x28, 8), cls.EXIT],
            'slots': [s2r(0, False), waiting(imad(1, 0, 16)), ldsm(4, 1, 2, 0), ldsm(12, 1, 1, 1, 0x400)] + [hmma(d, 4, 12, 255) for d in SLOTS_D]
                     + [hmma(d, 4, 12, d) for d in SLOTS_D] + [x for j, d in enumerate(SLOTS_D) for x in (sts(0x20 + 8 * j, d), sts(0x24 + 8 * j, d + 1))] + [cls.EXIT],
        }

    def test_fixtures_are_its_output(self):
        xc = next(ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign) and any(getattr(t, 'id', None) == 'XC' for t in n.targets))   # dmsh_build.py XC
        import dmsh_atomic   # the build's spirv-cross arguments for a module
        for name, prog in self.programs().items():
            with tempfile.TemporaryDirectory(prefix='census_') as d:
                work = Path(d); (work / f'{name}.bin').write_bytes(b''.join(inst(*i) for i in prog))
                job = dict(key=name, stage='cs', arch='sm86', code=str(work / f'{name}.bin'), tex={}, img={}, attr={}, fout={}, local=LOCAL[name], shared=0x2000,
                           nvn2_cs=[0, 0, 3, 0x40, 0], debug=True, reduced=True)   # dmsh_build.py's translation options
                (work / 'jobs.json').write_text(json.dumps([job]))
                r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                spv = str(work / f'{name}.spv')
                r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), *dmsh_atomic.cross_args(xc, spv), spv], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
            fixture = raw(name)
            self.assertEqual(r.stdout[r.stdout.index('kernel void'):].rstrip(), fixture[fixture.index('kernel void'):].rstrip(), name)
            signature = re.compile(r'\nint dmsh_hmma16816_f16\([^)]*\)\n')
            self.assertEqual([m.group(0) for m in signature.finditer(r.stdout)], [m.group(0) for m in signature.finditer(fixture)], name)


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

    def library(self, root, name='b-0123456789ab', pack=True, where='shader/cache', helper=True, chain_src=None):
        lib = Path(root) / where / name
        lib.mkdir(parents=True)
        if helper:
            (lib / '00000000000000c1_b.metal').write_text(chain_src or source('chain'))
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
            self.assertEqual((rep['census'], rep['shader'], rep['helper'], rep['source'], rep['local_size'], rep['verdict']['tiles']['ldsm']),
                             (3, '00000000000000c1', True, '/synthetic.pck#NDSR@0x0', [32, 1, 1], 2))
            self.assertEqual([h['paths']['A'] for h in rep['hmma']], ['direct', 'kept'])
            summary = json.loads((out / 'summary.census').read_text())
            self.assertEqual((summary['metal_sources'], summary['hmma_shaders'], summary['shuffling_shaders'], summary['tensor_shaders_without_helper']), (4, 1, 2, 1))
            self.assertEqual((summary['totals']['counts']['hmma'], summary['totals_without_helper']['counts']['ldsm']), (2, 1))
            self.assertEqual((summary['totals']['upstream']['served'], summary['totals']['stage1']['dropped'], summary['totals']['stage3']['of_acc']), (2, 1, 1))
            self.assertEqual(list(summary['by_file']), ['other.pck', 'synthetic.pck'])   # the file each shader came from, as its reflection's source names it
            self.assertIn('00000000000000c1 (synthetic.pck): LDSM 2, HMMA 2, shuffles 10; upstream 2/2; stage 1 1/1 (+1 dropped), stage 2 0/2, stage 3 A 0, acc 0, B 0', text)
            self.assertIn('00000000000000a1 (other.pck; no dmsh_hmma16816_f16): LDSM 1, HMMA 0, shuffles 4; stage 1 1/1, stage 2 0/0', text)
            self.assertIn("upstream's paths: 2 of 2 HMMAs with TensorPass's flags take neither A nor C through the scratch", text)
            summary_txt = (out / 'summary.txt').read_text()
            self.assertIn('1 of 4 shaders define dmsh_hmma16816_f16; 1 of the 2 others that shuffle have LDSM, MOVM or per-lane HMMA shuffles', summary_txt)
            self.assertNotIn('as_type', summary_txt + (out / '00000000000000c1.census').read_text())   # counts and structure, no source text

    def test_a_library_built_before_the_flags(self):   # its chain tells: another chain's library may be of the old form; this checkout's never is
        with tempfile.TemporaryDirectory() as d:
            self.library(d, chain_src=unflagged('chain'))
            rc, text = self.run_main('--library', d, '--out', str(Path(d) / 'o'))
            self.assertEqual(rc, 0, text)
            self.assertIn('LDSM 2, HMMA 2, shuffles 10; no flags; stage 1 2/2, stage 2 0/2', text)
            self.assertIn("2 HMMAs without TensorPass's flags: upstream's paths and stage 3 not known for them", text)
            self.assertIn("a library of chain 0123456789ab, not this checkout's", text); self.assertIn('built before TensorPass', text)
        chain = tc.this_chain()
        with tempfile.TemporaryDirectory() as d:
            self.library(d, f'b-{chain}', chain_src=unflagged('chain'))
            _, text = self.run_main('--library', d, '--out', str(Path(d) / 'o'))
            self.assertIn("[RED] 2 HMMA calls without TensorPass's flags in a library of this checkout's chain", text)

    def test_a_call_hmma_msl_did_not_rewrite(self):   # 19 arguments in a library: the translator's per-lane body runs, which reads no flag
        with tempfile.TemporaryDirectory() as d:
            self.library(d, chain_src=raw('chain'))
            rc, text = self.run_main('--library', d, '--out', str(Path(d) / 'o'))
            self.assertEqual(rc, 0, text)
            rep = json.loads((Path(d) / 'o/00000000000000c1.census').read_text())
            up = rep['verdict']['upstream']
            self.assertEqual((up['flagged'], up['not_rewritten'], up['served'], rep['verdict']['stage3']['known']), (0, 2, 0, False))
            self.assertEqual({h['form'] for h in rep['hmma']}, {'not rewritten'})
            self.assertIn("[RED] 2 calls of the translator's 19 arguments in a library: hmma_msl did not rewrite the helper", '\n'.join(rep['text']))
            self.assertIn("[RED] 2 HMMA calls of the translator's 19 arguments: hmma_msl did not rewrite their helper", text)
        self.assertEqual(census(raw('chain'))['verdict']['upstream']['not_rewritten'], 0)   # one source, not a library's: read as the build would rewrite it

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
