"""dm/ios/tools/gen_embed.py: a module's switchable mods (<module>.variants) as signed code pages, one per combination of the roles touching a page, and data runs, with the table loader.c reads"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
PG = 0x4000


class GenEmbedVariants(unittest.TestCase):
    def run_embed(self, variants):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        out = Path(t.name)
        (out / 'main.patched.bin').write_bytes(bytes(range(256)) * (0x10000 // 256))
        (out / 'main.fixups.tsv').write_text('# TEXT_END 0x4000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n')
        if variants is not None: (out / 'main.variants').write_text('# header\n' + variants)
        dst = out / 'embed.s'
        subprocess.run([sys.executable, REPO / 'dm/ios/tools/gen_embed.py', out, dst, 'main'], check=True, capture_output=True)
        return dst.read_text(), out / 'main.variants.bin'

    def table(self, asm):
        rows, lines = [], asm.split('__DATA,__dmmainvt')[1].splitlines()
        longs = [l for l in lines if '.long' in l]; quads = [l for l in lines if '.quad' in l]
        for lo, qu in zip(longs, quads):
            k, r, t, _ = (int(x, 0) for x in lo.split('.long')[1].split(','))
            io, ln, at = (int(x, 0) for x in qu.split('.quad')[1].split(','))
            rows.append((k, r, t, io if io < 1 << 63 else io - (1 << 64), ln, at))
        return rows

    def test_no_variants_no_sections(self):
        asm, vbin = self.run_embed(None)
        self.assertNotIn('__dmmainv', asm); self.assertFalse(vbin.exists())

    def test_pages_per_role_combination_and_data_runs(self):
        asm, vbin = self.run_embed('fps\tc\t0x10\t0x10\taabb\nultrawide\tc\t0x20\t0x20\tcc\nultrawide\tc\t0xc010\t0xc010\tdd\nfps\tw\t0x4100\t0x4100\t0102\n')
        self.assertIn('.section __TEXT,__dmmainv', asm)
        rows = self.table(asm)
        # page 0: touched by both roles: fps alone, ultrawide alone, both; page 0xc000: ultrawide alone; then the data run
        self.assertEqual([(k, r, t, io, ln) for k, r, t, io, ln, _ in rows],
                         [(0, 1, 3, 0, PG), (0, 2, 3, 0, PG), (0, 3, 3, 0, PG), (0, 2, 2, 0xc000, PG), (1, 1, 0, 0x4100, 2)])
        blob, base = vbin.read_bytes(), bytes(range(256)) * (0x10000 // 256)
        page = lambda i: blob[rows[i][5]:rows[i][5] + PG]
        self.assertEqual(page(0)[0x10:0x12], b'\xaa\xbb'); self.assertEqual(page(0)[0x20], base[0x20])
        self.assertEqual(page(1)[0x10:0x12], base[0x10:0x12]); self.assertEqual(page(1)[0x20], 0xcc)
        self.assertEqual((page(2)[0x10:0x12], page(2)[0x20]), (b'\xaa\xbb', 0xcc))
        self.assertEqual(page(3)[0x10], 0xdd)
        self.assertEqual(blob[rows[4][5]:rows[4][5] + 2], b'\x01\x02')


if __name__ == '__main__':
    unittest.main()
