#!/usr/bin/env python3
# The shader build's compile cache, one file per translation chain version (a generation): <cache folder>/cas-<chain>.db, read and written in place. It was a folder of a few files per shader (Metroid Dread: 84,541 files), kept as a tar between builds and unpacked
# for each build that ran. Nothing is unpacked now: an entry goes in and comes out by its name, and a file a tool needs is written only then.
# SQLite, as it is in Python and takes several writers: dmsh_build.py's threads share one connection (its worker processes use that one too, through this process: Served), and regress.py's chain builds and the NSP script can share a game's file at once (the wait is SQLite's).
# Generations: a chain's build writes only its own file. Its per-shader entries never hit another chain's (their digests cover the chain), and the Metal compiles it reuses from an older generation
# (keyed by the MSL, the convention and the compiler alone) are copied into its file when it takes them (for_chain). After a successful build the NSP script removes the other generations whole
# (drop_generations): an old chain, a stopped build of one, or a development build of another chain is one file, removed or deleted by hand without a vacuum. cas.db, the one file from before
# generations, holding every chain's entries, is the oldest generation and goes the same way.
# Two tables: entry (name, the blob it names, when it was written) and blob (the bytes, once each: a Zstandard frame when that is smaller, else as they are, codec says which). A library kept under its MSL's digest and under its shader's digest was one APFS clone of the other; inside
# one file it would be two copies, so bytes are stored by their hash. A file removed from the cache gives its pages back at the next prune (incremental vacuum), with no copy of the file.
# It only saves work: a damaged file costs the work it held and is made anew, and a full drive is one [RED] line. An entry is written and read whole, so its file is never seen half written.
# Names, as in the folder this replaces: metallib/<target>/<digest>[_x].metallib (dmsh_mtlcache.py), shader/<digest>/<mac|ios>/<output>, index/<key>.json, variant/<digest>/<file> (dmsh_build.py).
# Compression (upstream NXNative 5fa41f315): a blob of 64 bytes or more is kept as a Zstandard frame (level 1) when the frame is smaller, so the file is 40 to 62% smaller (upstream: Cuphead
# 180 to 107 MB, Super Mario Bros. Wonder 2.24 to 0.86 GB). That table is blob(hash, codec, payload), not blob(hash, data): an older checkout that opens such a file stops at "no such column:
# b.data" instead of reading a frame as a library. A file made before it (data) is read and written as it is, raw, and goes with its chain: the next chain's file is the new form. Without a zstd
# module (Python 3.14's compression.zstd, or backports.zstd before it, which the NSP script needs anyway) new blobs are kept raw and a compressed file cannot be read.
# Not part of the translation chain: it decides no output (dmsh_chain.py), like dmsh_mtlcache.py.
import contextlib, hashlib, json, multiprocessing, os, re, shutil, sqlite3, tarfile, threading, time
from pathlib import Path

try: from compression import zstd
except ImportError:
    try: from backports import zstd   # pyright: ignore[reportMissingImports]  # an optional package, only Python before 3.14 needs it
    except ImportError: zstd = None

SCHEMA = ('CREATE TABLE IF NOT EXISTS blob(id INTEGER PRIMARY KEY, hash BLOB UNIQUE NOT NULL, codec INTEGER NOT NULL, payload BLOB NOT NULL)',
          'CREATE TABLE IF NOT EXISTS entry(name TEXT PRIMARY KEY, blob INTEGER NOT NULL, mtime REAL NOT NULL) WITHOUT ROWID')
RAW, ZSTD, ZSTD_LEVEL, ZSTD_MIN = 0, 1, 1, 64   # blob.codec; a blob under ZSTD_MIN bytes, or one a frame does not make smaller, stays RAW
_BAD_FRAME = (zstd.ZstdError,) if zstd else ()   # a frame that does not decode: a damaged file
_TLS = threading.local()   # each thread's compressor
SHADER_ENTRY = re.compile(r'shader/([0-9a-f]{64})/')
WAIT = 600   # seconds another process's write may hold this one up
_DAMAGED = ('malformed', 'not a database', 'disk image')
GENERATION = re.compile(r'cas-([0-9a-f]{12})\.db')   # a chain's file in a cache folder
LEGACY = 'cas.db'   # the one file of every chain, from before generations
TARGETS = ('mac', 'ios')   # metallib/<target>/


