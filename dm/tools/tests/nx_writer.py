"""Writes NX archives (https://github.com/fab918/nxformat, SPEC.md 1.0.3, wire versions 0.2 and 0.3) for the tests of scripts/pack_nx.py. Test code only: it declares its own record layouts
from the spec and shares nothing with the reader, so a reader bug the writer repeats would still fail on the upstream conformance fixtures (dm/tools/tests/fixtures/nx).

write(path, apps, ...) writes a compact archive: both header slots, blocks deduplicated by content (RAW, or one zstd frame each when that is smaller), the CRC-32C table, Media (NACP and icons),
the Catalog (applications, programs, snapshots sorted as the spec orders them, localized entries, the Snapshot Metadata History extension, Source Resources for 0.3, extra extensions),
the Manifest and every snapshot identity. reseal(data) recomputes the three digests and both header CRCs after a test changed bytes, so a check behind them is reached."""
import hashlib
import struct

try: from compression import zstd
except ImportError:
    try: from backports import zstd   # pyright: ignore[reportMissingImports]
    except ImportError: zstd = None

NO = 0xFFFFFFFF
HEADER = struct.Struct('<4sHHIHH13Q32s32s32sQI24sI')


def crc32c(b):
    c = 0xFFFFFFFF
    for x in b:
        c ^= x
        for _ in range(8): c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
    return c ^ 0xFFFFFFFF


_T = []


def crc32c_fast(b):   # the same, table-driven (the 1 MiB blocks of some tests)
    if not _T:
        for i in range(256):
            c = i
            for _ in range(8): c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
            _T.append(c)
    c = 0xFFFFFFFF
    for x in b: c = (c >> 8) ^ _T[(c ^ x) & 0xFF]
    return c ^ 0xFFFFFFFF


def a16(x): return (x + 15) & ~15
def a8(x): return (x + 7) & ~7
def sha(b): return hashlib.sha256(b).digest()


class Frame:
    """A file whose one block is stored as the given bytes with codec 1 (zstd) instead of being compressed here: content is the logical bytes the CRC table and SHA-256 describe"""
    def __init__(self, frame, content):
        self.frame, self.content = frame, content


def nest(tree):   # {'a/b': bytes, 'c': {'d/e': bytes}} → {'a': {'b': bytes}, 'c': {'d': {'e': bytes}}}
    t = {}
    for p, v in tree.items():
        *ds, f = p.split('/'); c = t
        for x in ds: c = c.setdefault(x, {})
        c[f] = nest(v) if isinstance(v, dict) else v
    return t


