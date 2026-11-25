"""The prewarm seed list checked and grown from recorded lists (dm/tools/pso_seed.py), on a small shader map: the rows the host takes, each refusal (a key of no map or of
another stage, a key the prewarm drops, a pointer, bytes after a key, a path, a short or non-hex key, a mesh shader in an R row), repeated rows (a line, and an R row written
before attr_hi against the same key whole), add's order, notes and counts, the provisional line it removes, rows the list names already, and nothing written on a refused row.
And Persona 5 Royal's committed list, which must check clean."""
import io
import re
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pso_seed

V, P, C, T, M, G = 'a' * 16, 'b' * 16, 'c' * 16, 'd' * 16, 'e' * 16, '9' * 16
MAP = ('# kind: evidence\npackage\tindex\tstage\tdm_ctl_sha16\tsource\n'
       f'x.bin\t0\tvertex\t{V}\tmain\nx.bin\t1\tpixel\t{P}\tmain\nx.bin\t2\tcompute\t{C}\tmain\nx.bin\t3\ttask\t{T}\tmain\nx.bin\t4\tmesh\t{M}\tmain\nx.bin\t5\tgeometry\t{G}\tmain\n')
REPO = Path(__file__).resolve().parents[3]


def skey(vs=V + '_b', fs=P + '_b', vs_stage=0, fs_stage=1, merged=0, fz=0, ptr=0, fsfn=0, tail=b'', border=0, spare=0, size=512):
    """An R / M row's pso_skey hex as dm/gfx/nvn/nvn_pso_skey.h lays it out on arm64, field by field: vs[24], fs[24], four flags, pso_fz_desc (34) and padding to 88,
    then pso_key (two pointers, ... the specialized fragment pointer at 336, border and border_spare at 416); tail: bytes written after the vertex key's end. size 504: a row
    from before border (0.5's lists)"""
    k = bytearray(424)
    struct.pack_into('<Q', k, 0, ptr)
    struct.pack_into('<I', k, 16, 70)   # cfmt[0]: RGBA8Unorm
    struct.pack_into('<Q', k, 336, fsfn)
    struct.pack_into('<2I', k, 416, border, spare)
    v = (vs.encode() + b'\0' + tail).ljust(24, b'\0')[:24]
    head = v + fs.encode().ljust(24, b'\0') + bytes((vs_stage, fs_stage, merged, fz)) + bytes(36)
    return (head + bytes(k)).hex()[:2 * size]