def _encode(data):
    """(codec, payload) of a blob's bytes: a Zstandard frame when it is smaller, else the bytes"""
    if zstd is None or len(data) < ZSTD_MIN: return RAW, data
    comp = getattr(_TLS, 'zstd', None)
    if comp is None: comp = _TLS.zstd = zstd.ZstdCompressor(level=ZSTD_LEVEL)
    packed = comp.compress(data, mode=zstd.ZstdCompressor.FLUSH_FRAME)
    return (ZSTD, packed) if len(packed) < len(data) else (RAW, data)


def _decode(codec, payload):
    if codec == RAW: return bytes(payload)
    if codec != ZSTD: raise RuntimeError(f'a shader compile cache blob of codec {codec}, which this checkout does not know')
    if zstd is None: raise RuntimeError('reading a compressed shader compile cache needs Python 3.14+ or backports.zstd (pip install backports.zstd)')
    return zstd.decompress(payload)


def _compressed(db, schema='main'):   # True for a file whose blobs carry a codec (or one with no blob table yet), False for one from before (blob.data, raw)
    return 'data' not in {r[1] for r in db.execute(f'PRAGMA {schema}.table_info(blob)')}


def _get_sql(v2, with_hash=False):   # an entry's (codec, payload), with its hash first when asked
    cols = ('b.codec, b.payload' if v2 else '0, b.data')
    return f'SELECT {"b.hash, " if with_hash else ""}{cols} FROM entry e JOIN blob b ON b.id=e.blob WHERE e.name=?'


def generations(folder):
    """The compile cache files of a cache folder, newest first (by when each was last written): cas-<chain>.db, then cas.db"""
    folder = os.fspath(folder)
    try: names = os.listdir(folder)
    except OSError: return []
    def when(p):
        try: return max(os.path.getmtime(p + s) for s in ('', '-wal') if os.path.exists(p + s))
        except (OSError, ValueError): return 0
    gens = sorted((os.path.join(folder, n) for n in names if GENERATION.fullmatch(n)), key=when, reverse=True)
    return gens + ([os.path.join(folder, LEGACY)] if LEGACY in names else [])


class _ReadOnly:
    """Live SQLite readers of other compile cache files, asked in order: mode=ro sees a writer's committed WAL, never migrates, repairs or writes them.
    prefixes: the names they serve (an older generation serves only its Metal compiles: a per-shader entry of another chain never hits)"""
    def __init__(self, paths, say, prefixes=('metallib/',)):
        self.say, self.lock, self.prefixes, self.dbs = say, threading.RLock(), prefixes, []   # (path, connection, compressed form)
        for p in map(os.fspath, paths):
            if not os.path.isfile(p): continue
            try:
                db = sqlite3.connect(Path(p).resolve().as_uri() + '?mode=ro', uri=True, timeout=WAIT, check_same_thread=False, isolation_level=None)
                self.dbs.append((p, db, _compressed(db)))
            except sqlite3.Error as e: self.say(f'[RED] the read-only shader cache {p} cannot be read and is ignored: {e}')

    def _failed(self, i, e):
        p, db, _ = self.dbs.pop(i)
        self.say(f'[RED] the read-only shader cache {p} cannot be read and is ignored: {e}')
        with contextlib.suppress(sqlite3.Error): db.close()

    def shared(self, name): return name.startswith(self.prefixes) and name != 'metallib/filled.json'

    def _each(self, sql, *args):   # each file's rows, in order
        with self.lock:
            i = 0
            while i < len(self.dbs):
                try: rows = self.dbs[i][1].execute(sql, args).fetchall()
                except sqlite3.Error as e: self._failed(i, e); continue
                i += 1; yield rows

    def get_blob(self, name):
        """(hash, codec, payload, compressed form, bytes) of the first file holding name, None when none does. A file whose blob does not decode is dropped, and the next one asked"""
        if not self.shared(name): return None
        with self.lock:
            i = 0
            while i < len(self.dbs):
                _, db, v2 = self.dbs[i]
                try: rows = db.execute(_get_sql(v2, True), (name,)).fetchall()
                except sqlite3.Error as e: self._failed(i, e); continue
                if rows:
                    digest, codec, payload = bytes(rows[0][0]), rows[0][1], bytes(rows[0][2])
                    try: data = _decode(codec, payload)
                    except (RuntimeError, *_BAD_FRAME) as e: self._failed(i, e); continue
                    return digest, codec, payload, v2, data
                i += 1
        return None

    def get(self, name):
        got = self.get_blob(name)
        return got[4] if got else None

    def has(self, name): return self.shared(name) and any(rows for rows in self._each('SELECT 1 FROM entry WHERE name=?', name))

    def names(self, prefix):
        return {n for rows in self._each('SELECT name FROM entry WHERE name>=? AND name<?', prefix, prefix + '\U0010ffff') for n, in rows if self.shared(n)}

    def close(self):
        with self.lock:
            for _, db, _ in self.dbs:
                with contextlib.suppress(sqlite3.Error): db.close()
            self.dbs = []