class _Manifest:
    def __init__(self, chunk_log2, compress):
        self.chunk_log2, self.compress = chunk_log2, compress
        self.dirs, self.files, self.refs, self.pool = [], [], [], bytearray()
        self.blocks, self.by_content = [], {}   # (stored, logical, codec); logical bytes → block id

    def block(self, data, frame=None):
        if frame is None and data in self.by_content: return self.by_content[data]
        if frame is not None: stored, codec = frame, 1
        else:
            stored, codec = data, 0
            if self.compress and zstd is not None:
                z = zstd.compress(data, options={zstd.CompressionParameter.window_log: max(10, min(20, (len(data) - 1).bit_length())), zstd.CompressionParameter.content_size_flag: 1})
                if len(z) < len(data): stored, codec = z, 1
        self.blocks.append((stored, data, codec))
        if frame is None: self.by_content[data] = len(self.blocks) - 1
        return len(self.blocks) - 1

    def file(self, v):
        frame, data = (v.frame, v.content) if isinstance(v, Frame) else (None, v)
        chunk = 1 << self.chunk_log2
        first = len(self.refs)
        for at in range(0, len(data), chunk): self.refs.append(self.block(data[at:at + chunk], frame))
        self.files.append((len(data), first, len(self.refs) - first, self.chunk_log2, sha(data)))
        return len(self.files) - 1

    def tree(self, t):   # a nested dict → its directory ID; children sorted bytewise
        d = len(self.dirs); self.dirs.append(None)
        kids = []
        for name in sorted(t, key=lambda n: n.encode()):
            v = t[name]
            if isinstance(v, dict): kids.append((name.encode(), 1, self.tree(v)))
            else: kids.append((name.encode(), 2, self.file(v)))
        self.dirs[d] = kids
        return d

    def identity_nodes(self, root):
        nodes = [(b'', 1, -1)]
        def walk(d, pre):
            for name, kind, t in self.dirs[d]:
                p = pre + b'/' + name if pre else name
                nodes.append((p, kind, t))
                if kind == 1: walk(t, p)
        walk(root, b'')
        return sorted(nodes, key=lambda x: x[0])

    def logical(self, root): return sum(self.files[t][0] for _, k, t in self.identity_nodes(root) if k == 2)

    def bytes(self):
        nents = sum(len(k) for k in self.dirs)
        dir_off = cur = 96; cur += 16 * len(self.dirs)
        file_off = ent_off = ref_off = 0
        if self.files: file_off = cur = a8(cur); cur += 64 * len(self.files)
        if nents: ent_off = cur = a8(cur); cur += 24 * nents
        if self.refs: ref_off = cur = (cur + 3) & ~3; cur += 4 * len(self.refs)
        path_off = a8(cur)
        names, ents_raw, cursor = bytearray(), bytearray(), 0
        dirs_raw = bytearray()
        for kids in self.dirs:
            dirs_raw += struct.pack('<4I', cursor, len(kids), 0, 0)
            for name, kind, t in kids:
                ents_raw += struct.pack('<QIIBBHI', path_off + len(names), len(name), t, kind, 0, 0, 0); names += name
            cursor += len(kids)
        total = path_off + len(names)
        m = bytearray(total)
        m[dir_off:dir_off + len(dirs_raw)] = dirs_raw
        for i, (size, first, count, log2, digest) in enumerate(self.files):
            struct.pack_into('<QIIBBH32s12s', m, file_off + 64 * i, size, first, count, log2, 0, 0, digest, bytes(12))
        if nents: m[ent_off:ent_off + len(ents_raw)] = ents_raw
        for i, r in enumerate(self.refs): struct.pack_into('<I', m, ref_off + 4 * i, r)
        m[path_off:] = names
        struct.pack_into('<4sHHQ4I6Q16s', m, 0, b'NXMF', 1, 96, total, len(self.dirs), len(self.files), nents, len(self.refs), dir_off, file_off, ent_off, ref_off, path_off, len(names), bytes(16))
        return bytes(m)


def identity(platform, app_id, program_id, stype, version, content_id, nodes, files):
    b = bytearray(b'NX-SNAPSHOT-ID\0')
    b += struct.pack('<HBQQBI16sI', 3, platform, app_id, program_id, stype, version, content_id, len(nodes))
    for path, kind, t in nodes:
        b += struct.pack('<BI', kind, len(path)) + path
        if kind == 2: b += struct.pack('<Q', files[t][0]) + files[t][4]
    return sha(b)


