#!/usr/bin/env python3
# A game in a NUP container (one .nup file: https://github.com/a55uka/nup, SPEC.md v1) → the layout build_ipa_from_nsp.py extracts NSPs into. build_ipa_from_nsp.py calls this when it is given
# a .nup file, or a folder that holds one, and goes on with its other steps; run on its own, this script does only this step.
# A NUP holds the same packages as a dump folder (scripts/pack_dump.py): the base game, updates by version and DLC by title ID, each an exefs/ and romfs/ tree, its files stored raw or as one zstd
# frame each, with a SHA-256 per file. Its files are not encrypted, so it needs no keys. Unlike a dump it may carry control data in each package's meta block: the NACP and the icon. Its name,
# publisher and display version records are labels typed when the NUP was packed (Hyrule Warriors: Age of Imprisonment's says "HWAoI"), not the console's: without a NACP the name comes from the profile.
# A container may hold no base game, in two forms that mean the same: no base record, with standalone_update on every update (SPEC §3.1.2), or a base record with no files (title ID 0), as a NUP is
# packed when an update holds the whole game (Pokemon Pokopia's v655360). The title ID is then the program ID of the code present, there is no version 0, and the selected update needs its own ExeFS
# and RomFS, taken as the whole game. The flag does not promise that (the spec says such an update needs a matching base elsewhere), and nothing in a container can prove it, so the scripts say so
# (NO_BASE). What was measured: the update RomFS of both NUPs at hand holds every path of its base (Hyrule Warriors: Age of Imprisonment, Yoshi and the Mysterious Book).
# A NUP may hold code of several programs of one application (dm/tools/programs.py), base and update packages per program, told apart by the program ID each one's exefs/main.npdm
# names: a Nintendo Switch 2 Edition's update holds the Switch 1 game as program 0 and the Switch 2 one as program 1, whose title ID starts 04 (Xenoblade Chronicles X: Definitive Edition).
# One program is packed, under its own program ID (the profile's and the build folder's): --program N, else the Switch 2 Edition's Switch 2 program, else program 0; a program with no
# base package of its own is packed from its update alone, which carries it whole. No such NUP was at hand when this was written: --list prints each package and the program it names.
# A program other than the application's own (program 0) is read and chosen the same way, but not packed yet: the script stops with a red line that says so (programs.unsupported).
# Writes, under the build folder (<folder of the .nup>/<title ID>_build unless --work-dir names another):
#   extract/v<version>/ExeFS/   the version's code modules
#   extract/v<version>/RomFS.img   its RomFS as one image (dm/tools/romfs_image.py), written straight from the container: the RomFS is never unpacked into loose files
#   extract/v<version>/control.nacp, icon.jpg   the package's NACP and its icon, when it carries them (sips reads a PNG icon by its content). A NACP record that is not 0x4000 bytes is
#     no NACP: it is left out, with a line. Since its PR #20 (2026-11-04) nup writes every meta type one too low (NPDM 0 … localized icons 9); such a block is read one type up, with a
#     line. It is told apart by where its NACP (0x4000 bytes) or icon (a JPEG or PNG) is, at type 1 or 2 (shifted) or at 2 or 3 (SPEC §5's), and when the records cannot tell, as nup's
#     PR #32 tells it (a record of type 0, or one of type 7 that is not 32 bytes). A block of an older nup, in SPEC §5's numbers, is read as it is.
#   An NX's title.txt and icon.edited.jpg (scripts/pack_nx.py) left in the folder by an earlier build from an NX are removed: a NUP's name and icon are its NACP's and icon's
#   aoc/<index>.img   each DLC's RomFS (index = DLC title ID − base title ID − 0x1000), the host's DM_AOC_DIR
# An update's RomFS is packed on its own, never laid over the base: the dumps NUPs are packed from hold the patched RomFS of an update (pack_dump.py); an update with no romfs/ uses the base's.
# Every file read is checked against its SHA-256. A repeat run keeps code modules whose content is the same and an image made from the same container tree by the same packer,
# or, after a packer update, an image whose bytes check against the container's hashes.
# Needs the zstd module: compression.zstd (Python 3.14+) or backports.zstd, as the NSP script.
# Usage: pack_nup.py <game.nup> [--version N] [--program N] [--work-dir DIR] [--list]   (exit 1 on error)
import argparse, hashlib, mmap, os, shutil, struct, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm/tools'))
import romfs_image
import programs   # the programs of an application: which one a NUP holding several packs, and its DLC numbering
try: from compression import zstd
except ImportError:
    try: from backports import zstd   # pyright: ignore[reportMissingImports]  # an optional package, only Python before 3.14 needs it
    except ImportError: zstd = None


