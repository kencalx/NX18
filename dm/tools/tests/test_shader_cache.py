#!/usr/bin/env python3
# The compile cache as one file (dm/tools/shader_cache.py): entries in and out, bytes stored once, several threads and processes, a damaged file, pruning, and taking in a cache from before it.
import contextlib, hashlib, os, sqlite3, subprocess, sys, tarfile, tempfile, threading, time, unittest
from unittest import mock
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import shader_cache

D1, D2, D3 = 'a' * 64, 'b' * 64, 'c' * 64
APPLE_PYTHON = '/usr/bin/python3'   # Xcode's, whose sqlite3 is Apple's /usr/lib/libsqlite3.dylib: a fork that opens a database there dies (GitHub issue #2354)
SERVED = STORE = None   # what the forked workers inherit, and each worker's own store


def worker_start():
    global STORE
    assert SERVED is not None; STORE = SERVED.worker()


def forked_work(i):
    s = STORE; assert s is not None
    for j in range(300): s.put(f'f{i}/{j}', f'{i}'.encode() * 1000); assert s.get(f'f{i}/{j}') == f'{i}'.encode() * 1000
    with s.batch():
        with s.batch(): s.put(f'f{i}/batch', b'b')
        assert s.has(f'f{i}/batch')
    try:
        with s.batch(): s.put(f'f{i}/undone', b'u'); raise KeyError(i)
    except KeyError: pass
    try: s._call('close')
    except ValueError: pass
    else: raise AssertionError('a worker closed the store')
    tmp = f'{WORK}/{i}'
    assert s.to_file(f'f{i}/0', tmp) and not s.to_file('none', tmp); s.put_file(f'f{i}/file', tmp)
    return s.get('before'), sorted(s.names(f'f{i}/'))[-2:], s.get(f'f{i}/file'), s.full


def dies_in_batch(i):
    s = STORE; assert s is not None
    with s.batch(): s.put('dead', b'd'); os._exit(9)


def remote_blob_ids(prefix):
    assert STORE is not None
    return STORE.blob_ids(prefix)


def forked_stores(path, work):
    """Four forked workers of a process that has opened the store, as dmsh_build.py makes them → their results, and what the store holds then"""
    import multiprocessing
    global SERVED, WORK
    WORK = work; store = shader_cache.Store(path); store.put('before', b'0'); SERVED = shader_cache.Served(store, 4)
    with multiprocessing.get_context('fork').Pool(4, initializer=worker_start) as pool:   # every worker forked here, on any Python (an executor of Python 3.9 forks them as work comes)
        SERVED.start()
        got = pool.map(forked_work, range(4), 1)
    store.put('after', b'1')   # this process's connection still works
    return got, len(store.names('f')), store.has('f0/undone'), store.get('after')


WORK = ''
EXPECT = ([(b'0', [f'f{i}/batch', f'f{i}/file'], f'{i}'.encode() * 1000, False) for i in range(4)], 1208, False, b'1')


class Base(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name); self.path = self.root / 'cas.db'; self.said = []
        self.store = shader_cache.Store(self.path, self.said.append); self.addCleanup(self.store.close)

    def blobs(self): return self.store.db.execute('SELECT count(*) FROM blob').fetchone()[0]