class Rows(unittest.TestCase):
    def setUp(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'shader_map.tsv'; p.write_text(MAP); self.map = pso_seed.read_map(p)

    def why(self, line): return pso_seed.row_problem(line, self.map)

    def test_the_map_as_the_host_reads_it(self):
        self.assertEqual(self.map, {V: 'vertex', P: 'pixel', C: 'compute', T: 'task', M: 'mesh', G: 'geometry'})

    def test_rows_the_host_takes(self):
        for line in (f'S\t{V}_b\t0', f'S\t{P}_b\t1', f'C\t{C}_b', f'R\t{skey()}', f'R\t{skey(fs="", fs_stage=0)}', f'R\t{skey(size=504)}', f'R\t{skey(border=1)}', f'R\t{skey(size=440)}', f'R\t{skey(size=432)}',
                     f'M\t{T}_b\t{skey(vs=M + "_b", vs_stage=4)}', f'M\t-\t{skey(vs=M + "_b", vs_stage=4)}', f'G\t{V}\t{G}'):
            self.assertIsNone(self.why(line), line[:40])

    def test_refused(self):
        cases = {
            f'S\t{"f" * 16}_b\t0': 'not in the shader map', f'S\t{V}_b\t1': 'vertex shader', f'S\t{V}_bgv\t0': 'prewarm drops', f'S\t{V}\t0': 'prewarm drops',
            f'S\t{V}_b': 'S row', f'C\t{P}_b': 'pixel shader', f'R\t{skey(ptr=0x10f000000)}': 'pointer', f'R\t{skey(fsfn=0x1000)}': 'pointer',
            f'R\t{skey(tail=b"xy")}': 'after a shader key', f'R\t{skey(size=500)}': 'hex digits', f'R\t{skey()[:-2]}zz': 'not hex',
            f'R\t{skey(vs=M + "_b", vs_stage=4)}': 'mesh shader in an R row', f'R\t{skey(fs=V + "_b")}': 'vertex shader', f'R\t{skey(merged=2)}': 'flags', f'R\t{skey(border=2)}': 'flags', f'R\t{skey(spare=1)}': 'border_spare',
            f'M\t{V}_b\t{skey(vs=M + "_b", vs_stage=4)}': 'vertex shader', f'M\t-\t{skey()}': 'not a task / mesh', f'X\t{V}_b': 'unknown row kind',
            f'G\t{V}_b\t{G}': 'G row', f'G\t{V}': 'G row', f'G\t{G}\t{V}': 'geometry shader', f'G\t{V}\t{"f" * 16}': 'not in the shader map',
            f'S\t/var/mobile/{V}_b\t0': 'a path', f'C\t{C}_b\r': 'carriage return'}
        for line, want in cases.items():
            self.assertIn(want, self.why(line) or '', line[:60])

    def test_repeats_are_left_out_as_the_host_leaves_them(self):
        short = f'R\t{skey(size=432)}'
        whole = f'R\t{skey(size=432)}' + '0' * (1024 - 864)   # the same key, with atest / logic, attr_hi and border written as zero
        rel05 = f'R\t{skey(size=432)}' + '0' * (1008 - 864)   # and as 0.5 wrote it, without border
        keep, bad = pso_seed.collect([f'S\t{V}_b\t0', short, f'S\t{V}_b\t0', whole, rel05, f'C\t{C}_b', f'R\t{skey(border=1)}'], self.map)
        self.assertEqual((keep, bad), ([f'S\t{V}_b\t0', short, f'C\t{C}_b', f'R\t{skey(border=1)}'], []))   # border 1 is another pipeline


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
        self.assertEqual(pso_seed.counts(keep), {'S': 30357, 'R': 1954, 'C': 3, 'M': 0, 'rows': 32314})

    def grown(self, gid, counts, notes):
        """A list grown from iPhone sessions: every row checks clean against the map in the counts given, none repeated, and each
        (note start, (rows, S, R, C)) is a header line above the rows giving the counts of the rows it added"""
        g = REPO / 'dm/games' / gid
        shmap = pso_seed.read_map(g / 'shader_map.tsv')
        text = (g / 'pso_manifest.tsv').read_bytes().decode('utf-8')
        rows = pso_seed.rows_of(text, strip_cr=False)
        keep, bad = pso_seed.collect(rows, shmap)
        self.assertEqual((bad, len(keep), len(rows)), ([], len(rows), len(rows)))
        self.assertEqual(pso_seed.counts(keep), counts)
        self.assertEqual(len({pso_seed.identity(r) for r in rows}), counts['rows'])
        lines = [ln for ln in text.split('\n') if ln]
        head = [ln for ln in lines if ln.startswith('#')]
        self.assertTrue(all(ln.startswith('#') for ln in lines[:len(head)]), 'the notes stand above the rows')
        self.assertNotIn('Provisional', ''.join(head))
        for start, want in notes:
            note = next((ln for ln in head if ln.startswith(start)), None)
            assert note is not None, start
            m = re.search(r'(\d+) rows \((\d+) S, (\d+) R, (\d+) C\)', note)
            assert m, note
            self.assertIsNotNone(m, note)
            self.assertEqual(tuple(int(x) for x in m.groups()), want)
        return rows

    def test_mario_kart_8_deluxe_grown_from_the_phone(self):   # its README, Files and shaders
        self.grown('0100152000022000', {'S': 3577, 'R': 1463, 'C': 4, 'M': 0, 'rows': 5044},
                   [('# Grown on 2026-11-15 from an iPhone 18 Pro Max play session (about 5 min, build 431d5d18', (3133, 2566, 564, 3)),
                    ('# Added on 2026-11-15 from an earlier iPhone 18 Pro Max Documents/pso_user.tsv (0.5, build 5b302cd0', (395, 272, 123, 0))])


    def test_catherine_grown_from_the_phone(self):   # its README, Shaders
        self.grown('0100BF00112C0000', {'S': 1097, 'R': 702, 'C': 6, 'M': 0, 'rows': 1805},
                   [('# Grown on 2026-11-15 from an iPhone 18 Pro Max play session (about 9 min, build 431d5d18', (509, 396, 113, 0)),
                    ('# Grown on 2026-11-16 from the same iPhone 18 Pro Max\'s Documents/pso_user.tsv', (703, 381, 322, 0))])

    def test_super_mario_rpg_grown_from_the_phone(self):   # its README, Files and shaders
        self.grown('0100BC0018138000', {'S': 509, 'R': 315, 'C': 0, 'M': 0, 'rows': 824},
                   [('# Grown on 2026-11-15 from an iPhone 18 Pro Max play session (about 4 min, build 431d5d18', (444, 246, 198, 0))])

    def test_donkey_kong_bananza_grown_from_the_phone(self):   # its README, Files
        rows = self.grown('040074A01BF12000', {'S': 8143, 'R': 6801, 'C': 46, 'M': 0, 'G': 1, 'rows': 14991},
                          [('# Grown on 2026-11-15 from an iPhone 18 Pro Max\'s Documents/pso_user.tsv after three play sessions', (4657, 4412, 245, 0)),
                           ('# Added on 2026-11-15 from an earlier iPhone 18 Pro Max Documents/pso_user.tsv (X1.0, build 6448f757', (8, 0, 8, 0)),
                           ('# Grown on 2026-11-17 from the same iPhone 18 Pro Max\'s Documents/pso_user.tsv after runs on chain ae1dd68dc11c', (283, 1, 282, 0)),
                           ('# Grown on 2026-11-19 from the same iPhone 18 Pro Max\'s Documents/pso_user.tsv after the X2.0 runs of 2026-11-17 to 19 on chain ae1dd68dc11c', (5566, 1677, 3880, 9))])
        self.assertFalse([r for r in rows if '_bg' in r or '_bl' in r or '5f626776' in r], 'the geometry path\'s rows are left out')

    def test_super_mario_bros_wonder_recorded_on_the_phone(self):   # its README, Pipelines on a first start
        self.grown('010015100B514000', {'S': 5957, 'R': 1093, 'C': 15, 'M': 0, 'rows': 7065},
                   [('# Recorded on an iPhone 18 Pro Max from the owner\'s play (build 431d5d18', (6162, 5509, 642, 11)),
                    ('# Grown on 2026-11-16 from a second iPhone 18 Pro Max session (about 4.5 min, build 29dcbb4d', (468, 291, 176, 1)),
                    ('# Grown on 2026-11-17 from the same iPhone 18 Pro Max\'s Documents/pso_user.tsv after runs on chain ae1dd68dc11c', (435, 157, 275, 3))])

    def test_star_fox_grown_from_the_phone(self):   # its README, Pipelines on a first start
        self.grown('0400E88025B1A000', {'S': 657, 'R': 573, 'C': 15, 'M': 0, 'rows': 1245},
                   [('# Grown on 2026-11-15 from an iPhone 18 Pro Max play session (about 6 min, build 431d5d18', (83, 39, 44, 0)),
                    ('# Grown on 2026-11-16 from a second iPhone 18 Pro Max session (about 6 min, build 29dcbb4d', (6, 4, 2, 0)),
                    ('# Grown on 2026-11-19 from the same iPhone 18 Pro Max\'s Documents/pso_user.tsv after the X2.0 runs of 2026-11-17 to 19 on chain ae1dd68dc11c', (133, 61, 72, 0))])

    def test_13_sentinels_grown_from_the_phone(self):   # its README, Rendering (Prewarm list)
        self.grown('01003FC01670C000', {'S': 751, 'R': 147, 'C': 0, 'M': 0, 'rows': 898},
                   [('# Grown on 2026-11-15 from an iPhone 18 Pro Max play session (about 12 min, build 431d5d18', (38, 0, 38, 0)),
                    ('# Added on 2026-11-15 from an earlier iPhone 18 Pro Max Documents/pso_user.tsv (0.5, build 5b302cd0', (2, 0, 2, 0))])

if __name__ == '__main__':
    unittest.main()