class Error(Exception): pass


SUPER = struct.Struct('<4sHHQQ32sQQII16s32s')   # 0x80
TOC = struct.Struct('<4sIQQQQQ')   # 0x30
PKG = struct.Struct('<QIIIIBBHIQI20x')   # 0x40
DIR = struct.Struct('<IIIIQ')   # 0x18
FILE = struct.Struct('<IIQQQ32sBBH12x')   # 0x50
TLV = struct.Struct('<HHI')
NO_DIR = 0xFFFFFFFF
BASE, UPDATE, ADDON = 0, 1, 2
KINDS = ('base', 'update', 'addon', 'addon_update', 'system')
STANDALONE = 1   # package flags bit 0: an update in a container without a base
T_NACP, T_ICON, T_BUILD_ID, T_LICONS = 2, 3, 7, 10   # SPEC §5's numbers
TITLE_FILE, EDITED_ICON = 'title.txt', 'icon.edited.jpg'   # beside an NX version's control data (scripts/pack_nx.py): its display title without a NACP, an icon edited in NXConvert
NACP_SIZE = 0x4000   # every NACP's size: a record of another size is something else
SHIFTED = 'its meta block numbers every record one too low (written by nup after its PR #20 of 2026-11-04): read one type up, so its NACP and icon are the right records'
ARTIFACTS = {b'.listing'}   # dump-tool files a producer may have kept (SPEC §6.3): not game files
ADDED = 'its update is taken as the whole program (an update that adds a program, as a Nintendo Switch 2 Edition\'s, carries it whole, not as a patch)'
NO_BASE = 'no base game in this NUP: its update is taken as the whole game (if the game then stops on missing files, the update holds only what changed: pack a NUP with the base game)'


class Package:
    def __init__(self, nup, index, rec):
        self.nup, self.index = nup, index
        self.title_id, self.root, self.exefs, self.romfs, self.version, self.kind, self.flags, r1, r2, self.meta_off, self.meta_size = rec
        if self.kind >= len(KINDS): raise Error(f'{nup.path}: package {index} of unknown kind {self.kind}')
        if r1 or r2 or self.flags & ~STANDALONE: raise Error(f'{nup.path}: package {index} has reserved fields or flags set')
        self.shifted = self.marked = False   # set by meta()
        self.name = f'{nup.path.name} ({KINDS[self.kind]}' + (f' {self.version}' if self.kind == UPDATE else f' {self.title_id:016X}' if self.kind == ADDON else '') + ')'   # what pick_nsps prints
        self.label = self.name   # the name before scan adds the program of a NUP that holds several

    def meta(self):
        """{TLV type in SPEC §5's numbers: payload}, the first record of each type. nup since its PR #20 (merged 2026-11-04) writes every type one too low (NPDM 0, NACP 1, icon 2 …
        localized icons 9): every type of such a block is read one up, and self.shifted says so (shifted() tells such a block).
        self.marked: the block has what nup's PR #32 tells a shifted block by but its records say otherwise (a line says it is read as it is)"""
        recs, b = [], self.nup.mm[self.meta_off:self.meta_off + self.meta_size] if self.meta_size else b''
        p = 0
        while p + TLV.size <= len(b):
            t, _, n = TLV.unpack_from(b, p); p += TLV.size
            if p + n > len(b): raise Error(f'{self.nup.path}: package {self.index}: meta record {t:#x} runs past its block')
            recs.append((t, bytes(b[p:p + n]))); p += n
        self.shifted, self.marked = shifted(recs)
        out = {}
        for t, v in recs: out.setdefault(t + 1 if self.shifted else t, v)
        return out


def nacp_like(v): return v is not None and len(v) == NACP_SIZE and v[:4] != b'META' and not image(v)   # a NACP's size (an NPDM of that size starts META; an icon may be as big)
def image(v): return v is not None and (v[:2] == b'\xff\xd8' or v[:4] == b'\x89PNG')   # a JPEG's start of image, or PNG's signature


