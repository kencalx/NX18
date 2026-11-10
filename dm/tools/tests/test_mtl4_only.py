"""The host draws through Metal 4 only (release 1): no Metal 3 queue, command buffer, encoder or MTLDevice pipeline anywhere in the production code, and no classic queue in
the graphics test fixtures. A change that brings one back fails here at once, with the file and line.

Production code: dm/gfx/nvn, dm/gfx/tex, dm/host, dm/ios/Sources, dm/mac (their tests/ folders aside). Comments are skipped; string literals are not (a getenv of a retired
switch is code). The patterns are anchored so that the Metal 4 calls with the same selector stay legal: MTL4Compiler's newRenderPipelineStateWithDescriptor:compilerTaskOptions:
and an MTL4Archive's newRenderPipelineStateWithDescriptor:error: (a receiver the file declares as id<MTL4Archive>) are not MTLDevice pipelines, and
MTL4SpecializedFunctionDescriptor's constantValues property is not MTLLibrary's newFunctionWithName:constantValues:.
ALLOWED lists the only lines that may match, each with the number of times it must: the argument-buffer layout checks, which measure a function's own layout with an
MTLArgumentEncoder that is not kept (MTLFunction's, shared with Metal 4): the shader's own function at its load, and the four side libraries' entry points against the base
library's (critic C0 of the Metal 4 design: replacing them with the base's reflection would make them always pass). An allowed line that no longer matches fails too, so the
list cannot go stale."""
from pathlib import Path
import re
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[3]
PRODUCTION = ('dm/gfx/nvn', 'dm/gfx/tex', 'dm/host', 'dm/ios/Sources', 'dm/mac')
FIXTURES = 'dm/gfx/tests'
CODE = ('.c', '.m', '.mm', '.h', '.inc', '.swift', '.S')

# (name, pattern) over production code with its comments removed
FORBIDDEN = [
    ('MTLDevice render pipeline', None),   # newRenderPipelineStateWithDescriptor: without compilerTaskOptions: on a receiver that is not an MTL4Archive (device_pipeline below)
    ('MTLDevice compute pipeline', None),   # the same for newComputePipelineStateWithDescriptor:
    ('newComputePipelineStateWithFunction', r'newComputePipelineStateWithFunction'),
    ('newRenderPipelineStateWithMeshDescriptor', r'newRenderPipelineStateWithMeshDescriptor'),
    ('newRenderPipelineStateWithTileDescriptor', r'newRenderPipelineStateWithTileDescriptor'),
    ('newFunctionWithName:constantValues:', r'(?<![.\w])constantValues:'),
    ('newLibraryWithSource', r'newLibraryWithSource'),
    ('newCommandQueue', r'\bnewCommandQueue'),
    ('waitUntilCompleted', r'\bwaitUntilCompleted\b'),
    ('addCompletedHandler', r'\baddCompletedHandler\b'),
    ('classic command buffer', r'\bcommandBuffer(?:WithDescriptor:|WithUnretainedReferences)?\s*\]'),
    ('classic blit encoder', r'\bblitCommandEncoder\b'),
    ('set*Bytes', r'\bset(?:Vertex|Fragment|Compute|Mesh|Object|Tile)?Bytes:'),
    ('Metal 3 command types', r'\bid\s*<\s*MTL(?:CommandQueue|CommandBuffer|CommandEncoder|RenderCommandEncoder|ComputeCommandEncoder|BlitCommandEncoder|ParallelRenderCommandEncoder)\s*>'),
    ('Metal 3 pass descriptors', r'\bMTL(?:Render|Compute|Blit)PassDescriptor\b'),
    ('newArgumentEncoderWithBufferIndex', r'newArgumentEncoderWithBufferIndex'),
    ('g_classic', r'\bg_classic'),
    ('g_q', r'\bg_q\b'),
    ('q_cb', r'\bq_cb\b'),
    ('WS_OLDQ', r'\bWS_OLDQ\b'),
    ('present_encode', r'\bpresent_encode\b'),
    ('mtl_device_classic', r'\bmtl_device_classic\b'),
    ('Metal 3 nvn_deswz_gpu_encode', r'\bnvn_deswz_gpu_encode\b'),
    ('DM_TEST_NO_METAL4', r'\bDM_TEST_NO_METAL4\b'),
    ('pso4_on', r'\bpso4_on\b'),
    ('g_pb_legacy', r'\bg_pb_legacy\b'),
    ('g_mtk_dev', r'\bg_mtk_dev\b'),
    ('DM_GAME_PSO_MTL4', r'\bDM_GAME_PSO_MTL4\b'),
]
# The fixtures: no classic queue (Lane 2's acceptance), in the Objective-C runners the Python tests write too
FIXTURE_FORBIDDEN = [
    ('q_cb', r'\bq_cb\b'),
    ('g_q', r'\bg_q\b'),
    ('present_encode', r'\bpresent_encode\b'),
    ('newCommandQueue', r'\bnewCommandQueue'),
    ('classic command buffer', r'\bcommandBuffer\s*\]'),
    ('WS_OLDQ', r'\bWS_OLDQ\b'),
    ('g_classic', r'\bg_classic'),
    ('mtl_device_classic', r'\bmtl_device_classic\b'),
    ('DM_TEST_NO_METAL4', r'\bDM_TEST_NO_METAL4\b'),
]
# (file, pattern name, a piece of the line, how many lines of the file match it)
ALLOWED = [
    ('dm/gfx/nvn/nvn_mtl.m', 'newArgumentEncoderWithBufferIndex', '[o->fn newArgumentEncoderWithBufferIndex:o->rf.abi].encodedLength', 1),   # the shader's own function, at its load
    ('dm/gfx/nvn/nvn_mtl.m', 'newArgumentEncoderWithBufferIndex', '[f newArgumentEncoderWithBufferIndex:vs->rf.abi].encodedLength != vs->arg_len', 2),   # vin_fn, pull_load
    ('dm/gfx/nvn/nvn_mtl.m', 'newArgumentEncoderWithBufferIndex', '[f newArgumentEncoderWithBufferIndex:fs->rf.abi].encodedLength != fs->arg_len', 2),   # at_fn, lo_fn
]