class Entries(Base):
    def test_in_and_out(self):
        self.store.put('x/y', b'bytes')
        self.assertEqual(self.store.get('x/y'), b'bytes'); self.assertTrue(self.store.has('x/y'))
        self.assertIsNone(self.store.get('absent')); self.assertFalse(self.store.has('absent'))
        self.store.put('x/y', b'new'); self.assertEqual(self.store.get('x/y'), b'new')

    def test_empty_entry(self):
        self.store.put('e', b''); self.assertEqual(self.store.get('e'), b''); self.assertTrue(self.store.has('e'))
        out = self.root / 'out'; self.assertTrue(self.store.to_file('e', out)); self.assertEqual(out.read_bytes(), b'')

    def test_names_take_a_prefix_only(self):
        for n in ('shader/a/mac/x', 'shader/a/ios/x', 'shader/ab/mac/x', 'shader0'): self.store.put(n, b'1')
        self.assertEqual(self.store.names('shader/a/'), {'shader/a/mac/x', 'shader/a/ios/x'})

    def test_delete_prefix_takes_only_its_names_and_bytes_shared_stay(self):   # dmsh_build.py's staged outputs, once its image is written
        self.store.put('stage/x/mac/k_b.metallib', b'shared'); self.store.put('stage/x/mac/k_b.json', b'staged only')
        self.store.put('shader/d/mac/k_b.metallib', b'shared'); self.store.put('stage/xy', b'another stage')
        self.store.delete_prefix('stage/x/')
        self.assertEqual(self.store.names('stage/'), {'stage/xy'})
        self.assertEqual(self.store.get('shader/d/mac/k_b.metallib'), b'shared')
        self.assertEqual(self.blobs(), 2)   # 'staged only' gave its bytes back; 'shared' is still named

    def test_the_same_bytes_are_stored_once(self):   # a library under its MSL's digest and its shader's digest was one APFS clone
        self.store.put('metallib/mac/d.metallib', b'L' * 100000); self.store.put('shader/d/mac/k_b.metallib', b'L' * 100000)
        self.assertEqual(self.blobs(), 1)
        self.assertEqual(self.store.get('shader/d/mac/k_b.metallib'), b'L' * 100000)

    def test_blob_ids_match_shared_local_entries_only(self):
        old = self.root / 'cas.db'   # NX 18 has no read-only fallback: an older generation's entries are what is not local here
        o = shader_cache.Store(old); o.put('stage/a/old', b'same'); o.close()
        s = shader_cache.Store(self.root / 'local.db', older=[old]); self.addCleanup(s.close)
        s.put('stage/a/1', b'same'); s.put('stage/a/2', b'same'); s.put('stage/a/3', b'other'); s.put('stage/ab/1', b'same')
        ids = s.blob_ids('stage/a/')
        self.assertEqual(set(ids), {'stage/a/1', 'stage/a/2', 'stage/a/3'})
        self.assertEqual(ids['stage/a/1'], ids['stage/a/2'])
        self.assertNotEqual(ids['stage/a/1'], ids['stage/a/3'])

    def test_to_file_and_from_file(self):
        src, dst = self.root / 'src', self.root / 'dst'; src.write_bytes(b'data')
        self.store.put_file('f', src)
        self.assertTrue(self.store.to_file('f', dst)); self.assertEqual(dst.read_bytes(), b'data')
        self.assertFalse(self.store.to_file('absent', self.root / 'none')); self.assertFalse((self.root / 'none').exists())

    def test_one_file_is_left(self):
        self.store.put('x', b'1'); self.store.close()
        self.assertEqual(os.listdir(self.root), ['cas.db'])
        again = shader_cache.Store(self.path); self.addCleanup(again.close)
        self.assertEqual(again.get('x'), b'1')