class _Files:   # an entry from or to a file, by get and put
    def get(self, name) -> 'bytes | None': raise NotImplementedError
    def put(self, name, data, when=None): raise NotImplementedError

    def put_file(self, name, path):
        with open(path, 'rb') as f: self.put(name, f.read())

    def to_file(self, name, path):   # an entry written to path, whole or not at all; False when there is none
        data = self.get(name)
        if data is None: return False
        tmp = f'{path}.tmp-{os.getpid()}-{threading.get_ident()}'
        with open(tmp, 'wb') as f: f.write(data)
        os.replace(tmp, path)
        return True


class Store(_Files):
    def __init__(self, path, say=print, *, older=()):
        """older: the files of earlier generations of this one (for_chain), whose Metal compiles are copied into this file when they are read"""
        self.path, self.say = os.fspath(path), say
        self.lock = threading.RLock()   # one connection, for dmsh_build.py's threads: a read or a write of an entry takes microseconds next to a compile
        self.full = False
        self.v2 = True   # the file's blobs carry a codec (_prepare): False for a file from before, read and written raw as it is
        own = os.path.realpath(self.path)
        older = [p for p in map(os.fspath, older) if os.path.realpath(p) != own]
        self.older = _ReadOnly(older, say) if older else None
        self._open()

    def _open(self):
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        self.db = sqlite3.connect(self.path, timeout=WAIT, check_same_thread=False, isolation_level=None)
        try:
            self.db.execute('PRAGMA page_size=16384'); self.db.execute('PRAGMA auto_vacuum=INCREMENTAL')   # both only before the first table
            # WAL: a reader in another process does not wait for a writer, and a commit needs no fsync. A drive that cannot share its memory file stays on the rollback journal, unsynced: a stop costs the cache at worst
            if self.db.execute('PRAGMA journal_mode=WAL').fetchone()[0].lower() == 'wal': self.db.execute('PRAGMA synchronous=NORMAL')
            else: self.db.execute('PRAGMA synchronous=OFF')
            self.v2 = _compressed(self.db)
            for s in SCHEMA if self.v2 else SCHEMA[1:]: self.db.execute(s)
        except sqlite3.DatabaseError as e:
            if not self._damage(e): raise

    def _damage(self, e, force=False):   # True when e says the file is damaged (or force: a blob that does not decode), which is now made anew
        if not force and not any(w in str(e) for w in _DAMAGED): return False
        self.say(f'[RED] the shader compile cache {self.path} is damaged, and is made anew: {e}')
        with contextlib.suppress(sqlite3.Error): self.db.close()
        for suffix in ('', '-wal', '-shm', '-journal'):
            with contextlib.suppress(FileNotFoundError): os.unlink(self.path + suffix)
        self._open()
        return True

    def _run(self, sql, *args):   # a statement's rows, or [] when the file was damaged
        with self.lock:
            try: return self.db.execute(sql, args).fetchall()
            except sqlite3.DatabaseError as e:
                if not self._damage(e): raise
                return []

    def has(self, name): return bool(self._run('SELECT 1 FROM entry WHERE name=?', name)) or bool(self.older and self.older.has(name))

    def _adopt(self, name):   # (codec, payload, bytes) of an entry an older generation holds, copied into this file first (a frame as it is, no second compression), or None
        if not self.older or (got := self.older.get_blob(name)) is None: return None
        digest, codec, payload, from_v2, data = got
        if self.v2 and not from_v2: codec, payload = _encode(data)   # a raw file's blob into a compressed one
        if not self.v2: codec, payload = RAW, data
        self._store(name, digest, lambda v2: (codec, payload) if v2 else data, None)
        return codec, payload, data

    def get_raw(self, name):
        """An entry's (codec, payload), undecoded (Remote decodes in its worker), None when there is none; one an older generation holds is copied in first, as get"""
        rows = self._run(_get_sql(self.v2), name)
        if rows: return rows[0][0], bytes(rows[0][1])
        got = self._adopt(name)
        return got[:2] if got else None

    def get(self, name):
        """An entry's bytes, None when there is none. One an older generation holds is copied into this file first, so that it stays when that generation goes"""
        rows = self._run(_get_sql(self.v2), name)
        if rows:
            try: return _decode(rows[0][0], rows[0][1])
            except _BAD_FRAME as e:
                with self.lock: self._damage(e, force=True)
                return None
        got = self._adopt(name)
        return got[2] if got else None

    def names(self, prefix):   # the set of names starting with prefix
        local = {r[0] for r in self._run('SELECT name FROM entry WHERE name>=? AND name<?', prefix, prefix + '\U0010ffff')}
        return local | self.older.names(prefix) if self.older else local

    def blob_ids(self, prefix):   # {name: blob id} of local entries starting with prefix (dmsh_build.py's staged outputs, which share blobs in this file)
        return dict(self._run('SELECT name, blob FROM entry WHERE name>=? AND name<?', prefix, prefix + '\U0010ffff'))

    def _store(self, name, digest, payload_of, when, link_only=False):
        """name pointed at the blob of digest, which is written first when the file has none: payload_of(compressed form) gives (codec, payload), or the bytes for a raw file.
        link_only: write no blob; False when there is none (Remote then sends it). A cache that cannot be written (a full drive) is one [RED] line: the build goes on without it"""
        with self.lock:
            try:
                with self.batch():
                    row = self.db.execute('SELECT id FROM blob WHERE hash=?', (digest,)).fetchone()
                    if row: blob = row[0]
                    elif link_only: return False
                    elif self.v2: blob = self.db.execute('INSERT INTO blob(hash, codec, payload) VALUES(?, ?, ?)', (digest, *payload_of(True))).lastrowid
                    else: blob = self.db.execute('INSERT INTO blob(hash, data) VALUES(?, ?)', (digest, payload_of(False))).lastrowid
                    self.db.execute('INSERT OR REPLACE INTO entry(name, blob, mtime) VALUES(?, ?, ?)', (name, blob, time.time() if when is None else when))
            except sqlite3.OperationalError as e:
                if any(w in str(e) for w in _DAMAGED): self._damage(e)
                elif not self.full: self.full = True; self.say(f'[RED] the shader compile cache {self.path} cannot be written, the build goes on without it: {e}')
            except sqlite3.DatabaseError as e:
                if not self._damage(e): raise
        return True

    def put(self, name, data, when=None):
        """An entry's bytes, replacing what it held. A cache that cannot be written (a full drive) is one [RED] line: the build goes on without it"""
        digest = hashlib.blake2b(data, digest_size=16).digest()
        encoded = None
        if self.v2 and not self._run('SELECT 1 FROM blob WHERE hash=?', digest): encoded = _encode(data)   # outside the lock, so threads compress side by side (unless this one is in a batch)
        self._store(name, digest, lambda v2: (encoded or _encode(data)) if v2 else data, when)

    def put_link(self, name, digest, when=None):   # Remote: name pointed at a blob the file holds; False when it holds none, and the worker sends the blob (put_blob)
        return self._store(name, digest, None, when, link_only=True)

    def put_blob(self, name, digest, codec, payload, when=None):   # Remote: a blob its worker hashed and encoded (encoded for the form the worker knew; a raw file takes the bytes)
        self._store(name, digest, lambda v2: (codec, payload) if v2 else payload if codec == RAW else _decode(codec, payload), when)

    @contextlib.contextmanager
    def batch(self):
        """Several entries as one write: a stop leaves all of them or none (a shader's outputs and the index naming them), and thousands take one commit. Nests; the outermost commits"""
        with self.lock:
            if self.db.in_transaction: yield; return
            self.db.execute('BEGIN IMMEDIATE')
            try: yield
            except BaseException:
                if self.db.in_transaction: self.db.rollback()
                raise
            else: self.db.commit()

    def prune_shaders(self, keep, since):
        """Remove the shader/<64 hex digits>/ entries not in keep and all written before since, and the bytes nothing names any more, giving their pages back. Other names stay.
        Returns (shaders removed, bytes of their sources and reflection: their libraries are shared with metallib/)"""
        rows = self._run(f"SELECT e.name, e.mtime, length(b.{'payload' if self.v2 else 'data'}) FROM entry e JOIN blob b ON b.id=e.blob WHERE e.name>='shader/' AND e.name<'shader0'")   # stored bytes
        newest, size, names = {}, {}, {}
        for name, mtime, n in rows:
            m = SHADER_ENTRY.match(name)
            if not m: continue
            d = m.group(1); newest[d] = max(newest.get(d, 0), mtime); names.setdefault(d, []).append(name)
            if not name.endswith('.metallib'): size[d] = size.get(d, 0) + n
        gone = [d for d in newest if d not in keep and newest[d] < since]
        if not gone: return 0, 0
        with self.lock, self.batch():
            self.db.executemany('DELETE FROM entry WHERE name=?', ((n,) for d in gone for n in names[d]))
            self.db.execute('DELETE FROM blob WHERE id NOT IN (SELECT blob FROM entry)')
        self._run('PRAGMA incremental_vacuum')
        return len(gone), sum(size.get(d, 0) for d in gone)

    def delete_prefix(self, prefix):
        """Remove every entry whose name starts with prefix, and the bytes nothing names any more, giving their pages back (dmsh_build.py's staged outputs once its image is written)"""
        with self.lock:
            try:
                with self.batch():
                    self.db.execute('DELETE FROM entry WHERE name>=? AND name<?', (prefix, prefix + '\U0010ffff'))
                    self.db.execute('DELETE FROM blob WHERE id NOT IN (SELECT blob FROM entry)')
            except sqlite3.DatabaseError as e:
                if not self._damage(e): raise
        self._run('PRAGMA incremental_vacuum')

    def holds(self, prefix): return bool(self._run('SELECT 1 FROM entry WHERE name>=? AND name<? LIMIT 1', prefix, prefix + '\U0010ffff'))

    def take(self, path, prefix):
        """Copy the entries of the cache file path whose names start with prefix into this one, as they are (bytes, names, times); an entry this file holds stays. Returns the number taken.
        Between the two forms a blob is compressed (a raw file's into a compressed one) or decoded (the other way); a frame goes into a compressed file as it is"""
        hi, n = prefix + '\U0010ffff', 0
        pick = 'FROM old.entry e JOIN old.blob b ON b.id=e.blob WHERE e.name>=? AND e.name<?'
        with self.lock:
            self.db.execute('ATTACH DATABASE ? AS old', (os.fspath(path),))
            try:
                old_v2 = _compressed(self.db, 'old')
                with self.batch():
                    if self.v2 == old_v2:
                        cols = 'hash, codec, payload' if self.v2 else 'hash, data'
                        self.db.execute(f'INSERT OR IGNORE INTO main.blob({cols}) SELECT {", ".join("b." + c for c in cols.split(", "))} {pick}', (prefix, hi))
                    else:
                        new = ' AND b.hash NOT IN (SELECT hash FROM main.blob)'
                        if self.v2:
                            rows = self.db.execute(f'SELECT DISTINCT b.hash, b.data {pick}{new}', (prefix, hi)).fetchall()
                            self.db.executemany('INSERT OR IGNORE INTO main.blob(hash, codec, payload) VALUES(?, ?, ?)', ((h, *_encode(bytes(d))) for h, d in rows))
                        else:
                            rows = self.db.execute(f'SELECT DISTINCT b.hash, b.codec, b.payload {pick}{new}', (prefix, hi)).fetchall()
                            self.db.executemany('INSERT OR IGNORE INTO main.blob(hash, data) VALUES(?, ?)', ((h, _decode(c, p)) for h, c, p in rows))
                    n = self.db.execute('INSERT OR IGNORE INTO main.entry(name, blob, mtime) SELECT e.name, m.id, e.mtime FROM old.entry e JOIN old.blob b ON b.id=e.blob JOIN main.blob m ON m.hash=b.hash '
                                        'WHERE e.name>=? AND e.name<?', (prefix, hi)).rowcount
            except sqlite3.OperationalError as e:   # a full drive: nothing taken, and the caller keeps the other file
                self.full = True; self.say(f'[RED] the shader compile cache {self.path} cannot be written: {e}')
            finally: self.db.execute('DETACH DATABASE old')
        return 0 if self.full else n

    def close(self):   # also folds the write-ahead log into the file, so that one file is left
        with self.lock, contextlib.suppress(sqlite3.Error): self.db.close()
        if self.older: self.older.close()