def shifted(recs):
    """(shifted, marked) for a meta block's records [(type, payload)]. nup's PR #32 tells a shifted block by a record of type 0, which SPEC §5 does not register (a shifted NPDM), or one of
    type 7 that is not 32 bytes (SPEC's build ID is 32; a shifted block keeps the source name there). That rule misses a shifted block with neither (an update or DLC with no NPDM or source
    name) and takes a SPEC block with either (a packer's own type 0, a build ID of another length) as shifted, so what the records hold decides first: the NACP (0x4000 bytes) at type 1, the
    shifted place, or at 2, SPEC's; else the icon (a JPEG or PNG) at 2 or at 3. Only when they are at both places or neither does the rule decide. marked: the rule says shifted, the records not"""
    first = {}
    for t, v in recs: first.setdefault(t, v)
    rule = any(t == 0 or t == T_BUILD_ID and len(v) != 32 for t, v in recs)
    for test, at in ((nacp_like, T_NACP), (image, T_ICON)):
        low, spec = test(first.get(at - 1)), test(first.get(at))
        if low != spec: return low, rule and not low
    return rule, False


class Nup:
    """A validated NUP (SPEC §6.1): the superblock, the TOC's SHA-256, every record's bounds. File content is checked against its SHA-256 as it is read"""
    def __init__(self, path):
        self.path = Path(path)
        self.programs: dict[int, int] = {}   # what scan sets: {index: program ID} of the programs it holds code of, the index packed, the lines to print, the line for no base package
        self.program: int | None = None
        self.notes: list[str] = []
        self.no_base = ''
        with open(self.path, 'rb') as f:   # the map keeps its own descriptor
            try: self.mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
            except ValueError: raise Error(f'{self.path}: empty file') from None
        try: self._read()
        except BaseException:
            self.close(); raise

    def _read(self):
        if len(self.mm) < SUPER.size: raise Error(f'{self.path}: not a NUP (too short)')
        magic, hsize, _, toc_off, toc_size, toc_sha, self.blob, fsize, npkg, flags, self.uuid, _ = SUPER.unpack_from(self.mm)
        if magic[:3] != b'NUP': raise Error(f'{self.path}: not a NUP')
        if magic[3] != 1: raise Error(f'{self.path}: NUP format version {magic[3]}; this reads version 1')
        if hsize < SUPER.size or toc_off != hsize or flags: raise Error(f'{self.path}: unsupported NUP header')
        if fsize != len(self.mm): raise Error(f'{self.path}: {len(self.mm):,} bytes, its header says {fsize:,} (copied partly? copy it again, or pack it again from your own dump)')
        if self.blob < toc_off + toc_size or self.blob % 16 or self.blob > fsize: raise Error(f'{self.path}: TOC and data regions overlap')
        toc = self.mm[toc_off:toc_off + toc_size]
        self.toc_sha = toc_sha
        if hashlib.sha256(toc).digest() != toc_sha: raise Error(f'{self.path}: table of contents does not match its SHA-256 (damaged file)')
        tmagic, tpkg, self.ndirs, nfiles, pool_off, pool_size, _ = TOC.unpack_from(toc)
        need = TOC.size + tpkg * PKG.size + self.ndirs * DIR.size + nfiles * FILE.size
        if tmagic != b'TOC\x01' or tpkg != npkg or not npkg or len(toc) < need or pool_off < need or pool_off + pool_size > len(toc) or (pool_off - need) % 4:
            raise Error(f'{self.path}: malformed table of contents')
        pool = toc[pool_off:pool_off + pool_size]
        def name(off, n):
            if off + n > len(pool): raise Error(f'{self.path}: name out of bounds')
            return pool[off:off + n]
        p = TOC.size
        self.packages = [Package(self, i, PKG.unpack_from(toc, p + i * PKG.size)) for i in range(npkg)]; p += npkg * PKG.size
        self.dirs = []   # (name, first child slot, child count)
        for _ in range(self.ndirs):
            o, n, first, count, _ = DIR.unpack_from(toc, p); p += DIR.size
            self.dirs.append((name(o, n), first, count))
        self.files = []   # (name, size, sha256, extent offset, extent size, codec)
        for _ in range(nfiles):
            o, n, size, eoff, esz, sha, codec, cflags, _ = FILE.unpack_from(toc, p); p += FILE.size
            if codec not in (0, 1) or cflags: raise Error(f'{self.path}: file {name(o, n)!r} uses codec {codec}; this reads raw and zstd')
            if size and (eoff < self.blob or eoff + esz > fsize or eoff % 16 or not esz or codec == 0 and esz != size): raise Error(f'{self.path}: file {name(o, n)!r} out of bounds')
            if not size and (eoff or esz or codec): raise Error(f'{self.path}: empty file {name(o, n)!r} with data')
            self.files.append((name(o, n), size, sha, eoff, esz, codec))
        self.slots = struct.unpack_from(f'<{(pool_off - p) // 4}I', toc, p)
        for n, first, count in self.dirs:
            if first + count > len(self.slots): raise Error(f'{self.path}: folder {n!r} out of bounds')
        for s in self.slots:
            if s >= self.ndirs + nfiles: raise Error(f'{self.path}: child {s} out of bounds')
        self._acyclic()
        for k in self.packages:
            if k.root >= self.ndirs or any(d != NO_DIR and d >= self.ndirs for d in (k.exefs, k.romfs)) or k.meta_size and k.meta_off + k.meta_size > fsize:
                raise Error(f'{self.path}: package {k.index} out of bounds')

    def _acyclic(self):
        """Refuses a folder that contains itself, at any depth: the bounds checks pass it, and every walk of the tree (tree_bytes, entries) would recurse or loop for ever"""
        kids = [[s for s in self.slots[first:first + count] if s < self.ndirs] for _, first, count in self.dirs]
        state = bytearray(self.ndirs)   # 0 not seen, 1 on the current path, 2 done
        for top in range(self.ndirs):
            if state[top]: continue
            state[top], stack = 1, [(top, 0)]
            while stack:   # depth first without recursion: a container's depth is not bounded by Python's recursion limit
                d, i = stack[-1]
                if i == len(kids[d]): state[d] = 2; stack.pop(); continue
                stack[-1] = (d, i + 1); c = kids[d][i]
                if state[c] == 1: raise Error(f'{self.path}: folder {self.dirs[c][0]!r} (index {c}) contains itself (damaged file)')
                if not state[c]: state[c] = 1; stack.append((c, 0))

    def close(self):
        self.mm.close()

    def __enter__(self): return self
    def __exit__(self, *a): self.close()

    def children(self, d):   # [(name, is dir, index into dirs or files)], sorted by name (bytes), artifacts left out
        _, first, count = self.dirs[d]
        out = []
        for s in self.slots[first:first + count]:
            if s < self.ndirs: out.append((self.dirs[s][0], True, s))
            elif self.files[s - self.ndirs][0] not in ARTIFACTS: out.append((self.files[s - self.ndirs][0], False, s - self.ndirs))
        return sorted(out)

    def child(self, d, name):   # the index of a file in folder d, or None
        return next((i for n, isdir, i in self.children(d) if n == name and not isdir), None)

    def size(self, i): return self.files[i][1]
    def sha(self, i): return self.files[i][2]

    def tree_bytes(self, d):   # the uncompressed size of everything under folder d
        return sum(self.files[i][1] if not isdir else self.tree_bytes(i) for _, isdir, i in self.children(d))

    def copy(self, i, out):
        """File i's content to out (anything with write), streamed and checked against its size and SHA-256; returns its size"""
        name, size, sha, eoff, esz, codec = self.files[i]
        h, n, view = hashlib.sha256(), 0, memoryview(self.mm)
        def put(b):
            nonlocal n
            h.update(b); out.write(b); n += len(b)
        if codec == 0:
            for p in range(eoff, eoff + esz, 8 << 20): put(view[p:min(p + (8 << 20), eoff + esz)])
        elif size:
            if zstd is None: raise Error('reading a NUP needs the zstd module: compression.zstd (Python 3.14+) or pip install backports.zstd')
            d = zstd.ZstdDecompressor()
            try:
                for p in range(eoff, eoff + esz, 4 << 20):
                    put(d.decompress(view[p:min(p + (4 << 20), eoff + esz)]))
                    if n > size: break
            except zstd.ZstdError as e: raise Error(f'{self.path}: {name.decode(errors="replace")}: {e}') from e
            if not d.eof: n = -1
        view.release()
        if n != size or h.digest() != sha: raise Error(f'{self.path}: {name.decode(errors="replace")} does not match its size or SHA-256 (damaged file)')
        return n

    def read(self, i):
        class Buf(bytearray):
            write = bytearray.extend
        b = Buf(); self.copy(i, b); return bytes(b)

    def head(self, i, n=32):   # file i's first n bytes (fewer for a shorter file), for a survey's RomFS manifest; not checked against the SHA-256, which covers the whole file
        name, size, sha, eoff, esz, codec = self.files[i]
        if codec == 0 or not size: return bytes(self.mm[eoff:eoff + min(n, size)])
        if zstd is None: raise Error('reading a NUP needs the zstd module: compression.zstd (Python 3.14+) or pip install backports.zstd')
        d, out, p = zstd.ZstdDecompressor(), b'', eoff
        try:
            while len(out) < min(n, size) and p < eoff + esz and not d.eof:
                out += d.decompress(self.mm[p:min(p + (64 << 10), eoff + esz)], max_length=n - len(out)); p += 64 << 10
                while len(out) < min(n, size) and not d.needs_input and not d.eof: out += d.decompress(b'', max_length=n - len(out))
        except zstd.ZstdError as e: raise Error(f'{self.path}: {name.decode(errors="replace")}: {e}') from e
        return out[:n]


