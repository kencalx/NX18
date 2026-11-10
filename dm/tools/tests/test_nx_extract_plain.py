"""nx_extract --plain (dm/tools/nx_extract): decrypted NCAs (an NX made by nxconvert pack) read from a folder with no keys at all, run as the committed executable on synthetic NCAs
from dnca_writer.py (own layouts, no LibHac). The base game, an update laid over it (BKTR, the AesCtrEx table kept, zeroed or junk), --contents, --aoc, --manifest, --html, a base
flattened from sparse storage, a compressed section, damage and --allow-damaged, every refusal of the header wrapper and the folder rules (exit code 7), names a host folder cannot
hold, decompression and loop bombs, a run past its memory limit (exit code 8) and a seeded fuzz of the header and the first bytes of each section. Skipped unless on a Mac with an
executable built from the sources beside it (test_native_tools.py says when it is not). HOME is an empty folder in every run, so no prod.keys can be found."""
from pathlib import Path
import hashlib
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO / 'dm/tools'))
sys.path.insert(0, str(HERE))
import romfs_image
import dnca_writer as w

NX = REPO / 'dm/tools/nx_extract_bin/nx_extract'
APP = 0x0100000000AA0000
TID = f'{APP:016x}'


def source_sha():
    return hashlib.sha256(b''.join((REPO / 'dm/tools/nx_extract' / f).read_bytes() for f in ('Program.cs', 'nx_extract.csproj'))).hexdigest()[:16]


def usable():
    if sys.platform != 'darwin' or not NX.is_file(): return False
    try: return subprocess.run([str(NX), '--source-sha'], capture_output=True, text=True, timeout=60).stdout.strip() == source_sha()
    except (OSError, subprocess.SubprocessError): return False


USABLE = usable()


def image_files(img):   # {path: bytes} of a RomFS image's files
    data = Path(img).read_bytes()
    return {p: data[a:a + b] for p, (d, a, b) in romfs_image.read_index(img).items() if not d}


def damaged_flags(img):   # the guest paths an image flags as damaged (written as read)
    with open(img, 'rb') as f:
        _, ioff, isz, n = romfs_image.HEAD.unpack(f.read(romfs_image.HEAD.size)); f.seek(ioff); raw = f.read(isz)
    pool = raw[n * romfs_image.ENT.size:]
    return {pool[no:no + nl].decode() for k in range(n) for a, b, no, nl, t, fl in [romfs_image.ENT.unpack_from(raw, k * romfs_image.ENT.size)] if fl}


def folder_files(d):
    return {str(p.relative_to(d)): p.read_bytes() for p in sorted(Path(d).rglob('*')) if p.is_file()}