PIPELINE = re.compile(r'\[\s*([A-Za-z_][\w.]*(?:->\w+)?)\s+(newRenderPipelineStateWithDescriptor|newComputePipelineStateWithDescriptor):([^\]]*)')
ARCHIVE_DECL = re.compile(r'id\s*<\s*MTL4Archive\s*>\s*(?:__strong\s*)?\*?\s*(\w+)')


def strip_comments(text, swift=False):
    """The text with // and /* */ comments blanked (newlines kept, so line numbers hold), string and character literals left as they are"""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            i = n if j < 0 else j
        elif c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j]))
            i = j
        elif c == '"' or (c == "'" and not swift):
            j = i + 1
            while j < n and text[j] != c and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            out.append(text[i:j + 1])
            i = j + 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def tracked(root):
    """The files git tracks under root (not what a build generates there, such as dm/host/gen)"""
    out = subprocess.run(['git', 'ls-files', root], cwd=REPO, capture_output=True, text=True, check=True).stdout.split('\n')
    return [rel for rel in out if rel and (REPO / rel).is_file()]


def code_files(root, suffixes):
    for rel in tracked(root):
        if Path(rel).suffix in suffixes and '/tests/' not in rel and 'third_party' not in rel:
            yield rel, REPO / rel


def device_pipelines(rel, code):
    """Lines that build a pipeline through MTLDevice: the descriptor selectors without compilerTaskOptions:, on a receiver not declared as an MTL4Archive in the file"""
    archives = set(ARCHIVE_DECL.findall(code))
    hits = []
    for no, line in enumerate(code.split('\n'), 1):
        for m in PIPELINE.finditer(line):
            recv, sel, rest = m.groups()
            if 'compilerTaskOptions:' in rest or recv in archives:
                continue
            hits.append((rel, no, 'MTLDevice render pipeline' if sel.startswith('newRender') else 'MTLDevice compute pipeline', line.strip()))
    return hits


def production_hits():
    hits = []
    pats = [(name, re.compile(p)) for name, p in FORBIDDEN if p]
    for root in PRODUCTION:
        for rel, p in code_files(root, CODE):
            code = strip_comments(p.read_text(errors='replace'), swift=p.suffix == '.swift')
            hits += device_pipelines(rel, code)
            for no, line in enumerate(code.split('\n'), 1):
                for name, rx in pats:
                    if rx.search(line):
                        hits.append((rel, no, name, line.strip()))
    return hits


