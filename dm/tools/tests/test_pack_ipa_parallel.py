"""pack_ipa.py deflates a streamed file (one above BIG) in pieces on its pool: the archive tests clean, every member reads back as its source, the pieces in flight are bounded,
and one thread (DM_PACK_THREADS=1 or --threads 1) writes the archive the code before the pieces wrote, byte for byte. Small stand-ins for BIG and PIECE keep the files small."""
import collections
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import zipfile
import zlib

REPO = Path(__file__).resolve().parents[3]
TOOL = REPO / 'dm/ios/tools/pack_ipa.py'
OLD = 'e09ff955f16d5ae27b8403dcd021978519978efc'   # the last commit of pack_ipa.py before the pieces
spec = importlib.util.spec_from_file_location('pack_ipa', TOOL); assert spec and spec.loader
pack = importlib.util.module_from_spec(spec); spec.loader.exec_module(pack)

BIG, PIECE = 100_000, 48 << 10   # PIECE above deflate's 32 KiB window; Small uses one below it
# Zip.stream before the pieces, verbatim, run with pack_ipa's globals: the one-thread reference when git cannot give the old script
OLD_STREAM = '''
def stream(self, e, deflate):   # a big file: the local header first, its CRC (and a deflated size) patched in afterwards
    usize = e.st.st_size; z64 = usize >= L32   # a deflate that is not smaller is redone stored, so the deflated size stays below usize
    h = self.local(e, 8 if deflate else 0, 0, 0 if deflate else usize, usize, z64)
    crc, csize, read, c = 0, 0, 0, zlib.compressobj(LEVEL, zlib.DEFLATED, -15) if deflate else None
    with open(e.path, 'rb') as f:
        while b := f.read(CHUNK):
            read += len(b); crc = zlib.crc32(b, crc)
            if c: b = c.compress(b)
            self.w(b); csize += len(b)
        if c: b = c.flush(); self.w(b); csize += len(b)
    if read != usize: sys.exit(f'[RED] pack_ipa: {e.path} changed size while it was packed')
    if c and csize >= usize:   # not smaller: stored instead
        self.f.seek(h[0]); self.f.truncate(); self.pos = h[0]; return self.stream(e, False)
    self.patch(h[0] + 14, struct.pack('<I', crc) + (b'' if z64 else struct.pack('<II', csize, usize)))
    if z64: self.patch(h[0] + 30 + len(h[1]) + 4, struct.pack('<QQ', usize, csize))
    self.f.seek(self.pos)
    self.central(e, h, 8 if c else 0, crc, csize, usize)
'''


def old_stream():
    ns = {}; exec(OLD_STREAM, pack.__dict__, ns); return ns['stream']


def text(rng, n):   # compressible, but not trivially: words drawn at random
    words = [bytes(rng.choice(b'abcdefghijklmnopqrstuvwxyz') for _ in range(rng.randint(2, 9))) for _ in range(400)]
    out = bytearray()
    while len(out) < n: out += rng.choice(words) + (b'\n' if rng.random() < 0.1 else b' ')
    return bytes(out[:n])


