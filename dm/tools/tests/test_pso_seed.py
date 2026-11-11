"""The prewarm seed list checked and grown from recorded lists (dm/tools/pso_seed.py), on a small shader map: the rows the host takes, each refusal (a key of no map or of
another stage, a key the prewarm drops, a pointer, bytes after a key, a path, a short or non-hex key, a mesh shader in an R row), repeated rows (a line, and an R row written
before attr_hi against the same key whole), add's order, notes and counts, the provisional line it removes, rows the list names already, and nothing written on a refused row.
And Persona 5 Royal's committed list, which must check clean."""
import io
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

V, P, C, T, M = 'a' * 16, 'b' * 16, 'c' * 16, 'd' * 16, 'e' * 16
MAP = ('# kind: evidence\npackage\tindex\tstage\tdm_ctl_sha16\tsource\n'
       f'x.bin\t0\tvertex\t{V}\tmain\nx.bin\t1\tpixel\t{P}\tmain\nx.bin\t2\tcompute\t{C}\tmain\nx.bin\t3\ttask\t{T}\tmain\nx.bin\t4\tmesh\t{M}\tmain\n')
REPO = Path(__file__).resolve().parents[3]


def skey(vs=V + '_b', fs=P + '_b', vs_stage=0, fs_stage=1, merged=0, fz=0, ptr=0, fsfn=0, tail=b'', size=504):
    """An R / M row's pso_skey hex as dm/gfx/nvn/nvn_pso_skey.h lays it out on arm64, field by field: vs[24], fs[24], four flags, pso_fz_desc (34) and padding to 88,
    then pso_key (two pointers, ... the specialized fragment pointer at 336); tail: bytes written after the vertex key's end"""
    k = bytearray(416)
    struct.pack_into('<Q', k, 0, ptr)
    struct.pack_into('<I', k, 16, 70)   # cfmt[0]: RGBA8Unorm
    struct.pack_into('<Q', k, 336, fsfn)
    v = (vs.encode() + b'\0' + tail).ljust(24, b'\0')[:24]
    head = v + fs.encode().ljust(24, b'\0') + bytes((vs_stage, fs_stage, merged, fz)) + bytes(36)
    return (head + bytes(k)).hex()[:2 * size]