def program_id(npdm, where):   # the ACI0 program ID of an NPDM; a short or cut NPDM is an Error, not a struct.error
    if npdm[:4] != b'META' or len(npdm) < 0x78: raise Error(f'{where}: not an NPDM ({len(npdm):,} bytes)')
    off, size = struct.unpack_from('<II', npdm, 0x70)
    if npdm[off:off + 4] != b'ACI0' or size < 0x18 or off + 0x18 > len(npdm): raise Error(f'{where}: no ACI0 section')
    return struct.unpack_from('<Q', npdm, off + 0x10)[0]


def is_nup(path):
    try:
        with open(path, 'rb') as f: return f.read(3) == b'NUP'
    except OSError: return False


def scan(n, program=None, known=None, dev=None):
    """What a NUP holds: (title ID, base package or None, {update version: package}, {DLC title ID: package}), with the checks pack_dump.scan makes.
    A NUP may hold code of several programs of one application (dm/tools/programs.py), a package per program and version: a Nintendo Switch 2 Edition's update carries the Switch 1
    game as program 0 and the Switch 2 one as program 1. One program is packed, and its own program ID is the title ID: program (an index), else programs.pick's choice
    (known(title ID): whether that program has a game profile). Each package is the program's its exefs/main.npdm names; one without code is the program its record's title ID names,
    else the lowest. Sets n.programs ({index: program ID}), n.program (the index packed), n.notes (lines to print) and n.no_base (the line for a program with no base package).
    A program other than program 0 stops the scan (gate) unless dev, or NX18_DEV with dev None, lets it through: programs.supported"""
    bases = [k for k in n.packages if k.kind == BASE]
    updates = [k for k in n.packages if k.kind == UPDATE]
    if not bases and (not updates or any(not k.flags & STANDALONE for k in updates)):
        raise Error(f'{n.path}: no base game: pack the base game and its update into one NUP, or use updates marked standalone_update with complete exefs/ and romfs/')
    # With no base the game is identified from the code actually present; each selected version is checked by pack_version.
    pid = {k.index: program_id(n.read(i), f'{k.name} exefs/main.npdm') for k in bases + updates if k.exefs != NO_DIR and (i := n.child(k.exefs, b'main.npdm')) is not None}
    ids = set(pid.values())
    if not ids: raise Error(f'{n.path}: no exefs/main.npdm in the base or updates')
    progs = {}   # {index: program ID}
    for x in sorted(ids):
        if (i := programs.index(x)) is None: raise Error(f'{n.path}: program ID {x:016X} is not a base title ID nor a program of one')
        progs[i] = x
    if len(progs) != len(ids) or len({programs.application(x) for x in ids}) != 1:
        raise Error(f'{n.path}: base and updates have different program IDs: ' + ', '.join(f'{x:016X}' for x in sorted(ids)))
    by_id = {x: i for i, x in progs.items()}
    def owner(k):   # the program index of a base or update package
        if k.index in pid: return by_id[pid[k.index]]
        return by_id.get(k.title_id, by_id.get(k.title_id & ~0x800, min(progs)))   # an update record may carry the update's ID (…800)
    per = {i: ([], {}) for i in progs}
    for k in bases + updates:
        b, vers = per[owner(k)]
        if k.kind == BASE: b.append(k); continue
        if not k.version: raise Error(f'{n.path}: an update of version 0')
        if k.version in vers: raise Error(f'{n.path}: two updates of version {k.version}' + (f' of program {owner(k)}' if len(progs) > 1 else ''))
        vers[k.version] = k
    for i, (b, _) in per.items():
        if len(b) > 1: raise Error(f'{n.path}: {len(b)} base packages' + (f' of program {i}' if len(progs) > 1 else ''))
    i, why = programs.pick(progs, program, known)
    if i is None: raise Error(f'{n.path}: no program {program} (--program / PROGRAM_INDEX): it holds programs {programs.listing(progs)}')
    app, (b, vers) = progs[i], per[i]
    if len(progs) > 1:
        for k in bases + updates: k.name = k.label[:-1] + f', program {owner(k)})'   # two packages of one version: what pick_nsps prints tells them apart
    base = b[0] if b and n.tree_bytes(b[0].root) else None   # a base record with no files is no base game
    n.programs, n.program = progs, i
    n.notes = [line] if (line := programs.note(n.path.name, progs, i, why)) else []
    n.no_base = NO_BASE if not any(n.tree_bytes(k.root) for k in bases) else f'program {i} has no base package of its own: {ADDED}'
    gate(n, app, dev)
    dlc = {}
    for k in n.packages:
        if k.kind == ADDON:
            if programs.dlc_index(k.title_id, app) is None: raise Error(f'{n.path}: {k.title_id:016X} is not a DLC of {app:016X}')
            if k.romfs == NO_DIR: raise Error(f'{n.path}: DLC {k.title_id:016X} has no romfs/')
            if k.title_id in dlc: raise Error(f'{n.path}: DLC {k.title_id:016X} more than once')
            dlc[k.title_id] = k
    return app, base, vers, dlc


