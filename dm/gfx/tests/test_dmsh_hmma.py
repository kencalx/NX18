"""Ampere HMMA.16816 with an f16 accumulator through simdgroup_matrix (dmsh_build.py hmma_msl): the rewrite of the translator's helper dmsh_hmma16816_f16 as spirv-cross
writes it, its arguments and scratch array; the start-up self-test's kernel (DM_SELFTEST=hmma: hmma_selftest.py, selftest.m) as exactly that rewrite, compiled as each platform's
game shaders are and checked against the one reference (hmma_check.h), with its switch wired as the host's other diagnostics are; and on this Mac's GPU the rewritten body
against that CPU reference of PTX mma.m16n8k16 (f16 sources and accumulator) on random fragments, four SIMD-groups a threadgroup, four calls a lane in a row on one scratch
block (each D the next call's C) and eight runs, compiled once with the macOS chain's Metal flags and once with the iOS chain's (on the macosx SDK), printing for each the GPU,
how close the worst output came to its bound, the largest absolute and relative error and the flags."""
import ast
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

GFX = Path(__file__).resolve().parents[1]
TOOLS, NVN, REPO = GFX / 'tools', GFX / 'nvn', GFX.parents[1]
# hmma_msl read from dmsh_build.py here, apart from hmma_selftest.py's own reading of it, so the self-test's kernel is checked against the build's function itself
tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
selected = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name == 'hmma_msl')
            or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) == 'HMMA_BODY' for t in n.targets))]
scope = {'re': re}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), scope)
hmma_msl = scope['hmma_msl']
sys.path.insert(0, str(TOOLS)); import hmma_selftest   # the kernel: the helper as spirv-cross writes it, in a check kernel; both chains' compiles
HEAD, HELPER, KERNEL = hmma_selftest.HEAD, hmma_selftest.HELPER, hmma_selftest.KERNEL

# The GPU check: the kernel's library from argv[1] through hmma_check.h's run, the code the start-up self-test runs (64 threadgroups of 128 lanes, four chained calls, eight runs,
# the fragments, the reference and its bound, the summary line). Exit 0 within the bound, 1 over it, with runs that differ, or not run, 2 without a Metal device
RUNNER = r'''#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "hmma_check.h"
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        if (!dev || argc < 2) { printf("no Metal device\n"); return 2; }
        NSData *lib_data = [NSData dataWithContentsOfFile:@(argv[1])];
        id<MTLLibrary> lib = lib_data ? [dev newLibraryWithData:dispatch_data_create(lib_data.bytes, lib_data.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e] : nil;
        if (!lib) { printf("library: %s\n", e.localizedDescription.UTF8String); return 1; }
        char line[768]; struct hmma_check_result r;
        int ran = hmma_check_run(dev, lib, &r, line, sizeof line);
        printf("%s\n", line);
        return !ran || hmma_check_failed(&r);
    }
}
'''


class HmmaRewrite(unittest.TestCase):
    def test_body_replaced_with_its_arguments(self):
        out = hmma_msl(HEAD + HELPER + KERNEL)
        body = out[out.index('int dmsh_hmma16816_f16('):out.index('kernel void check')]
        self.assertEqual(body.count('simdgroup_multiply_accumulate('), 4)
        self.assertIn('threadgroup uint* s = &_34[uint(_42962)];', body)        # the scratch array at the block offset
        self.assertIn('uint g = uint(_42961) >> 2', body)                        # the lane
        self.assertIn('s[g * 8 + t] = uint(_42963)', body)                       # A0
        self.assertIn('s[192 + (g + 8) * 4 + t] = uint(_42970)', body)           # C1
        self.assertIn('_42971 = as_type<int>(d1);', body)                        # the out argument
        self.assertIn('return as_type<int>(d0);', body)
        self.assertNotIn('_42974', body)                                         # the translator's body is gone, the braces of its blocks too
        self.assertIn(KERNEL.strip(), out)

    def test_other_shaders_unchanged(self):
        src = HEAD + KERNEL.replace('dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, d1, scr)', 'a0')
        self.assertEqual(hmma_msl(src), src)

    def test_unexpected_signature_refused(self):
        with self.assertRaises(ValueError):
            hmma_msl(HEAD + HELPER.replace('thread const int& _42970, ', ''))