class Rows(unittest.TestCase):
    def setUp(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'shader_map.tsv'; p.write_text(MAP); self.map = pso_seed.read_map(p)

    def why(self, line): return pso_seed.row_problem(line, self.map)

    def test_the_map_as_the_host_reads_it(self):
        self.assertEqual(self.map, {V: 'vertex', P: 'pixel', C: 'compute', T: 'task', M: 'mesh'})

    def test_rows_the_host_takes(self):
        for line in (f'S\t{V}_b\t0', f'S\t{P}_b\t1', f'C\t{C}_b', f'R\t{skey()}', f'R\t{skey(fs="", fs_stage=0)}', f'R\t{skey(size=440)}', f'R\t{skey(size=432)}',
                     f'M\t{T}_b\t{skey(vs=M + "_b", vs_stage=4)}', f'M\t-\t{skey(vs=M + "_b", vs_stage=4)}'):
            self.assertIsNone(self.why(line), line[:40])

    def test_refused(self):
        cases = {
            f'S\t{"f" * 16}_b\t0': 'not in the shader map', f'S\t{V}_b\t1': 'vertex shader', f'S\t{V}_bgv\t0': 'prewarm drops', f'S\t{V}\t0': 'prewarm drops',
            f'S\t{V}_b': 'S row', f'C\t{P}_b': 'pixel shader', f'R\t{skey(ptr=0x10f000000)}': 'pointer', f'R\t{skey(fsfn=0x1000)}': 'pointer',
            f'R\t{skey(tail=b"xy")}': 'after a shader key', f'R\t{skey(size=500)}': 'hex digits', f'R\t{skey()[:-2]}zz': 'not hex',
            f'R\t{skey(vs=M + "_b", vs_stage=4)}': 'mesh shader in an R row', f'R\t{skey(fs=V + "_b")}': 'vertex shader', f'R\t{skey(merged=2)}': 'flags',
            f'M\t{V}_b\t{skey(vs=M + "_b", vs_stage=4)}': 'vertex shader', f'M\t-\t{skey()}': 'not a task / mesh', f'X\t{V}_b': 'unknown row kind',
            f'S\t/var/mobile/{V}_b\t0': 'a path', f'C\t{C}_b\r': 'carriage return'}
        for line, want in cases.items():
            self.assertIn(want, self.why(line) or '', line[:60])

    def test_repeats_are_left_out_as_the_host_leaves_them(self):
        short = f'R\t{skey(size=432)}'
        whole = f'R\t{skey(size=432)}' + '0' * (1008 - 864)   # the same key, with atest / logic and attr_hi written as zero
        keep, bad = pso_seed.collect([f'S\t{V}_b\t0', short, f'S\t{V}_b\t0', whole, f'C\t{C}_b'], self.map)
        self.assertEqual((keep, bad), ([f'S\t{V}_b\t0', short, f'C\t{C}_b'], []))


class Add(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.p = Path(self.d.name)
        (self.p / 'shader_map.tsv').write_text(MAP); self.map = pso_seed.read_map(self.p / 'shader_map.tsv')
        self.man = self.p / 'pso_manifest.tsv'
        self.man.write_text('# Prewarm seed list (shipped in the app).\n# Provisional profile: empty until recorded on the Mac (DM_PSO_MANIFEST=off DM_PSO_RECORD).\n')

    def tearDown(self): self.d.cleanup()

    def rec(self, *rows):
        p = self.p / 'pso_user.tsv'; p.write_text(''.join(r + '\n' for r in rows)); return p

    def test_appends_in_order_with_notes_and_counts(self):
        r = f'R\t{skey()}'
        new, bad = pso_seed.add(self.man, [self.rec(f'S\t{V}_b\t0', f'S\t{P}_b\t1', r, f'S\t{V}_b\t0', f'C\t{C}_b')], self.map, ['from a phone: {rows} rows, {S} S, {R} R, {C} C'])
        self.assertEqual(bad, [])
        self.assertEqual(self.man.read_text(), f'# Prewarm seed list (shipped in the app).\n# from a phone: 4 rows, 2 S, 1 R, 1 C\nS\t{V}_b\t0\nS\t{P}_b\t1\n{r}\nC\t{C}_b\n')
        # a second list adds only what the manifest does not name, below the rows and notes already there
        new, bad = pso_seed.add(self.man, [self.rec(f'S\t{P}_b\t1', f'R\t{skey(fs="", fs_stage=0)}')], self.map, ['# later: {R} R'])
        self.assertEqual(new, [f'R\t{skey(fs="", fs_stage=0)}'])
        self.assertTrue(self.man.read_text().endswith(f'C\t{C}_b\n# later: 1 R\nR\t{skey(fs="", fs_stage=0)}\n'))
        before = self.man.read_text()
        self.assertEqual(pso_seed.add(self.man, [self.rec(f'S\t{P}_b\t1')], self.map, ['nothing new'])[0], [])
        self.assertEqual(self.man.read_text(), before)   # nothing new: the list is left as it is, no note

    def test_a_refused_row_writes_nothing_unless_dropped(self):
        before = self.man.read_text()
        src = self.rec(f'S\t{V}_b\t0', f'R\t{skey(ptr=1)}')
        new, bad = pso_seed.add(self.man, [src], self.map)
        self.assertEqual((len(bad), self.man.read_text()), (1, before))
        new, bad = pso_seed.add(self.man, [src], self.map, drop_invalid=True)
        self.assertEqual(new, [f'S\t{V}_b\t0'])
        self.assertNotIn('Provisional', self.man.read_text())

    def test_the_command_line(self):
        src = self.rec(f'S\t{V}_b\t0', f'C\t{C}_b')
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(pso_seed.main(['add', '--map', str(self.p / 'shader_map.tsv'), '--manifest', str(self.man), '--note', '{S} S', str(src)]), 0)
            self.assertEqual(pso_seed.main(['check', '--map', str(self.p / 'shader_map.tsv'), str(self.man)]), 0)
            self.assertEqual(pso_seed.main(['check', '--map', str(self.p / 'shader_map.tsv'), str(self.rec(f'S\t{P}_b\t0'))]), 1)
            crlf = self.p / 'crlf.tsv'; crlf.write_bytes(f'S\t{V}_b\t0\r\nC\t{C}_b\r\n'.encode())   # the host drops the C row; add takes the rows clean
            self.assertEqual(pso_seed.main(['check', '--map', str(self.p / 'shader_map.tsv'), str(crlf)]), 1)
        self.assertIn('2 rows added (S 1, R 0, C 1, M 0)', out.getvalue())
        self.assertIn('pixel shader in the shader map', err.getvalue())
        self.assertIn('carriage return', err.getvalue())


class Committed(unittest.TestCase):
    def test_persona_5_royal_checks_clean(self):   # recorded on an iPhone 18 Pro Max (its README, Pipelines on a first start)
        g = REPO / 'dm/games/01005CA01580E000'
        shmap = pso_seed.read_map(g / 'shader_map.tsv')
        rows = pso_seed.rows_of((g / 'pso_manifest.tsv').read_bytes().decode('utf-8'), strip_cr=False)
        keep, bad = pso_seed.collect(rows, shmap)
        self.assertEqual((bad, len(keep), len(rows)), ([], len(rows), len(rows)))
        self.assertEqual(pso_seed.counts(keep), {'S': 30357, 'R': 564, 'C': 2, 'M': 0, 'rows': 30923})


if __name__ == '__main__':
    unittest.main()