class Writers(Base):
    def test_threads_share_it(self):
        def work(i):
            for j in range(200):
                self.store.put(f't{i}/{j}', f'{i}.{j}'.encode()); self.assertEqual(self.store.get(f't{i}/{j}'), f'{i}.{j}'.encode())
        ts = [threading.Thread(target=work, args=(i,)) for i in range(8)]
        for t in ts: t.start()
        for t in ts: t.join()
        self.assertEqual(len(self.store.names('t')), 1600)

    def test_a_batch_is_all_or_nothing(self):
        with self.assertRaises(ZeroDivisionError):
            with self.store.batch():
                self.store.put('a', b'1'); self.store.put('b', b'2'); raise ZeroDivisionError
        self.assertEqual(self.store.names(''), set())
        with self.store.batch():
            with self.store.batch(): self.store.put('a', b'1')
            self.store.put('b', b'2')
        self.assertEqual(self.store.names(''), {'a', 'b'})

    def test_processes_share_it(self):   # regress.py's chain builds and the NSP script on one game's file
        code = ("import sys; sys.path.insert(0, sys.argv[1]); import shader_cache\ns = shader_cache.Store(sys.argv[2])\n"
                "for j in range(300): s.put(f'{sys.argv[3]}/{j}', sys.argv[3].encode() * 1000); assert s.get(f'{sys.argv[3]}/{j}') == sys.argv[3].encode() * 1000\ns.close()\n")
        ps = [subprocess.Popen([sys.executable, '-c', code, str(REPO / 'dm/tools'), str(self.path), f'p{i}']) for i in range(4)]
        self.assertEqual([p.wait() for p in ps], [0, 0, 0, 0])
        self.assertEqual(len(self.store.names('p')), 1200)

    def test_forked_workers_share_it(self):   # dmsh_build.py's worker processes: forks of a process that has the file open, their calls made by that process
        self.store.close()
        self.assertEqual(forked_stores(self.path, str(self.root)), EXPECT)

    def test_forked_workers_with_apples_sqlite(self):   # the same with a Python whose SQLite is Apple's, where a fork that opens the file is killed
        probe = "import _sqlite3, subprocess; print(subprocess.run(['otool', '-L', _sqlite3.__file__], capture_output=True, text=True).stdout)"
        try: libs = subprocess.run([APPLE_PYTHON, '-c', probe], capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.TimeoutExpired): libs = ''
        if '/usr/lib/libsqlite3.dylib' not in libs: self.skipTest(f"no {APPLE_PYTHON} with Apple's SQLite")
        self.store.close()
        code = "import sys; sys.path.insert(0, sys.argv[1]); import test_shader_cache as t; assert t.forked_stores(sys.argv[2], sys.argv[3]) == t.EXPECT, 'results differ'"
        r = subprocess.run([APPLE_PYTHON, '-c', code, str(Path(__file__).parent), str(self.path), str(self.root)], capture_output=True, text=True, timeout=300)
        self.assertEqual((r.returncode, r.stderr), (0, ''))

    def test_worker_dying_in_a_batch(self):   # its batch is rolled back and the store goes on
        import concurrent.futures as cf, multiprocessing
        global SERVED; SERVED = shader_cache.Served(self.store, 2)
        with cf.ProcessPoolExecutor(2, mp_context=multiprocessing.get_context('fork'), initializer=worker_start) as ex:
            ex.submit(int).result(); SERVED.start()
            with self.assertRaises(cf.process.BrokenProcessPool): ex.submit(dies_in_batch, 0).result()
        t = threading.Thread(target=lambda: self.store.put('alive', b'a')); t.start(); t.join(20)
        self.assertFalse(t.is_alive()); self.assertFalse(self.store.has('dead')); self.assertTrue(self.store.has('alive'))


    def test_a_killed_writer_loses_only_what_it_had_not_committed(self):
        code = ("import os, sys; sys.path.insert(0, sys.argv[1]); import shader_cache\ns = shader_cache.Store(sys.argv[2]); s.put('done', b'1')\n"
                "s.db.execute('BEGIN IMMEDIATE'); s.put('half', b'2'); os.kill(os.getpid(), 9)\n")
        subprocess.run([sys.executable, '-c', code, str(REPO / 'dm/tools'), str(self.path)])
        self.assertEqual(self.store.names(''), {'done'})

    def test_remote_blob_ids(self):
        import concurrent.futures as cf, multiprocessing
        global SERVED; SERVED = shader_cache.Served(self.store, 1)
        self.store.put('stage/a/1', b'same'); self.store.put('stage/a/2', b'same'); self.store.put('stage/a/3', b'other')
        with cf.ProcessPoolExecutor(1, mp_context=multiprocessing.get_context('fork'), initializer=worker_start) as ex:
            ex.submit(int).result(); SERVED.start()
            ids = ex.submit(remote_blob_ids, 'stage/a/').result()
        self.assertEqual(set(ids), {'stage/a/1', 'stage/a/2', 'stage/a/3'})
        self.assertEqual(ids['stage/a/1'], ids['stage/a/2'])
        self.assertNotEqual(ids['stage/a/1'], ids['stage/a/3'])