def fixture_hits():
    hits = []
    pats = [(name, re.compile(p)) for name, p in FIXTURE_FORBIDDEN]
    for rel in tracked(FIXTURES):
        p = REPO / rel
        if p.suffix not in CODE + ('.py',):
            continue
        text = p.read_text(errors='replace')
        if p.suffix == '.py':   # the Objective-C a Python test writes is in its strings: only whole comment lines are skipped
            code = '\n'.join('' if ln.lstrip().startswith(('#', '//')) else ln for ln in text.split('\n'))
        else:
            code = strip_comments(text)
        for no, line in enumerate(code.split('\n'), 1):
            for name, rx in pats:
                if rx.search(line):
                    hits.append((rel, no, name, line.strip()))
    return hits


class StripComments(unittest.TestCase):
    def test_comments_go_and_strings_stay(self):
        src = 'a(); // [q commandBuffer]\nb("http://x // y"); /* waitUntilCompleted\n */ c();\n'
        out = strip_comments(src)
        self.assertNotIn('commandBuffer', out)
        self.assertNotIn('waitUntilCompleted', out)
        self.assertIn('"http://x // y"', out)
        self.assertIn('c();', out)
        self.assertEqual(out.count('\n'), src.count('\n'))

    def test_anchors(self):
        code = ('id<MTL4Archive> a;\n'
                'x = [g_comp4 newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:e];\n'
                'y = [a newRenderPipelineStateWithDescriptor:d error:nil];\n'
                'z = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];\n'
                'w = [dev newComputePipelineStateWithDescriptor:cd options:0 reflection:nil error:&e];\n')
        self.assertEqual([(no, kind) for _, no, kind, _ in device_pipelines('f.m', code)], [(4, 'MTLDevice render pipeline'), (5, 'MTLDevice compute pipeline')])
        rx = dict(FORBIDDEN)
        self.assertFalse(re.search(rx['newFunctionWithName:constantValues:'], 'sd.constantValues = cv;'))
        self.assertTrue(re.search(rx['newFunctionWithName:constantValues:'], '[lib newFunctionWithName:n constantValues:cv error:&e]'))
        self.assertFalse(re.search(rx['newCommandQueue'], '[g_dev newMTL4CommandQueueWithDescriptor:q error:&e]'))
        self.assertFalse(re.search(rx['classic command buffer'], '[g_dev newCommandBuffer]'))
        self.assertTrue(re.search(rx['classic command buffer'], '[q commandBuffer]'))
        self.assertFalse(re.search(rx['present_encode'], 'present_encode_m4(cb, src, dst)'))
        self.assertFalse(re.search(rx['g_q'], 'g_q4 = nil;'))


class Mtl4Only(unittest.TestCase):
    def test_production_has_no_metal3_path(self):
        hits = production_hits()
        left = []
        used = {i: 0 for i in range(len(ALLOWED))}
        for rel, no, name, line in hits:
            for i, (f, pname, piece, _) in enumerate(ALLOWED):
                if f == rel and pname == name and piece in line:
                    used[i] += 1
                    break
            else:
                left.append(f'{rel}:{no}: {name}: {line[:200]}')
        self.assertEqual(left, [], 'Metal 3 in the production code (the host draws through Metal 4 only):\n' + '\n'.join(left))
        stale = [f'{ALLOWED[i][0]}: {ALLOWED[i][2]} (matched {n} times, expected {ALLOWED[i][3]})' for i, n in used.items() if n != ALLOWED[i][3]]
        self.assertEqual(stale, [], 'allowed lines that changed: update ALLOWED\n' + '\n'.join(stale))

    def test_fixtures_have_no_classic_queue(self):
        hits = [f'{rel}:{no}: {name}: {line[:200]}' for rel, no, name, line in fixture_hits()]
        self.assertEqual(hits, [], 'a classic queue in the graphics fixtures (t_mtl4.h gives them Metal 4 command buffers):\n' + '\n'.join(hits))


if __name__ == '__main__':
    unittest.main()