@unittest.skipUnless(USABLE, 'needs the committed nx_extract built from the sources beside it, on a Mac')
class Plain(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.g = w.Game(APP, manual=True)

    def setUp(self):
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        self.dir = Path(td.name).resolve()
        (self.dir / 'home').mkdir()

    def run_x(self, *args, env=None, timeout=30):
        e = {'PATH': '/usr/bin:/bin', 'HOME': str(self.dir / 'home'), **(env or {})}
        r = subprocess.run([str(NX), *map(str, args)], capture_output=True, text=True, env=e, timeout=timeout, errors='replace')
        out = r.stdout + r.stderr
        self.assertNotIn('Unhandled exception', out)
        self.assertNotIn('   at ', out)   # no stack trace
        return r.returncode, out

    def put(self, name, files):
        d = self.dir / name
        if d.exists(): shutil.rmtree(d)
        return w.folder(d, files)

    def extract(self, base, upd='-', *more, out='out', env=None, timeout=30):
        return self.run_x('--plain', base, upd, self.dir / out, '--app', TID, *more, env=env, timeout=timeout)

    def snap(self, prog, ctrl=None):   # a base game's folder files: one Program NCA (Built or bytes) and a Control NCA
        return w.snapshot(w.APPLICATION, APP, 0, [prog, ctrl or w.control_nca(APP)])[0]

    # ---- what it reads ----
    def test_base(self):
        code, out = self.extract(self.put('b', self.g.base), '-', '--romfs-image')
        self.assertEqual(code, 0, out)
        self.assertEqual(folder_files(self.dir / 'b'), self.g.base)   # the NCA files are read through an in-memory header, never changed
        o = self.dir / 'out'
        self.assertEqual(folder_files(o / 'ExeFS'), self.g.exefs0)
        self.assertEqual(image_files(o / 'RomFS.img'), self.g.romfs0)
        self.assertEqual((o / 'control.nacp').read_bytes(), w.nacp('Test Game', '1.0.0'))
        self.assertEqual((o / 'icon.jpg').read_bytes(), b'\xff\xd8\xff icon 0')
        for line in (f'title {TID}', 'display version 1.0.0', 'name Test Game', f'main build id {self.g.bid0[:16].hex()}', 'RomFS.img: 4 files'):
            self.assertIn(line, out)

    def test_update_over_its_base_in_one_folder(self):
        for aesctrex in ('table', 'zero', 'junk'):   # the AesCtrEx table: kept, zeroed or junk (unused without encryption)
            with self.subTest(aesctrex=aesctrex):
                g = self.g if aesctrex == 'table' else w.Game(APP, aesctrex=aesctrex, dlc=False)
                u = self.put('u', g.update)
                code, out = self.extract(u, u, '--romfs-image', out=f'out_{aesctrex}')
                self.assertEqual(code, 0, out)
                o = self.dir / f'out_{aesctrex}'
                self.assertEqual(folder_files(o / 'ExeFS'), g.exefs1)
                self.assertEqual(image_files(o / 'RomFS.img'), g.romfs1)
                self.assertEqual((o / 'control.nacp').read_bytes(), w.nacp('Test Game', '1.2.0'))
                self.assertIn(f'title {TID}, update {TID}', out)
                self.assertIn(f'main build id {g.bid1[:16].hex()}', out)

    def test_contents(self):
        code, out = self.run_x('--plain', '--contents', self.put('b', self.g.base), self.put('u', self.g.update), self.put('d', self.g.dlc))
        self.assertEqual(code, 0, out)
        self.assertEqual([l for l in out.splitlines() if l.startswith(('package', 'content'))],
                         ['package 0 b', f'content Application {TID} 0', 'package 1 u', f'content Application {TID} 0', f'content Patch {APP | 0x800:016x} {self.g.version}',
                          'package 2 d', f'content AddOnContent {self.g.dlc_tid:016x} 0'])
        code, out = self.run_x('--plain', '--contents', self.put('x', {'0' * 32 + '.nca': b'x' * 0xC00}))   # a package that cannot be read: its line, exit code 5
        self.assertEqual(code, 5, out); self.assertIn('[RED] x: ', out)

    def test_aoc(self):
        img = self.dir / 'aoc/1.img'
        code, out = self.run_x('--plain', '--aoc', self.put('d', self.g.dlc), img, f'{self.g.dlc_tid:016x}', '--romfs-image')
        self.assertEqual(code, 0, out)
        self.assertEqual(image_files(img), self.g.dlc_files)
        self.assertIn(f'add-on content {self.g.dlc_tid:016x}', out)
        code, out = self.run_x('--plain', '--aoc', self.dir / 'd', img, f'{self.g.dlc_tid + 1:016x}', '--romfs-image')
        self.assertEqual(code, 7, out); self.assertIn(f'no data NCA of add-on content {self.g.dlc_tid + 1:016x}', out)

    def test_manifest_and_nros(self):
        prog = w.program_nca(APP, w.exefs(APP, b'\x11' * 16), {'nro/a.nro': b'NRO module', 'data.bin': b'z' * 100})
        files, _ = w.snapshot(w.APPLICATION, APP, 0, [prog, w.control_nca(APP)])
        code, out = self.extract(self.put('b', files), '-', '--manifest')
        self.assertEqual(code, 0, out)
        rows = (self.dir / 'out/romfs_manifest.tsv').read_text().splitlines()
        self.assertEqual(rows[0], '# path\tbytes\tfirst 32 bytes (hex)')
        self.assertEqual(sorted(r.split('\t')[0] for r in rows[1:]), ['/data.bin', '/nro/a.nro'])
        self.assertEqual((self.dir / 'out/romfs_nro/nro/a.nro').read_bytes(), b'NRO module')

    def test_html(self):   # the update's HtmlDocument NCA read over the base game's (a patch), then the base game's own
        u = self.put('u', self.g.update)
        (self.dir / 'h').mkdir()
        code, out = self.run_x('--plain', u, u, self.dir / 'h', '--app', TID, '--html')
        self.assertEqual(code, 0, out)
        self.assertIn('a patch of the base game\'s NCA', out); self.assertIn('2 HtmlDocument NCAs', out)
        self.assertEqual(folder_files(self.dir / 'h'), {'html0/index.html': self.g.html1['index.html'], 'html1/index.html': self.g.html0['index.html']})

    def test_sparse_base(self):   # flattened by the decrypter (DSPF): alone it needs its update (exit code 4); with it, the update's files
        g = w.Game(APP, sparse_base=True, dlc=False)
        code, out = self.extract(self.put('b', g.base), '-', '--romfs-image')
        self.assertEqual(code, 4, out); self.assertIn('sparse', out)
        u = self.put('u', g.update)
        code, out = self.extract(u, u, '--romfs-image')
        self.assertEqual(code, 0, out)
        self.assertEqual(image_files(self.dir / 'out/RomFS.img'), g.romfs1)
        self.assertEqual(folder_files(self.dir / 'out/ExeFS'), g.exefs1)
        base = bytearray(g.base_prog.data)   # sparse info kept, no DSPF: the decrypter did not finish it
        base[0x600 + 0x1D0:0x600 + 0x1D4] = bytes(4); w.rehash(base, 1)
        code, out = self.extract(self.put('b2', self.swap(g.base, g.base_prog.data, bytes(base))), '-', '--romfs-image')
        self.assertEqual(code, 7, out); self.assertIn('keeps a sparse layer that was not flattened', out)

    @unittest.skipIf(w.lz4block is None, 'lz4 is needed for a compressed section')
    def test_compressed_section(self):
        g = w.Game(APP, compress=True, dlc=False)
        code, out = self.extract(self.put('b', g.base), '-', '--romfs-image')
        self.assertEqual(code, 0, out)
        self.assertEqual(image_files(self.dir / 'out/RomFS.img'), g.romfs0)

    def test_list_and_second_program(self):
        g = w.Game(APP, program2=True, dlc=False)
        b = self.put('b', g.base)
        code, out = self.run_x('--plain', b, '-', self.dir / 'l', '--app', TID, '--list')
        self.assertEqual(code, 0, out)
        self.assertIn(f'base Program {APP + 1:016x}', out); self.assertIn(f'base Program {TID}', out)
        code, out = self.run_x('--plain', b, '-', self.dir / 'p2', '--app', TID, f'--program={APP + 1:016x}', '--romfs-image')
        self.assertEqual(code, 0, out)
        self.assertEqual(folder_files(self.dir / 'p2/ExeFS'), g.exefs2)
        self.assertIn('name Second', out)

    # ---- damage ----
    def swap(self, files, old, new):   # files with the NCA whose bytes are old replaced by new (same name: the content meta still lists it)
        return {k: (new if v == old else v) for k, v in files.items()}

    def test_damage_and_allow_damaged(self):
        prog = bytearray(self.g.base_prog.data)
        start, _ = w.section_span(prog, 1)
        off, _ = w.ivfc_data_level(prog[0x600 + 8:0x600 + 0x100])   # FS header 1's hash data
        prog[start + off + 0x5000] ^= 0xFF   # base_only.bin's data (0x200 to 0x9200 of the RomFS), in an IVFC block of its own
        b = self.put('b', self.swap(self.g.base, self.g.base_prog.data, bytes(prog)))
        code, out = self.extract(b, '-', '--romfs-image')
        self.assertEqual(code, 3, out); self.assertIn('[RED] hash check failed: /', out)
        self.assertIn('[RED] the NCA files are damaged: 1 files fail the NCA\'s hash check', out); self.assertIn('pack them again from a good dump', out); self.assertNotIn('NSP', out)
        self.assertFalse((self.dir / 'out/RomFS.img').exists())
        code, out = self.extract(b, '-', '--allow-damaged', out='folder')   # folder output: the file the checked read began is written again as read (every file is created new)
        self.assertEqual(code, 0, out); self.assertIn('[RED] the NCA files are damaged: 1 files written as read', out)
        self.assertEqual(len((self.dir / 'folder/RomFS/base_only.bin').read_bytes()), len(self.g.romfs0['base_only.bin']))
        self.assertEqual((self.dir / 'folder/RomFS/data/same.bin').read_bytes(), self.g.romfs0['data/same.bin'])
        code, out = self.extract(b, '-', '--romfs-image', '--allow-damaged', out='out2')   # a new folder: plain mode creates every file new
        self.assertEqual(code, 0, out)
        self.assertEqual(damaged_flags(self.dir / 'out2/RomFS.img'), {'base_only.bin'})
        self.assertEqual(image_files(self.dir / 'out2/RomFS.img')['data/same.bin'], self.g.romfs0['data/same.bin'])

    def test_patch_over_the_wrong_base(self):
        other = w.program_nca(APP, self.g.exefs0, {'data/same.bin': w.rand(0x30000, 99)})
        u = self.put('u', self.swap(self.g.update, self.g.base_prog.data, other.data))
        code, out = self.extract(u, u, '--romfs-image')
        self.assertEqual(code, 3, out)

    # ---- refusals: the header wrapper ----
    def refused(self, nca, why, files=None, upd=False):
        files = self.swap(files or (self.g.update if upd else self.g.base), self.g.upd_prog.data if upd else self.g.base_prog.data, bytes(nca))
        d = self.put('r', files)
        code, out = self.extract(d, d if upd else '-', '--romfs-image')
        self.assertEqual(code, 7, out)
        self.assertRegex(out, r'\[RED\] .*' + why)
        return out

    def test_header_refusals(self):
        p0 = self.g.base_prog.data
        def m(edits, fs=None, data=p0):
            b = bytearray(data)
            for at, v in edits: b[at:at + len(v)] = v
            if fs is not None: w.rehash(b, fs)
            return b
        s1 = w.section_span(p0, 1)
        cases = [
            ('short', p0[:0x800], 'shorter than an NCA header'),
            ('NCA3', m([(0x200, b'NCA3')]), 'a plaintext NCA without the DNCA marker'),
            ('random', m([(0x200, w.rand(0x40, 3))]), 'not a decrypted NCA'),
            ('distribution', m([(0x204, b'\2')]), 'distribution type 2'),
            ('content type', m([(0x205, b'\6')]), 'content type 6'),
            ('size field', m([(0x208, struct.pack('<Q', len(p0) + 0x200))]), 'its header says'),
            ('before the header', m([(0x240, struct.pack('<I', 5))]), 'section 0 lies outside the file'),
            ('past the end', m([(0x254, struct.pack('<I', len(p0) // 0x200 + 1))]), 'section 1 lies outside the file'),
            ('overlap', m([(0x250, struct.pack('<I', s1[0] // 0x200 - 1))]), 'sections 0 and 1 overlap'),
            ('no section', m([(0x240, bytes(0x40))]), 'no section'),
            ('FS header hash', m([(0x600 + 0x20, b'\1')]), 'FS header 1 fails its hash'),
            ('FS version', m([(0x600, b'\3\0')], 1), 'FS header 1: version 3'),
            ('hash type', m([(0x603, b'\4')], 1), 'FS header 1: hash type 4'),
            ('encryption 2', m([(0x604, b'\2')], 1), 'section 1 is still encrypted \\(encryption type 2\\)'),
            ('encryption 4', m([(0x604, b'\4')], 1), 'section 1 is still encrypted \\(encryption type 4\\)'),
            ('IVFC levels', m([(0x608 + 0xC, struct.pack('<I', 8))], 1), 'section 1: its IVFC header'),
            ('SHA-256 layers', m([(0x408 + 0x24, struct.pack('<I', 3))], 0), 'section 0: its SHA-256 hash tree'),
            ('PFS0 count', m([(w.section_span(p0, 0)[0] + struct.unpack_from('<Q', p0, 0x408 + 0x38)[0] + 4, struct.pack('<I', 100000))]), 'section 0: its file table is too large'),
        ]
        for name, nca, why in cases:
            with self.subTest(name): self.refused(nca, why)
        u0 = self.g.upd_prog.data
        for name, nca, why in [('BKTR count', m([(0x600 + 0x118, struct.pack('<I', 1 << 25))], 1, u0), 'section 1: its relocation table is out of range'),
                               ('BKTR outside', m([(0x600 + 0x100, struct.pack('<q', len(u0)))], 1, u0), 'section 1: its relocation table is out of range')]:
            with self.subTest(name): self.refused(nca, why, upd=True)

    def test_folder_refusals(self):
        b = self.put('b', self.g.base)
        code, out = self.extract(next(b.iterdir()), '-'); self.assertEqual(code, 7, out); self.assertIn('not a file', out)
        for name, extra, why in (('upper', {'A' * 32 + '.nca': b'x'}, 'not a decrypted NCA\'s file name'), ('ticket', {'x.tik': b'x'}, 'not a decrypted NCA\'s file name'),
                                 ('dir', None, 'a folder, where only'), ('link', None, 'a symbolic link')):
            with self.subTest(name):
                d = self.put('f', self.g.base)
                if extra: w.folder(d, extra)
                elif name == 'dir': (d / ('0' * 32 + '.nca')).mkdir()
                else: (d / ('1' * 32 + '.nca')).symlink_to(next(iter(sorted(d.iterdir()))))
                code, out = self.extract(d, '-'); self.assertEqual(code, 7, out); self.assertIn(why, out)
        d = self.put('many', self.g.base)
        for k in range(4097 - len(self.g.base)): (d / f'{k:032x}.nca').write_bytes(b'')
        code, out = self.extract(d, '-'); self.assertEqual(code, 7, out); self.assertIn('more than the 4,096', out)
        u = self.put('u', {k: v for k, v in self.g.update.items() if v != self.g.upd_prog.data})   # the Patch content meta lists a Program NCA the folder lacks
        code, out = self.extract(u, u); self.assertEqual(code, 7, out); self.assertIn('content meta lists Program NCA', out)

    def test_data_only_update_refused(self):
        own, _ = w.snapshot(w.PATCH, APP | 0x800, 0x10000, [w.control_nca(APP, display='1.1.0')], other=APP, seed=13)
        u = self.put('u', dict(self.g.base, **own))
        code, out = self.extract(u, u, '--romfs-image')
        self.assertEqual(code, 7, out); self.assertIn('the update changes no code', out)

    def test_usage(self):
        self.assertEqual(self.run_x('--plain', '--keys', self.dir)[0], 2)
        self.assertEqual(self.run_x('--plain', self.dir, '-', self.dir / 'o', '--max-bytes', 'x')[0], 2)
        self.assertEqual(self.run_x(self.dir / 'prod.keys', self.dir, '-', self.dir / 'o', '--max-bytes', '5')[0], 2)   # plain mode only

    # ---- names a host folder cannot hold ----
    def program_with(self, exefs=None, romfs=None, **kw):
        prog = w.program_nca(APP, exefs or w.exefs(APP, b'\x11' * 16), romfs if romfs is not None else {'a.bin': b'a'}, **kw)
        return w.snapshot(w.APPLICATION, APP, 0, [prog, w.control_nca(APP)])[0]

    def test_host_names(self):
        main = w.nso(b'\x11' * 16)
        for name, exefs, romfs, mode, why in (
                ('dot dot', {'..': main, 'main.npdm': w.npdm(APP)}, None, '--romfs-image', 'invalid name'),
                ('slash', {'a/b': main, 'main': main}, None, '--romfs-image', 'invalid name'),
                ('case', {'main': main, 'MAIN': main}, None, '--romfs-image', 'differ only in letter case'),
                ('tab in the manifest', None, {'a\tb.bin': b'x'}, '--manifest', 'holds a control character'),
                ('long NRO name', None, {'n' * 296 + '.nro': b'x'}, '--manifest', 'longer than a host file name')):
            with self.subTest(name):
                code, out = self.extract(self.put('n', self.program_with(exefs, romfs)), '-', mode, out=f'o{name}')
                self.assertEqual(code, 7, out); self.assertIn(why, out)
                self.assertFalse((self.dir / f'o{name}/ExeFS/main').exists() and name != 'tab in the manifest' and name != 'long NRO name')

    # ---- bombs ----
    def test_entries_sharing_one_range_are_bounded_by_max_bytes(self):
        d = self.put('s', self.program_with_shared())   # 64 files of 1 MiB each, all one range: 64 MiB declared by 1 MiB of data
        code, out = self.extract(d, '-', '--romfs-image', '--max-bytes', str(1 << 24))
        self.assertEqual(code, 7, out); self.assertRegex(out, r'the files declare 67,108,864 bytes, more than the [\d,]+ this extraction may write')
        self.assertFalse((self.dir / 'out/RomFS.img.part').exists())
        code, out = self.extract(d, '-', '--romfs-image', '--max-bytes', str(1 << 32), out='big')
        self.assertEqual(code, 0, out)   # the same files within the budget: written

    def program_with_shared(self):
        rom = w.romfs({}, shared=(64, 1 << 20))
        sec, h = w.ivfc_section(rom)
        prog = w.nca(w.PROGRAM, APP, [w._pfs(w.exefs(APP, b'\x11' * 16)), w.Section(sec, 0, 3, h)])
        return w.snapshot(w.APPLICATION, APP, 0, [prog, w.control_nca(APP)])[0]

    def test_loops_end(self):
        for loop in ('sibling', 'child'):
            with self.subTest(loop):
                rom = w.romfs({'d/x.bin': b'x'}, loop=loop)
                sec, h = w.ivfc_section(rom)
                prog = w.nca(w.PROGRAM, APP, [w._pfs(w.exefs(APP, b'\x11' * 16)), w.Section(sec, 0, 3, h)])
                d = self.put('l', w.snapshot(w.APPLICATION, APP, 0, [prog, w.control_nca(APP)])[0])
                for mode in ('--romfs-image', '--manifest'):   # a folder that is its own sibling is listed twice; one that is its own child is not found under itself (LibHac)
                    code, out = self.extract(d, '-', mode, out=f'o{loop}{mode}')
                    self.assertEqual(code, 7 if loop == 'sibling' else 8, out); self.assertRegex(out, r'\[RED\] .*(twice|cannot be read)')

    def test_hash_table_loops_and_long_chains(self):   # LibHac walks a bucket's chain with no bound on every lookup: a loop never ends, one long chain makes reading quadratic
        files, many = {'d/a.bin': b'a', 'b.bin': b'b'}, {f'{i:05}': b'' for i in range(3000)}
        for name, prog, ctrl, why in (('file cycle', w.program_nca(APP, self.g.exefs0, files, buckets='file-cycle'), None, 'file hash table reaches one entry twice'),
                                      ('folder cycle', w.program_nca(APP, self.g.exefs0, files, buckets='dir-cycle'), None, 'folder hash table reaches one entry twice'),
                                      ('one chain', w.program_nca(APP, self.g.exefs0, many, buckets='one-chain'), None, 'puts its 3,000 entries in too few chains'),
                                      ('control data', w.program_nca(APP, self.g.exefs0, files), w.control_nca(APP, buckets='file-cycle'), 'file hash table reaches one entry twice')):
            d = self.put('h', self.snap(prog, ctrl))
            for mode in ('--romfs-image', '--manifest', None):
                with self.subTest(name, mode=mode):
                    code, out = self.extract(d, '-', *([mode] if mode else []), out=f'o{name}{mode}', timeout=20)
                    self.assertEqual(code, 7, out); self.assertIn(why, out)
        code, out = self.extract(self.put('ok', self.snap(w.program_nca(APP, self.g.exefs0, many))), '-', '--romfs-image', out='ok')
        self.assertEqual(code, 0, out)

    @unittest.skipIf(w.lz4block is None, 'lz4 is needed for a compressed section')
    def test_compression_table_entries(self):   # LibHac's CompressedStorage loops forever on virtual offsets that do not increase
        for name, edit, why in (('backwards', lambda e, end: ([e[0], (e[1][0], 0, 0, 0, e[1][0]), (e[1][0], 0, 0, 0, e[1][0])], end), 'virtual offsets that do not increase'),
                                ('type 9', lambda e, end: ([e[0], e[1][:2] + (9,) + e[1][3:]], end), 'compression type 9'),
                                ('not from 0', lambda e, end: ([(0x10,) + e[0][1:], e[1]], end), 'does not start at offset 0'),
                                ('LZ4 past the level', lambda e, end: ([e[0], e[1][:4] + (0xFFFFFFF0,)], end), 'LZ4 entry larger than any'),
                                ('end before the last entry', lambda e, end: (e, e[1][0]), 'ends before its last entry')):
            with self.subTest(name):
                d = self.put('c', self.snap(w.program_nca(APP, self.g.exefs0, self.g.romfs0, compress=edit)))
                code, out = self.extract(d, '-', '--romfs-image', out=f'o{name}', timeout=20)
                self.assertEqual(code, 7, out); self.assertIn(why, out)

    def test_manifest_rows_are_spent(self):   # --max-bytes counts the manifest's own rows: deep paths of empty files would amplify a small input
        files = {('d' * 200, 'e' * 200, f'{i:04}'): b'' for i in range(400)}   # 400 rows of about 430 bytes
        d = self.put('m', self.snap(w.program_nca(APP, self.g.exefs0, files)))
        code, out = self.extract(d, '-', '--manifest', '--max-bytes', '100000')
        self.assertEqual(code, 7, out); self.assertRegex(out, r'declare [\d,]+ bytes, more than the [\d,]+ this extraction may write')
        self.assertFalse((self.dir / 'out/romfs_manifest.tsv').exists())
        code, out = self.extract(d, '-', '--manifest', '--max-bytes', str(1 << 20), out='o2')
        self.assertEqual(code, 0, out); self.assertLess((self.dir / 'o2/romfs_manifest.tsv').stat().st_size, 1 << 20)

    def test_text_from_the_ncas_cannot_forge_lines(self):   # pack_nx.py reads the title and build ID lines: a name with a newline is printed escaped
        ctrl = w.control_nca(APP, 'Test Game\nmain build id ' + '00' * 16 + '\n[RED] forged\x1b[31m', '1.0\n[RED] v')
        code, out = self.extract(self.put('n', self.snap(self.g.base_prog, ctrl)), '-', '--romfs-image')
        self.assertEqual(code, 0, out)
        self.assertIn('name Test Game\\x0amain build id', out); self.assertIn('display version 1.0\\x0a[RED] v', out)
        self.assertEqual([l for l in out.splitlines() if l.startswith(('main build id', '[RED]'))], [f'main build id {self.g.bid0[:16].hex()}'])
        self.assertNotIn('\x1b', out)

    def test_memory_limit(self):   # NativeAOT takes DOTNET_GCHeapHardLimit in hexadecimal without 0x: 8 MiB cannot hold the copy buffers, a clean exit code 8
        code, out = self.extract(self.put('b', self.g.base), '-', '--romfs-image', env={'DOTNET_GCHeapHardLimit': '800000'})
        self.assertEqual(code, 8, out); self.assertIn('need more memory than nx_extract allows itself', out)

    def test_fuzz(self):   # seeded mutations of the header and the first 8 KiB of each section: a known exit code, one line, nothing outside the output layout
        rng = random.Random(1855)
        u = self.g.update
        names = {'ExeFS', 'RomFS.img', 'control.nacp', 'icon.jpg'}
        for k in range(300):
            upd = k % 3 == 2
            src = bytearray(self.g.upd_prog.data if upd else self.g.base_prog.data)
            spans = [w.section_span(src, i) for i in range(2)]
            for _ in range(rng.randint(1, 4)):
                lo, hi = rng.choice([(0x200, 0xC00)] + [(a, min(b, a + 0x2000)) for a, b in spans])
                at = rng.randrange(lo, hi)
                n = rng.choice((1, 1, 2, 4, 8))
                src[at:at + n] = rng.randbytes(n)
            files = self.swap(u if upd else self.g.base, self.g.upd_prog.data if upd else self.g.base_prog.data, bytes(src))
            d = self.put('z', files); o = self.dir / 'zo'
            if o.exists(): shutil.rmtree(o)
            code, out = self.extract(d, d if upd else '-', '--romfs-image', out='zo')
            with self.subTest(k=k):
                self.assertIn(code, (0, 3, 4, 7, 8), out)
                if code: self.assertIn('[RED]', out)
                if o.exists():
                    self.assertLessEqual({p.name for p in o.iterdir()}, names)
                    if (o / 'ExeFS').exists(): self.assertLessEqual({p.name for p in (o / 'ExeFS').iterdir()}, {'main', 'main.npdm', 'subsdk0'})


if __name__ == '__main__':
    unittest.main()