def exefs(n, k, dst):   # the package's ExeFS into dst, kept as it is when every file there has the same content
    files = []
    for name, isdir, i in n.children(k.exefs):
        if isdir: continue
        # NUP names are labels (§6.1). Validate them before using them as host paths.
        filename = os.fsdecode(name)
        if filename in ('', '.', '..') or '\0' in filename or Path(filename).name != filename:
            raise Error(f'{n.path}: invalid ExeFS name {name!r}')
        if not name.startswith(b'.'): files.append((name, i))
    def same():
        if not dst.is_dir() or {os.fsencode(p.name) for p in dst.iterdir()} != {name for name, _ in files}: return False
        def sha(f):
            with open(f, 'rb') as h: return hashlib.file_digest(h, 'sha256').digest()
        return all(sha(dst / os.fsdecode(name)) == n.files[i][2] for name, i in files)
    if same(): return
    tmp = dst.with_name(dst.name + '.partial')
    shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(parents=True)
    for name, i in files:
        with open(tmp / os.fsdecode(name), 'wb') as f: n.copy(i, f)
    shutil.rmtree(dst, ignore_errors=True); tmp.rename(dst)


def entries(n, d):   # romfs_image.entries for a folder of the container: [name, file index, is dir, a, b], breadth-first
    ents, i = [[b'', d, True, 0, 0]], 0
    while i < len(ents):
        if ents[i][2]:
            kids = n.children(ents[i][1])
            ents[i][3], ents[i][4] = len(ents), len(kids)
            ents.extend([name, j, isdir, 0, 0] for name, isdir, j in kids)
        i += 1
    return ents


