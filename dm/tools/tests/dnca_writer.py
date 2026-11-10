"""Synthetic decrypted NCAs (DNCA: the files an NX made by nxconvert pack holds, NXFormat 1.0.2) for the tests of nx_extract's --plain mode and of scripts/pack_nx.py's NCA
snapshots. Test code only, with its own layouts (switchbrew's NCA, PFS0, RomFS, IVFC, CNMT and bucket-tree records): it shares nothing with LibHac, nx_extract or pack_nx, so a
reader bug cannot be repeated here. Nothing of NXFormat's is used. A DNCA is an NCA whose 0xC00-byte header is plaintext with the marker DNCA at 0x200 and every section's
encryption type 1 (none); a sparse section flattened by the decrypter carries DSPF at FS header 0x1D0.

nca(...) builds one NCA from Sections; check(b) states the rules NXConvert applies to a DNCA (marker, size, section table, FS header hashes, encryption) and runs on every NCA made here.
Builders: pfs0, sha256_section (ExeFS / CNMT: PFS0 + a SHA-256 table), romfs (Nintendo RomFS, with hostile variants), ivfc_section (7 levels), cnmt, meta_nca, control_nca,
program_nca, data_nca, manual_nca, patch_nca (a BKTR patch over a base section: a relocation table over 0x4000 blocks, an AesCtrEx table), sparse (a base section flattened from
sparse storage), compressed (CompressionInfo with a None and an LZ4 entry), snapshot (the flat folder of one content meta) and Game (base, update and DLC snapshots for nx_writer)."""
import hashlib
import random
import struct

try: import lz4.block as lz4block
except ImportError: lz4block = None

HEAD = 0xC00
PROGRAM, META, CONTROL, MANUAL, DATA, PUBLIC_DATA = range(6)   # NCA content types (header 0x205)
APPLICATION, PATCH, ADDON = 0x80, 0x81, 0x82   # content meta types
RECORD = {PROGRAM: 1, CONTROL: 3, MANUAL: 4, DATA: 2, PUBLIC_DATA: 2, META: 0}   # NCA content type → content meta record type
BLOCK = 0x4000   # bucket-tree node size of the indirect, AesCtrEx and compression tables


def sha(b): return hashlib.sha256(b).digest()
def align(x, a): return (x + a - 1) // a * a


def rand(n, seed):
    return random.Random(seed).randbytes(n)


# ---- PFS0 + SHA-256 (ExeFS, the CNMT's partition) ----
def pfs0(files):
    """{name: bytes} → a PFS0: magic, count, string-table size, reserved; 0x18-byte entries (offset from the data, size, name offset); the names, padded so the header is 0x20-aligned"""
    names = sorted(files, key=lambda n: n.encode())
    table, offs = bytearray(), []
    for n in names: offs.append(len(table)); table += n.encode() + b'\0'
    head = 0x10 + 0x18 * len(names) + len(table)
    table += bytes(align(head, 0x20) - head)
    out, data = bytearray(struct.pack('<4sIII', b'PFS0', len(names), len(table), 0)), bytearray()
    for n, o in zip(names, offs):
        out += struct.pack('<QQII', len(data), len(files[n]), o, 0); data += files[n]
    return bytes(out + table + data)