def write(path, apps, *, minor=2, chunk_log2=16, compress=True, extensions=(), resources=(), generation=0, history=True):
    """apps: [{'id', 'platform' (1), 'programs' ([id]), 'snapshots': [{'type', 'version', 'program' (index into programs, None for DLC with no program), 'tree' (nested dict of bytes or
    Frame), 'addon' (a DLC's add-on title ID), 'content_id', 'build_id', 'display', 'meta': {'nacp', 'icon', 'icon_type' (2 JPEG), 'title', 'publisher', 'localized': [(tag, title, icon)]}}]}].
    The application's metadata snapshot is its highest-version snapshot with meta (not DLC); the others' meta go to the Snapshot Metadata History (history=False leaves them out).
    extensions: extra (type, flags, owner kind, owner index, payload). resources (0.3): [(kind, {name: bytes})], owned by the first application. Returns the bytes written"""
    man = _Manifest(chunk_log2, compress)
    strings, pool = {}, bytearray()
    def sref(s):
        if s is None: return NO, 0
        b = s.encode()
        if b not in strings: strings[b] = len(pool); pool.extend(b)
        return strings[b], len(b)
    media = []   # (type, bytes)
    def mref(t, b):
        if b is None: return NO
        media.append((t, b)); return len(media) - 1
    app_rows, prog_rows, snap_rows, local_rows, ext_rows = [], [], [], [], []
    for app in sorted(apps, key=lambda a: (a.get('platform', 1), a['id'])):
        plat, aid = app.get('platform', 1), app['id']
        pids = app.get('programs', [aid])
        first_prog = len(prog_rows)
        snaps = []
        for s in app['snapshots']:
            cid = struct.pack('<Q8x', s['addon']) if s.get('addon') else s.get('content_id', bytes(16))
            root = man.tree(nest(s['tree']))
            prog = s.get('program', 0 if s['type'] != 2 else None)
            snaps.append(dict(s, cid=cid, root=root, prog=prog, build=s.get('build_id', bytes(32))))
        snaps.sort(key=lambda s: (s['prog'] if s['prog'] is not None else 1 << 40, s['type'], s['version'], s['cid'], s['build']))
        first_snap = len(snap_rows)
        for i, s in enumerate(snaps): s['index'] = first_snap + i
        for pi, pid in enumerate(pids):
            mine = [s['index'] for s in snaps if s['prog'] == pi]
            prog_rows.append(struct.pack('<QIBBH16s4I16s', pid, len(app_rows), 0 if pi == 0 else 1, 0, 0, bytes(16), mine[0], len(mine), NO, 0, bytes(16)))
        metas = [s for s in snaps if s.get('meta') and s['type'] != 2]
        chosen = max(metas, key=lambda s: (s['version'], s['index'])) if metas else None
        first_local = len(local_rows)
        def localized(m, rows):
            for tag, title, icon in sorted(m.get('localized', []), key=lambda x: x[0].encode()):
                rows.append(struct.pack('<6I', *sref(tag), *sref(title), mref(m.get('icon_type', 2), icon), 0))
        hist = []
        if chosen is not None:
            m = chosen['meta']
            title, pub = sref(m.get('title')), sref(m.get('publisher'))
            icon, nacp = mref(m.get('icon_type', 2), m.get('icon')), mref(4, m.get('nacp'))
            localized(m, local_rows)
            for s in metas:
                if s is not chosen and history: hist.append(s)
        else: title = pub = (NO, 0); icon = nacp = NO
        nlocal = len(local_rows) - first_local
        types = {s['type'] for s in snaps}
        flags = (1 if 0 in types else 0) | (2 if 2 in types else 0)
        app_rows.append(struct.pack('<QBBH15I8s', aid, plat, flags, 0, first_prog if pids else NO, len(pids), first_snap, len(snaps), *title, *pub, icon,
                                    first_local, nlocal, nacp, 0, 0, chosen['index'] if chosen is not None else NO, bytes(8)))
        app_index = len(app_rows) - 1
        if hist:
            rows, locs = bytearray(), []
            for s in sorted(hist, key=lambda s: s['index']):
                m = s['meta']; first = len(locs); localized(m, locs)
                rows += struct.pack('<12I', s['index'], *sref(m.get('title')), *sref(m.get('publisher')), mref(m.get('icon_type', 2), m.get('icon')), mref(4, m.get('nacp')),
                                    first, len(locs) - first, 0, 0, 0)
            ext_rows.append((0x00010004, 1, 1, app_index, struct.pack('<4sHHIIII', b'NXSM', 1, 24, len(hist), len(locs), 0, 0) + rows + b''.join(locs)))
        for s in snaps:
            pid = pids[s['prog']] if s['prog'] is not None else 0xFFFFFFFFFFFFFFFF
            ident = identity(plat, aid, pid, s['type'], s['version'], s['cid'], man.identity_nodes(s['root']), man.files)
            sflags = (1 if s['build'] != bytes(32) else 0) | (2 if s.get('addon') else 0)
            snap_rows.append(struct.pack('<IBBHIIQII16sII32s32s', first_prog + s['prog'] if s['prog'] is not None else NO, s['type'], sflags, 0, s['version'], s['root'],
                                         man.logical(s['root']), *sref(s.get('display')), s['cid'], 0, 0, ident, s['build']))
    if minor == 3 or resources:
        recs = []
        for kind, files in resources:
            recs.append((kind, man.tree(files)))
        recs.sort()
        ext_rows.append((0x00010008, 1, 1, 0, struct.pack('<4sHHII', b'NXSR', 1, 16, len(recs), 0) + b''.join(struct.pack('<II', *r) for r in recs)))
    ext_rows += list(extensions)
    ext_rows.sort(key=lambda e: (e[0], e[2], e[3]))
    # Catalog
    tables = [(app_rows, 80), (prog_rows, 64), (snap_rows, 120), (local_rows, 24), ([], 56), ([None] * len(ext_rows), 32)]
    offs, cur = [], 128
    for rows, size in tables:
        if rows: cur = a8(cur); offs.append(cur); cur += len(rows) * size
        else: offs.append(0)
    pool_off = a8(cur); cur = pool_off + len(pool)
    pay = []
    for e in ext_rows:
        cur = a8(cur); pay.append(cur); cur += len(e[4])
    cat = bytearray(cur)
    for (rows, size), off in zip(tables[:4], offs):
        for i, r in enumerate(rows): cat[off + i * size:off + (i + 1) * size] = r
    for i, (e, at) in enumerate(zip(ext_rows, pay)):
        struct.pack_into('<IIHHIQQ', cat, offs[5] + 32 * i, e[0], e[1], e[2], 0, e[3], at, len(e[4]))
        cat[at:at + len(e[4])] = e[4]
    cat[pool_off:pool_off + len(pool)] = pool
    struct.pack_into('<4sHHQ8I8Q16s', cat, 0, b'NXCT', 1, 128, len(cat), 0, len(app_rows), len(prog_rows), len(snap_rows), len(local_rows), 0, len(ext_rows), 0,
                     *offs, pool_off, len(pool), bytes(16))
    manifest = man.bytes()
    # Data, then the tail
    out = bytearray(8192)
    index, integrity = bytearray(), bytearray()
    for stored, data, codec in man.blocks:
        at = a16(len(out)); out += bytes(at - len(out)) + stored
        index += struct.pack('<QIIBBHI', at, len(stored), len(data), codec, 0, 0, len(integrity) // 4)
        for k in range(0, len(data), 16384): integrity += struct.pack('<I', crc32c_fast(data[k:k + 16384]))
    data_size = len(out) - 8192 if man.blocks else 0
    def put(b):
        nonlocal out
        at = a16(len(out)); out += bytes(at - len(out)) + b; return at
    media_off = media_size = 0
    if media:
        n = len(media); pay_off = a16(32 + 64 * n)
        recs, cur = bytearray(), pay_off
        for t, b in media:
            cur = a16(cur); recs += struct.pack('<HBBQQQ32sI', t, 0, 0, len(b), len(b), cur, sha(b), 0); cur += len(b)
        region = bytearray(cur)
        region[32:32 + len(recs)] = recs
        c = pay_off
        for _, b in media:
            c = a16(c); region[c:c + len(b)] = b; c += len(b)
        struct.pack_into('<4sHHQIHHII', region, 0, b'NXMD', 1, 32, len(region), n, 64, 0, 32, pay_off)
        media_off, media_size = put(bytes(region)), len(region)
    cat_off = put(bytes(cat)); man_off = put(manifest)
    idx_off = put(bytes(index)) if man.blocks else 0
    int_off = put(bytes(integrity)) if man.blocks else 0
    h = bytearray(HEADER.pack(b'NXAR', 0, minor, 256, 1, 0, len(out), cat_off, len(cat), media_off, media_size, 8192 if man.blocks else 0, data_size, man_off, len(manifest),
                              idx_off, len(man.blocks), int_off, len(integrity), sha(bytes(cat)), sha(manifest), sha(bytes(index) + bytes(integrity)), generation, 16384, bytes(24), 0))
    struct.pack_into('<I', h, 252, crc32c(h[:252]))
    out[0:256] = h; out[4096:4352] = h
    data = bytes(out)
    if path is not None:
        with open(path, 'wb') as f: f.write(data)
    return data


def reseal(data, slot_b=True):
    """data with its Catalog, Manifest and index digests and slot A's CRC recomputed from slot A's offsets; slot B made the same as A (slot_b)"""
    b = bytearray(data)
    v = list(HEADER.unpack_from(b, 0))
    asize, cat_off, cat_size, _, _, _, _, man_off, man_size, idx_off, nblocks, int_off, int_size = v[6:19]
    v[19] = sha(bytes(b[cat_off:cat_off + cat_size]))
    v[20] = sha(bytes(b[man_off:man_off + man_size]))
    v[21] = sha(bytes(b[idx_off:idx_off + nblocks * 24]) + bytes(b[int_off:int_off + int_size]))
    h = bytearray(HEADER.pack(*v[:25], 0))
    struct.pack_into('<I', h, 252, crc32c(h[:252]))
    b[0:256] = h
    if slot_b: b[4096:4352] = h
    return bytes(b)


def catalog_span(data):   # (offset, size) of the Catalog
    v = HEADER.unpack_from(data, 0)
    return v[7], v[8]
