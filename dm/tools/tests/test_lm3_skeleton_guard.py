"""Luigi's Mansion 3 1.4.0's billboard skeleton lookup guard (dm/games/0100DCA0064A6000/patches.py skeleton_guard, from upstream NXNative 089c1e5b1): the lookup in
RenderManager::RenderFrame goes to a stub that checks the handle before the bone search, and the search's missing-hash exits go to the component loop's clean skip. The layout
is checked without game files, at upstream's offsets (none of them read from the game here); on an arm64 Mac the stub's words run natively over upstream's paths (a valid
handle, a freed odd slot, a reused slot of another generation, a zero generation, a null slot, a skeleton with no bones, no skeleton)."""
import importlib.util
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from nso_asm import B   # noqa: E402

spec = importlib.util.spec_from_file_location('lm3_patches', Path(__file__).resolve().parents[2] / 'games/0100DCA0064A6000/patches.py')
assert spec is not None and spec.loader is not None
patch = importlib.util.module_from_spec(spec); spec.loader.exec_module(patch)

AREA = 0x5000000
BUILD = '79e5950ffa85acf63e28c9aec051eac2'


def build(at=None, area=AREA, table=patch.handle_table, other=None):
    """Run a guard against a recording context: (words emitted at area, {site: (words, why)}, {site: original hex}); the adrps name table (other: the handle-free one's)"""
    words, puts, sites = [], {}, {}
    at = at or patch.at_140
    ctx = types.SimpleNamespace(here=lambda: area + 4 * len(words), emit=words.append, site=sites.__setitem__, put=lambda off, ws, why: puts.__setitem__(off, (ws, why)),
                                address=lambda off: other if other is not None and off == at['handle_free'] + 0x24 else table)
    if at is patch.at_140: patch.STUBS[BUILD](ctx)
    else: patch.skeleton_guard(ctx, at)
    return words, puts, sites


def target(at, w):   # where a b / b.cond / cbz at `at` goes
    if w & 0xfc000000 == 0x14000000: return at + (((w & 0x3ffffff) ^ 0x2000000) - 0x2000000) * 4
    return at + ((((w >> 5) & 0x7ffff) ^ 0x40000) - 0x40000) * 4


class Layout(unittest.TestCase):
    def test_only_the_1_4_0_main(self):
        self.assertEqual(list(patch.STUBS), [BUILD])
        tsv = (Path(__file__).resolve().parents[2] / 'games/0100DCA0064A6000/game.tsv').read_text(encoding='utf-8')
        self.assertIn(f'main={BUILD}', tsv, 'the profile\'s 1.4.0 main')

    def test_upstreams_offsets(self):   # 089c1e5b1: RenderManager::RenderFrame at main+0x464920, lookup +0xda34, b.ne +0xdacc, mov #-1 +0xdadc, skip +0xe790
        at = patch.at_140
        self.assertEqual((at['lookup'], at['bne'], at['not_found'], at['skip']), (0x472354, 0x4723ec, 0x4723fc, 0x4730b0))
        self.assertEqual((at['idx_reg'], at['idx_sp'], at['handle_free'], patch.handle_table), (16, 0xf0, 0x7cb760, 0x18868e0))
        self.assertTrue(at['lookup'] < 0x4723a0 < 0x4723c8 < at['bne'] < at['not_found'] < 0x47241c < at['skip'], 'the crash sites lie between the lookup and the skip')

    def test_the_sites_are_asserted(self):
        _, _, sites = build()
        at = patch.at_140
        self.assertEqual(sites, {at['lookup']: '080040b9', at['bne']: 'a1000054', at['not_found']: '1c008012'})

    def test_the_sites_go_to_the_stub_and_the_skip(self):
        words, puts, _ = build()
        at = patch.at_140
        self.assertEqual(sorted(puts), [at['lookup'], at['bne'], at['not_found']])
        (b,), why = puts[at['lookup']]
        self.assertEqual(b & 0xfc000000, 0x14000000)
        self.assertEqual(target(at['lookup'], b), AREA, 'the lookup branches to the stub')
        self.assertIn('Ghost Gallery', why)
        (bne,), _ = puts[at['bne']]
        self.assertEqual(bne & 0xff00001f, 0x54000001, 'still a b.ne')
        self.assertEqual(target(at['bne'], bne), at['not_found'], 'a missing hash goes to the not-found site')
        (nf,), _ = puts[at['not_found']]
        skip = AREA + 18 * 4
        self.assertEqual(target(at['not_found'], nf), skip, 'and from there to the stub\'s skip')
        self.assertEqual(len(words), 21)
        self.assertEqual(words[17], B(AREA + 17 * 4, at['lookup'] + 0x1c), 'a good handle goes on with the search')
        self.assertEqual(words[18], 0xf9407bf0, 'ldr x16, [sp, #0xf0]')
        self.assertEqual(words[19], 0xd2c00036, 'movz x22, #1, lsl #32')
        self.assertEqual(words[20], B(AREA + 20 * 4, at['skip']), 'the loop\'s clean skip')
        for i in (0, 3, 11, 13, 14, 16): self.assertEqual(target(AREA + 4 * i, words[i]), skip, f'check {i} fails to the skip')

    def test_the_handle_tables_must_agree(self):
        with self.assertRaises(AssertionError): build(other=patch.handle_table + 0x1000)
        words, _, _ = build(table=0x18868e0 - 0x18000)   # the table the adrps name is the one the stub reads
        self.assertEqual(words[5:7], [patch.ADRP(9, AREA + 20, 0x18868e0 - 0x18000), patch.ADDI(9, 9, 0x8e0)])

    def test_nothing_the_rewriter_would_rewrite(self):   # a stub is not scanned: no x18, svc, system register or exclusive access
        words, _, _ = build()
        for w in words:
            self.assertNotEqual(w & 0xffe0001f, 0xd4000001, 'svc')
            self.assertNotEqual(w & 0xffc00000, 0xd5000000 & 0xffc00000, 'system register')
            self.assertNotEqual(w & 0x3f000000, 0x08000000, 'exclusive')
            if w & 0xfc000000 != 0x14000000: self.assertNotEqual(w & 31, 18, 'x18')