class _Gone(Exception): pass    # a worker's end closed inside its batch
class _Abort(Exception): pass   # a worker's batch raised


class Served:
    """A store for forked worker processes (dmsh_build.py's), which must not open the file themselves: Apple's SQLite (/usr/lib/libsqlite3.dylib, which Xcode's Python and Pythons built
    from source use) calls os_signpost when it opens a database, and in a fork of a process that has opened one, that call reads the parent's logging state at an address the child does
    not have (SIGSEGV in _os_log_preferences_refresh, GitHub issue #2354). So the process that opened the store makes every call: each worker has a pipe to a thread here, which stands
    where that worker's thread stood when the build finished its shaders in threads, on the one connection and under its lock. A worker's batch is that thread's batch, so it is whole
    or absent as before, and is rolled back when the worker dies inside it.
    Made before the fork; start() here once every worker is forked (it starts threads); worker() in each worker gives its store (get, has, names, put, put_file, to_file, delete_prefix, batch, full)"""
    OPS = ('get', 'get_raw', 'has', 'names', 'blob_ids', 'put', 'put_link', 'put_blob', 'delete_prefix')

    def __init__(self, store, n):
        ctx = multiprocessing.get_context('fork')
        self.store, self.pipes, self.taken = store, [ctx.Pipe() for _ in range(n)], ctx.Value('i', 0)

    def start(self):
        for here, there in self.pipes:
            there.close()   # so that a dead worker ends its thread's read
            threading.Thread(target=self._serve, args=(here,), daemon=True).start()

    def worker(self):
        with self.taken.get_lock(): i = self.taken.value; self.taken.value += 1
        for j, (here, there) in enumerate(self.pipes):
            here.close()
            if j != i: there.close()
        return Remote(self.pipes[i][1], self.store.v2)

    def _serve(self, conn):
        with contextlib.suppress(_Gone, EOFError, OSError): self._calls(conn, False)

    def _calls(self, conn, inside):   # answers a worker's calls: until its end closes, or inside its batch until the batch ends
        s = self.store
        while True:
            try: op, args = conn.recv()
            except (EOFError, OSError):
                if inside: raise _Gone from None
                return
            if op == 'end' and inside: return
            if op == 'abort' and inside: raise _Abort
            try:
                if op == 'begin' and not inside:
                    try:
                        with s.batch(): conn.send((True, None, s.full)); self._calls(conn, True)
                    except _Abort: pass
                    value = None   # the answer to the batch's end, once it is committed or rolled back
                elif op in self.OPS: value = getattr(s, op)(*args)
                else: raise ValueError(f'shader cache: no call {op!r}')
            except _Gone: raise
            except Exception as e: conn.send((False, e, s.full))
            else: conn.send((True, value, s.full))