def verified(n, ents, dst):
    """The identity of the image at dst when it is, byte for byte, what write() makes of ents now, each file's bytes with the container's SHA-256 (romfs_image.verify_image); else None"""
    return romfs_image.verify_image(ents, dst, n.size, n.sha)


def pack(n, d, img, say=print, step=lambda s: None):
    """The RomFS folder d of the container → img. Returns how: 'kept' (the stamp says the container tree and the packers are the same), 'verified' (the stamp is
    from another packer, but the image checks against the container's hashes: its stamp is renewed) or 'packed'. step(name): the step it is in, for a progress line"""
    img.parent.mkdir(parents=True, exist_ok=True)
    ents, dst = entries(n, d), os.fspath(img)
    digest = hashlib.sha256(Path(romfs_image.__file__).read_bytes() + Path(__file__).read_bytes() + n.toc_sha + struct.pack('<I', d)).hexdigest()   # the TOC hash covers every name and file hash
    if romfs_image.reusable(dst, digest): return 'kept'
    if img.is_file():   # a packer update changes the digest, not the image: check its bytes before unpacking minutes of data again
        step('checking the image'); say(f'checking {img} against {n.path.name}')
        if identity := verified(n, ents, dst):
            romfs_image.stamp(dst, digest, identity)
            say('  kept: the image matches the container')
            return 'verified'
    step('unpacking'); say(f'packing {n.path.name} folder {d} → {img}')
    part = dst + '.part'
    try: romfs_image.publish(romfs_image.write(ents, dst, n.copy), dst, digest)
    except BaseException:
        Path(part).unlink(missing_ok=True); raise
    say(f'  {len(ents):,} entries, {img.stat().st_size / 2**30:.2f} GB')
    return 'packed'