class Damage(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.path = Path(t.name) / 'cas.db'; self.said = []

    def test_a_file_that_is_no_database_costs_the_work_it_held(self):
        self.path.write_bytes(b'not a database at all' * 2000)
        s = shader_cache.Store(self.path, self.said.append); self.addCleanup(s.close)
        self.assertIn('[RED]', self.said[0])
        s.put('x', b'1'); self.assertEqual(s.get('x'), b'1')

    def test_damage_found_in_use(self):
        s = shader_cache.Store(self.path, self.said.append)
        for i in range(300): s.put(f'x{i}', os.urandom(40000))
        s.close()
        b = bytearray(self.path.read_bytes()); b[16384:len(b) // 2] = b'\xee' * (len(b) // 2 - 16384); self.path.write_bytes(b)
        s = shader_cache.Store(self.path, self.said.append)
        for i in range(300): s.get(f'x{i}')   # a miss or an entry, never an exception
        s.put('after', b'1'); self.assertEqual(s.get('after'), b'1')
        s.close()
        self.assertTrue(any('[RED]' in m for m in self.said))


class Prune(Base):
    def shader(self, digest, when):
        self.store.put(f'shader/{digest}/mac/k_b.metal', digest.encode() * 10, when); self.store.put(f'shader/{digest}/mac/k_b.metallib', b'L' + digest.encode(), when)

    def test_old_ones_go_with_their_bytes(self):
        now = time.time()
        for d in (D1, D2): self.shader(d, now - 100)
        self.shader(D3, now + 100); self.store.put('shader/notadigest/mac/x', b'k', now - 100); self.store.put('metallib/mac/m.metallib', b'L' + D2.encode(), now - 100)
        before = self.blobs()
        stored_src = self.store.db.execute('SELECT length(b.payload) FROM entry e JOIN blob b ON b.id=e.blob WHERE e.name=?', (f'shader/{D2}/mac/k_b.metal',)).fetchone()[0]
        self.assertEqual(self.store.prune_shaders({D1}, now), (1, stored_src))   # the source's stored bytes, not the library's
        self.assertEqual({n.split('/')[1] for n in self.store.names('shader/')}, {D1, D3, 'notadigest'})
        self.assertEqual(self.blobs(), before - 1)   # D2's source; its library's bytes stay under metallib/
        self.assertEqual(self.store.get('metallib/mac/m.metallib'), b'L' + D2.encode())

    def test_the_file_gives_back_its_pages(self):
        now = time.time()
        for i in range(40): self.store.put(f'shader/{i:064x}/mac/k_b.metal', os.urandom(100000), now - 100)
        self.store.db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); big = self.path.stat().st_size
        self.assertEqual(self.store.prune_shaders(set(), now)[0], 40)
        self.store.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        self.assertLess(self.path.stat().st_size, big // 4)


class Generations(unittest.TestCase):   # one file per chain: a build writes its own, copies the Metal compiles it reads from older ones, and the older ones go whole after it
    A, B, C = '0123456789ab', 'bbbbbbbbbbbb', 'cccccccccccc'

    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.d = Path(t.name); self.said = []

    def file(self, name, entries, when):   # a generation holding entries, last written at when
        s = shader_cache.Store(self.d / name)
        for n, data in entries.items(): s.put(n, data)
        s.close(); os.utime(self.d / name, (when, when))

    def names(self, path):
        s = shader_cache.Store(path); self.addCleanup(s.close)
        return set(s.names(''))

    def test_older_compiles_are_copied_on_read(self):
        now = time.time()
        self.file('cas.db', {'metallib/mac/old.metallib': b'legacy', f'shader/{D1}/mac/k_b.metal': b'old chain'}, now - 300)
        self.file(f'cas-{self.B}.db', {'metallib/mac/m.metallib': b'B', 'metallib/mac/old.metallib': b'newer'}, now - 100)
        self.assertEqual([Path(p).name for p in shader_cache.generations(self.d)], [f'cas-{self.B}.db', 'cas.db'])   # newest first, the one file last
        s = shader_cache.for_chain(self.d, self.A)
        self.assertEqual(s.path, str(self.d / f'cas-{self.A}.db'))
        self.assertTrue(s.has('metallib/mac/m.metallib'))
        self.assertEqual(s.get('metallib/mac/old.metallib'), b'newer')   # the newest generation answers
        self.assertIsNone(s.get(f'shader/{D1}/mac/k_b.metal')); self.assertFalse(s.has(f'shader/{D1}/mac/k_b.metal'))   # another chain's shader never hits
        s.close()
        self.assertEqual(self.names(self.d / f'cas-{self.A}.db'), {'metallib/mac/old.metallib'})   # what it read is its own now; what it only saw is not

    def test_older_generations_go_after_a_build(self):
        now = time.time()
        self.file('cas.db', {'metallib/ios/i.metallib': b'ios', 'metallib/mac/x.metallib': b'old mac', f'shader/{D1}/mac/k_b.metal': b'm'}, now - 300)
        self.file(f'cas-{self.B}.db', {'metallib/mac/b.metallib': b'B'}, now - 100)
        self.assertEqual(shader_cache.drop_generations(self.d, self.A, self.said.append), [])   # no file of its own: nothing goes
        self.file(f'cas-{self.A}.db', {'metallib/mac/a.metallib': b'A', f'shader/{D2}/mac/k_b.metal': b'a'}, now)
        open(self.d / 'cas.db.lock', 'w').close()
        self.assertEqual(sorted(shader_cache.drop_generations(self.d, self.A, self.said.append)), [f'cas-{self.B}.db', 'cas.db'])
        self.assertEqual(sorted(p.name for p in self.d.iterdir()), [f'cas-{self.A}.db'])
        self.assertEqual(self.names(self.d / f'cas-{self.A}.db'), {'metallib/mac/a.metallib', 'metallib/ios/i.metallib', f'shader/{D2}/mac/k_b.metal'})   # iOS, which it compiled none of, kept
        self.assertIn('kept 1 ios Metal compiles of cas.db: this build compiled none for ios', self.said)
        self.assertEqual(shader_cache.drop_generations(self.d, self.A, self.said.append), [])


class Adopt(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name); self.old = self.root / 'cas'; self.path = self.root / 'cas.db'; self.said = []

    def fill(self):
        for name, data in (('metallib/mac/ab/abcd.metallib', b'compiled'), ('metallib/mac/ab/abcd_x.metallib', b'cut'), ('metallib/ios/cd/cdef.metallib', b'ios'), ('metallib/filled.json', b'{}'),
                           (f'shader/{D1}/mac/k_b.metal', b'old chain'), ('index/k.json', b'{}'), ('variant/ee/metal', b'msl'), ('variant/ee/mac.metallib', b'v'), ('metallib/mac/ab/._abcd.metallib', b'appledouble')):
            p = self.old / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)

    def check(self):
        s = shader_cache.Store(self.path)
        self.assertEqual(s.names(''), {'metallib/mac/abcd.metallib', 'metallib/mac/abcd_x.metallib', 'metallib/ios/cdef.metallib'})
        self.assertEqual(s.get('metallib/mac/abcd.metallib'), b'compiled')
        s.close()
        self.assertEqual(sorted(os.listdir(self.root)), ['cas.db'])

    def test_a_folder(self):
        self.fill(); self.assertEqual(shader_cache.adopt(self.old, self.path, self.said.append), 3); self.check()

    def test_a_tar_read_without_unpacking(self):
        self.fill()
        with tarfile.open(f'{self.old}.tar', 'w', format=tarfile.PAX_FORMAT) as t: t.add(self.old, '.')
        import shutil; shutil.rmtree(self.old)
        self.assertEqual(shader_cache.adopt(self.old, self.path, self.said.append), 3); self.check()

    def test_a_damaged_tar_costs_what_it_held(self):
        Path(f'{self.old}.tar').write_bytes(b'not a tar' * 100)
        self.assertEqual(shader_cache.adopt(self.old, self.path, self.said.append), 0)
        self.assertFalse(Path(f'{self.old}.tar').exists()); self.assertTrue(any('[RED]' in m for m in self.said))

    def test_nothing_there(self):
        self.assertEqual(shader_cache.adopt(self.old, self.path, self.said.append), 0)
        self.assertEqual(os.listdir(self.root), []); self.assertFalse(shader_cache.exists(self.path))

    def test_what_a_stopped_build_left(self):
        for p in (f'{self.old}.gone', f'{self.old}.unpack'): os.makedirs(p); (Path(p) / 'x').write_bytes(b'1')
        Path(f'{self.old}.tar.part').write_bytes(b'1')
        shader_cache.adopt(self.old, self.path, self.said.append)
        self.assertEqual(os.listdir(self.root), [])


def _make_v1(path, entries):
    """Create a legacy v1 raw compile cache (blob(id, hash, data)) as written before inline Zstd compression."""
    with contextlib.closing(sqlite3.connect(path)) as db:
        db.execute('CREATE TABLE blob(id INTEGER PRIMARY KEY, hash BLOB UNIQUE NOT NULL, data BLOB NOT NULL)')
        db.execute('CREATE TABLE entry(name TEXT PRIMARY KEY, blob INTEGER NOT NULL, mtime REAL NOT NULL) WITHOUT ROWID')
        for name, data in entries.items():
            h = hashlib.blake2b(data, digest_size=16).digest()
            row = db.execute('SELECT id FROM blob WHERE hash=?', (h,)).fetchone()
            bid = row[0] if row else db.execute('INSERT INTO blob(hash, data) VALUES(?, ?)', (h, data)).lastrowid
            db.execute('INSERT OR REPLACE INTO entry(name, blob, mtime) VALUES(?, ?, ?)', (name, bid, 100.0))
        db.commit()


@unittest.skipIf(shader_cache.zstd is None, 'zstd module unavailable')
class Compression(Base):   # upstream NXNative 5fa41f315's cases
    def test_inline_compression_and_incompressible_fallback(self):
        text = b'kernel void main0() { /* shader source */ }\n' * 1000
        rand = os.urandom(4096)
        tiny = b'short'
        self.store.put('text', text); self.store.put('rand', rand); self.store.put('tiny', tiny)
        self.assertEqual((self.store.get('text'), self.store.get('rand'), self.store.get('tiny')), (text, rand, tiny))
        rows = {n: (c, l) for n, c, l in self.store.db.execute('SELECT e.name, b.codec, length(b.payload) FROM entry e JOIN blob b ON b.id=e.blob')}
        self.assertEqual(rows['text'][0], shader_cache.ZSTD)
        self.assertLess(rows['text'][1], len(text) // 10)
        self.assertEqual(rows['rand'], (shader_cache.RAW, len(rand)))
        self.assertEqual(rows['tiny'], (shader_cache.RAW, len(tiny)))

    def test_older_checkout_fails_closed(self):
        self.store.put('metallib/mac/a.metallib', b'library' * 500)
        with self.assertRaisesRegex(sqlite3.OperationalError, 'no such column'):
            self.store.db.execute('SELECT b.data FROM entry e JOIN blob b ON b.id=e.blob WHERE e.name=?', ('metallib/mac/a.metallib',))

    def test_legacy_v1_read_write_generation_copy_and_take(self):
        payload = b'compiled metal library ' * 400
        d = self.root / 'mig'; d.mkdir()
        v1 = d / 'cas.db'
        _make_v1(v1, {'metallib/mac/m.metallib': payload, 'metallib/ios/i.metallib': payload + b'ios'})
        # Opening an existing v1 file keeps it readable and writable in place.
        s1 = shader_cache.Store(v1, self.said.append); self.addCleanup(s1.close)
        self.assertFalse(s1.v2)
        self.assertEqual(s1.get('metallib/mac/m.metallib'), payload)
        s1.put('metallib/mac/n.metallib', payload + b'new'); s1.close()
        # Migrating from v1 older generation into a new v2 generation compresses on read and on take().
        a, b = 'aaaaaaaaaaaa', 'bbbbbbbbbbbb'
        sa = shader_cache.for_chain(d, a, self.said.append); self.addCleanup(sa.close)
        self.assertTrue(sa.v2)
        self.assertEqual(sa.get('metallib/mac/m.metallib'), payload)
        self.assertEqual(sa.db.execute('SELECT codec FROM blob').fetchone()[0], shader_cache.ZSTD)
        self.assertEqual(sa.take(v1, 'metallib/ios/'), 1)
        self.assertEqual(sa.get('metallib/ios/i.metallib'), payload + b'ios')
        self.assertTrue(all(c == shader_cache.ZSTD for c, in sa.db.execute('SELECT codec FROM blob')))
        sa.close()
        # Copying from a v2 older generation into a newer v2 generation must not re-encode already-compressed blobs.
        sb = shader_cache.for_chain(d, b, self.said.append); self.addCleanup(sb.close)
        with mock.patch.object(shader_cache, '_encode', side_effect=AssertionError('re-encoded v2 blob')):
            self.assertEqual(sb.get('metallib/mac/m.metallib'), payload)
            self.assertEqual(sb.take(d / f'cas-{a}.db', 'metallib/ios/'), 1)
        self.assertEqual(sb.get('metallib/ios/i.metallib'), payload + b'ios')
        # Taking from v2 into a v1 store decodes back to raw bytes.
        v1_dst = d / 'v1_dst.db'; _make_v1(v1_dst, {})
        sd = shader_cache.Store(v1_dst, self.said.append); self.addCleanup(sd.close)
        self.assertEqual(sd.take(d / f'cas-{b}.db', 'metallib/mac/'), 1)
        self.assertEqual(sd.get('metallib/mac/m.metallib'), payload)

    def test_corrupt_zstd_frame_recovers_local_and_ignores_readonly(self):
        payload = b'shader source ' * 500
        self.store.put('metallib/mac/a.metallib', payload)
        self.store.db.execute('UPDATE blob SET payload=?', (b'not a valid zstd frame',))
        self.assertIsNone(self.store.get('metallib/mac/a.metallib'))
        self.assertTrue(any('[RED]' in m for m in self.said))
        self.store.put('metallib/mac/a.metallib', payload)
        self.assertEqual(self.store.get('metallib/mac/a.metallib'), payload)
        # Corrupt Zstd in a read-only fallback is ignored without altering the fallback file, and falls through to the next file.
        good = self.root / 'good.db'; sg = shader_cache.Store(good); sg.put('metallib/mac/a.metallib', b'from good'); sg.close()
        bad = self.root / 'bad.db'; sb = shader_cache.Store(bad); sb.put('metallib/mac/a.metallib', payload); sb.db.execute('UPDATE blob SET payload=?', (b'corrupt',)); sb.close()
        before = bad.read_bytes()
        ro = shader_cache._ReadOnly([bad, good], self.said.append); self.addCleanup(ro.close)
        self.assertEqual(ro.get('metallib/mac/a.metallib'), b'from good')
        self.assertEqual(bad.read_bytes(), before)
        # A corrupt older generation never poisons a new generation (either directly or via get_raw).
        fresh = shader_cache.Store(self.root / 'fresh.db', self.said.append, older=[bad, good]); self.addCleanup(fresh.close)
        self.assertEqual(fresh.get('metallib/mac/a.metallib'), b'from good')
        self.assertEqual(fresh.get('metallib/mac/a.metallib'), b'from good')   # copied the valid entry, not the corrupt one

    def test_missing_codec_and_unknown_codec_preserve_cache(self):
        payload = b'precious shader ' * 500
        self.store.put('keep', payload); self.store.close()
        with mock.patch.object(shader_cache, 'zstd', None):
            s = shader_cache.Store(self.path, self.said.append); self.addCleanup(s.close)
            with self.assertRaisesRegex(RuntimeError, 'backports.zstd'): s.get('keep')
            self.assertEqual(s.db.execute('SELECT count(*) FROM blob').fetchone()[0], 1)   # never wiped as damaged
            s.close()
            raw_store = shader_cache.Store(self.root / 'no_zstd.db', self.said.append); self.addCleanup(raw_store.close)
            raw_store.put('raw', payload)
            self.assertEqual(raw_store.get('raw'), payload)
            self.assertEqual(raw_store.db.execute('SELECT codec FROM blob').fetchone()[0], shader_cache.RAW)
        s = shader_cache.Store(self.path, self.said.append); self.addCleanup(s.close)
        self.assertEqual(s.get('keep'), payload)
        s.db.execute('UPDATE blob SET codec=99')
        with self.assertRaisesRegex(RuntimeError, 'codec 99'): s.get('keep')
        self.assertEqual(s.db.execute('SELECT count(*) FROM blob').fetchone()[0], 1)

    def test_remote_corrupt_zstd_falls_back_to_parent_recovery(self):
        import multiprocessing
        global SERVED
        payload = b'worker shader ' * 500
        self.store.put('metallib/mac/bad.metallib', payload)
        self.store.db.execute('UPDATE blob SET payload=?', (b'bad zstd',))
        SERVED = shader_cache.Served(self.store, 1)
        def check_worker():
            assert SERVED is not None
            remote = SERVED.worker()
            assert remote.get('metallib/mac/bad.metallib') is None
            remote.put('metallib/mac/ok.metallib', payload)
            assert remote.get('metallib/mac/ok.metallib') == payload
        p = multiprocessing.get_context('fork').Process(target=check_worker)
        p.start(); SERVED.start(); p.join(20)
        self.assertEqual(p.exitcode, 0)
        self.assertEqual(self.store.get('metallib/mac/ok.metallib'), payload)
        self.assertTrue(any('[RED]' in m for m in self.said))


if __name__ == '__main__': unittest.main()