class Remote(_Files):
    """A worker's store (Served.worker): each call is made by the process that opened the file; hashing, compression and decompression run here, in the worker
    (upstream NXNative 5fa41f315), so a blob the file already holds is linked by its hash without its bytes crossing the pipe"""
    def __init__(self, conn, v2=True): self.conn, self.v2, self.lock, self.inside, self.full = conn, v2, threading.RLock(), False, False

    def _call(self, op, *args):
        with self.lock:
            self.conn.send((op, args)); ok, value, self.full = self.conn.recv()
        if not ok: raise value
        return value

    def get(self, name):
        raw = self._call('get_raw', name)
        if raw is None: return None
        try: return _decode(*raw)
        except _BAD_FRAME: return self._call('get', name)   # the process that opened the file finds the damage and makes the file anew

    def has(self, name): return self._call('has', name)
    def names(self, prefix): return self._call('names', prefix)
    def blob_ids(self, prefix): return self._call('blob_ids', prefix)
    def put(self, name, data, when=None):
        digest = hashlib.blake2b(data, digest_size=16).digest()
        if self._call('put_link', name, digest, when): return
        self._call('put_blob', name, digest, *(_encode(data) if self.v2 else (RAW, data)), when)
    def delete_prefix(self, prefix): self._call('delete_prefix', prefix)

    @contextlib.contextmanager
    def batch(self):   # as Store.batch: nests, and the lock is held for all of it
        with self.lock:
            if self.inside: yield; return
            self._call('begin'); self.inside = True
            try: yield
            except BaseException: self.inside = False; self._call('abort'); raise
            else: self.inside = False; self._call('end')


