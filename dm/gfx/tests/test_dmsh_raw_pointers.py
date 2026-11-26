"""Fixed storage-buffer pointer sources through the real translator and reflection.
Discovery is metadata only: scalar and vector accesses keep the raw pool table.
The translator notes each source as `gptr site K: c<slot>[<word>] +<byte>`; dmsh_reflect.gptr_sites turns those notes into gmem_map's "pointers"
(the host and reflection half, checked here once it is in the tree)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_dmsh_maxwell_ftz import EXIT, PT, TOOLS, code, sts, s2r_tid, fsetp  # noqa: E402
sys.path.insert(0, str(TOOLS))
import dmsh_chain  # noqa: E402
import dmsh_reflect  # noqa: E402
from dmsh_reflect import reflect  # noqa: E402

HAVE_GPTR = hasattr(dmsh_reflect, 'gptr_sites')


# Upstream takes these from test_dmsh_storage_offset.py, which NX 18 does not have
def mov_c(rd, slot, offset): return 0x4c98 << 48 | 0xf << 39 | slot << 34 | offset // 4 << 20 | PT << 16 | rd   # MOV rd, c[slot][offset]
def ldg(rd, a): return 0xeed0 << 48 | 4 << 48 | 1 << 45 | PT << 16 | a << 8 | rd                              # LDG.E.32 rd, [a]


def translate(test, job, code_bytes):   # the translator's report and the shader's Metal source (upstream's StorageOffset.translate)
    with tempfile.TemporaryDirectory(prefix='raw_pointers_') as d:
        work = Path(d)
        (work / 'k.bin').write_bytes(code_bytes)
        (work / 'jobs.json').write_text(json.dumps([dict(key='k', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={}, local=[32, 1, 1], debug=True, **job)]))
        r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
        test.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        res = json.loads((work / 'k.res.json').read_text())
        import dmsh_geometry
        dmsh_geometry.flatten_sets(work / 'k.spv')
        r = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', dmsh_chain.MSL_VERSION, '--msl-argument-buffers', str(work / 'k.spv')],
                           capture_output=True, text=True)
        test.assertEqual(r.returncode, 0, r.stderr)
        return res, r.stdout


def sites(res):
    return [n for n in res['notes'] if 'gptr site ' in n]


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class RawPointers(unittest.TestCase):
    def test_mixed_traced_and_loaded_pointer_paths(self):
        def predicated_mov(rd, src): return 0x5c98 << 48 | 0xf << 39 | src << 20 | rd  # @P0 MOV rd, src
        body = (s2r_tid(1), fsetp(1, 255), mov_c(2, 0, 0x310), mov_c(3, 0, 0x314), ldg(4, 2), ldg(5, 2) | 4 << 20,
                mov_c(6, 0, 0x310), mov_c(7, 0, 0x314), predicated_mov(6, 4), predicated_mov(7, 5), ldg(8, 6), sts(8, 0), EXIT)
        res, msl = translate(self, dict(stage='cs', shared=0x1000), code(*body))
        self.assertTrue(any('some paths only' in n for n in res['notes']))
        self.assertEqual(len(sites(res)), 1, res['notes'])
        self.assertTrue(sites(res)[0].endswith('gptr site 0: c0[196] +0'), sites(res))   # c0 + 0x310, the pointer at byte 0
        if HAVE_GPTR:
            table = [b for b in reflect('k', 'cs', msl, res) if b['kind'] == 'gmem_map']
            self.assertEqual(table[0]['pointers'], [[0, 0]])

    def test_scalar_and_vector_loads_discover_the_same_pointer(self):
        for words, size in ((1, 4), (2, 5), (4, 6)):
            with self.subTest(words=words):
                # c0 + 0x310 is compute storage slot 0. Its words at bytes 8 and 12 hold the address of a second, otherwise untraceable buffer.
                raw = (ldg(8, 4) & ~(7 << 48)) | size << 48
                body = (mov_c(2, 0, 0x310), mov_c(3, 0, 0x314), ldg(4, 2) | 8 << 20, ldg(5, 2) | 12 << 20, raw,
                        *(sts(8 + k, k * 4) for k in range(words)), EXIT)
                res, msl = translate(self, dict(stage='cs', shared=0x1000), code(*body))
                self.assertEqual(len(sites(res)), 1, res['notes'])
                self.assertTrue(sites(res)[0].endswith('gptr site 0: c0[196] +8'), sites(res))
                if words > 1:
                    self.assertIn(f'reinterpret_cast<const device uint{words}*>', msl)
                if HAVE_GPTR:
                    bindings = reflect('k', 'cs', msl, res)
                    self.assertEqual([b['kind'] for b in bindings], ['sbuf', 'gmem_map'])
                    self.assertEqual(bindings[1]['pointers'], [[0, 8]])


if __name__ == '__main__':
    unittest.main()