def localized(payload):   # the localized icons record (TLV 0x000A) → {lowercase language tag: image bytes}
    out, p = {}, 0
    while p < len(payload):
        ln = payload[p]; tag = payload[p + 1:p + 1 + ln].decode(errors='replace').lower(); p += 1 + ln
        if p + 4 > len(payload): break
        dn = struct.unpack_from('<I', payload, p)[0]; p += 4
        out.setdefault(tag, payload[p:p + dn]); p += dn
    return out


def pick(tags, code):   # the record for a language code: the exact tag, then its primary subtag
    code = code.lower()
    return tags.get(code) or tags.get(code.split('-')[0])


def app_package(n, k=None):   # (k: the package, as pack_nx.app_package takes it) the record that holds application metadata when no base game is there (SPEC §5.1): a base record with no files, as some NUPs are packed, else the first package
    return next((k for k in n.packages if k.kind == BASE), n.packages[0])


def tell(k, line, say):   # say line once for package (or NX snapshot) k: a build reads a version's control data for its survey and again for its extraction
    told = vars(k).setdefault('told', set())
    if line not in told: told.add(line); say(line)


def control(k, out, fallback=None, say=print):   # the package's control data beside its ExeFS; what it lacks comes from fallback
    meta = {}
    for p in (fallback, k):
        if p is None: continue
        m = p.meta()
        if p.shifted: tell(p, f'{p.name}: {SHIFTED}', say)
        elif p.marked: tell(p, f'{p.name}: its meta block has a record of type 0, or one of type 7 that is not 32 bytes, as nup writes one numbered one too low, but its NACP or icon '
                               'is where SPEC §5 puts it: read as it is', say)
        if (b := m.get(T_NACP)) is not None and len(b) != NACP_SIZE:
            tell(p, f'{p.name}: its NACP record is {len(b):,} bytes, not {NACP_SIZE:,} (0x4000): it is not a NACP, left out', say)
            del m[T_NACP]
        meta.update(m)
    nacp_bytes = meta.get(T_NACP)
    icons = localized(meta.get(T_LICONS, b''))
    icon = meta.get(T_ICON) or pick(icons, 'en-US') or next(iter(icons.values()), None)
    for name, data in (('control.nacp', nacp_bytes), ('icon.jpg', icon), (TITLE_FILE, None), (EDITED_ICON, None)):
        if data: (out / name).write_bytes(data)
        else: (out / name).unlink(missing_ok=True)


def romfs_of(k, base):   # the RomFS folder a version runs with: its own, or the base game's for an update without one
    d = k.romfs if k.romfs != NO_DIR else base.romfs if base is not None else NO_DIR
    if d == NO_DIR: raise Error(f'{k.name}: no romfs/ in this package or the base game')
    return d


def pack_version(n, k, base, app, out, say=print, step=lambda s: None, note=None):
    """One version (the base package, or an update package) → out/ExeFS, out/RomFS.img and its control data; returns how pack() got the image. note: where the lines about the control data go
    (a meta block read one type up, a NACP left out), by default say: the NSP script keeps the packing quiet and says these"""
    if k.exefs == NO_DIR or n.child(k.exefs, b'main') is None or n.child(k.exefs, b'main.npdm') is None: raise Error(f'{k.name}: no exefs/main and exefs/main.npdm')
    if (pid := program_id(n.read(n.child(k.exefs, b'main.npdm')), f'{k.name} exefs/main.npdm')) != app: raise Error(f'{k.name}: program ID {pid:016X}, the base is {app:016X}')
    d = romfs_of(k, base)
    out.mkdir(parents=True, exist_ok=True)
    exefs(n, k, out / 'ExeFS')
    how = pack(n, d, out / 'RomFS.img', say, step)
    control(k, out, app_package(n) if base is None else None, note or say)
    return how