# Native run: the stub assembled at offset AREA_N of a JIT region whose offset 0x1000 is the lookup, 0x101c the search's resume (returns 1), 0x2000 the clean skip (returns 2),
# and 0x100000 the handle table (its generations at +0xffff8). A wrapper sets [sp, #0xf0] (the loop index's slot), clears x16 / x22 and enters at the lookup's branch.
AREA_N, TABLE_N = 0x3000, 0x100000
AT_N = {'lookup': 0x1000, 'bne': 0x1098, 'not_found': 0x10a8, 'not_found_orig': '1c008012', 'skip': 0x2000, 'idx_reg': 16, 'idx_sp': 0xf0, 'handle_free': 0x4000}
HARNESS = r'''#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
extern int64_t call_guard(void *obj, void *entry, uint64_t out[4]);
int main(int argc, char **argv) {
    size_t size = 0x400000;
    uint8_t *r = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (r == MAP_FAILED) return 77;
    static uint8_t code[0x4000];                       /* read first: the kernel cannot write the JIT pages */
    FILE *f = fopen(argv[1], "rb"); if (!f) return 2;
    if (fread(code, 1, sizeof code, f) != sizeof code) return 2;
    fclose(f);
    pthread_jit_write_protect_np(0);
    memcpy(r, code, sizeof code);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(r, 0x4000);
    uint64_t *slots = (uint64_t *)(r + 0x100000); uint16_t *gens = (uint16_t *)(r + 0x100000 + 0xffff8);
    static uint32_t skel[8]; skel[5] = 3;             /* a skeleton: 3 bone pairs at +0x14 */
    static uint32_t empty[8];                          /* no bone pairs */
    for (int k = 2; k + 3 < argc; k += 4) {
        uint32_t handle = (uint32_t)strtoul(argv[k], 0, 16), slot = handle & 0x1ffff;
        int kind = atoi(argv[k + 1]); uint16_t gen = (uint16_t)strtoul(argv[k + 2], 0, 16); int null_obj = atoi(argv[k + 3]);
        pthread_jit_write_protect_np(0);
        gens[slot] = gen;
        slots[slot] = kind == 0 ? (uint64_t)skel : kind == 1 ? (((uint64_t)(slot + 1)) << 3 | 1) : kind == 2 ? 0 : (uint64_t)empty;
        pthread_jit_write_protect_np(1);
        uint32_t obj = handle; uint64_t out[4] = {0};
        int64_t got = call_guard(null_obj ? NULL : &obj, r + 0x1000, out);
        printf("%lld %llx %llx %d %llu\n", (long long)got, (unsigned long long)out[0], (unsigned long long)out[1], out[2] == (uint64_t)skel, (unsigned long long)out[3]);
    }
    return 0;
}
'''
WRAPPER = '''.text
.globl _call_guard
.p2align 2
_call_guard:
 stp x29, x30, [sp, #-32]!
 str x22, [sp, #16]
 sub sp, sp, #0x100
 movz x9, #0x7777
 str x9, [sp, #0xf0]
 mov x16, #0
 mov x22, #0
 adr x30, 1f
 br x1
1:
 str x16, [x2]
 str x22, [x2, #8]
 str x9, [x2, #16]
 and x10, x10, #0xffffffff
 str x10, [x2, #24]
 add sp, sp, #0x100
 ldr x22, [sp, #16]
 ldp x29, x30, [sp], #32
 ret
'''


@unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64' and shutil.which('xcrun'), 'runs the stub natively on an arm64 Mac')
class Run(unittest.TestCase):
    #        handle      slot kind (0 skeleton, 1 free-list link, 2 null, 3 no bones), the slot's generation, no object; what comes out
    CASES = (('25660005', 0, '12b3', 0, 'search'),    # generation 0x12b3 (handle >> 17), slot 5: a valid handle, on to the search
             ('25660006', 1, '12b4', 0, 'skip'),      # freed: a free-list link and the generation bumped
             ('25660007', 1, '12b3', 0, 'skip'),      # an odd slot pointer with the right generation (tbnz)
             ('25660008', 0, '12b9', 0, 'skip'),      # reused by another generation
             ('00000009', 0, '0000', 0, 'skip'),      # generation 0
             ('2566000a', 2, '12b3', 0, 'skip'),      # a null slot
             ('2566000b', 3, '12b3', 0, 'skip'),      # a skeleton with no bone pairs
             ('2566000c', 0, '12b3', 1, 'skip'))      # no skeleton (x0 null)

    def test_every_path(self):
        words, puts, _ = build(AT_N, AREA_N, TABLE_N)
        img = bytearray(0x4000)
        struct.pack_into('<2I', img, 0x101c, 0xd2800020, 0xd65f03c0)   # resume: mov x0, #1; ret
        struct.pack_into('<2I', img, 0x2000, 0xd2800040, 0xd65f03c0)   # skip: mov x0, #2; ret
        for off, (ws, _) in puts.items(): struct.pack_into(f'<{len(ws)}I', img, off, *ws)
        struct.pack_into(f'<{len(words)}I', img, AREA_N, *words)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / 'w.S').write_text(WRAPPER); (p / 'm.c').write_text(HARNESS); (p / 'img.bin').write_bytes(bytes(img))
            subprocess.run(['xcrun', 'clang', '-Wall', '-Werror', str(p / 'm.c'), str(p / 'w.S'), '-o', str(p / 'g')], check=True)
            args = [str(a) for c in self.CASES for a in c[:4]]
            r = subprocess.run([str(p / 'g'), str(p / 'img.bin'), *args], capture_output=True, text=True)
        if r.returncode == 77: self.skipTest('no MAP_JIT memory here (a sandbox)')
        self.assertEqual(r.returncode, 0, r.stderr)
        for (handle, _, _, _, want), line in zip(self.CASES, r.stdout.split('\n')):
            got, x16, x22, slot_ptr, count = line.split()
            if want == 'search':
                self.assertEqual((got, slot_ptr, count), ('1', '1', '3'), f'{handle}: on to the search with x9 the skeleton and w10 its pair count')
            else:
                self.assertEqual((got, x16, x22), ('2', '7777', '100000000'), f'{handle}: the clean skip with the loop index back and x22 = 0x100000000')
        self.assertEqual(len(r.stdout.split('\n')) - 1, len(self.CASES))


if __name__ == '__main__':
    unittest.main()