class SelfTest(unittest.TestCase):
    """The start-up self-test DM_SELFTEST=hmma: the body it runs, the reference it compares with, and where the host starts and waits for it"""
    def test_kernel_is_the_rewrite_games_get(self):
        self.assertEqual(hmma_selftest.msl(), hmma_msl(HEAD + HELPER + KERNEL))
        self.assertEqual(hmma_selftest.hmma_msl.__code__.co_filename, str(TOOLS / 'dmsh_build.py'))   # dmsh_build.py's function, not a copy
        own = (TOOLS / 'hmma_selftest.py').read_text()
        self.assertNotIn('simdgroup_multiply_accumulate', own)   # no body of its own
        self.assertEqual(subprocess.run([sys.executable, str(TOOLS / 'hmma_selftest.py'), '--msl'], capture_output=True, text=True, check=True).stdout, hmma_selftest.msl())

    def test_compiled_with_each_platforms_game_shader_flags(self):
        import ios_metal
        self.assertEqual(hmma_selftest.CHAIN['MAC_METAL'][:4], ['xcrun', '-sdk', 'macosx', 'metal'])
        metal, fallback, metallib = hmma_selftest.ios_flags_on_mac()
        self.assertEqual([a for a in ios_metal.METAL if not a.startswith('-mios-version-min=')], [('iphoneos' if a == 'macosx' else a) for a in metal])
        self.assertIn('-std=metal4.1', metal); self.assertIn('-fmetal-math-mode=relaxed', metal)
        self.assertEqual(fallback, [ios_metal.FALLBACK_STD if a == ios_metal.STD else a for a in metal])
        self.assertEqual(metallib, ['xcrun', '-sdk', 'macosx', 'metallib'])
        self.assertNotEqual(hmma_selftest.inputs('iphoneos'), hmma_selftest.inputs('macosx'))

    def test_one_reference_for_the_mac_test_and_the_self_test(self):
        selftest = (NVN / 'selftest.m').read_text()
        for src in (RUNNER, selftest):
            self.assertIn('#include "hmma_check.h"', src)
            self.assertIn('hmma_check_run(dev, lib, &r, line, sizeof line)', src)
            self.assertIn('hmma_check_failed(&r)', src)   # over the bound, or runs that differ
            self.assertNotIn('h2f', src); self.assertNotIn('srand', src); self.assertNotIn('0.004', src)   # no fragments, inputs or bound of their own
        check = (NVN / 'hmma_check.h').read_text()
        self.assertIn('HMMA_CHECK_GROUPS = 64, HMMA_CHECK_LANES = 128', check)
        self.assertIn(f'HMMA_CHECK_STEPS = {hmma_selftest.STEPS}, HMMA_CHECK_RUNS = 8', check)   # the kernel's calls a lane, the header's steps
        self.assertIn('"OVER BOUND"', check); self.assertNotIn('[RED]', check)   # the verdict; the self-test's line, not the summary, starts with the red mark (AGENTS.md)
        self.assertIn('STLOG("%sself-test hmma: %s; compiled by %s", !ran || hmma_check_failed(&r) ? "[RED] " : "", line, record);', selftest)   # and names its compile

    def test_the_kernel_chains_its_calls_on_one_scratch_block(self):   # as games make them: the scratch reused across calls (the body's last barrier), D fed back as C
        call = 'int d0 = dmsh_hmma16816_f16(l, blk, a0, a1, a2, a3, b0, b1, c0, c1, d1, scr);'
        self.assertEqual(KERNEL.count(call), hmma_selftest.STEPS); self.assertEqual(KERNEL.count('threadgroup spvUnsafeArray<uint, 1024> scr;'), 1)
        self.assertEqual(KERNEL.count('c0 = d0; c1 = d1;'), hmma_selftest.STEPS)
        for k in range(hmma_selftest.STEPS):
            self.assertIn(f'device const uint *f = in + ({k} * n + gid) * 6;', KERNEL); self.assertIn(f'out[({k} * n + gid) * 2] = uint(d0)', KERNEL)
        self.assertIn(f'int c0 = int(in[{6 * hmma_selftest.STEPS} * n + gid * 2])', KERNEL)   # step 0's C after every step's A and B (hmma_check_c0)

    @unittest.skipUnless(shutil.which('cc'), 'needs a C compiler')
    def test_reference_is_ptx_mma_m16n8k16(self):
        # hmma_check.h's C part, built here: its tiles against PTX's fragment layout worked out in Python, then the check's verdicts for an ideal GPU's runs (each step rounded
        # once to f16 and fed to the next as C), one output far off, two NaN outputs, and one output an f16 step off in one run (within the bound, but not the first run's)
        driver = r'''#include "hmma_check.h"
#include <stdio.h>
#include <stdlib.h>
static uint32_t in[HMMA_CHECK_IN];
static void say(const struct hmma_check_result *r) { char line[512]; hmma_check_summary(r, HMMA_CHECK_RUNS, line, sizeof line); printf("%ld %ld %d|%s\n", r->over, r->nan, r->runs_differ, line); }
int main(void) {
    uint32_t *out = malloc(sizeof *out * HMMA_CHECK_OUT * HMMA_CHECK_RUNS); if (!out) return 1;
    hmma_check_fill(in, HMMA_CHECK_SEED);
    const uint32_t *ab = hmma_check_ab(in, 0), *c0 = hmma_check_c0(in);
    for (int L = 0; L < 64; L++) printf("%u %u %u %u %u %u %u %u\n", ab[L * 6], ab[L * 6 + 1], ab[L * 6 + 2], ab[L * 6 + 3], ab[L * 6 + 4], ab[L * 6 + 5], c0[L * 2], c0[L * 2 + 1]);
    float D[16][8]; hmma_check_tile(ab, c0, 1, D);
    for (int r = 0; r < 16; r++) for (int c = 0; c < 8; c++) printf("%.9g%c", D[r][c], c == 7 ? '\n' : ' ');
    for (int run = 0; run < HMMA_CHECK_RUNS; run++) for (int step = 0; step < HMMA_CHECK_STEPS; step++) {
        uint32_t *o = out + (size_t)run * HMMA_CHECK_OUT, *d = o + step * HMMA_CHECK_THREADS * 2; const uint32_t *c = step ? hmma_check_d(o, step - 1) : c0;
        for (int w = 0; w < HMMA_CHECK_TILES; w++) {
            hmma_check_tile(hmma_check_ab(in, step), c, w, D);
            for (int L = 0; L < 32; L++) for (int q = 0; q < 2; q++)
                d[(w * 32 + L) * 2 + q] = hmma_check_f2h(D[L / 4 + 8 * q][2 * (L % 4)]) | (uint32_t)hmma_check_f2h(D[L / 4 + 8 * q][2 * (L % 4) + 1]) << 16;
        }
    }
    struct hmma_check_result r; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r);
    printf("%ld %ld %ld %d %.6f %.6f %.6f\n", r.over, r.nan, r.outputs, r.runs_differ, r.worst, r.abs, r.abs_at); say(&r);
    uint32_t *last = out + (size_t)(HMMA_CHECK_RUNS - 1) * HMMA_CHECK_OUT + (HMMA_CHECK_STEPS - 1) * HMMA_CHECK_THREADS * 2, keep = last[5];   // the last run's last step
    last[5] ^= 0x4000; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r); say(&r);
    last[5] = 0x7e007e00; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r); say(&r);
    last[5] = keep ^ 1; hmma_check_runs(in, out, HMMA_CHECK_RUNS, &r); say(&r);
    free(out);
    return 0;
}
'''
        import struct
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'ref.c').write_text(driver)
            subprocess.run(['cc', '-O1', '-std=c11', f'-I{NVN}', str(Path(d) / 'ref.c'), '-o', str(Path(d) / 'ref'), '-lm'], check=True)
            lines = subprocess.run([str(Path(d) / 'ref')], capture_output=True, text=True, check=True).stdout.split('\n')
        words = [[int(w) for w in lines[i].split()] for i in range(64)]   # lanes 0..63 (warps 0 and 1), step 0: A0..A3, B0, B1, then step 0's C0, C1
        def half(w, hi): return struct.unpack('<e', struct.pack('<H', (w >> (16 * hi)) & 0xffff))[0]
        self.assertTrue(all(-1 <= half(w, h) <= 1 for lane in words for w in lane for h in (0, 1)))
        A = [[0.0] * 16 for _ in range(16)]; B = [[0.0] * 8 for _ in range(16)]; C = [[0.0] * 8 for _ in range(16)]
        for lane in range(32):   # warp 1: PTX ISA, mma.m16n8k16 .f16 fragments (a0..a7, b0..b3, c0..c3 by groupID = lane / 4 and threadID_in_group = lane % 4)
            f, g, t = words[32 + lane], lane // 4, lane % 4
            for i in range(8): A[g + 8 * ((i // 2) % 2)][2 * t + i % 2 + 8 * (i // 4)] = half(f[i // 2], i % 2)
            for i in range(4): B[2 * t + i % 2 + 8 * (i // 2)][g] = half(f[4 + i // 2], i % 2)
            for i in range(4): C[g + 8 * (i // 2)][2 * t + i % 2] = half(f[6 + i // 2], i % 2)
        tile = [[float(x) for x in lines[64 + r].split()] for r in range(16)]
        for r in range(16):
            for c in range(8):
                self.assertAlmostEqual(tile[r][c], C[r][c] + sum(A[r][k] * B[k][c] for k in range(16)), places=4)   # summed in float there
        over, nan, outputs, differ, worst, err, _ = lines[80].split()
        self.assertEqual((over, nan, outputs, differ), ('0', '0', str(256 * 128 * hmma_selftest.STEPS * 8), '0'))
        self.assertLess(float(worst), 0.15)   # rounded once to f16 at each step: half an f16 step at most, about a tenth of the bound
        self.assertLess(float(err), 0.01)
        verdict = lambda i: lines[i].split('|')   # noqa: E731
        self.assertEqual(verdict(81)[0], '0 0 0')
        self.assertRegex(verdict(81)[1], r'^256 tiles x 4 chained calls, 8 runs: worst output at \d+% of its bound 0\.01 \+ 0\.4% of its value; max error [\d.e-]+ abs '
                                         r'\(at an output of [\d.]+\), [\d.e-]+% rel: ok$')
        self.assertEqual(verdict(82), ['1 0 1', verdict(82)[1]]); self.assertTrue(verdict(82)[1].endswith(': OVER BOUND (1 of 1048576 outputs, 1 of 8 runs differ from the first)'))   # one output far off
        self.assertEqual(verdict(83)[0], '2 2 1'); self.assertIn('OVER BOUND (2 of 1048576 outputs, NaN among them, 1 of 8 runs differ from the first)', verdict(83)[1])   # two NaN outputs
        self.assertEqual(verdict(84)[0], '0 0 1'); self.assertTrue(verdict(84)[1].endswith(': RUNS DIFFER (1 of 8 runs differ from the first)'))   # within the bound, but not the first run's

    def test_switch_starts_it_once_off_the_game_threads_before_the_first_instruction(self):
        main = (REPO / 'dm/host/main.c').read_text()
        body = main[main.index('int main(int argc, char **argv) {'):]
        body = body[:body.index('\n}\n')]
        self.assertIn('const char *selftest = getenv("DM_SELFTEST");', body)
        self.assertIn('if (selftest && (!*selftest || !strcmp(selftest, "0"))) selftest = NULL;', body)   # empty or 0: off, as other switches
        uses = [line.strip() for line in body.split('\n') if 'dm_selftest_' in line and not line.strip().startswith('void ')]
        self.assertEqual(uses, ['if (selftest) dm_selftest_start(selftest);', 'if (selftest) dm_selftest_wait();'])   # only with the switch
        self.assertLess(body.index('dm_selftest_start(selftest)'), body.index('host_preload(argc, argv)'))   # it runs while the host loads,
        self.assertIn('if (selftest) dm_selftest_wait();\n    front_run(guest_main);', body)                # and ends before the game's first instruction
        st = (NVN / 'selftest.m').read_text()
        start_fn = st[st.index('void dm_selftest_start('):st.index('void dm_selftest_wait(')]
        self.assertIn('atomic_exchange(&once, 1)', start_fn)                  # once a process
        self.assertIn('pthread_create(&th, &a, selftest_thread, arg)', start_fn)   # on its own thread
        self.assertNotIn('selftest_hmma()', start_fn)                         # never on main.c's, which becomes the game's
        self.assertIn('dispatch_semaphore_wait(g_selftest_done', st)
        self.assertRegex(st, r'void dm_selftest_wait\(void\) \{\n    if \(!g_selftest_done\) return;')
        self.assertNotIn('getenv(', st)   # the switch is read in one place, main.c
        rows = {l.split('\t')[0]: l.split('\t') for l in (REPO / 'docs/env_switches.tsv').read_text().split('\n') if l.startswith('DM_')}
        self.assertEqual(rows['DM_SELFTEST'][1], 'diagnostic')
        self.assertIn('hmma', rows['DM_SELFTEST'][2])


def have_sdk(sdk):
    return bool(shutil.which('xcrun')) and subprocess.run(['xcrun', '-sdk', sdk, '--show-sdk-path'], capture_output=True).returncode == 0


@unittest.skipUnless(shutil.which('xcrun') and shutil.which('clang'), 'needs Xcode')
class HmmaOnGpu(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.tmp.name)
        (cls.dir / 'run.m').write_text(RUNNER)
        subprocess.run(['clang', '-fobjc-arc', '-O1', f'-I{NVN}', str(cls.dir / 'run.m'), '-framework', 'Metal', '-framework', 'Foundation', '-o', str(cls.dir / 'run')], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_on_gpu(self, flags, built):
        lib, record = built
        r = subprocess.run([str(self.dir / 'run'), lib], capture_output=True, text=True)
        if r.returncode == 2: self.skipTest(r.stdout.strip())
        print(f'\n{flags}: {r.stdout.strip()}\n  compiled by: {record}', flush=True)   # the numbers and the GPU they were measured on, not just pass or fail
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def work(self, name):
        d = self.dir / name; d.mkdir(exist_ok=True)
        return str(d)

    def test_macos_chain_flags(self):   # dmsh_build.py's mac_compile (MAC_METAL): the compile of every Mac game shader
        self.run_on_gpu('macOS chain', hmma_selftest.build('macosx', self.work('mac')))

    def test_ios_chain_flags_on_the_mac(self):   # ios_metal.compile with ios_metal.METAL's language, math and optimisation flags on the macosx SDK (its fallback language if 4.1 refuses)
        self.run_on_gpu('iOS chain on the macosx SDK', hmma_selftest.build_ios_on_mac(self.work('ios_on_mac')))

    @unittest.skipUnless(have_sdk('iphoneos'), 'needs the iOS SDK')
    def test_ios_library_builds(self):   # the iphoneos library the iOS host embeds, which a Mac cannot run
        lib, record = hmma_selftest.build('iphoneos', self.work('ios'))
        self.assertGreater(os.path.getsize(lib), 0)
        print(f'\niOS chain: compiled by {record}', flush=True)


if __name__ == '__main__':
    unittest.main()