def _adopted_name(name):
    """What a file of the old folder is called here, None for one not taken. A shader/ or index/ entry's digest covers the chain's code, which the change to this file moved, so none can hit. A variant/ entry from
    before shader compiles read their source from standard input (f2a50f35) holds its source's file name in its function constants, so its bytes differ from a fresh compile's: few, and cheap to compile again.
    The compile results are the ones worth keeping, and their digests cover the MSL and the compiler alone"""
    m = re.fullmatch(r'metallib/([^/]+)/[0-9a-f]{2}/([^/]+\.metallib)', name)
    return f'metallib/{m.group(1)}/{m.group(2)}' if m else None


def adopt(old, path, say=print):
    """A compile cache from before this file (the folder old, or old.tar: tree_tar.py) into the file path, and the old one removed, so a build folder converts by itself at its next build. A damaged tar costs the work it held.
    Returns the number of entries taken"""
    folder, tar = os.fspath(old), f'{os.fspath(old)}.tar'
    leftovers = [p for p in (f'{folder}.gone', f'{folder}.unpack', f'{tar}.part') if os.path.lexists(p)]
    if not (os.path.isdir(folder) or os.path.isfile(tar) or leftovers): return 0
    n, store = 0, None
    def take(name, read):
        nonlocal n, store
        new = _adopted_name(name.removeprefix('./'))
        if new is None or os.path.basename(name).startswith('._'): return
        store = store or Store(path, say)
        store.put(new, read()); n += 1
    def in_batches(items):
        for i, item in enumerate(items):
            if not i % 2000 and store is not None and store.db.in_transaction: store.db.commit()
            if store is not None and not store.db.in_transaction: store.db.execute('BEGIN IMMEDIATE')
            yield item
        if store is not None and store.db.in_transaction: store.db.commit()
    try:
        if os.path.isfile(tar):
            say(f'moving the compile cache {tar} into one file read in place')
            with tarfile.open(tar, 'r:') as t:
                for m in in_batches(t):
                    source = t.extractfile(m) if m.isfile() else None
                    if source: take(m.name, source.read)
    except (tarfile.TarError, OSError) as e: say(f'[RED] could not read {tar}, the build goes on without it: {e}')
    if os.path.isdir(folder):   # the newer of the two, when a stopped build left both
        say(f'moving the compile cache {folder} into one file read in place')
        def files():
            for d, _, fs in os.walk(folder):
                for f in fs: yield os.path.join(d, f)
        for p in in_batches(files()):
            def read(p=p):
                with open(p, 'rb') as f: return f.read()
            take(os.path.relpath(p, folder), read)
    if store is not None: store.close()
    for p in [folder, tar] + leftovers:
        try:
            if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p, onexc=lambda f, q, e: None if isinstance(e, FileNotFoundError) else (_ for _ in ()).throw(e))
            elif os.path.lexists(p): os.unlink(p)
        except OSError as e: say(f'[RED] could not remove the old compile cache {p}: {e}')
    return n