def pack_dlc(n, app, dlc, aoc, say=print):   # {DLC title ID: package} → aoc/<index>.img; images of DLC no longer in the container go
    want = {f'{programs.dlc_index(tid, app)}.img': k for tid, k in dlc.items()}   # a program's DLC are the application's (numbered from the title ID itself for a base game)
    if aoc.is_dir():
        for f in aoc.iterdir():
            if f.name.removesuffix('.inputs.json') not in want: f.unlink()
    for name, k in want.items(): pack(n, k.romfs, aoc / name, say)


def gate(n, app, dev=None):   # a program other than the application's own is read and chosen, but built only with NX18_DEV on (programs.supported): else a red line says it is not supported yet
    if not programs.supported(app, dev): raise Error(programs.unsupported(n.path.name, app, getattr(n, 'programs', None)))


def listing(n):   # the --list lines: every package, with the program ID its code names
    out = []
    for k in n.packages:
        i = n.child(k.exefs, b'main.npdm') if k.exefs != NO_DIR else None
        try: code = f'{program_id(n.read(i), k.name):016X}' if i is not None else '-'
        except Error as e: code = f'? ({e})'
        out.append(f'{k.index}\t{KINDS[k.kind]}\ttitle {k.title_id:016X}\tversion {k.version}\tprogram {code}\texefs/ {"yes" if k.exefs != NO_DIR else "no"}\tromfs/ {"yes" if k.romfs != NO_DIR else "no"}'
                   f'\t{n.tree_bytes(k.root):,} bytes' + ('\tstandalone' if k.flags & STANDALONE else ''))
    return out


def has_profile(tid):   # whether a game profile has title ID tid (dm/games, DM_GAMES_DIR): the program the NSP script would pick of several (programs.pick's known)
    games = str(Path(__file__).resolve().parents[1] / 'dm/games')
    if games not in sys.path: sys.path.insert(0, games)
    import game
    return game.by_title(tid) is not None


def main():
    ap = argparse.ArgumentParser(description='Pack your game\'s NUP container (made from your own dump) into the extraction layout of build_ipa_from_nsp.py')
    ap.add_argument('nup', type=Path, help='the .nup file')
    ap.add_argument('--version', type=int, help='the update version to pack (default: the newest in the container; 0 = the base game)')
    ap.add_argument('--program', type=int, help='a NUP holding several programs of one application (a Nintendo Switch 2 Edition): the program index to pack '
                    '(default, as the NSP script chooses: of the Switch 2 Edition\'s Switch 2 program and program 0, the first with a game profile in dm/games or DM_GAMES_DIR, else the first). '
                    'Only program 0 packs for now: another stops, not supported yet')
    ap.add_argument('--work-dir', type=Path, help='the build folder (default: <folder of the .nup>/<title ID>_build)')
    ap.add_argument('--list', action='store_true', help='list the packages and the program each one\'s code names, and pack nothing')
    a = ap.parse_args()
    path = a.nup.resolve()
    try:
        with Nup(path) as n:
            if a.list:
                print('\n'.join(listing(n))); return
            app, base, vers, dlc = scan(n, a.program, has_profile)
            for line in n.notes: print(line, flush=True)
            ver = a.version if a.version is not None else max(vers, default=0)
            if ver and ver not in vers: raise Error(f'no update {ver} in {path.name} (have: {", ".join(map(str, sorted(vers))) or "none"})')
            k = vers[ver] if ver else base
            if k is None: raise Error(f'{path.name}: no base game (version 0); choose a standalone update version')
            if base is None: print(n.no_base, flush=True)
            work =(a.work_dir or path.parent / f'{app:016X}_build').resolve()
            out = work / 'extract' / f'v{ver}'
            print(f'{app:016X} version {ver}: {k.name}', flush=True)
            say = lambda s: print(s, flush=True)
            pack_version(n, k, base, app, out, say)
            pack_dlc(n, app, dlc, work / 'aoc', say)
    except (Error, OSError) as e: sys.exit(f'[RED] {e}')
    print(f'done: {out}' + (f', {len(dlc)} DLC in {work / "aoc"}' if dlc else ''))


if __name__ == '__main__':
    main()