class Pieces(unittest.TestCase):
    piece, slack = PIECE, 1.01   # slack: how much larger than one thread's archive the pieces may make it

    @classmethod
    def setUpClass(cls):
        rng = random.Random(1131); P = cls.piece; m = (BIG // P + 3) * P; block = rng.randbytes(20000)
        cls.files = {   # archive name below Payload/DmIOS.app/: bytes; the sizes sit on both sides of BIG and of the piece size
            'romfs/small.txt': text(rng, 30000), 'romfs/small.rnd': rng.randbytes(20000), 'romfs/at_big.txt': text(rng, BIG), 'romfs/big_plus1.txt': text(rng, BIG + 1),
            'romfs/sub/exact.txt': text(rng, m), 'romfs/sub/minus.txt': text(rng, m - 1), 'romfs/sub/plus.txt': text(rng, m + 1),   # m whole pieces: the read ahead ends at the file's end
            'romfs/big.rnd': rng.randbytes(m + 77), 'romfs/zeros.bin': bytes(m + 3 * P), 'romfs/big.store': text(rng, m),
            # a block repeated 27000 bytes later, the second copy in the next piece: a match that only the dictionary reaches
            'romfs/mixed.bin': text(rng, max(0, P - 25000)) + block + text(rng, 7000) + block + rng.randbytes(P) + text(rng, 2 * P) + bytes(P // 2) + block + text(rng, BIG),
            'exe': text(rng, m + P // 2 + 5), 'info.plist': b'<plist/>' * 100}

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory(); self.addCleanup(self.tmpdir.cleanup)
        self.tmp = Path(self.tmpdir.name)
        app, rom = self.tmp / 'src/app', self.tmp / 'src/romfs'; app.mkdir(parents=True); (rom / 'sub').mkdir(parents=True)
        for name, data in self.files.items():
            path = (rom / name[6:]) if name.startswith('romfs/') else app / name; path.write_bytes(data)
        os.chmod(app / 'exe', 0o755)
        self.maps = [f'Payload/DmIOS.app/romfs={rom}', f'Payload/DmIOS.app={app}']
        self.calls = collections.Counter()

    def run_pack(self, name, *opts, env=None, module=pack, stream=None):
        out = self.tmp / name
        argv = ['pack_ipa', str(out), '--no-reuse', '--store', '.store', *opts, *self.maps]
        real = pack.piece
        def counted(b, zdict, last):
            self.calls['pieces'] += 1; self.calls['last'] += last; return real(b, zdict, last)
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ)); os.environ.pop('DM_PACK_THREADS', None)
            if env is not None: os.environ['DM_PACK_THREADS'] = env
            for key, value in (('BIG', BIG), ('CHUNK', 4096)): stack.enter_context(patch.object(module, key, value))
            if module is pack: stack.enter_context(patch.object(pack, 'PIECE', self.piece)); stack.enter_context(patch.object(pack, 'piece', counted))
            if stream: stack.enter_context(patch.object(module.Zip, 'stream', stream))
            stack.enter_context(patch.object(sys, 'argv', argv)); stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            module.main()
        for suffix in ('.partial', '.clone', '.idx.partial'): self.assertFalse(Path(str(out) + suffix).exists())
        return out

    def check(self, out):   # a clean archive whose members are the sources; returns {name: compress type}
        raw = out.read_bytes(); methods = {}
        with zipfile.ZipFile(out) as z:
            self.assertIsNone(z.testzip())
            names = [i.filename for i in z.infolist() if not i.is_dir()]
            self.assertEqual(sorted(names), sorted('Payload/DmIOS.app/' + n for n in self.files))
            for i in z.infolist():
                if i.is_dir(): continue
                name = i.filename[len('Payload/DmIOS.app/'):]
                self.assertEqual(z.read(i), self.files[name], name)
                sig, _, _, method, _, _, crc, csize, usize, nl, el = struct.unpack_from('<IHHHHHIIIHH', raw, i.header_offset)   # the patched local header agrees with the central one
                self.assertEqual((sig, method, crc, csize, usize), (0x04034B50, i.compress_type, i.CRC, i.compress_size, i.file_size), name)
                if i.compress_type == 8:   # one deflate stream, ended by its last block and nothing after it
                    at = i.header_offset + 30 + nl + el; d = zlib.decompressobj(-15)
                    self.assertEqual(d.decompress(raw[at:at + i.compress_size]), self.files[name], name)
                    self.assertTrue(d.eof, name); self.assertEqual(d.unused_data, b'', name)
                methods[name] = i.compress_type
        if shutil.which('unzip'): subprocess.run(['unzip', '-tqq', str(out)], check=True, capture_output=True)
        return methods

    def streamed(self):   # the pieces a parallel pack deflates: every file above BIG not stored by suffix (the incompressible one too, before it is redone stored)
        sizes = [len(d) for n, d in self.files.items() if len(d) > BIG and not n.endswith('.store')]
        return sum(-(-s // self.piece) for s in sizes), len(sizes)

    def test_pieces_read_back_and_test_clean(self):
        out = self.run_pack('n.ipa', '--threads', '4'); methods = self.check(out)
        self.assertEqual((self.calls['pieces'], self.calls['last']), self.streamed())
        self.assertEqual({n for n, t in methods.items() if t == 0}, {'romfs/small.rnd', 'romfs/big.rnd', 'romfs/big.store'})   # stored: incompressible, or by --store
        one = self.run_pack('one.ipa', '--threads', '1'); self.assertEqual(self.check(one), methods)
        with zipfile.ZipFile(out) as a, zipfile.ZipFile(one) as b:
            self.assertEqual(a.namelist(), b.namelist())
            for ia, ib in zip(a.infolist(), b.infolist()):
                for key in ('CRC', 'file_size', 'compress_type', 'external_attr', 'date_time', 'flag_bits'): self.assertEqual(getattr(ia, key), getattr(ib, key), (ia.filename, key))
                if len(self.files.get(ia.filename[len('Payload/DmIOS.app/'):], b'')) <= BIG: self.assertEqual(ia.compress_size, ib.compress_size, ia.filename)   # the pool's files: unchanged
        self.assertLess(out.stat().st_size, one.stat().st_size * self.slack)
        self.assertEqual(self.run_pack('n2.ipa', '--threads', '2').read_bytes(), out.read_bytes())   # the pieces do not depend on the thread count

    def test_one_thread_is_the_code_before_the_pieces(self):
        ref = self.run_pack('ref.ipa', stream=old_stream()).read_bytes(); self.assertEqual(self.calls['pieces'], 0)
        self.check(self.tmp / 'ref.ipa')
        with patch.object(pack, 'piece', side_effect=AssertionError('a piece with one thread')):
            for name, opts, env in (('env.ipa', (), '1'), ('opt.ipa', ('--threads', '1'), None), ('both.ipa', ('--threads', '1'), '8')):
                with self.subTest(name):
                    self.assertEqual(self.run_pack(name, *opts, env=env).read_bytes(), ref)
        self.run_pack('opt4.ipa', '--threads', '4', env='1'); self.assertGreater(self.calls['pieces'], 0)   # the option wins over the variable
        self.calls.clear(); self.run_pack('env3.ipa', env='3'); self.assertEqual(self.calls['pieces'], self.streamed()[0])

    def test_one_thread_matches_the_old_script(self):
        r = subprocess.run(['git', '-C', str(REPO), 'show', f'{OLD}:dm/ios/tools/pack_ipa.py'], capture_output=True)
        if r.returncode: self.skipTest(f'git has no {OLD[:8]}')
        old = types.ModuleType('pack_ipa_old')
        exec(compile(r.stdout, 'pack_ipa_old.py', 'exec'), old.__dict__)
        self.assertFalse(hasattr(old, 'PIECE'))
        ref = self.run_pack('old.ipa', module=old).read_bytes()
        self.assertEqual(self.run_pack('env.ipa', env='1').read_bytes(), ref)
        self.assertEqual(self.calls['pieces'], 0)

    def test_bad_thread_counts_stop(self):
        for opts, env in (((), 'x'), ((), '0'), ((), '-2'), (('--threads', '0'), None)):
            with self.subTest(opts=opts, env=env), self.assertRaisesRegex(SystemExit, r'^\[RED\] pack_ipa: '):
                self.run_pack('bad.ipa', *opts, env=env)
            self.assertFalse((self.tmp / 'bad.ipa').exists())

    def test_pieces_in_flight_are_bounded(self):
        path = self.tmp / 'src/romfs/sub/plus.txt'; data = self.files['romfs/sub/plus.txt']
        live, most = set(), [0]
        class Held:   # a future the writer has not written yet
            def __init__(self, f): self.f = f; live.add(self); most[0] = max(most[0], len(live))
            def result(self): live.discard(self); return self.f.result()
        class Pool(pack.cf.Executor):
            def __init__(self, pool): self.pool = pool
            def submit(self, fn, /, *args, **kwargs): return Held(self.pool.submit(fn, *args, **kwargs))
        out = self.tmp / 'bound.ipa'
        with pack.cf.ThreadPoolExecutor(4) as pool, patch.object(pack, 'PIECE', self.piece):
            z = pack.Zip(str(out)); z.pool, z.ahead = Pool(pool), 3
            z.stream(pack.Entry('plus.txt', str(path), os.stat(path), str(path.parent)), True); z.close()
        self.assertEqual(most[0], 3); self.assertEqual(live, set())
        with zipfile.ZipFile(out) as a:
            self.assertIsNone(a.testzip()); self.assertEqual(a.read('plus.txt'), data); self.assertEqual(a.getinfo('plus.txt').compress_type, 8)

    def test_size_change_while_streamed_in_pieces(self):
        stream = pack.Zip.stream; source = self.tmp / 'src/app/exe'
        for grow in (False, True):
            with self.subTest(grow=grow):
                source.write_bytes(self.files['exe']); self.calls.clear()
                def changed(z, e, deflate, grow=grow):
                    if e.path == str(source): data = source.read_bytes(); source.write_bytes(data + b'grow' if grow else data[:-4])
                    return stream(z, e, deflate)
                with self.assertRaisesRegex(SystemExit, 'changed size while it was packed'): self.run_pack('changed.ipa', '--threads', '4', stream=changed)
                self.assertGreater(self.calls['pieces'], 0); self.assertFalse((self.tmp / 'changed.ipa').exists())


class Small(Pieces):   # pieces smaller than deflate's window: each one's dictionary reaches back over several earlier pieces
    piece, slack = 4096, 1.03


if __name__ == '__main__':
    unittest.main()