def exists(path): return os.path.isfile(os.fspath(path))


def chain_file(folder, chain): return os.path.join(os.fspath(folder), f'cas-{chain}.db')


def for_chain(folder, chain, say=print, **kw):
    """The cache of chain's build in a cache folder: its own file, cas-<chain>.db, over the folder's other generations (their Metal compiles, copied in when read)"""
    return Store(chain_file(folder, chain), say, older=generations(folder), **kw)


def _file_size(p): return sum(os.path.getsize(p + s) for s in ('', '-wal') if os.path.isfile(p + s))


def drop_generations(folder, chain, say=print):
    """After a successful build of chain: remove the cache folder's other generations whole, the files of older chains and cas.db (the one file from before generations).
    The build copied in every Metal compile it reused; a target it compiled nothing for (iOS after a Mac-only build, the Mac after an iPhone-only one) first takes the compiles of the newest
    other generation that holds some, the work its next build of that target can reuse. Nothing goes without the chain's own file, or when copying fails (a full drive).
    Returns the names of the files removed"""
    cur = chain_file(folder, chain)
    others = [p for p in generations(folder) if os.path.realpath(p) != os.path.realpath(cur)]
    if not others or not os.path.isfile(cur): return []
    store = Store(cur, say)
    try:
        for t in TARGETS:
            prefix = f'metallib/{t}/'
            if store.holds(prefix): continue
            for p in others:
                src = _ReadOnly([p], say)
                try: has = bool(next(src._each('SELECT 1 FROM entry WHERE name>=? AND name<? LIMIT 1', prefix, prefix + '\U0010ffff'), None))
                finally: src.close()
                if has:
                    n = store.take(p, prefix)
                    if n: say(f'kept {n:,} {t} Metal compiles of {os.path.basename(p)}: this build compiled none for {t}')
                    break
        if store.full: return []
    finally: store.close()
    gone, size = [], 0
    for p in others:
        n = _file_size(p)
        try:
            for s in ('', '-wal', '-shm', '-journal', '.lock'):
                with contextlib.suppress(FileNotFoundError): os.unlink(p + s)
        except OSError as e: say(f'[RED] could not remove the old shader compile cache {p}: {e}'); continue
        gone.append(os.path.basename(p)); size += n
    if gone: say(f'removed old shader compile caches {", ".join(gone)} ({size / 1e9:.2f} GB)')
    return gone


def main():
    import sys
    if len(sys.argv) != 2: sys.exit('usage: shader_cache.py <cas.db>: what it holds')
    s = Store(sys.argv[1])
    kinds = {}
    for name, in s._run('SELECT name FROM entry'): kinds[name.split('/', 1)[0]] = kinds.get(name.split('/', 1)[0], 0) + 1
    print(json.dumps({'entries': kinds, 'blobs': s._run('SELECT count(*) FROM blob')[0][0], 'bytes': os.path.getsize(sys.argv[1]), 'codec': 'zstd' if s.v2 else 'raw'}))
    s.close()


if __name__ == '__main__': main()