def sha256_section(data, block=0x1000):
    """(section bytes, 0xF8 hash data): the SHA-256 of each block of data (the last at its own length), data at the next 0x200; hash data = master hash, block size, 2 layers,
    hash table (offset, size), data (offset, size)"""
    n = max(1, -(-len(data) // block))
    table = b''.join(sha(data[i * block:(i + 1) * block]) for i in range(n))
    at = align(len(table), 0x200)
    sec = bytearray(align(at + len(data), 0x200))
    sec[:len(table)] = table; sec[at:at + len(data)] = data
    h = bytearray(0xF8)
    h[:0x20] = sha(table)
    struct.pack_into('<IIQQQQ', h, 0x20, block, 2, 0, len(table), at, len(data))
    return bytes(sec), bytes(h)


# ---- RomFS + IVFC ----
def _hash(parent, name):
    h = parent ^ 123456789
    for c in name: h = (((h >> 5) | (h << 27)) & 0xFFFFFFFF) ^ c
    return h


def romfs(files, *, shared=None, loop=None):
    """files: {path: bytes}, a path being 'a/b/c' or a tuple of name parts (str or bytes: a name may then hold '/', a tab, '..'). A Nintendo RomFS: 0x50-byte header, the data at 0x200,
    then the directory hash table, directory entries (parent, sibling, first child folder, first file, next in bucket, name length, name), the file hash table and file entries
    (parent, sibling, data offset, size, next in bucket, name length, name). Hostile variants: shared=(count, size) adds count files that all point at one range of size bytes;
    loop='sibling' makes the first folder its own sibling, loop='child' its own first child folder"""
    root = {'name': b'', 'dirs': {}, 'files': {}}
    for path, data in files.items():
        parts = [p.encode() if isinstance(p, str) else p for p in (path.split('/') if isinstance(path, str) else path)]
        d = root
        for x in parts[:-1]: d = d['dirs'].setdefault(x, {'name': x, 'dirs': {}, 'files': {}})
        d['files'][parts[-1]] = data
    if shared:
        blob = rand(shared[1], 5)
        for i in range(shared[0]): root['files'][f'f{i:05}'.encode()] = blob
    dirs, q = [], [root]   # breadth-first; offsets in the directory table
    while q:
        d = q.pop(0); dirs.append(d)
        q.extend(d['dirs'][k] for k in sorted(d['dirs']))
    at = 0
    for d in dirs: d['off'] = at; at += 0x18 + align(len(d['name']), 4)
    files_l, at = [], 0
    for d in dirs:
        for name in sorted(d['files']):
            f = {'name': name, 'data': d['files'][name], 'parent': d}
            f['off'] = at; at += 0x20 + align(len(name), 4); files_l.append(f)
    data, seen = bytearray(), {}
    for f in files_l:
        if shared and id(f['data']) in seen: f['at'] = seen[id(f['data'])]; continue
        f['at'] = len(data); seen[id(f['data'])] = f['at']; data += f['data'] + bytes(align(len(f['data']), 0x10) - len(f['data']))
    nb_d, nb_f = max(3, len(dirs) | 1), max(3, len(files_l) | 1)
    dh, fh = [0xFFFFFFFF] * nb_d, [0xFFFFFFFF] * nb_f
    dmeta, fmeta = bytearray(), bytearray()
    for d in dirs:
        kids = [d['dirs'][k] for k in sorted(d['dirs'])]
        for a, b in zip(kids, kids[1:]): a['sib'] = b['off']
        for k in kids: k['parent'] = d
        fl = [f for f in files_l if f['parent'] is d]
        for a, b in zip(fl, fl[1:]): a['sib'] = b['off']
        d['child'] = kids[0]['off'] if kids else 0xFFFFFFFF
        d['file'] = fl[0]['off'] if fl else 0xFFFFFFFF
    for d in dirs:
        parent = d['parent']['off'] if 'parent' in d else 0
        b = _hash(parent, d['name']) % nb_d
        nxt, dh[b] = dh[b], d['off']
        sib, child = d.get('sib', 0xFFFFFFFF), d['child']
        if loop and len(dirs) > 1 and d is dirs[1]:
            if loop == 'sibling': sib = d['off']
            else: child = d['off']
        dmeta += struct.pack('<6I', parent, sib, child, d['file'], nxt, len(d['name'])) + d['name'] + bytes(align(len(d['name']), 4) - len(d['name']))
    for f in files_l:
        b = _hash(f['parent']['off'], f['name']) % nb_f
        nxt, fh[b] = fh[b], f['off']
        fmeta += struct.pack('<IIQQII', f['parent']['off'], f.get('sib', 0xFFFFFFFF), f['at'], len(f['data']), nxt, len(f['name'])) + f['name'] + bytes(align(len(f['name']), 4) - len(f['name']))
    data_off = 0x200
    at = align(data_off + len(data), 4)
    dh_off, dm_off = at, at + 4 * nb_d
    fh_off = align(dm_off + len(dmeta), 4); fm_off = fh_off + 4 * nb_f
    out = bytearray(fm_off + len(fmeta))
    struct.pack_into('<10Q', out, 0, 0x50, dh_off, 4 * nb_d, dm_off, len(dmeta), fh_off, 4 * nb_f, fm_off, len(fmeta), data_off)
    out[data_off:data_off + len(data)] = data
    struct.pack_into(f'<{nb_d}I', out, dh_off, *dh); out[dm_off:dm_off + len(dmeta)] = dmeta
    struct.pack_into(f'<{nb_f}I', out, fh_off, *fh); out[fm_off:fm_off + len(fmeta)] = fmeta
    return bytes(out)


def ivfc_section(data, log2=14, levels=7):
    """(section bytes, 0xF8 hash data): levels - 2 hash levels over data, each block hashed padded with zeros to the block size, every level at a block boundary; hash data = IVFC,
    version 0x20000, master hash size 0x20, the level count, (offset, size, log2 block size) per stored level, the master hash (of level 0 padded to one block) at 0xC0"""
    bs = 1 << log2
    lv = [data]
    for _ in range(levels - 2):
        below = lv[0]
        lv.insert(0, b''.join(sha(below[i * bs:(i + 1) * bs].ljust(bs, b'\0')) for i in range(max(1, -(-len(below) // bs)))))
    offs, at = [], 0
    for x in lv: at = align(at, bs); offs.append(at); at += len(x)
    sec = bytearray(align(at, 0x200))
    for o, x in zip(offs, lv): sec[o:o + len(x)] = x
    h = bytearray(0xF8)
    struct.pack_into('<4sIII', h, 0, b'IVFC', 0x20000, 0x20, levels)
    for i, (o, x) in enumerate(zip(offs, lv)): struct.pack_into('<QQI', h, 0x10 + 0x18 * i, o, len(x), log2)
    h[0xC0:0xE0] = sha(lv[0].ljust(bs, b'\0'))
    return bytes(sec), bytes(h)


def ivfc_data_level(hash_data):   # (offset, size) of the IVFC data level (the last stored level)
    n = struct.unpack_from('<I', hash_data, 0xC)[0]
    return struct.unpack_from('<QQ', hash_data, 0x10 + 0x18 * (n - 2))


# ---- NCA ----
class Section:
    """One NCA section: data, fs type (0 RomFS, 1 PartitionFS), hash type (2 SHA-256, 3 IVFC), hash data, encryption type (1 none), extra(fs): edits of the FS header (patch,
    sparse or compression info) before its hash is taken"""
    def __init__(self, data, fs_type, hash_type, hash_data, enc=1, extra=None):
        self.data, self.fs_type, self.hash_type, self.hash_data, self.enc, self.extra = data, fs_type, hash_type, hash_data, enc, extra
        self.entries, self.virtual = [], b''   # a patch section's relocation entries and patched storage


def _pfs(files):
    sec, h = sha256_section(pfs0(files)); return Section(sec, 1, 2, h)


def romfs_section(files, **kw):
    sec, h = ivfc_section(romfs(files, **kw)); return Section(sec, 0, 3, h)


def nca(content_type, program_id, sections, *, marker=b'DNCA', rights_id=True, seed=1, key_gen=0x11, verify=True):
    """sections: up to 4 Section (None for an unused slot) → the NCA bytes: random signatures and key area, the marker at 0x200, distribution 0, the content type, key generation
    (0x206 and 0x220), the size, the program ID, an SDK version, a rights ID (random when rights_id), the section table (start and end in 0x200 units), each FS header (version 2)
    and its SHA-256 at 0x280"""
    at, spans = HEAD, []
    for s in sections:
        if s is None: spans.append(None); continue
        spans.append((at, align(at + len(s.data), 0x200))); at = spans[-1][1]
    b = bytearray(at)
    b[:0x200] = rand(0x200, seed)
    b[0x200:0x204] = marker
    b[0x204], b[0x205], b[0x206], b[0x207] = 0, content_type, 2, 0
    struct.pack_into('<QQII', b, 0x208, at, program_id, 0, 0x000C1100)
    b[0x220] = key_gen
    if rights_id: b[0x230:0x240] = rand(16, seed + 7)
    b[0x300:0x340] = rand(0x40, seed + 5)
    for i, (s, span) in enumerate(zip(sections, spans)):
        if s is None: continue
        struct.pack_into('<II', b, 0x240 + 16 * i, span[0] // 0x200, span[1] // 0x200)
        b[0x248 + 16 * i] = 1
        fs = bytearray(0x200)
        struct.pack_into('<HBBB', fs, 0, 2, s.fs_type, s.hash_type, s.enc)
        fs[8:8 + len(s.hash_data)] = s.hash_data
        struct.pack_into('<Q', fs, 0x140, (i + 1) << 32)
        if s.extra: s.extra(fs)
        b[0x400 + 0x200 * i:0x600 + 0x200 * i] = fs
        b[span[0]:span[0] + len(s.data)] = s.data
        rehash(b, i)
    if verify: check(bytes(b))
    return bytes(b)


def rehash(b, i):   # FS header i's SHA-256 into the header (b: a bytearray), after an edit
    b[0x280 + 32 * i:0x2A0 + 32 * i] = sha(bytes(b[0x400 + 0x200 * i:0x600 + 0x200 * i]))


def section_span(b, i):   # (start, end) bytes of section i
    s, e = struct.unpack_from('<II', b, 0x240 + 16 * i)
    return s * 0x200, e * 0x200


def check(b):
    """NXConvert's rules for a DNCA (format.md §3-4), as code: the marker, a content type 0-5, the size field = the file size, the section table (unused = 0/0; else start ≥ 0xC00,
    end > start, end ≤ the size, no overlap, at least one), each used FS header's SHA-256, its version 2 and encryption type 1. Raises AssertionError"""
    assert len(b) >= HEAD and b[0x200:0x204] == b'DNCA', 'marker'
    assert b[0x205] <= 5, 'content type'
    assert struct.unpack_from('<Q', b, 0x208)[0] == len(b), 'size field'
    used = []
    for i in range(4):
        s, e = struct.unpack_from('<II', b, 0x240 + 16 * i)
        if s == e == 0: continue
        assert s * 0x200 >= HEAD and e > s and e * 0x200 <= len(b), f'section {i} range'
        assert all(e <= a or s >= z for a, z in used), f'section {i} overlaps'
        used.append((s, e))
        fs = b[0x400 + 0x200 * i:0x600 + 0x200 * i]
        assert sha(fs) == b[0x280 + 32 * i:0x2A0 + 32 * i], f'FS header {i} hash'
        assert struct.unpack_from('<H', fs)[0] == 2 and fs[4] == 1, f'FS header {i} version or encryption'
    assert used, 'no section'


# ---- content meta ----
def cnmt(kind, tid, version, records, other=0, platform=0):
    """A content meta: 0x20-byte header (title ID, version, type, platform at 0x0D, extended header size, content count, meta count, 0 at 0x1C), the extended header of its kind
    (Application: patch ID; Patch: application ID, then the size of its extended data; AddOnContent: application ID), 0x38-byte content records (hash, content ID, 6-byte size, type,
    ID offset), a Patch's extended data (counts, all zero) and the digest. records: [(content ID, size, record type, ID offset)]"""
    ext = struct.pack('<QIIQ', other, 0, 0x1C, 0) if kind == PATCH else struct.pack('<QII', other, 0, 0)
    b = bytearray(struct.pack('<QIBBHHHBBBBII', tid, version, kind, platform, len(ext), len(records), 0, 0, 0, 0, 0, 0, 0)) + ext
    for cid, size, rtype, idoff in records:
        b += rand(32, size) + cid + struct.pack('<IHBB', size & 0xFFFFFFFF, size >> 32, rtype, idoff)
    if kind == PATCH: b += bytes(0x1C)
    return bytes(b + bytes(32))


def meta_nca(kind, tid, version, records, other=0, platform=0, seed=11):
    name = {APPLICATION: 'Application', PATCH: 'Patch', ADDON: 'AddOnContent'}[kind]
    return nca(META, tid, [_pfs({f'{name}_{tid:016x}.cnmt': cnmt(kind, tid, version, records, other, platform)})], seed=seed)


def nacp(name, display):
    b = bytearray(0x4000)
    b[:len(name)] = name.encode(); b[0x3060:0x3060 + len(display)] = display.encode()
    return bytes(b)


def control_nca(pid, name='Test Game', display='1.0.0', icon=b'\xff\xd8\xff icon', nacp_bytes=None, seed=21):
    files = {'control.nacp': nacp_bytes if nacp_bytes is not None else nacp(name, display)}
    if icon is not None: files['icon_AmericanEnglish.dat'] = icon
    return nca(CONTROL, pid, [romfs_section(files)], seed=seed)


def nso(build_id, seed=3, size=0x800):
    b = bytearray(rand(size, seed)); b[:4] = b'NSO0'; b[0x40:0x60] = build_id.ljust(32, b'\0')
    return bytes(b)


def npdm(tid):
    d = bytearray(0x100)
    d[:4] = b'META'
    struct.pack_into('<II', d, 0x70, 0x80, 0x20)
    d[0x80:0x84] = b'ACI0'
    struct.pack_into('<Q', d, 0x90, tid)
    return bytes(d)


def exefs(pid, build_id, seed=3):
    return {'main': nso(build_id, seed), 'main.npdm': npdm(pid), 'subsdk0': nso(b'\x5a' * 16, seed + 1)}


class Built:   # an NCA's bytes and its data section (for a patch over it, or a sparse copy) and that section's index
    def __init__(self, data, section, index):
        self.data, self.section, self.index = data, section, index


def program_nca(pid, exefs_files, romfs_files, *, compress=False, seed=31, sparse_patch=None):
    """A Program NCA: section 0 the ExeFS (PFS0 + SHA-256), section 1 the RomFS (IVFC; None: no RomFS section). compress: the RomFS data level kept compressed (CompressionInfo:
    a None and an LZ4 entry). sparse_patch: a base flattened from sparse storage, with only the ranges that patch section reads from it (see sparse())"""
    secs = [_pfs(exefs_files)]
    rom = None
    if romfs_files is not None:
        if compress: rom = compressed(romfs(romfs_files))
        else: rom = romfs_section(romfs_files)
        if sparse_patch is not None: rom = sparse(rom, sparse_patch)
        secs.append(rom)
    return Built(nca(PROGRAM, pid, secs, seed=seed), rom, 1)


def data_nca(tid, files, content_type=PUBLIC_DATA, seed=41):
    s = romfs_section(files); return Built(nca(content_type, tid, [s], seed=seed), s, 0)


def manual_nca(pid, files, seed=51):
    s = romfs_section(files); return Built(nca(MANUAL, pid, [s], seed=seed), s, 0)


# ---- patches (BKTR), sparse and compressed sections ----
def bucket_tree(entries, end):
    """One entry set: a node (header: index 0, 1 set, end offset; the set's start offset 0) and the set (header: index 0, entry count, end offset; the entries), BLOCK bytes each"""
    node = bytearray(BLOCK); struct.pack_into('<iiqq', node, 0, 0, 1, end, 0)
    es = bytearray(BLOCK); struct.pack_into('<iiq', es, 0, 0, len(entries), end)
    at = 16
    for e in entries: es[at:at + len(e)] = e; at += len(e)
    assert at <= BLOCK
    return bytes(node + es)


def bktr(count): return struct.pack('<4sIII', b'BKTR', 1, count, 0)


def relocations(virtual, base):
    """Relocation entries (virtual, physical, storage) over BLOCK-sized blocks of virtual: storage 0 (the base section) where the block's bytes are there, else 1 (the patch data,
    appended); runs merged. Returns (entries, patch data)"""
    out, data = [], bytearray()
    for v in range(0, len(virtual), BLOCK):
        blk = virtual[v:v + BLOCK]
        hit = base.find(blk) if len(blk) == BLOCK and any(blk) else -1
        e = (v, hit, 0) if hit >= 0 else (v, len(data), 1)
        if hit < 0: data += blk
        if out and out[-1][2] == e[2] and e[1] - out[-1][1] == v - out[-1][0]: continue
        out.append(e)
    return out, bytes(data)


def patch_section(base, new_files, aesctrex='table'):
    """A BKTR patch section over base (a Section): the new RomFS's IVFC storage V as relocation entries from base or from the patch data; the relocation table at the next BLOCK
    after the data, an AesCtrEx table after it (aesctrex: 'table' one entry, 'zero' zeroed, 'junk' random bytes); FS header 0x100-0x13F set; hash data = V's IVFC"""
    virtual, h = ivfc_section(romfs(new_files))
    ents, data = relocations(virtual, base.data)
    rel_at = align(len(data), BLOCK)
    rel = bucket_tree([struct.pack('<qqi', *e) for e in ents], len(virtual))
    enc_at = rel_at + len(rel)
    enc = bucket_tree([struct.pack('<qii', 0, 0, 1)], rel_at)
    if aesctrex == 'zero': enc = bytes(len(enc))
    elif aesctrex == 'junk': enc = rand(len(enc), 77)
    sec = bytearray(enc_at + len(enc))
    sec[:len(data)] = data; sec[rel_at:rel_at + len(rel)] = rel; sec[enc_at:] = enc
    def extra(fs):
        struct.pack_into('<qq', fs, 0x100, rel_at, len(rel)); fs[0x110:0x120] = bktr(len(ents))
        struct.pack_into('<qq', fs, 0x120, enc_at, len(enc)); fs[0x130:0x140] = bktr(1)
    s = Section(bytes(sec), 0, 3, h, extra=extra); s.entries = ents; s.virtual = virtual
    return s


def patch_nca(content_type, pid, base, new_files, exefs_files=None, aesctrex='table', seed=61):
    """A patch NCA over base (a Built): its data section (index base.index) a BKTR patch of base's, a Program's ExeFS whole in section 0"""
    p = patch_section(base.section, new_files, aesctrex)
    secs = [None] * (base.index + 1)
    secs[base.index] = p
    if exefs_files is not None: secs[0] = _pfs(exefs_files)
    return Built(nca(content_type, pid, secs, seed=seed), p, base.index)


def sparse(section, patch):
    """section (a base RomFS Section) flattened from sparse storage: every byte that no storage-0 relocation entry of patch (a patch Section) reads is zero (the holes), SparseInfo
    set (generation 1) and DSPF at FS header 0x1D0, as the decrypter leaves it"""
    data, ents = bytearray(len(section.data)), patch.entries
    for k, (v, p, s) in enumerate(ents):
        n = (ents[k + 1][0] if k + 1 < len(ents) else len(patch.virtual)) - v
        if s == 0: data[p:p + n] = section.data[p:p + n]
    data = bytes(data)
    def extra(fs):
        struct.pack_into('<qq', fs, 0x148, 0x4000, 0x8000); fs[0x158:0x168] = bktr(1)
        struct.pack_into('<qH', fs, 0x168, 0xC00, 1)
        fs[0x1D0:0x1D4] = b'DSPF'
    return Section(data, section.fs_type, section.hash_type, section.hash_data, extra=extra)


def compressed(plain):
    """An IVFC section whose data level holds plain compressed: the first half raw (a None entry), the rest one LZ4 block, then the compression table at the next BLOCK;
    CompressionInfo at FS header 0x178"""
    half = align(len(plain) // 2, 0x10)
    if lz4block is None: raise RuntimeError('lz4 is needed for a compressed section')
    lz = lz4block.compress(plain[half:], store_size=False)
    at = align(half + len(lz), BLOCK)
    table = bucket_tree([struct.pack('<qqBbxxI', 0, 0, 0, 0, half), struct.pack('<qqBbxxI', half, half, 3, 0, len(lz))], len(plain))
    level = bytearray(at + len(table))
    level[:half] = plain[:half]; level[half:half + len(lz)] = lz; level[at:] = table
    sec, h = ivfc_section(bytes(level))
    def extra(fs):
        struct.pack_into('<qq', fs, 0x178, at, len(table)); fs[0x188:0x198] = bktr(2)
    return Section(sec, 0, 3, h, extra=extra)


# ---- snapshots and games ----
def content_id(b): return sha(b)[:16]


def snapshot(kind, tid, version, ncas, other=0, platform=0, id_offsets=None, seed=11):
    """The flat folder of one content meta: {'<id>.nca': bytes} for ncas (bytes or Built) and '<meta id>.cnmt.nca' listing them. Returns (files, meta content ID)"""
    files, recs = {}, []
    for k, x in enumerate(ncas):
        b = x.data if isinstance(x, Built) else x
        cid = content_id(b)
        files[cid.hex() + '.nca'] = b
        recs.append((cid, len(b), RECORD[b[0x205]], (id_offsets or {}).get(k, 0)))
    m = meta_nca(kind, tid, version, recs, other, platform, seed=seed)
    mid = content_id(m)
    files[mid.hex() + '.cnmt.nca'] = m
    return files, mid


class Game:
    """A game as nxconvert pack leaves it: base, update (its own NCAs and every base file) and DLC snapshots. Attributes: the trees, the content IDs, what each version holds
    (exefs / romfs files, control) for the tests to compare. Options: manual (an HtmlDocument NCA in the base, patched in the update), sparse (the base RomFS flattened sparse),
    compress (the base RomFS compressed; no update), aesctrex ('table', 'zero' or 'junk'), program2 (a second program in the base, ID offset 1), no_update"""
    def __init__(self, app, version=0x70000, *, manual=False, sparse_base=False, compress=False, aesctrex='table', program2=False, dlc=True):
        self.app, self.version = app, version
        self.bid0, self.bid1 = bytes(range(1, 17)) + bytes(16), bytes(range(0x81, 0x91)) + bytes(16)
        same = rand(0x30000, 11)
        self.exefs0, self.exefs1 = exefs(app, self.bid0, 3), exefs(app, self.bid1, 4)
        self.romfs0 = {'data/same.bin': same, 'data/changed.txt': b'old version', 'base_only.bin': rand(0x9000, 12), 'empty': b''}
        self.romfs1 = {'data/same.bin': same, 'data/changed.txt': b'new version 1.2.0', 'new/added.bin': rand(0x14000, 13), 'empty': b''}
        self.html0, self.html1 = {'index.html': b'<p>manual one</p>' + rand(0x6000, 14)}, {'index.html': b'<p>manual two</p>' + rand(0x6000, 14)}
        base_prog = program_nca(app, self.exefs0, self.romfs0, compress=compress)
        upd_prog = patch_nca(PROGRAM, app, base_prog, self.romfs1, self.exefs1, aesctrex)   # compress: made, not packed (a base game alone)
        if sparse_base: base_prog = program_nca(app, self.exefs0, self.romfs0, sparse_patch=upd_prog.section)
        self.base_prog, self.upd_prog = base_prog, upd_prog
        ctrl0, ctrl1 = control_nca(app, 'Test Game', '1.0.0', b'\xff\xd8\xff icon 0', seed=21), control_nca(app, 'Test Game', '1.2.0', b'\xff\xd8\xff icon 1', seed=22)
        base_ncas, offsets = [base_prog, ctrl0], {}
        if manual:
            man0 = manual_nca(app, self.html0); base_ncas.append(man0)
        if program2:
            self.exefs2 = exefs(app + 1, bytes(range(0x41, 0x51)), 5)
            base_ncas += [program_nca(app + 1, self.exefs2, {'second.bin': b'second program'}, seed=33), control_nca(app + 1, 'Second', '1.0.0', seed=23)]
            offsets = {len(base_ncas) - 2: 1, len(base_ncas) - 1: 1}
        self.base, self.base_id = snapshot(APPLICATION, app, 0, base_ncas, other=app | 0x800, id_offsets=offsets, seed=12)
        self.update = {}
        if not compress:
            upd_ncas = [upd_prog, ctrl1]
            if manual: upd_ncas.append(patch_nca(MANUAL, app, man0, self.html1, seed=62))
            own, self.update_id = snapshot(PATCH, app | 0x800, version, upd_ncas, other=app, seed=13)
            self.update = dict(self.base, **own)
        self.dlc = {}
        if dlc:
            self.dlc_tid = app + 0x1001
            self.dlc_files = {'dlcfile': b'dlc content', 'more/x.bin': rand(0x2000, 15)}
            self.dlc, self.dlc_id = snapshot(ADDON, self.dlc_tid, 0, [data_nca(self.dlc_tid, self.dlc_files)], other=app, seed=14)

    def snapshots(self, meta=None, base_build=True):
        """The snapshot rows for nx_writer.write (the base, the update, the DLC); meta: the base's NX Media metadata"""
        rows = [{'type': 0, 'version': 0, 'tree': self.base, 'content_id': self.base_id, **({'build_id': self.bid0} if base_build else {}), **({'meta': meta} if meta else {})}]
        if self.update: rows.append({'type': 1, 'version': self.version, 'tree': self.update, 'content_id': self.update_id, 'build_id': self.bid1, 'display': '1.2.0'})
        if self.dlc: rows.append({'type': 2, 'version': 0, 'tree': self.dlc, 'content_id': self.dlc_id})
        return rows


def folder(path, files):   # a snapshot's files written into a folder (the staging layout nx_extract --plain reads)
    path.mkdir(parents=True, exist_ok=True)
    for name, b in files.items(): (path / name).write_bytes(b)
    return path
