#!/usr/bin/env python3
# A game in an NX archive (one .nx file: https://github.com/fab918/nxformat, NXFormat 1.0.3, SPEC.md; wire versions 0.2 and 0.3) → the layout build_ipa_from_nsp.py extracts NSPs into,
# the same as scripts/pack_nup.py writes for a NUP. build_ipa_from_nsp.py calls this when it is given a .nx file, or a folder that holds one, and goes on with its other steps; run on its own,
# this script does only this step. It reads the format with its own code: nothing of NXFormat's (nxconvert, its C++ reader) is used or needed.
# An NX holds decrypted Switch 1 and Switch 2 games: per application, snapshots (the base game, updates, standalone updates and DLC), each a complete file tree, never laid over another
# (SPEC §8). The files are cut into blocks of 64 KiB to 1 MiB, each stored raw or as one zstd frame, shared between files and snapshots (dedup), with a CRC-32C per 16 KiB of a block and a SHA-256
# per file. Its files are not encrypted, so it needs no keys. The NACP and the icons are records of their own (Media), each tied to one exact snapshot.
# Two kinds of tree, by what NXConvert packed:
#   from a NUP or extracted folders (nxconvert pack-nup, pack-tree, add-tree): exefs/, romfs/ and an optional data/ per snapshot, an update's tree already merged with its base's
#     (its ExeFS replaces the base's, its RomFS paths shadow the base's). These are packed here, by this script alone.
#   from a decrypted NSP or XCI (nxconvert pack, add): a flat set of decrypted NCA files (<content ID>.nca, <content ID>.cnmt.nca; DNCA at 0x200, no section encrypted), an update's
#     holding its base game's NCAs and its unresolved patch NCAs. These are read by nx_extract --plain (dm/tools/nx_extract, LibHac: no keys), found the first time such a snapshot
#     is touched (a tree archive never starts it) and refused unless built from the in-repo source. The scan reads every one's own content meta (one nx_extract --contents run) and
#     checks it against the Catalog; a DLC's add-on title ID comes from there. To pack a version, the NCA files it needs (Meta, Program, Control, Manual: never Data or delta
#     fragments; a DLC: Meta, Data, PublicData) are staged into <build folder>/tmp/nca/<label>/, each checked against its SHA-256 as it is streamed out of the archive, and deleted
#     after the run: an update version needs free space for its base and patch NCAs beside its output (checked first). An update is read in one folder as base and update, its patch
#     Program NCA laid over the base one (BKTR) by nx_extract. Refused: Switch 2 or platform-unknown games and snapshot types 3 and 4 (nxconvert 1.0.3 writes none: code native),
#     anything in a snapshot root but those NCA files, an NCA without the DNCA marker, with an encrypted section, an unflattened sparse layer, an FS header other than version 2 or
#     hash trees other than SHA-256 and IVFC, a data-only update (code nca), a sparse base game packed alone (code sparse: it runs only with its update).
#     nx_extract writes extract/v<version>/ (its log: logs/extract_v<version>.log, with display version and build IDs) through extract/v<version>.partial/, and a stamp
#     native.inputs.json (a digest of the tool's source, this script, the IDs and every NCA's name, size and SHA-256 from the Manifest, and the SHA-256 of what it wrote): a repeat run
#     with that digest stages nothing, also after an appended generation or a recompression. The NACP and icon come from the Control NCA, what it lacks from the Media records.
# Writes, under the build folder (<folder of the .nx>/<title ID>_build unless --work-dir names another):
#   extract/v<version>/ExeFS/   the version's code modules
#   extract/v<version>/RomFS.img   its RomFS as one image (dm/tools/romfs_image.py), written straight from the archive: the RomFS is never unpacked into loose files
#   extract/v<version>/control.nacp, icon.jpg   the snapshot's NACP and icon, when the archive has them for it, else its exact base snapshot's (also a base that holds only metadata; never
#     another update's); none when neither has them (sips reads a PNG icon by its content). A NACP record that is not 0x4000 bytes is no NACP: left out, with a line, and that
#     snapshot's display title with it (NXConvert 1.0.0 and 1.0.1 filled both from the wrong records of a NUP numbered one too low)
#   extract/v<version>/title.txt   without a NACP, the archive's display title for the version (or its base's; when it holds only spaces or control characters, a localized one, American
#     English first), cut to a NACP name's 511 bytes: the NSP script's app name then, before the profile's
#   extract/v<version>/icon.edited.jpg   an NCA snapshot's own icon in the archive (one set in NXConvert's sidebar) when it differs from its Control NCA's icon.jpg and its localized icons
#     do not hold that one (a new icon clears them; otherwise the default is the game's own in another language): the app's icon then
#   aoc/<index>.img   each DLC's RomFS (index = DLC title ID − base title ID − 0x1000; DLC converted from a NUP or folders carry their add-on title ID), the host's DM_AOC_DIR
# Checks, in the order of the format's own validator so a damaged or hostile archive gets the error the format names (Error.code):
#   open: both header slots (magic, CRC-32C, zero page padding; the valid one of the highest generation; an older generation when the newer one's tail is damaged), the version (0.2 and 0.3
#     only: a newer NX needs a newer reader), required and optional feature bits, the region layout, SHA-256 of the Catalog, the Manifest and the block index, every table, string, media
#     reference and extension (an unknown required extension refuses the archive, an unknown optional one is skipped), every directory tree (names, cycles, a node reached twice) and every
#     snapshot's identity, recomputed. The format's limits (SECURITY.md) and lower budgets of this reader (Budgets: the Manifest and block index are held in memory) bound all of it.
#   read: a zstd block must be one frame with its content size, no dictionary, a window of 1 MiB at most and no trailing bytes, and decodes to at most its logical size; every file streamed
#     is checked against its SHA-256 before the image is published. A file that fails has its blocks' CRC-32C checked to name the damaged block. CRC-32C is computed here in Python
#     (17 MiB/s, the SHA-256 runs at about 2 GB/s), so it is checked on every block read only with --crc; --verify checks the whole archive (every block with its CRC-32C, also unreferenced
#     ones, and every file). The archive is read with pread, never mapped: a file that shrinks while it is read is an error (io), not a SIGBUS.
#   host: what is written out is bounded before it is read: main.npdm up to 1 MiB, a code module up to 1 GiB, each name one host file name (255 bytes, no control characters, none that a
#     case- and normalization-insensitive volume takes for another), and the bytes to write against the volume's free space (dedup lets a small archive declare terabytes). Strings from the
#     archive are printed with their control characters escaped (shown).
# A repeat run keeps code modules whose content is the same and an image made from the same RomFS tree (paths, sizes and SHA-256) by the same packer, or, after a packer update, an image whose
# bytes check against the archive's hashes. An edit that appends a generation (nxconvert add) or recompresses the archive keeps those trees, so the images are kept.
# Needs the zstd module for zstd blocks: compression.zstd (Python 3.14+) or backports.zstd, as the NSP script.
# A base snapshot with no game files (no exefs/main, nothing in romfs/: one that holds only the application's metadata) is no base game, as a NUP's empty base record.
# An archive may hold one title ID on two platforms: --title-id <ID>:switch1 / :switch2 / :unknown picks one, and its build folder is <ID>-<platform>_build.
# Usage: pack_nx.py <game.nx> [--version N] [--title-id ID[:PLATFORM]] [--work-dir DIR] [--list] [--verify] [--crc] [--allow-damaged]   (exit 1 on error)
import argparse, hashlib, json, os, re, shutil, struct, subprocess, sys, tempfile, unicodedata
import typing
from typing import NoReturn
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm/tools'))
import romfs_image
import pack_nup   # the NUP packer: program_id, entries and the error class both share
try: from compression import zstd
except ImportError:
    try: from backports import zstd   # pyright: ignore[reportMissingImports]  # an optional package, only Python before 3.14 needs it
    except ImportError: zstd = None


class Error(pack_nup.Error):
    """A refused archive or snapshot. code: what failed, in the format's words (SPEC, the conformance fixtures' expected_error): unsupported, version, feature, format, length, bounds,
    resource, structure, padding, header, catalog, catalog_hash, string, manifest, manifest_hash, path, index_hash, block, block_hash, zstd, snapshot_identity, media_hash, file_hash; and this
    reader's own: native (an NCA snapshot of a kind not supported), nca (an NCA snapshot's files or content meta refused, by this script or nx_extract), nca_hash (an NCA fails its own
    hash check), sparse (a sparse base game packed without its update), tool (nx_extract missing, not built from the in-repo source, or failing), select (no such game or version), io"""
    def __init__(self, msg, code='format'):
        super().__init__(msg); self.code = code


PAGE, DATA_START, CHECK, NO = 4096, 8192, 16384, 0xFFFFFFFF
MiB, INT64_MAX = 1 << 20, (1 << 63) - 1
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'
# Wire records (SPEC §3-§7), little-endian, no padding
HEADER = struct.Struct('<4sHHIHH13Q32s32s32sQI24sI')   # NxHeader 256
CATALOG = struct.Struct('<4sHHQ8I8Q16s')   # NxCatalogHeader 128
APP = struct.Struct('<QBBH15I8s')   # NxApplication 80
PROGRAM = struct.Struct('<QIBBH16s4I16s')   # NxProgram 64
SNAPSHOT = struct.Struct('<IBBHIIQII16sII32s32s')   # NxSnapshot 120
LOCAL = struct.Struct('<6I')   # NxLocalizedEntry 24
DEPEND = struct.Struct('<BBH16s32sI')   # NxDependency 56
EXT = struct.Struct('<IIHHIQQ')   # NxExtension 32
MEDIA_HEAD = struct.Struct('<4sHHQIHHII')   # NxMediaRegionHeader 32
MEDIA = struct.Struct('<HBBQQQ32sI')   # NxMediaRecord 64
MANIFEST = struct.Struct('<4sHHQ4I6Q16s')   # NxManifestHeader 96
DIRECTORY = struct.Struct('<4I')   # NxDirectory 16
ENTRY = struct.Struct('<QIIBBHI')   # NxDirectoryEntry 24
FILE = struct.Struct('<QIIBBH32s12s')   # NxFile 64
BLOCK = struct.Struct('<QIIBBHI')   # NxBlock 24
HISTORY = struct.Struct('<12I')   # a Snapshot Metadata History row, 48
BASE, UPDATE, DLC, STANDALONE, UNKNOWN = range(5)
TYPES = ('base', 'update', 'DLC', 'standalone update', 'unknown')
PLATFORMS = {0: 'platform unknown', 1: 'Switch 1', 2: 'Switch 2'}
PNG, JPEG, NPDM, NACP, OPAQUE = 1, 2, 3, 4, 5
EXT_FIRMWARE, EXT_LANGUAGES, EXT_REGIONS, EXT_HISTORY, EXT_NATIVE, EXT_RECIPES, EXT_RESOURCES = 0x00010001, 0x00010002, 0x00010003, 0x00010004, 0x00010005, 0x00010006, 0x00010008
KNOWN_REQUIRED = {EXT_FIRMWARE, EXT_LANGUAGES, EXT_REGIONS, EXT_HISTORY, EXT_NATIVE, EXT_RESOURCES}
DAMAGE = {'length', 'bounds', 'structure', 'padding', 'catalog_hash', 'manifest_hash', 'index_hash'}   # failures of a newer generation that fall back to the older one (SPEC §1)


class _File:
    """The archive's bytes, read with pread: f[a:b] is bytes. A file that shrinks while it is open (a drive or share dropped, a tool rewriting it) gives an Error (code io), where a
    memory map of it would kill the process with SIGBUS, before any clean-up ran"""
    def __init__(self, path, f):
        self.path, self.fd, self.size, self.closed = path, os.dup(f.fileno()), os.fstat(f.fileno()).st_size, False

    def __len__(self): return self.size

    def __getitem__(self, s):
        start, stop, _ = s.indices(self.size)
        out, at = [], start
        while at < stop:
            try: b = os.pread(self.fd, min(stop - at, 64 * MiB), at)
            except OSError as e: raise Error(f'{self.path.name}: {e.strerror or e} (reading at {at:#x})', 'io') from e
            if not b: raise Error(f'{self.path.name}: the file ends at {at:#x}, before the {self.size:,} bytes it had when it was opened (removed, rewritten or its drive gone?)', 'io')
            out.append(b); at += len(b)
        return b''.join(out)

    def close(self):
        if not self.closed: self.closed = True; os.close(self.fd)


class Budgets:
    """This reader's limits, below the format's (SECURITY.md allows lower per-mount budgets): what it holds in memory and walks at open. A larger archive is refused with code resource"""
    def __init__(self, **kw):
        self.manifest = 256 * MiB   # Manifest bytes, read whole
        self.index = 256 * MiB   # block index + integrity table, read whole and hashed before use
        self.dirs, self.files, self.entries, self.refs = 1 << 20, 1 << 21, 1 << 22, 1 << 24
        self.nodes, self.visits, self.path_bytes = 1 << 22, 1 << 26, 1 << 30   # one snapshot's tree; all snapshots' trees; their paths' bytes
        for k, v in kw.items():
            if not hasattr(self, k): raise TypeError(f'no budget {k}')
            setattr(self, k, v)


_CRC = None


def _crc_tables():
    global _CRC
    if _CRC is None:
        t0 = []
        for i in range(256):
            c = i
            for _ in range(8): c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
            t0.append(c)
        ts = [t0]
        for _ in range(7): ts.append([(c >> 8) ^ t0[c & 0xFF] for c in ts[-1]])
        _CRC = ts
    return _CRC


def crc32c(data, crc=0):
    """CRC-32C (Castagnoli, reflected 0x82f63b78, as SPEC §3), table-driven 8 bytes at a time; crc continues an earlier value"""
    t0, t1, t2, t3, t4, t5, t6, t7 = _crc_tables()
    c = crc ^ 0xFFFFFFFF
    mv = memoryview(data).cast('B')
    n = len(mv) & ~7
    for (q,) in struct.iter_unpack('<Q', mv[:n]):
        q ^= c
        c = (t7[q & 0xFF] ^ t6[(q >> 8) & 0xFF] ^ t5[(q >> 16) & 0xFF] ^ t4[(q >> 24) & 0xFF] ^
             t3[(q >> 32) & 0xFF] ^ t2[(q >> 40) & 0xFF] ^ t1[(q >> 48) & 0xFF] ^ t0[q >> 56])
    for x in mv[n:]: c = (c >> 8) ^ t0[(c ^ x) & 0xFF]
    return c ^ 0xFFFFFFFF


def is_nx(path):   # NXAR in either header slot (slot A may be the damaged one); whether it opens is Nx's to say
    try:
        with open(path, 'rb') as f: b = f.read(PAGE + 4)
    except OSError: return False
    return b[:4] == b'NXAR' or b[PAGE:PAGE + 4] == b'NXAR'


def align(x, a): return (x + a - 1) // a * a


def valid_tag(raw):   # a lowercase ASCII BCP 47 language tag: subtags of 1-8 letters and digits
    return 0 < len(raw) <= 63 and all(1 <= len(p) <= 8 and all(c in b'abcdefghijklmnopqrstuvwxyz0123456789' for c in p) for p in raw.split(b'-'))


class App:
    def __init__(self, i, rec):
        (self.id, self.platform, self.flags, self.r0, self.first_program, self.nprograms, self.first_snapshot, self.nsnapshots, self.title_off, self.title_len, self.pub_off, self.pub_len,
         self.icon, self.first_local, self.nlocal, self.nacp, self.opaque_first, self.opaque_count, self.meta_snapshot, self.r1) = rec
        self.index, self.title, self.publisher, self.localized = i, None, None, []
        self.programs, self.snapshots = [], []


class Program:
    def __init__(self, i, rec):
        self.id, self.app, self.kind, self.flags, self.r0, self.content_id, self.first_snapshot, self.nsnapshots, self.npdm, self.r1, self.r2 = rec
        self.index = i


class Snapshot:
    """One snapshot: a complete tree under root. exefs and romfs are its exefs/ and romfs/ folders (NO without one); kind: 'tree' (exefs/ or romfs/), 'native' (decrypted NCA files),
    'empty' or 'other'; title_id: a DLC's add-on title ID (ADDON_TITLE_ID), else None; name: what the build prints for it"""
    def __init__(self, nx, i, rec):
        (self.program, self.type, self.flags, self.r0, self.version, self.root, self.logical_size, self.dv_off, self.dv_len, self.content_id, self.first_dep, self.ndeps,
         self.identity, self.build_id) = rec
        self.nx, self.index, self.app, self.display_version = nx, i, typing.cast(App, None), None   # app: set as the Catalog is read
        self.exefs = self.romfs = NO
        self.kind = 'empty'
        self.title_id = struct.unpack_from('<Q', self.content_id)[0] if self.flags & 2 else None
        self.name = ''

    def describe(self):
        what = TYPES[self.type] + (f' {self.version}' if self.type in (UPDATE, STANDALONE) else f' {self.title_id:016X}' if self.title_id is not None else
                                   f' v{self.version}' if self.type == DLC else f' v{self.version}' if self.version else '')
        return f'{self.nx.path.name} ({what})'


class Nx:
    """A validated NX archive: the header slot of the highest valid generation, the Catalog, Media, the Manifest, the block index and every snapshot tree and identity (SPEC §12 levels 1 and 2).
    Block data is checked as it is read (copy: each file's SHA-256; crc=True: also every block's CRC-32C) or all at once (verify). Raises Error"""
    def __init__(self, path, budgets=None, crc=False):
        self.path, self.budgets, self.crc = Path(path), budgets or Budgets(), crc
        self.notes, self.fell_back = [], None
        self.nca_tool: 'Native | None' = None   # a Native: how NCA snapshots are read (the caller sets it; none: they are refused, code tool)
        self.heads = {}   # file index → content type of an NCA whose header was checked (nca_head)
        try:
            with open(self.path, 'rb') as f:   # the reader keeps its own descriptor
                size = os.fstat(f.fileno()).st_size
                if size < DATA_START: raise Error(f'{self.path.name}: {size:,} bytes, shorter than the two header pages (8,192 bytes): not a whole NX archive', 'length')
                self.mm = _File(self.path, f)
        except OSError as e: raise Error(f'{self.path}: {e.strerror or e}', 'io') from e
        try: self._open()
        except BaseException:
            self.close(); raise

    def fail(self, code, msg) -> NoReturn:
        raise Error(f'{self.path.name}: {msg}', code)

    def close(self):
        mm = getattr(self, 'mm', None)
        if mm is not None and not mm.closed: mm.close()

    def __enter__(self): return self
    def __exit__(self, *a): self.close()

    # ---- header slots and generations (SPEC §1, §3) ----
    def _slots(self):
        valid = []
        for at in (0, PAGE):
            raw = self.mm[at:at + HEADER.size]
            v = HEADER.unpack(raw)
            if v[0] != b'NXAR' or crc32c(raw[:252]) != v[25] or self.mm[at + HEADER.size:at + PAGE] != bytes(PAGE - HEADER.size): continue
            valid.append((v[22], raw, v))
        if not valid: self.fail('unsupported', 'neither header slot is valid (magic, CRC-32C, page padding): not an NX archive of a supported layout, or both header pages are damaged')
        if len(valid) == 2 and valid[0][0] == valid[1][0] and valid[0][1] != valid[1][1]:
            self.fail('format', f'both header slots are valid with generation {valid[0][0]} but differ')
        return sorted(valid, key=lambda s: s[0], reverse=True)

    def _open(self):
        slots = self._slots()
        try: self._mount(slots[0][2])
        except Error as e:
            if e.code not in DAMAGE or len(slots) < 2 or slots[0][0] == slots[1][0]: raise
            try: self._mount(slots[1][2])
            except Error: raise e from None
            self.fell_back = (slots[0][0], e)
            self.notes.append(f'{self.path.name}: generation {slots[0][0]} is damaged ({e}); reading generation {slots[1][0]}, the one before the last edit')

    def _mount(self, h):
        _, major, minor, hsize, required, optional = h[:6]
        (self.archive_size, cat_off, cat_size, media_off, media_size, data_off, data_size, man_off, man_size, idx_off, nblocks, integ_off, integ_size) = h[6:19]
        cat_sha, man_sha, idx_sha, self.generation, check_size, reserved, _ = h[19:26]
        self.version = (major, minor)
        if major != 0 or minor not in (2, 3) or hsize != 256:
            self.fail('version', f'NX format version {major}.{minor} (header size {hsize}): this reader reads 0.2 and 0.3 (NXFormat 1.0.x); an archive of a newer format needs a newer NX 18')
        if required != 1: self.fail('feature', f'required feature bits {required:#06x}: this reader knows bit 0 (separate header pages) only; the archive needs a newer reader')
        if optional: self.fail('feature', f'optional feature bits {optional:#06x}: none is defined in NX {major}.{minor}')
        if reserved != bytes(24) or check_size != CHECK: self.fail('header', 'reserved header bytes or integrity check size invalid')
        if self.archive_size > len(self.mm): self.fail('length', f'{len(self.mm):,} bytes, its header says {self.archive_size:,} (copied or downloaded partly?)')
        if self.archive_size > INT64_MAX or cat_size > 16 * MiB: self.fail('resource', 'archive or Catalog size above the format limit')
        if nblocks > 1 << 32 or integ_size % 4: self.fail('structure', 'block count or integrity table size invalid')
        if nblocks == 0:
            if idx_off or integ_off or data_off or data_size or integ_size: self.fail('structure', 'no blocks, but block regions are set')
        elif data_off != DATA_START or not idx_off or not integ_off or not data_size or not integ_size: self.fail('structure', 'blocks without a Data region or block index')
        self._range(cat_off, cat_size, self.archive_size, 'the Catalog')
        catalog = self.mm[cat_off:cat_off + cat_size]
        if hashlib.sha256(catalog).digest() != cat_sha: self.fail('catalog_hash', 'the Catalog does not match its SHA-256 (damaged archive)')
        if man_size < MANIFEST.size or man_size > 4 << 30: self.fail('resource', 'Manifest size outside the format limit')
        if media_size == 0 and media_off: self.fail('structure', 'no Media region, but its offset is set')
        # the tail: Media?, Catalog, Manifest, block index, integrity table, packed on 16-byte boundaries after the data
        tail = ([(media_off, media_size, 'Media')] if media_size else []) + [(cat_off, cat_size, 'Catalog'), (man_off, man_size, 'Manifest')]
        if nblocks: tail += [(idx_off, nblocks * BLOCK.size, 'block index'), (integ_off, integ_size, 'integrity table')]
        start = tail[0][0]
        if start % 16 or start < align(data_off + data_size if nblocks else DATA_START, 16): self.fail('structure', f'the {tail[0][2]} does not start after the Data region on a 16-byte boundary')
        end = start
        for k, (at, size, what) in enumerate(tail):
            if k and at != align(end, 16): self.fail('structure', f'the {what} is not at its place in the tail')
            self._range(at, size, self.archive_size, f'the {what}')
            if self.mm[end:at] != bytes(at - end): self.fail('padding', f'nonzero padding before the {what}')
            end = at + size
        if end != self.archive_size: self.fail('length', 'the tail does not end at the archive size')
        if nblocks * BLOCK.size + integ_size > self.budgets.index: self.fail('resource', f'block index of {nblocks:,} blocks: above this reader\'s budget (Budgets.index)')
        self.index = self.mm[idx_off:idx_off + nblocks * BLOCK.size]
        self.integrity = self.mm[integ_off:integ_off + integ_size]
        if hashlib.sha256(self.index + self.integrity).digest() != idx_sha: self.fail('index_hash', 'the block index or integrity table does not match its SHA-256 (damaged archive)')
        self.nblocks, self.data_end = nblocks, data_off + data_size
        self.media_off, self.media_size = media_off, media_size
        self._catalog(catalog, minor)
        self._media()
        if man_size > self.budgets.manifest: self.fail('resource', f'Manifest of {man_size:,} bytes: above this reader\'s budget (Budgets.manifest)')
        manifest = self.mm[man_off:man_off + man_size]
        if hashlib.sha256(manifest).digest() != man_sha: self.fail('manifest_hash', 'the Manifest does not match its SHA-256 (damaged archive)')
        self._manifest(manifest)
        self._blocks(data_off)
        self._resources()
        self._trees()

    def _range(self, at, size, limit, what, code='bounds'):
        if at < 0 or size < 0 or at > limit or size > limit - at: self.fail(code, f'{what} ([{at:#x}, +{size:#x})) lies outside its region of {limit:#x} bytes')
        return at, at + size

    # ---- Catalog (SPEC §4) ----
    def _table(self, at, count, size, total, optional=False):
        if count == 0:
            if at and optional: self.fail('structure', 'an empty table has an offset')
            return None
        if at == 0 or at % 8: self.fail('structure', 'a table offset is zero or misaligned')
        if count * size > total: self.fail('bounds', 'a table is larger than its region')
        return self._range(at, count * size, total, 'a table')

    def _string(self, off, length, required=False, limit=4096):
        if off == NO:
            if length or required: self.fail('string', 'a string reference is absent and has a length, or is a required string')
            return None
        if length == 0: self.fail('string', 'a present string reference has length 0 (an empty string is written as absent)')
        if length > limit or off > len(self.pool) or length > len(self.pool) - off: self.fail('bounds', 'a string reference lies outside the string pool or is too long')
        raw = self.pool[off:off + length]
        if b'\0' in raw: self.fail('string', 'a string holds a NUL byte')
        try: return raw.decode('utf-8')
        except UnicodeDecodeError: self.fail('string', 'a string is not UTF-8')

    def _catalog(self, cat, minor):
        if len(cat) < CATALOG.size: self.fail('catalog', 'the Catalog is shorter than its header')
        (magic, ver, hsize, total, flags, napps, nprogs, nsnaps, nlocal, ndeps, nexts, r0, app_off, prog_off, snap_off, local_off, dep_off, ext_off,
         pool_off, pool_size, r1) = CATALOG.unpack_from(cat)
        if (magic, ver, hsize, total, flags, r0, r1) != (b'NXCT', 1, 128, len(cat), 0, 0, bytes(16)): self.fail('catalog', 'invalid Catalog header')
        if not (1 <= napps <= 4096 and nprogs <= 16384 and 1 <= nsnaps <= 65536 and nlocal <= 16384 and ndeps <= 32768 and nexts <= 4096):
            self.fail('resource', 'Catalog counts above the format limits')
        tables = [self._table(app_off, napps, APP.size, len(cat)), self._table(prog_off, nprogs, PROGRAM.size, len(cat)), self._table(snap_off, nsnaps, SNAPSHOT.size, len(cat)),
                  self._table(local_off, nlocal, LOCAL.size, len(cat), True), self._table(dep_off, ndeps, DEPEND.size, len(cat), True), self._table(ext_off, nexts, EXT.size, len(cat), True)]
        if pool_off % 8: self.fail('catalog', 'the string pool is misaligned')
        spans = sorted([(0, CATALOG.size)] + [t for t in tables if t] + [self._range(pool_off, pool_size, len(cat), 'the string pool')])
        for (_, end), (start, _) in zip(spans, spans[1:]):
            if start < end: self.fail('catalog', 'Catalog tables overlap')
            if cat[end:start] != bytes(start - end): self.fail('padding', 'nonzero Catalog padding')
        cursor = CATALOG.size
        for at, count, size in ((app_off, napps, APP.size), (prog_off, nprogs, PROGRAM.size), (snap_off, nsnaps, SNAPSHOT.size), (local_off, nlocal, LOCAL.size),
                                (dep_off, ndeps, DEPEND.size), (ext_off, nexts, EXT.size)):
            if count:
                cursor = align(cursor, 8)
                if at != cursor: self.fail('catalog', 'a Catalog table is not at its packed offset')
                cursor += count * size
            elif at: self.fail('catalog', 'an empty Catalog table has an offset')
        cursor = align(cursor, 8)
        if pool_off != cursor: self.fail('catalog', 'the string pool is not at its packed offset')
        cursor += pool_size
        self.pool = cat[pool_off:pool_off + pool_size]
        apps = self.apps = [App(i, APP.unpack_from(cat, app_off + i * APP.size)) for i in range(napps)]
        progs = self.programs = [Program(i, PROGRAM.unpack_from(cat, prog_off + i * PROGRAM.size)) for i in range(nprogs)]
        snaps = self.snapshots = [Snapshot(self, i, SNAPSHOT.unpack_from(cat, snap_off + i * SNAPSHOT.size)) for i in range(nsnaps)]
        local = [LOCAL.unpack_from(cat, local_off + i * LOCAL.size) for i in range(nlocal)]
        of_program = [[] for _ in progs]
        for s in snaps:
            if s.program != NO and s.program < nprogs: of_program[s.program].append(s.index)
        refs, opaque = [], []   # (media index, allowed types); opaque ranges
        pcur = scur = lcur = 0
        for a in apps:
            if not a.id or a.platform not in PLATFORMS or a.flags & ~3 or a.r0 or a.r1 != bytes(8): self.fail('catalog', f'invalid application record {a.index}')
            if a.index and (a.platform, a.id) <= (apps[a.index - 1].platform, apps[a.index - 1].id): self.fail('catalog', 'applications are not sorted by (platform, ID), or one is listed twice')
            if a.nprograms:
                if a.first_program != pcur or a.first_program + a.nprograms > nprogs: self.fail('catalog', f'application {a.id:016X}: invalid program range')
                pcur += a.nprograms
            elif a.first_program != NO: self.fail('catalog', f'application {a.id:016X}: invalid program range')
            if a.first_snapshot != scur or not a.nsnapshots or a.first_snapshot + a.nsnapshots > nsnaps: self.fail('catalog', f'application {a.id:016X}: invalid snapshot range')
            scur += a.nsnapshots
            a.title, a.publisher = self._string(a.title_off, a.title_len), self._string(a.pub_off, a.pub_len)
            if a.icon != NO: refs.append((a.icon, (PNG, JPEG)))
            if a.nacp != NO: refs.append((a.nacp, (NACP,)))
            if a.first_local != lcur or a.first_local + a.nlocal > nlocal: self.fail('catalog', f'application {a.id:016X}: invalid localized-entry range')
            lcur += a.nlocal
            has = a.title is not None or a.publisher is not None or a.icon != NO or a.nacp != NO or a.nlocal or a.opaque_count
            if a.meta_snapshot == NO:
                if has: self.fail('catalog', f'application {a.id:016X}: display metadata without the snapshot it comes from')
            elif not a.first_snapshot <= a.meta_snapshot < a.first_snapshot + a.nsnapshots: self.fail('catalog', f'application {a.id:016X}: its metadata snapshot is not one of its snapshots')
            elif not has: self.fail('catalog', f'application {a.id:016X}: a metadata snapshot with no metadata')
            if a.opaque_count:
                if a.opaque_count > 65535 or a.opaque_first > 65535 - a.opaque_count: self.fail('catalog', f'application {a.id:016X}: its opaque media range lies past the Media records\' limit (65,535)')
                refs.extend((m, (OPAQUE,)) for m in range(a.opaque_first, a.opaque_first + a.opaque_count)); opaque.append((a.opaque_first, a.opaque_first + a.opaque_count))
            elif a.opaque_first not in (0, NO): self.fail('catalog', f'application {a.id:016X}: an empty opaque media range with a start')
        if pcur != nprogs or scur != nsnaps or lcur != nlocal: self.fail('catalog', 'application ranges do not cover the Catalog tables')
        for p in progs:
            if not p.id or p.app >= napps or p.kind not in (0, 1, 2) or p.flags & ~1 or p.r0 or p.r1 or p.r2 != bytes(16): self.fail('catalog', f'invalid program record {p.index}')
            if bool(p.flags & 1) != (p.content_id != bytes(16)): self.fail('catalog', f'program {p.id:016X}: content ID flag and value disagree')
            if p.index and (p.app, p.id) <= (progs[p.index - 1].app, progs[p.index - 1].id): self.fail('catalog', 'programs are not sorted')
            if not p.nsnapshots or p.first_snapshot + p.nsnapshots > nsnaps: self.fail('catalog', f'program {p.id:016X}: invalid snapshot range')
            if of_program[p.index] != list(range(p.first_snapshot, p.first_snapshot + p.nsnapshots)): self.fail('catalog', f'program {p.id:016X}: its snapshot range is not its snapshots')
            if p.npdm != NO:
                if p.nsnapshots != 1: self.fail('catalog', f'program {p.id:016X}: one NPDM for several snapshots')
                refs.append((p.npdm, (NPDM,)))
        for a in apps:
            for i in range(a.first_program, a.first_program + a.nprograms):
                if progs[i].app != a.index: self.fail('catalog', f'application {a.id:016X}: its program range holds another application\'s program')
            mine, dlc_seen, last = set(range(a.first_program, a.first_program + a.nprograms)), False, -1
            for i in range(a.first_snapshot, a.first_snapshot + a.nsnapshots):
                s = snaps[i]
                if s.program == NO:
                    if s.type != DLC: self.fail('catalog', f'snapshot {i}: only DLC may have no program')
                    dlc_seen = True
                elif s.program not in mine or dlc_seen or s.program < last: self.fail('catalog', f'application {a.id:016X}: snapshot {i} is outside its programs or out of order')
                else: last = s.program
        langs = {}
        for a in apps:
            for i in range(a.first_local, a.first_local + a.nlocal):
                a.localized.append(self._localized(local[i], langs.get(a.index)))
                langs[a.index] = a.localized[-1][0].encode()
                if a.localized[-1][2] != NO: refs.append((a.localized[-1][2], (PNG, JPEG)))
        deps = [DEPEND.unpack_from(cat, dep_off + i * DEPEND.size) for i in range(ndeps)]
        owner = [None] * nsnaps
        for a in apps:
            for i in range(a.first_snapshot, a.first_snapshot + a.nsnapshots): owner[i] = a; a.snapshots.append(snaps[i])
            for i in range(a.first_program, a.first_program + a.nprograms): a.programs.append(progs[i])
        seen, dcur, last = set(), 0, None
        for s in snaps:
            s.app = owner[s.index]
            if s.flags & 2 and (s.type != DLC or s.program != NO or s.content_id[:8] == bytes(8) or s.content_id[8:] != bytes(8)):
                self.fail('catalog', f'snapshot {s.index}: an add-on title ID on a snapshot that is not a DLC without a program')
            if (s.type > UNKNOWN or s.flags & ~3 or s.r0 or (s.program == NO and s.type != DLC) or (s.program != NO and s.program >= nprogs) or
                    bool(s.flags & 1) != (s.build_id != bytes(32))): self.fail('catalog', f'invalid snapshot record {s.index}')
            if s.identity == bytes(32) or s.identity in seen: self.fail('catalog', f'snapshot {s.index}: zero or duplicate snapshot identity')
            seen.add(s.identity)
            key = (s.app.index, s.program if s.program != NO else nprogs, s.type, s.version, s.content_id, s.build_id)
            if last is not None and key <= last: self.fail('catalog', 'snapshots are not sorted, or two have the same key')
            last = key
            if s.first_dep != dcur or s.first_dep + s.ndeps > ndeps: self.fail('catalog', f'snapshot {s.index}: invalid dependency range')
            dcur += s.ndeps
            s.display_version = self._string(s.dv_off, s.dv_len, limit=256)
        for a in apps:
            if a.meta_snapshot != NO and snaps[a.meta_snapshot].type == DLC: self.fail('catalog', f'application {a.id:016X}: a DLC cannot supply its display metadata')
        if dcur != ndeps: self.fail('catalog', 'snapshot ranges do not cover the dependencies')
        for kind, flags, r0, cid, target, r1 in deps:
            if kind not in (1, 2, 3) or flags & ~1 or r0 or r1 or target == bytes(32): self.fail('catalog', 'invalid dependency record')
            if bool(flags & 1) == (cid == bytes(16)): self.fail('catalog', 'dependency content ID flag and value disagree')
        self.history, self.native, self.resource_dirs = {}, {}, []   # {app index: {snapshot index: row}}, {snapshot index: (NPDM media, firmware or None)}, [(kind, root directory)]
        prior = None
        for e in range(nexts):
            type_id, flags, okind, r0, oidx, p_off, p_size = EXT.unpack_from(cat, ext_off + e * EXT.size)
            if flags & ~1 or okind not in (0, 1, 2, 3) or r0: self.fail('catalog', f'invalid extension record {e}')
            if (okind == 0 and oidx != NO) or (okind == 1 and oidx >= napps) or (okind == 2 and oidx >= nprogs) or (okind == 3 and oidx >= nsnaps): self.fail('catalog', f'extension {type_id:#010x}: invalid owner')
            if prior is not None and (type_id, okind, oidx) <= prior: self.fail('catalog', f'extension {type_id:#010x}: extensions are not sorted by (type, owner kind, owner index), or one is listed twice for one owner')
            prior = (type_id, okind, oidx)
            lo, hi = self._range(p_off, p_size, len(cat), f'extension {type_id:#010x}')
            if lo < pool_off + pool_size: self.fail('catalog', f'extension {type_id:#010x}: its payload overlaps the tables or strings')
            if cat[cursor:align(cursor, 8)] != bytes(align(cursor, 8) - cursor): self.fail('padding', f'nonzero Catalog padding before extension {type_id:#010x}\'s payload')
            cursor = align(cursor, 8)
            if lo != cursor: self.fail('catalog', f'extension {type_id:#010x}: its payload is not at its packed offset')
            cursor = hi
            payload = cat[lo:hi]
            if type_id in (EXT_FIRMWARE, EXT_LANGUAGES, EXT_REGIONS) and (okind != 1 or apps[oidx].meta_snapshot == NO):
                self.fail('catalog', f'extension {type_id:#010x}: an application fact without the application\'s metadata snapshot')
            if type_id == EXT_FIRMWARE:
                if p_size != 4: self.fail('catalog', 'invalid required-firmware extension')
            elif type_id == EXT_LANGUAGES: self._languages(payload)
            elif type_id == EXT_REGIONS:
                n = struct.unpack_from('<H', payload)[0] if p_size >= 2 else 0
                codes = [payload[2 + 2 * i:4 + 2 * i] for i in range(n)]
                if p_size < 4 or not 1 <= n <= 249 or p_size != 2 + 2 * n: self.fail('catalog', 'invalid regions extension')
                if any(c not in b'ABCDEFGHIJKLMNOPQRSTUVWXYZ' for code in codes for c in code) or codes != sorted(set(codes)): self.fail('catalog', 'invalid or unsorted region code')
            elif type_id == EXT_HISTORY:
                if okind != 1 or flags != 1: self.fail('catalog', 'invalid Snapshot Metadata History extension record')
                self._history(apps[oidx], payload, owner, refs)
            elif type_id == EXT_NATIVE:
                if okind != 1 or flags != 1: self.fail('catalog', 'invalid Snapshot Native Metadata extension record')
                self._native(apps[oidx], payload, owner, refs)
            elif type_id == EXT_RESOURCES:
                if okind != 1 or flags != 1 or p_size < 16: self.fail('catalog', 'invalid Source Resources extension record')
                magic, v, hs, n, rr = struct.unpack_from('<4sHHII', payload)
                if (magic, v, hs, rr) != (b'NXSR', 1, 16, 0) or not 1 <= n <= 4096 or p_size != 16 + 8 * n: self.fail('catalog', 'invalid Source Resources header')
                prior = None
                for i in range(n):
                    item = struct.unpack_from('<II', payload, 16 + 8 * i)
                    if item[0] > 1 or (prior is not None and item <= prior): self.fail('catalog', 'invalid or unsorted source resource')
                    self.resource_dirs.append(item); prior = item
            elif type_id == EXT_RECIPES:   # optional: checked, then not used
                if okind != 1 or flags != 0: self.fail('catalog', 'invalid Rebuild Recipes extension record')
                self._recipes(payload)
            elif flags & 1: self.fail('feature', f'extension {type_id:#010x} is required and unknown to this reader: the archive was made by a newer NXConvert; it needs a newer NX 18')
        if len(self.resource_dirs) > 4096 or (minor == 3) != bool(self.resource_dirs):
            self.fail('catalog', f'NX 0.{minor} ' + ('without Source Resources (0.3 has them)' if minor == 3 else 'with Source Resources (only 0.3 has them)'))
        if cursor != len(cat): self.fail('catalog', 'the Catalog has bytes after its last payload')
        for ai in self.history:
            if apps[ai].meta_snapshot == NO: self.fail('catalog', 'metadata history without the application\'s metadata snapshot')
        self._refs, self._opaque = refs, opaque

    def _localized(self, row, previous):
        lang_off, lang_len, t_off, t_len, icon, flags = row
        lang = self._string(lang_off, lang_len, required=True, limit=63) or ''   # never absent: required
        if not valid_tag(lang.encode()) or flags: self.fail('catalog', f'invalid language tag {lang!r} or localized flags')
        if previous is not None and lang.encode() <= previous: self.fail('catalog', 'localized entries are not sorted by language, or one is listed twice')
        title = self._string(t_off, t_len)
        if title is None and icon == NO: self.fail('catalog', f'localized entry {lang!r} has neither a title nor an icon')
        return lang, title, icon

    def _languages(self, payload):
        if len(payload) < 3: self.fail('catalog', 'invalid supported-languages extension')
        n, p, prev = struct.unpack_from('<H', payload)[0], 2, b''
        if not 1 <= n <= 64: self.fail('catalog', 'supported-languages count outside 1..64')
        for _ in range(n):
            if p >= len(payload): self.fail('catalog', 'supported-languages extension cut short')
            ln = payload[p]; p += 1
            if not 1 <= ln <= 63 or ln > len(payload) - p: self.fail('catalog', 'invalid supported-language length')
            tag = payload[p:p + ln]; p += ln
            if not valid_tag(tag) or tag <= prev: self.fail('catalog', 'invalid or unsorted supported language')
            prev = tag
        if p != len(payload): self.fail('catalog', 'bytes after the supported languages')

    def _history(self, a, payload, owner, refs):
        if len(payload) < 24: self.fail('catalog', 'invalid Snapshot Metadata History extension record')
        magic, v, hs, nrec, nloc, nopq, rr = struct.unpack_from('<4sHHIIII', payload)
        if magic != b'NXSM' or v != 1 or hs != 24 or rr or not nrec or len(payload) != 24 + nrec * 48 + nloc * 24 + nopq * 4:
            self.fail('catalog', 'invalid Snapshot Metadata History header or size')
        if a.meta_snapshot == NO or a.nsnapshots < 2 or nrec > a.nsnapshots - 1 or nloc > 16384: self.fail('catalog', 'Snapshot Metadata History counts or metadata snapshot invalid')
        lbase, obase = 24 + nrec * 48, 24 + nrec * 48 + nloc * 24
        rows, lcur, ocur, prior = {}, 0, 0, -1
        for r in range(nrec):
            si, t_off, t_len, p_off, p_len, icon, nacp, first_l, nl, first_o, no, rr = HISTORY.unpack_from(payload, 24 + r * 48)
            if (rr or not a.first_snapshot <= si < a.first_snapshot + a.nsnapshots or si == a.meta_snapshot or si <= prior or owner[si] is not a or first_l != lcur or nl > nloc - lcur or
                    first_o != ocur or no > nopq - ocur): self.fail('catalog', 'a metadata history row names another application\'s snapshot, the metadata snapshot, or invalid ranges')
            row = {'title': self._string(t_off, t_len), 'publisher': self._string(p_off, p_len), 'icon': icon, 'nacp': nacp, 'localized': []}
            if row['title'] is None and row['publisher'] is None and icon == NO and nacp == NO and not nl and not no: self.fail('catalog', 'an empty metadata history row')
            if icon != NO: refs.append((icon, (PNG, JPEG)))
            if nacp != NO: refs.append((nacp, (NACP,)))
            prev = None
            for i in range(first_l, first_l + nl):
                row['localized'].append(self._localized(LOCAL.unpack_from(payload, lbase + i * 24), prev))
                prev = row['localized'][-1][0].encode()
                if row['localized'][-1][2] != NO: refs.append((row['localized'][-1][2], (PNG, JPEG)))
            refs.extend((struct.unpack_from('<I', payload, obase + i * 4)[0], (OPAQUE,)) for i in range(first_o, first_o + no))
            rows[si] = row; prior = si; lcur += nl; ocur += no
        if lcur != nloc or ocur != nopq: self.fail('catalog', 'metadata history rows do not cover their arrays')
        self.history[a.index] = rows

    def _native(self, a, payload, owner, refs):
        if len(payload) < 16: self.fail('catalog', 'invalid Snapshot Native Metadata extension record')
        magic, v, hs, n, rr = struct.unpack_from('<4sHHII', payload)
        if magic != b'NXNM' or v != 1 or hs != 16 or rr or not n or n > a.nsnapshots or len(payload) != 16 + 16 * n: self.fail('catalog', 'invalid Snapshot Native Metadata header')
        prev = -1
        for i in range(n):
            si, npdm, fw, flags = struct.unpack_from('<4I', payload, 16 + 16 * i)
            if si >= len(owner) or owner[si] is not a or si <= prev or flags & ~1 or (not flags & 1 and fw) or (npdm == NO and not flags & 1): self.fail('catalog', 'invalid Snapshot Native Metadata row')
            if npdm != NO:
                prog = self.snapshots[si].program
                if prog == NO or self.programs[prog].npdm != NO: self.fail('catalog', 'a snapshot NPDM without a program, or beside the program\'s')
                refs.append((npdm, (NPDM,)))
            self.native[si] = (npdm, fw if flags & 1 else None); prev = si

    def _recipes(self, payload):
        if len(payload) < 16: self.fail('catalog', 'invalid Rebuild Recipes extension record')
        magic, v, hs, n, rr = struct.unpack_from('<4sHHII', payload)
        if magic != b'NXRC' or v != 1 or hs != 16 or rr or not 1 <= n <= 4096: self.fail('catalog', 'invalid Rebuild Recipes header')
        at, prev = 16, b''
        for _ in range(n):
            if at + 8 > len(payload): self.fail('catalog', 'a rebuild recipe is cut short')
            ln = struct.unpack_from('<Q', payload, at)[0]
            start, end = at + 8, at + 8 + ln
            if ln < 104 or end > len(payload): self.fail('catalog', 'a rebuild recipe is cut short')
            recipe = payload[start:end]
            if recipe[:8] != b'NXRECIPE' or hashlib.sha256(recipe[:-32]).digest() != recipe[-32:]: self.fail('catalog', 'a rebuild recipe fails its checksum')
            if recipe[-32:] <= prev: self.fail('catalog', 'rebuild recipes are not sorted, or one is listed twice')
            prev, at = recipe[-32:], align(end, 8)
            if at > len(payload) or payload[end:at] != bytes(at - end): self.fail('catalog', 'invalid rebuild recipe padding')
        if at != len(payload): self.fail('catalog', 'bytes after the rebuild recipes')

    # ---- Media (SPEC §5) ----
    def _media(self):
        off, size, self.media_records = self.media_off, self.media_size, []
        if size:
            self._range(off, size, len(self.mm), 'the Media region')
            if off % 16 or size < MEDIA_HEAD.size or size > 4 << 30: self.fail('structure', 'invalid Media region alignment or size')
            magic, v, hs, total, n, rsize, r0, rec_off, pay_off = MEDIA_HEAD.unpack(self.mm[off:off + MEDIA_HEAD.size])
            if (magic, v, hs, total, rsize, r0, rec_off) != (b'NXMD', 1, 32, size, 64, 0, 32): self.fail('structure', 'invalid Media header')
            if not 1 <= n <= 65535 or pay_off != align(32 + n * 64, 16): self.fail('structure', 'invalid Media record count or payload start')
            self._range(off + 32, n * MEDIA.size, off + size, 'the Media records')
            if self.mm[off + 32 + n * 64:off + pay_off] != bytes(pay_off - 32 - n * 64): self.fail('padding', 'nonzero Media table padding')
            cursor, recs = pay_off, self.mm[off + 32:off + 32 + n * MEDIA.size]
            for i in range(n):
                mtype, codec, flags, stored, logical, d_off, sha, rr = MEDIA.unpack_from(recs, i * 64)
                if mtype not in (PNG, JPEG, NPDM, NACP, OPAQUE) or codec or flags or rr: self.fail('structure', f'invalid Media record {i}')
                if not stored or stored > 64 * MiB or logical != stored or d_off % 16: self.fail('resource', f'Media record {i}: size or alignment outside the limit')
                if d_off != align(cursor, 16): self.fail('structure', f'Media record {i}: payload not at its packed offset')
                lo, hi = self._range(d_off, stored, size, f'Media record {i}')
                if self.mm[off + cursor:off + lo] != bytes(lo - cursor): self.fail('padding', 'nonzero Media payload padding')
                self.media_records.append((mtype, off + lo, stored, sha))
                cursor = hi
            if cursor != size: self.fail('structure', 'the Media region has bytes after its last payload')
        counts = [0] * len(self.media_records)
        for m, types in self._refs:
            if m >= len(self.media_records) or self.media_records[m][0] not in types: self.fail('catalog', f'media reference {m} names no record of its type')
            counts[m] += 1
        if 0 in counts: self.fail('catalog', 'a Media record nothing refers to')
        for m, rec in enumerate(self.media_records):
            if rec[0] not in (PNG, JPEG) and counts[m] != 1: self.fail('catalog', f'Media record {m} is not an icon and is referred to {counts[m]} times')
        spans = sorted(self._opaque)
        for (_, end), (start, _) in zip(spans, spans[1:]):
            if start < end: self.fail('catalog', 'opaque media ranges overlap')

    def media(self, m):   # Media record m's payload, checked against its SHA-256
        mtype, at, size, sha = self.media_records[m]
        data = self.mm[at:at + size]
        if hashlib.sha256(data).digest() != sha: self.fail('media_hash', f'Media record {m} does not match its SHA-256 (damaged archive)')
        return data

    # ---- Manifest (SPEC §6) ----
    def _manifest(self, man):
        magic, v, hs, total, ndirs, nfiles, nents, nrefs, dir_off, file_off, ent_off, ref_off, path_off, path_size, rr = MANIFEST.unpack_from(man)
        if (magic, v, hs, total, rr) != (b'NXMF', 1, 96, len(man), bytes(16)): self.fail('manifest', 'invalid Manifest header')
        if not (1 <= ndirs <= 16_777_216 and nfiles <= 33_554_432 and nents <= 50_331_648 and path_size <= 2 << 30): self.fail('resource', 'Manifest counts above the format limits')
        b = self.budgets
        if ndirs > b.dirs or nfiles > b.files or nents > b.entries or nrefs > b.refs: self.fail('resource', f'{ndirs:,} folders, {nfiles:,} files, {nents:,} entries, {nrefs:,} block references: above this reader\'s budgets')
        tables = [self._table(dir_off, ndirs, DIRECTORY.size, len(man)), self._table(file_off, nfiles, FILE.size, len(man), True),
                  self._table(ent_off, nents, ENTRY.size, len(man), True), self._mtable(ref_off, nrefs, len(man))]
        spans = sorted([(0, MANIFEST.size)] + [t for t in tables if t] + [self._range(path_off, path_size, len(man), 'the path pool')])
        for (_, end), (start, _) in zip(spans, spans[1:]):
            if start < end: self.fail('manifest', 'Manifest tables overlap')
            if man[end:start] != bytes(start - end): self.fail('padding', 'nonzero Manifest padding')
        cursor = MANIFEST.size
        for at, count, size, a in ((dir_off, ndirs, 16, 8), (file_off, nfiles, 64, 8), (ent_off, nents, 24, 8), (ref_off, nrefs, 4, 4)):
            if count:
                cursor = align(cursor, a)
                if at != cursor: self.fail('manifest', 'a Manifest table is not at its packed offset')
                cursor += count * size
            elif at: self.fail('manifest', 'an empty Manifest table has an offset')
        cursor = align(cursor, 8)
        if path_off != cursor: self.fail('manifest', 'the path pool is not at its packed offset')
        if cursor + path_size != len(man): self.fail('manifest', 'the Manifest has bytes after its path pool')
        self.dirs = [d[:2] for d in DIRECTORY.iter_unpack(man[dir_off:dir_off + ndirs * 16])] if ndirs else []
        ents, ecur, pool_end = [], 0, path_off + path_size
        raw = list(ENTRY.iter_unpack(man[ent_off:ent_off + nents * 24])) if nents else []
        for d, (first, count, flags, rr) in enumerate(DIRECTORY.iter_unpack(man[dir_off:dir_off + ndirs * 16])):
            if first != ecur or first + count > nents or flags or rr: self.fail('manifest', f'folder {d}: invalid entry range or flags')
            prev = None
            for e in range(first, first + count):
                n_off, n_len, target, kind, flags, r0, r1 = raw[e]
                if kind not in (1, 2) or flags or r0 or r1 or not 1 <= n_len <= 4096: self.fail('path', f'invalid entry {e}')
                if n_off < path_off or n_off > pool_end or n_len > pool_end - n_off: self.fail('bounds', f'entry {e}: its name lies outside the path pool')
                name = man[n_off:n_off + n_len]
                try: name.decode('utf-8')
                except UnicodeDecodeError: self.fail('path', f'entry {e}: name {name!r} is not UTF-8')
                if b'\0' in name or b'/' in name or b'\\' in name or name in (b'.', b'..'): self.fail('path', f'entry {e}: unsafe name {name!r}')
                if prev is not None and name <= prev: self.fail('path', f'folder {d}: names not sorted, or {name!r} twice')
                prev = name
                if (kind == 1 and target >= ndirs) or (kind == 2 and target >= nfiles): self.fail('manifest', f'entry {e}: its target is out of range')
                ents.append((name, kind == 1, target))
            ecur += count
        if ecur != nents: self.fail('manifest', 'folders do not cover the entries')
        self.ents = ents
        self.refs = struct.unpack_from(f'<{nrefs}I', man, ref_off) if nrefs else ()
        self.files, rcur = [], 0
        for i, (size, first, count, log2, flags, r0, sha, r1) in enumerate(FILE.iter_unpack(man[file_off:file_off + nfiles * 64]) if nfiles else ()):
            if size > INT64_MAX or log2 not in (16, 17, 18, 19, 20) or flags or r0 or r1 != bytes(12): self.fail('manifest', f'invalid file record {i}')
            if count != -(-size >> log2) or first != rcur or first + count > nrefs: self.fail('manifest', f'file record {i}: its block count or range does not match its size')
            if count and max(self.refs[first:first + count]) >= self.nblocks: self.fail('manifest', f'file record {i}: a block reference is out of range')
            rcur += count
            self.files.append((size, first, count, log2, sha))
        if rcur != nrefs: self.fail('manifest', 'files do not cover the block references')

    def _mtable(self, at, count, total):   # the block reference table: 4-byte aligned
        if count == 0:
            if at: self.fail('structure', 'an empty Manifest table has an offset')
            return None
        if at == 0 or at % 4: self.fail('structure', 'a Manifest table offset is zero or misaligned')
        return self._range(at, count * 4, total, 'the block reference table')

    # ---- blocks (SPEC §7) ----
    def _blocks(self, data_off):
        last, check = data_off, 0
        for i, (at, stored, logical, codec, flags, r0, first) in enumerate(BLOCK.iter_unpack(self.index)):
            if flags or r0 or codec not in (0, 1) or not 1 <= logical <= MiB or not 1 <= stored <= MiB + 65536: self.fail('block', f'invalid block record {i}')
            if first != check: self.fail('block', f'block {i}: first check is not the running slice count')
            check += -(-logical // CHECK)
            if check * 4 > len(self.integrity): self.fail('structure', 'the integrity table is shorter than the blocks\' slices')
            if at % 16 or at < align(last, 16): self.fail('block', f'block {i}: overlapping or misaligned')
            self._range(at, stored, self.data_end, f'block {i}')
            if codec == 0 and stored != logical: self.fail('block', f'block {i}: raw, but stored and logical sizes differ')
            last = at + stored
        if self.nblocks:
            if last != self.data_end: self.fail('length', 'the Data region does not end at the last block')
            if check * 4 != len(self.integrity): self.fail('structure', 'the integrity table size does not match the blocks\' slices')
        for i, (size, first, count, log2, _) in enumerate(self.files):
            chunk = 1 << log2
            for k in range(count):
                if self._block(self.refs[first + k])[2] != min(chunk, size - k * chunk): self.fail('manifest', f'file record {i}: block {k} is not the size of its chunk')

    def _block(self, bid):   # (data offset, stored size, logical size, codec, first check)
        at, stored, logical, codec, _, _, first = BLOCK.unpack_from(self.index, bid * BLOCK.size)
        return at, stored, logical, codec, first

    def _resources(self):
        roots, kids = set(), {t for _, isdir, t in self.ents if isdir}
        snap_roots = {s.root for s in self.snapshots}
        for kind, root in self.resource_dirs:
            if root >= len(self.dirs) or root in roots or root in kids or root in snap_roots: self.fail('manifest', f'source resource folder {root} is invalid')
            roots.add(root)
            members = self.children(root)
            if not members or any(isdir for _, isdir, _ in members) or len({t for _, _, t in members}) != len(members): self.fail('manifest', 'a source resource is not a flat set of distinct files')
            if kind == 1 and (len(members) != 1 or members[0][0] != b'partition.hfs0'): self.fail('manifest', 'a system update resource without partition.hfs0')

    # ---- snapshot trees and identities (SPEC §6, §12) ----
    def _trees(self):
        b, visits, pbytes = self.budgets, 0, 0
        for s in self.snapshots:
            if s.root >= len(self.dirs): self.fail('manifest', f'snapshot {s.index}: root folder out of range')
            nodes, seen_d, seen_f, total = [(b'', 1, -1)], {s.root}, set(), 0
            todo = [(s.root, b'', 0)]
            while todo:
                d, pre, depth = todo.pop()
                for name, isdir, t in self.children(d):
                    path = pre + b'/' + name if pre else name
                    pbytes += len(path)
                    if isdir:
                        if depth + 1 > 256: self.fail('resource', f'snapshot {s.index}: folders nested deeper than 256')
                        if t in seen_d: self.fail('manifest', f'snapshot {s.index}: folder {path!r} is reached twice (a cycle or a repeated folder)')
                        seen_d.add(t); nodes.append((path, 1, -1)); todo.append((t, path, depth + 1))
                    else:
                        if t in seen_f: self.fail('manifest', f'snapshot {s.index}: file {path!r} is a file record already in this snapshot')
                        seen_f.add(t); nodes.append((path, 2, t)); total += self.files[t][0]
                    if len(nodes) > b.nodes: self.fail('resource', f'snapshot {s.index}: more than {b.nodes:,} files and folders (Budgets.nodes)')
            visits += len(nodes)
            if visits > b.visits or pbytes > b.path_bytes: self.fail('resource', 'the snapshots\' trees are larger than this reader\'s budgets (Budgets.visits, path_bytes)')
            if total != s.logical_size: self.fail('manifest', f'snapshot {s.index}: its files add up to {total:,} bytes, its record says {s.logical_size:,}')
            nodes.sort(key=lambda x: x[0])
            app = s.app
            pid = 0xFFFFFFFFFFFFFFFF if s.program == NO else self.programs[s.program].id
            h = hashlib.sha256(b'NX-SNAPSHOT-ID\0' + struct.pack('<HBQQBI16sI', 3, app.platform, app.id, pid, s.type, s.version, s.content_id, len(nodes)))
            for path, kind, t in nodes:
                h.update(struct.pack('<BI', kind, len(path))); h.update(path)
                if kind == 2: h.update(struct.pack('<Q', self.files[t][0])); h.update(self.files[t][4])
            if h.digest() != s.identity: self.fail('snapshot_identity', f'snapshot {s.index}: its identity does not match its tree')
            top = {name: (isdir, t) for name, isdir, t in self.children(s.root)}
            if top.get(b'exefs', (False,))[0]: s.exefs = top[b'exefs'][1]
            if top.get(b'romfs', (False,))[0]: s.romfs = top[b'romfs'][1]
            s.kind = ('tree' if s.exefs != NO or s.romfs != NO else 'native' if any(n.lower().endswith(b'.nca') and not d for n, (d, _) in top.items()) else
                      'empty' if not top else 'other')
            s.name = s.describe()
        for a in self.apps:
            types = {s.type for s in a.snapshots}
            if bool(a.flags & 1) != (BASE in types) or bool(a.flags & 2) != (DLC in types): self.fail('catalog', f'application {a.id:016X}: base/DLC flags disagree with its snapshots')

    # ---- reading ----
    def children(self, d):   # [(name, is dir, folder or file index)], sorted by name (bytes), as the Manifest stores them
        first, count = self.dirs[d]
        return self.ents[first:first + count]

    def child(self, d, name):   # the index of the file name in folder d, or None
        return next((t for n, isdir, t in self.children(d) if n == name and not isdir), None)

    def subdir(self, d, name):   # the index of the folder name in folder d, or None
        return next((t for n, isdir, t in self.children(d) if n == name and isdir), None)

    def size(self, i): return self.files[i][0]
    def sha(self, i): return self.files[i][4]

    def tree_bytes(self, d):   # the uncompressed size of everything under folder d (a folder of a snapshot's tree: no cycles)
        return sum(self.files[t][0] if not isdir else self.tree_bytes(t) for _, isdir, t in self.children(d))

    def block(self, bid, crc=False):
        """Block bid's logical bytes: a raw block as stored, a zstd block decoded by the rules of SPEC §7 (one frame, its content size, no dictionary, a window of 1 MiB at most, nothing after
        it), never more than its logical size; crc: its slices checked against the integrity table"""
        at, stored, logical, codec, first = self._block(bid)
        raw = self.mm[at:at + stored]
        if codec == 0: data = raw
        else:
            if zstd is None: raise Error('reading a zstd block needs the zstd module: compression.zstd (Python 3.14+) or pip install backports.zstd', 'zstd')
            def bad(why) -> NoReturn: self.fail('zstd', f'block {bid}: {why} (damaged archive)')
            if raw[:4] != ZSTD_MAGIC or len(raw) < 6: bad('not one standard zstd frame')
            if not raw[4] & 0x20:   # the window descriptor of a frame without the single-segment flag (zstd's format, 3.1.1.1.2): libzstd skips its own limit
                e = raw[5] >> 3      # when the output buffer holds the whole content, so it is checked here
                if (1 << (10 + e)) + ((1 << (10 + e)) >> 3) * (raw[5] & 7) > MiB: bad('its frame window is larger than 1 MiB')
            try:
                if zstd.get_frame_size(raw) != stored: bad('more than one frame, or bytes after the frame')
                info = zstd.get_frame_info(raw)
                if info.decompressed_size != logical: bad(f'its frame says {info.decompressed_size} bytes, the block {logical}')
                if info.dictionary_id: bad('its frame needs a dictionary')
                dec = zstd.ZstdDecompressor(options={zstd.DecompressionParameter.window_log_max: 20})
                data = dec.decompress(raw, max_length=logical)
            except zstd.ZstdError as e: bad(str(e))
            if len(data) != logical or not dec.eof or dec.unused_data: bad('its frame does not decode to exactly its logical size')
        if crc: self._check(bid, data, first)
        return data

    def _check(self, bid, data, first):
        for k in range(0, len(data), CHECK):
            if crc32c(data[k:k + CHECK]) != struct.unpack_from('<I', self.integrity, (first + k // CHECK) * 4)[0]:
                self.fail('block_hash', f'block {bid}: its bytes fail their CRC-32C at {k:#x} (damaged archive)')

    def copy(self, i, out):
        """File i's content to out (anything with write), streamed block by block and checked against its size and SHA-256 (and with crc, each block's CRC-32C); returns its size"""
        size, first, count, _, sha = self.files[i]
        h, n = hashlib.sha256(), 0
        for k in range(count):
            data = self.block(self.refs[first + k], self.crc)
            h.update(data); out.write(data); n += len(data)
        if n != size or h.digest() != sha: self._damaged(i)
        return n

    def _damaged(self, i):   # file i failed its SHA-256: name it, and the block whose CRC-32C fails
        _, first, count, _, _ = self.files[i]
        where = self.file_path(i)
        for k in range(count):
            bid = self.refs[first + k]
            try: self.block(bid, crc=True)
            except Error as e: self.fail(e.code, f'{where}: block {bid} fails its {"CRC-32C" if e.code == "block_hash" else "zstd frame check"} (damaged archive)')
        self.fail('file_hash', f'{where} does not match its SHA-256 (damaged archive)')

    def file_path(self, i):   # a path of file record i, for messages ('file record i' when no folder holds it)
        parent = {}
        for d, (first, count) in enumerate(self.dirs):
            for name, isdir, t in self.ents[first:first + count]:
                parent.setdefault((isdir, t), (d, name))
        parts, key, roots = [], (False, i), {s.root: s for s in self.snapshots}
        while key in parent and len(parts) <= 257:
            d, name = parent[key]; parts.append(shown(name.decode(errors='replace')))
            if d in roots: return f'{roots[d].name}: {"/".join(reversed(parts))}'
            key = (True, d)
        return '/'.join(reversed(parts)) if parts else f'file record {i}'

    def read(self, i, limit=None):   # file i whole, checked; limit: the most bytes the caller takes, refused (code resource) before anything is read
        if limit is not None and self.size(i) > limit: raise Error(f'{self.file_path(i)}: {self.size(i):,} bytes, above the {limit:,} this reader takes for it', 'resource')
        class Buf(bytearray):
            write = bytearray.extend
        b = Buf(); self.copy(i, b); return bytes(b)

    def head(self, i, n=32):   # file i's first n bytes (fewer for a shorter file), for a survey's RomFS manifest: from its first block, not checked against the SHA-256, which covers the whole file
        size, first, count, _, _ = self.files[i]
        out = b''
        for k in range(count):
            if len(out) >= min(n, size): break
            out += bytes(self.block(self.refs[first + k]))
        return out[:min(n, size)]

    def verify(self, crc=True, progress=None):
        """Full verification (SPEC §12 level 4): every Media payload's SHA-256, every block decoded by the zstd rules and checked against its slices' CRC-32C (once per block, also when
        its files' SHA-256 would pass: an archive whose integrity table disagrees with its data fails every read of the format's own reader), and every file record's SHA-256.
        crc is kept for callers: the blocks' CRC-32C are always checked here. progress(done, total) per block, then per file. Raises Error"""
        for m in range(len(self.media_records)): self.media(m)
        for bid in range(self.nblocks):
            if progress and not bid % 64: progress(bid, self.nblocks, 'blocks')
            self.block(bid, crc=True)
        class Sink:
            def write(self, b): pass
        sink, self.crc, crc = Sink(), False, self.crc   # every block's CRC-32C is checked already
        try:
            for i in range(len(self.files)):
                if progress and not i % 256: progress(i, len(self.files), 'files')
                self.copy(i, sink)
        finally: self.crc = crc

    # ---- metadata ----
    def meta(self, s):
        """Snapshot s's own control data: {'nacp': bytes or None, 'icon': bytes or None, 'title': str or None (its display title)}, from its application's record when s is its metadata
        snapshot, else from the metadata history"""
        if (rec := self._display_record(s)) is None: return {'nacp': None, 'icon': None, 'title': None}
        nacp, icon, local, title = rec
        def pick(rows, default, none):   # the default, else the American English one, else English, else the first (as pack_nup.control picks an icon)
            if default != none: return default
            by = {lang.lower(): v for lang, v in rows if v != none}
            return by.get('en-us', by.get('en', next(iter(by.values()), none)))
        title = pick([(lang, display_title(t)) for lang, t, _ in local], display_title(title), None)   # a title of only spaces or control characters is none: a localized one then
        icon = pick([(lang, i) for lang, _, i in local], icon, NO)
        return {'nacp': self.media(nacp) if nacp != NO else None, 'icon': self.media(icon) if icon != NO else None, 'title': title}

    def localized_icons(self, s):   # the icons snapshot s's own display record lists per language (a new icon set with set-metadata clears them: NXConvert's CLI.md)
        rec = self._display_record(s)
        return [self.media(i) for _, _, i in rec[2] if i != NO] if rec is not None else []

    def _display_record(self, s):   # (nacp, icon, localized, title) of snapshot s's own display record: its application's when s is its metadata snapshot, else the metadata history's; None without one
        a = s.app
        if a.meta_snapshot == s.index: return a.nacp, a.icon, a.localized, a.title
        if (row := self.history.get(a.index, {}).get(s.index)) is not None: return row['nacp'], row['icon'], row['localized'], row['title']
        return None


NPDM_MAX, MODULE_MAX = MiB, 1 << 30   # the largest main.npdm read whole (real ones are a few KB), and the largest code module or NRO written out (real ones are tens of MB)
SELECTORS = {0: 'unknown', 1: 'switch1', 2: 'switch2'}   # the platform after a title ID (--title-id 0100…:switch2), for an archive that holds one ID on two platforms
_UNSHOWN = re.compile('[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]')   # C0, DEL, C1 and the bidirectional overrides


def shown(text):   # an archive's string as it is printed: control characters escaped, so a title cannot drive the terminal (set its title, erase or rewrite lines)
    return _UNSHOWN.sub(lambda m: f'\\x{ord(m.group()):02x}' if ord(m.group()) < 0x100 else f'\\u{ord(m.group()):04x}', text) if text else text


def parse_title_id(text):   # '0100…' or '0100…:switch1' / ':switch2' / ':unknown' (or :1, :2, :0) → (application ID, platform or None); None when it is neither
    m = re.fullmatch(r'([0-9A-Fa-f]{16})(?::(switch1|switch2|unknown|[012]))?', text.strip(), re.IGNORECASE)
    if not m: return None
    plat = m.group(2)
    return int(m.group(1), 16), None if plat is None else int(plat) if plat.isdigit() else {v: k for k, v in SELECTORS.items()}[plat.lower()]


def platform_tag(n, a):   # 'switch1', 'switch2' or 'unknown' when the archive holds a's ID on another platform too (its build folder and app are kept apart by it), else ''
    return SELECTORS[a.platform] if any(b is not a and b.id == a.id for b in n.apps) else ''


class HostNames:
    """Archive names written as host files (ExeFS modules, a survey's NROs): each one component of at most 255 bytes with no control characters (a survey's RomFS manifest is tab- and
    line-separated), and no two in one folder that a case- and normalization-insensitive volume (APFS by default) takes for the same name, so no file overwrites another. add(parts) → the
    names as str; raises Error (code path)"""
    def __init__(self, where):
        self.where, self.seen = where, {}

    def add(self, parts):
        out, key = [], ()
        for raw in parts:
            name = os.fsdecode(raw)
            if name in ('', '.', '..') or '\0' in name or Path(name).name != name: raise Error(f'{self.where}: invalid name {name!r} for a host file', 'path')
            if any(ord(c) < 0x20 or ord(c) == 0x7F for c in name): raise Error(f'{self.where}: name {name!r} holds control characters, which no host file name here takes', 'path')
            if len(os.fsencode(name)) > 255: raise Error(f'{self.where}: name {shown(name[:40])!r}… is {len(os.fsencode(name)):,} bytes, longer than a host file name (255)', 'path')
            fold = unicodedata.normalize('NFD', unicodedata.normalize('NFD', name).casefold())
            other = self.seen.setdefault(key + (fold,), name)
            if other != name: raise Error(f'{self.where}: names {other!a} and {name!a} differ only in case or Unicode normalization: one file on a case-insensitive volume', 'path')
            out.append(name); key += (fold,)
        return out


def primary(a):   # the application's own program: its ID is the application's, else its one primary program, else its one program
    progs = a.programs
    return next((p for p in progs if p.id == a.id), None) or (ps[0] if len(ps := [p for p in progs if p.kind == 0]) == 1 else progs[0] if len(progs) == 1 else None)


def npdm_id(n, k):   # the program ID of snapshot k's exefs/main.npdm, read whole only when it is the size of an NPDM
    try: return pack_nup.program_id(n.read(n.child(k.exefs, b'main.npdm'), NPDM_MAX), f'{k.name} exefs/main.npdm')
    except Error: raise
    except pack_nup.Error as e: raise Error(str(e), 'format') from e


def has_game(n, k):   # whether snapshot k holds game files: exefs/main, or files in romfs/ (an NCA snapshot: its Program NCA, which nxconvert requires and nx_extract reads). A base snapshot
    # without them holds only the application's metadata, as a NUP's empty base record
    if k.kind == 'native': return True
    return (k.exefs != NO and n.child(k.exefs, b'main') is not None) or (k.romfs != NO and bool(n.children(k.romfs)))


def scan(n, want=None, platform=None):
    """What an NX holds for the game to pack: (title ID, base snapshot or None, {update version: snapshot}, {DLC title ID: snapshot}), with the checks pack_nup.scan makes.
    want: the application ID (--title-id) when the archive holds more than one game; platform: its platform (1 Switch 1, 2 Switch 2, 0 unknown) when it holds that ID on two.
    A base snapshot with no game files is no base game, as a NUP's empty base record (pack_nup.scan); its metadata still serves its updates (base_of). Lines about what is left out go to n.notes"""
    games = [a for a in n.apps if any(s.type != DLC for s in a.snapshots)]
    def listing(apps):
        return ', '.join(f'{a.id:016X}{f":{SELECTORS[a.platform]}" if any(b is not a and b.id == a.id for b in apps) else ""} ({PLATFORMS[a.platform]}{f", {shown(a.title)}" if a.title else ""})'
                         for a in apps)
    if want is not None:
        mine = [a for a in games if a.id == want and (platform is None or a.platform == platform)]
        what = f'{want:016X}' + (f':{SELECTORS[platform]}' if platform is not None else '')
        if not mine: raise Error(f'no game {what} (--title-id / TITLE_ID) in {n.path.name}, which holds {listing(games) or "no game, only DLC"}', 'select')
        games = mine
    if not games: raise Error(f'{n.path.name}: no game, only DLC ({listing(n.apps)})', 'select')
    if len(games) > 1:
        twice = len({a.id for a in games}) < len(games)
        raise Error(f'{n.path.name} holds {len(games)} games: {listing(games)}; name the one to pack with --title-id / TITLE_ID'
                    + (' as listed, with its platform after the ID (:switch1, :switch2 or :unknown): the archive holds one title ID on two platforms' if twice else ''), 'select')
    a = n.selected = games[0]
    p = primary(a)
    if p is None: raise Error(f'{n.path.name}: application {a.id:016X} has {len(a.programs)} programs and none is its own: ' + ', '.join(f'{q.id:016X}' for q in a.programs), 'select')
    if len(a.programs) > 1: n.notes.append(f'{n.path.name}: application {a.id:016X} has {len(a.programs)} programs: packing {p.id:016X}, its own')
    snaps = [s for s in a.snapshots if s.program == p.index and s.type != DLC]
    for s in a.snapshots:
        if s.kind != 'native' or s not in snaps and s.type != DLC: continue
        if a.platform != 1: raise Error(f'{s.name}: NCA snapshots of a {PLATFORMS[a.platform]} game are not supported: NXFormat 1.0.3 writes only Switch 1 games that way; make the NX from '
                                        'extracted folders (nxconvert pack-tree / pack-nup)', 'native')
        if s.type in (STANDALONE, UNKNOWN): raise Error(f'{s.name}: an NCA snapshot of type {s.type} ({TYPES[s.type]}), which nxconvert never writes; not supported', 'native')
    for s in snaps:
        if s.type == UNKNOWN: n.notes.append(f'{s.name}: a snapshot of unknown type, left out')
    snaps = [s for s in snaps if s.type != UNKNOWN]
    if not any(s.kind in ('tree', 'native') for s in snaps): raise Error(f'{n.path.name}: no snapshot of {a.id:016X} holds exefs/ or romfs/, nor NCA files', 'select')
    natives = [s for s in snaps if s.kind == 'native'] + [s for s in a.snapshots if s.type == DLC and s.kind == 'native']
    if natives: probe(n, a, natives)   # their content metas against the Catalog, a DLC's add-on title ID
    bases = [s for s in snaps if s.type == BASE]
    if len(bases) > 1: raise Error(f'{n.path.name}: {len(bases)} base game snapshots of {a.id:016X} (versions ' + ', '.join(str(s.version) for s in bases) + ')', 'select')
    base, vers = (bases[0] if bases and has_game(n, bases[0]) else None), {}
    if bases and base is None:
        held = "the application's metadata" if a.meta_snapshot == bases[0].index else 'a tree'
        n.notes.append(f'{bases[0].name}: no game files (no exefs/main, nothing in romfs/), only {held}: no base game, so each update is taken as the whole game')
    for s in snaps:
        if s.type in (UPDATE, STANDALONE):
            if s.version in vers or base is not None and s.version == base.version: raise Error(f'{n.path.name}: two snapshots of version {s.version}', 'select')
            vers[s.version] = s
    if base is None and not vers: raise Error(f'{n.path.name}: no snapshot of {a.id:016X} holds the game\'s files (exefs/main or romfs/)', 'select')
    ids = {npdm_id(n, s) for s in snaps if s.exefs != NO and n.child(s.exefs, b'main.npdm') is not None}
    if ids - {p.id}: raise Error(f'{n.path.name}: program {p.id:016X} has code of other program IDs: ' + ', '.join(f'{x:016X}' for x in sorted(ids - {p.id})), 'select')
    app = p.id
    if app & 0xFFF: raise Error(f'{n.path.name}: program ID {app:016X} is not a base title ID', 'select')
    dlc = {}
    for s in a.snapshots:
        if s.type != DLC: continue
        if s.title_id is None: n.notes.append(f'{s.name}: a DLC with no add-on title ID, left out'); continue
        if not 0 < s.title_id - app - 0x1000 <= 2000: raise Error(f'{n.path.name}: {s.title_id:016X} is not a DLC of {app:016X}', 'select')
        if s.romfs == NO and s.kind != 'native': raise Error(f'{n.path.name}: DLC {s.title_id:016X} has no romfs/', 'select')
        if s.title_id in dlc: n.notes.append(f'{n.path.name}: DLC {s.title_id:016X} in versions {dlc[s.title_id].version} and {s.version}: packing the newer')
        if s.title_id not in dlc or s.version > dlc[s.title_id].version: dlc[s.title_id] = s
    return app, base, vers, dlc


def exefs(n, k, dst):   # the snapshot's exefs/ into dst, kept as it is when every file there has the same content
    if k.kind == 'native': raise Error(f'internal: {k.name} is an NCA snapshot, read by nx_extract', 'native')
    if k.exefs == NO: raise Error(f'{k.name}: no exefs/', 'select')
    files, names = [], HostNames(f'{k.name} exefs/')
    for name, isdir, i in n.children(k.exefs):
        if isdir or name.startswith(b'.'): continue
        names.add([name])   # names were checked as archive path components; a host file name must also be one component the volume can hold, and unique on a case-insensitive one
        if n.size(i) > MODULE_MAX: raise Error(f'{k.name}: exefs/{os.fsdecode(name)!r} is {n.size(i):,} bytes, larger than any code module ({MODULE_MAX:,} at most)', 'resource')
        files.append((name, i))
    def same():
        if not dst.is_dir() or {os.fsencode(p.name) for p in dst.iterdir()} != {name for name, _ in files}: return False
        def sha(f):
            with open(f, 'rb') as h: return hashlib.file_digest(h, 'sha256').digest()
        return all(sha(dst / os.fsdecode(name)) == n.sha(i) for name, i in files)
    if same(): return
    tmp = dst.with_name(dst.name + '.partial')
    shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(parents=True)
    try:
        for name, i in files:
            with open(tmp / os.fsdecode(name), 'wb') as f: n.copy(i, f)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True); raise
    shutil.rmtree(dst, ignore_errors=True); tmp.rename(dst)


def exefs_bytes(n, k):   # what exefs() writes for snapshot k
    return sum(n.size(i) for name, isdir, i in n.children(k.exefs) if not isdir and not name.startswith(b'.')) if k.exefs != NO else 0


entries = pack_nup.entries   # romfs_image entries for a folder of the archive


def tree_digest(n, ents):   # the RomFS tree as the image holds it: names, folders, sizes and SHA-256s, in entry order; the same after an append edit, a recompression or a compaction
    h = hashlib.sha256(b'NX-romfs\0')
    for name, i, isdir, _, _ in ents:
        h.update(struct.pack('<I?Q', len(name), isdir, 0 if isdir else n.size(i))); h.update(name)
        if not isdir: h.update(n.sha(i))
    return h.digest()


def pack(n, d, img, say=print, step=lambda s: None):
    """The RomFS folder d of the archive → img. Returns how: 'kept' (the stamp says the tree and the packers are the same), 'verified' (the stamp is from another packer, but the image checks
    against the archive's hashes: its stamp is renewed) or 'packed'. step(name): the step it is in, for a progress line"""
    img.parent.mkdir(parents=True, exist_ok=True)
    ents, dst = entries(n, d), os.fspath(img)
    digest = hashlib.sha256(Path(romfs_image.__file__).read_bytes() + Path(__file__).read_bytes() + tree_digest(n, ents)).hexdigest()
    if romfs_image.reusable(dst, digest): return 'kept'
    if img.is_file():
        step('checking the image'); say(f'checking {img} against {n.path.name}')
        if identity := romfs_image.verify_image(ents, dst, n.size, n.sha):
            romfs_image.stamp(dst, digest, identity)
            say('  kept: the image matches the archive')
            return 'verified'
    step('unpacking'); say(f'packing {n.path.name} folder {d} → {img}')
    part = dst + '.part'
    try: romfs_image.publish(romfs_image.write(ents, dst, n.copy), dst, digest)
    except BaseException:
        Path(part).unlink(missing_ok=True); raise
    say(f'  {len(ents):,} entries, {img.stat().st_size / 2**30:.2f} GB')
    return 'packed'


def base_of(k):
    """The exact base snapshot of snapshot k (its program's base, also one that holds only metadata), or None. An update with no control data of its own runs with its base game's, as
    the console inherits an unchanged Control through the update's base (READER.md); never with another update's, whose NACP and display version are that update's (SPEC §4)"""
    return next((s for s in k.app.snapshots if s.type == BASE and s.program == k.program), None) if k.type != DLC else None


def app_package(n, k):   # (as pack_nup.app_package, for the NSP script's survey) the snapshot whose control data stands in for k's when the archive has no base game: k's exact base, or none
    return base_of(k)


def media_meta(k, fallback, say=print):
    """Snapshot k's control data in the archive's Media ({'nacp', 'icon', 'title'}), what it lacks from fallback's (its base game). A NACP record that is not 0x4000 bytes is left out, with a line:
    NXConvert 1.0.0 and 1.0.1 may have stored something else as the NACP of a NUP whose meta block was numbered one too low (pack_nup.SHIFTED), and the reader takes a NACP of any size.
    That snapshot's display title goes with it: such an archive's title is the NUP's publisher record (NXConvert 1.0.2's notes: wrong title, publisher and display version)"""
    snaps = [k] if fallback is None or fallback is k else [k, fallback]
    metas = [s.nx.meta(s) for s in snaps]
    for s, m in zip(snaps, metas):
        if m['nacp'] is not None and len(m['nacp']) != pack_nup.NACP_SIZE:
            pack_nup.tell(s, f"{s.name}: the archive's NACP for it is {len(m['nacp']):,} bytes, not {pack_nup.NACP_SIZE:,} (0x4000): it is not a NACP, left out, and so is its "
                             'display title, taken from the wrong record too (repack the NX with NXConvert 1.0.2 or later)', say)
            m['nacp'] = m['title'] = None   # NXConvert 1.0.0 and 1.0.1 took a shifted NUP's publisher record as its title: never the app's name
    return {key: next((m[key] for m in metas if m[key]), None) for key in metas[0]}


EDITED_ICON = pack_nup.EDITED_ICON   # beside an NCA snapshot's icon.jpg: the archive's own icon for it when that differs from the Control NCA's, which the NSP script takes first
TITLE_MAX = 0x1FF   # the bytes of a title kept as the app's name: a NACP's name field holds as many (0x200 with its NUL); the format allows 4,096


def display_title(title):   # an archive's display title as an app's name: control and bidirectional characters dropped, spaces trimmed, at most TITLE_MAX bytes of UTF-8; None when nothing is left
    t = _UNSHOWN.sub('', title or '').strip().encode()[:TITLE_MAX].decode('utf-8', 'ignore').strip()
    return t or None


def title_file(out, title):
    """out/title.txt: the archive's display title for a version with no NACP (nxconvert --fallback-title, or a title typed in NXConvert's sidebar), which the NSP script takes as the app's
    name then (build_ipa_from_nsp.control_name); as display_title makes it. None removes an older one: a NACP names the game"""
    title = display_title(title)
    if title and not (out / 'control.nacp').is_file(): (out / pack_nup.TITLE_FILE).write_text(title, encoding='utf-8')
    else: (out / pack_nup.TITLE_FILE).unlink(missing_ok=True)


def control(k, out, fallback=None, say=print):
    """The snapshot's control data beside its ExeFS (control.nacp, icon.jpg, and title.txt without a NACP); what it lacks comes from fallback's (its base game). Returns {'nacp', 'icon', 'title'}"""
    meta = media_meta(k, fallback, say)
    for name, data in (('control.nacp', meta['nacp']), ('icon.jpg', meta['icon']), (EDITED_ICON, None)):   # (an NCA snapshot's, left by an earlier build of another archive)
        if data: (out / name).write_bytes(data)
        else: (out / name).unlink(missing_ok=True)
    title_file(out, meta['title'])
    return meta


def romfs_of(k, base=None):   # the RomFS folder a version runs with: its own, as every NX snapshot is a complete tree (never the base game's)
    if k.kind == 'native': raise Error(f'internal: {k.name} is an NCA snapshot, read by nx_extract', 'native')
    if k.romfs == NO: raise Error(f'{k.name}: no romfs/ in this snapshot (an NX snapshot is the whole game: it does not take the base game\'s)', 'select')
    return k.romfs


def pack_version(n, k, base, app, out, say=print, step=lambda s: None, note=None):
    """One snapshot → out/ExeFS, out/RomFS.img and its control data; returns how pack() got the image. note: where the lines about the control data go (as pack_nup.pack_version)"""
    if k.kind == 'native': return pack_native(n, k, base, app, out, say, step, note)
    if k.exefs == NO or n.child(k.exefs, b'main') is None or n.child(k.exefs, b'main.npdm') is None: raise Error(f'{k.name}: no exefs/main and exefs/main.npdm', 'select')
    if (pid := npdm_id(n, k)) != app: raise Error(f'{k.name}: program ID {pid:016X}, the game is {app:016X}', 'select')
    d = romfs_of(k, base)
    out.mkdir(parents=True, exist_ok=True)
    exefs(n, k, out / 'ExeFS')
    how = pack(n, d, out / 'RomFS.img', say, step)
    if not control(k, out, base_of(k), note or say)['nacp']:
        say(f'{k.name}: the archive has no NACP for this version' + ('' if k.type == BASE else ' or its base game') + ': the game\'s name and languages come from elsewhere (its profile)')
    return how


def pack_dlc(n, app, dlc, aoc, say=print):   # {DLC title ID: snapshot} → aoc/<index>.img; images of DLC no longer in the archive go
    want = {f'{tid - app - 0x1000}.img': k for tid, k in dlc.items()}
    if aoc.is_dir():
        for f in aoc.iterdir():
            if f.name.removesuffix('.inputs.json') not in want: f.unlink()
    for (name, k), tid in zip(want.items(), dlc):
        if k.kind == 'native': pack_native_dlc(n, app, tid, k, aoc / name, say)
        else: pack(n, romfs_of(k), aoc / name, say)


def listing(n):   # the --list lines
    out = [f'{n.path.name}: NX {n.version[0]}.{n.version[1]}, generation {n.generation}, {n.archive_size:,} bytes, {n.nblocks:,} blocks, {len(n.files):,} file records']
    for a in n.apps:
        out.append(f'{a.id:016X} {PLATFORMS[a.platform]}' + (f': {shown(a.title)}' + (f' ({shown(a.publisher)})' if a.publisher else '') if a.title else ''))
        for s in a.snapshots:
            pid = '-' if s.program == NO else f'{n.programs[s.program].id:016X}'
            out.append(f'  {s.index:3} {TYPES[s.type]:17} v{s.version:<10} program {pid}  {s.kind:6} {s.logical_size / 2**30:7.2f} GB'
                       + (f'  add-on {s.title_id:016X}' if s.title_id is not None else '') + (f'  display {shown(s.display_version)}' if s.display_version else '')
                       + (f'  build {s.build_id.hex()[:16]}' if s.flags & 1 else '') + ('  (metadata)' if a.meta_snapshot == s.index else ''))
    return out


def free_bytes(p):   # free bytes on the volume of p, or of the nearest folder above it that exists
    p = Path(p)
    while not p.exists(): p = p.parent
    return shutil.disk_usage(p).free


# ---- NCA snapshots (nxconvert pack): read by nx_extract --plain ----
REPO = Path(__file__).resolve().parents[1]
NX_EXTRACT = 'dm/tools/nx_extract_bin/nx_extract'   # the committed native executable (dm/tools/native_tools.sh), built from dm/tools/nx_extract
NCA_NAME = re.compile(rb'[0-9a-f]{32}(\.cnmt)?\.nca')
NCA_FILES_MAX, META_MAX, NCA_HEAD, GiB = 4096, 16 * MiB, 0xC00, 1 << 30
CT_PROGRAM, CT_META, CT_CONTROL, CT_MANUAL, CT_DATA, CT_PUBLIC = range(6)   # NCA content types (header 0x205)
GAME_TYPES, DLC_TYPES = frozenset({CT_PROGRAM, CT_META, CT_CONTROL, CT_MANUAL}), frozenset({CT_META, CT_DATA, CT_PUBLIC})   # what a version or a DLC stages
GC_LIMIT = '100000000'   # nx_extract's GC heap, 4 GiB: hexadecimal without 0x, as NativeAOT reads DOTNET_GCHeapHardLimit (it ignores a value with 0x)
CONTENTS_TIMEOUT = 120   # seconds for the scan's --contents run (meta NCAs only)
RUN_BASE, RUN_RATE = 300, 10 * MiB   # every other run's time limit: 300 s plus 1 s per 10 MiB staged (tables that never end would hold the build forever)
WRITE_SLACK = 256 * MiB   # what a run may write beyond the bound the disk checks count (version_bytes): a RomFS image's index, a manifest
NATIVE_PACKER = 1   # in the stamp of every NCA snapshot's output: raise it when what pack_native, pack_native_dlc or survey_native write changes (nx_extract's own source is stamped too)
STAMP = 'native.inputs.json'
TOOL_FIX = 'rebuild it with dm/tools/native_tools.sh nx_extract'


def nx_extract_source_sha(repo=REPO):   # the same convention as nx_extract --source-sha: the sha256 of Program.cs and nx_extract.csproj, in that order, first 16 digits
    return hashlib.sha256(b''.join((Path(repo) / 'dm/tools/nx_extract' / f).read_bytes() for f in ('Program.cs', 'nx_extract.csproj'))).hexdigest()[:16]


def tool_error(why):
    return Error(f'reading an NX made by nxconvert pack needs nx_extract built from the in-repo source: {why}; {TOOL_FIX}', 'tool')


def find_tool(repo=REPO, env=None):
    """The committed nx_extract, once it has shown that it runs and was built from the in-repo source (after an edit to Program.cs the old executable would read with the old code)"""
    exe = Path(repo) / NX_EXTRACT
    try: r = subprocess.run([str(exe), '--source-sha'], capture_output=True, text=True, env=env, timeout=60, errors='replace')
    except (OSError, subprocess.SubprocessError) as e: raise tool_error(f'{exe} does not start ({e})') from e
    got, want = r.stdout.strip(), nx_extract_source_sha(repo)
    if r.returncode or not got: raise tool_error(f'{exe} does not run (exit code {r.returncode})')
    if got != want: raise tool_error(f'{exe} was built from source {got}, the repository holds {want}')
    return exe


class Native:
    """How NCA snapshots are read, set on an open archive as n.nca_tool by its caller. tool(): the nx_extract path, asked for (and checked) the first time an NCA snapshot is touched,
    then kept; tmp: the folder the NCA files are staged under (<tmp>/nca/<label>/; None: <build folder>/tmp); logs: the folder of each run's output (None: <build folder>/logs);
    allow_damaged: --allow-damaged; env: nx_extract's environment (None: this process's)"""
    def __init__(self, tool=None, tmp=None, logs=None, allow_damaged=False, env=None):
        self._tool, self.tmp, self.logs, self.allow_damaged, self.env = tool or find_tool, tmp, logs, allow_damaged, env
        self._exe = None

    def tool(self):
        if self._exe is None: self._exe = Path(self._tool())
        return self._exe


def _native(n) -> Native:
    if n.nca_tool is None: raise Error(f'{n.path.name}: reading its NCA snapshots needs nx_extract, which this caller did not set up', 'tool')
    return n.nca_tool


def native_files(n, k):
    """[(name, file index)] of NCA snapshot k's root, before anything is read: only files named <32 lowercase hex>.nca or .cnmt.nca (all NXConvert writes there), at most 4,096,
    each at least an NCA header long"""
    kids = n.children(k.root)
    if len(kids) > NCA_FILES_MAX: raise Error(f'{k.name}: {len(kids):,} files, more than the {NCA_FILES_MAX:,} an NCA snapshot may hold', 'nca')
    out = []
    for name, isdir, i in kids:
        if isdir or not NCA_NAME.fullmatch(name):
            raise Error(f'{k.name}: {shown(os.fsdecode(name))!r} is not a decrypted NCA\'s file name (<32 hex>.nca or <32 hex>.cnmt.nca); NXConvert never writes one into an NCA snapshot', 'nca')
        if n.size(i) < NCA_HEAD: raise Error(f'{k.name}: {name.decode()} is {n.size(i):,} bytes, shorter than an NCA header (3,072 bytes)', 'nca')
        out.append((name.decode(), i))
    return out


def nca_head(n, k, name, i):
    """The content type of NCA file i, from its header in the file's first block (CRC-32C checked): the DNCA marker, a content type an NCA has and the size field are checked here,
    before gigabytes are staged; nx_extract checks the whole header again"""
    if i in n.heads: return n.heads[i]
    size, first, _, _, _ = n.files[i]
    head = n.block(n.refs[first], crc=True)[:NCA_HEAD]   # blocks are 64 KiB at least and the file is 3,072 bytes at least: the header is in the first block
    def bad(why) -> NoReturn: raise Error(f'{k.name}: {name}: {why}', 'nca')
    magic = head[0x200:0x204]
    if magic != b'DNCA': bad('a plaintext NCA without the DNCA marker of a decrypted NCA' if magic in (b'NCA3', b'NCA2', b'NCA0') else 'not a decrypted NCA (still encrypted, or not an NCA)')
    if head[0x205] > CT_PUBLIC: bad(f'content type {head[0x205]} is not one an NCA has')
    if (declared := struct.unpack_from('<Q', head, 0x208)[0]) != size: bad(f'its header says {declared:,} bytes, the file has {size:,}')
    n.heads[i] = head[0x205]
    return head[0x205]


def chosen(n, k, types):   # [(name, file index, content type)] of k's NCA files whose content type is in types: what a step stages
    return [(name, i, t) for name, i in native_files(n, k) if (t := nca_head(n, k, name, i)) in types]


def staging_bytes(n, k):   # what packing snapshot k stages (an NCA snapshot), for the disk checks
    if k.kind != 'native': return 0
    return sum(n.size(i) for _, i, _ in chosen(n, k, DLC_TYPES if k.type == DLC else GAME_TYPES))


def version_bytes(n, k, base=None):
    """An upper bound of what packing snapshot k writes: a tree's RomFS and ExeFS; an NCA snapshot's Program, Control and Manual NCAs (a DLC: its data NCAs), as the ExeFS and the
    patched RomFS are at most the base section and the patch section"""
    if k.kind != 'native': return n.tree_bytes(romfs_of(k, base)) + exefs_bytes(n, k)
    out = {CT_DATA, CT_PUBLIC} if k.type == DLC else {CT_PROGRAM, CT_CONTROL, CT_MANUAL}
    return sum(n.size(i) for _, i, t in chosen(n, k, out))


def stage(n, files, dst, fresh=True):
    """files ([(name, file index, type)]) streamed out of the archive into the new folder dst (<tmp>/nca/<label>), each checked against its SHA-256; returns the bytes written.
    fresh: <tmp>/nca is emptied first (what a killed run left there)"""
    shutil.rmtree(dst.parent if fresh else dst, ignore_errors=True); dst.mkdir(parents=True)
    total = 0
    for name, i, _ in files:
        with open(dst / name, 'xb') as f: total += n.copy(i, f)
    return total


def run_timeout(nbytes):   # the time limit of a run that reads nbytes of staged NCA files
    return RUN_BASE + nbytes // RUN_RATE


def write_cap(bound, where):   # nx_extract's --max-bytes: the bound the disk checks counted (plus WRITE_SLACK), and never past the volume's free space less 1 GiB
    return max(0, min(free_bytes(where) - GiB, bound + WRITE_SLACK))


def _run(n, args, log=None, timeout=None):   # nx_extract with args (an argument list, never a shell) → (exit code, its output); the output also goes to log
    nat = _native(n)
    exe = nat.tool()
    env = dict(nat.env if nat.env is not None else os.environ, DOTNET_GCHeapHardLimit=GC_LIMIT)
    cmd = [str(exe), *map(str, args)]
    try:
        if log is None:
            r = subprocess.run(cmd, capture_output=True, text=True, errors='replace', env=env, timeout=timeout)
            return r.returncode, r.stdout + r.stderr
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, 'w') as f: r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, timeout=timeout)
        return r.returncode, log.read_text(errors='replace')
    except subprocess.TimeoutExpired as e:
        raise Error(f'nx_extract did not finish reading the NCA files in {timeout:,} s ({shown(" ".join(cmd[1:3]))} …): their tables may never end (a crafted or broken archive)', 'nca') from e
    except OSError as e: raise tool_error(f'{exe} does not start ({e.strerror or e})') from e


def _reds(text):   # nx_extract's [RED] lines, escaped
    return [shown(line[6:]) for line in text.splitlines() if line.startswith('[RED] ')]


def _failed(k, code, text, log) -> NoReturn:   # nx_extract's exit code → Error
    reds = _reds(text)
    first = reds[0] if reds else f'no message (log: {log})'
    where = k.name if k is not None else 'the content metas'
    if code == 2: raise Error(f'nx_extract refused its arguments: {first}', 'tool')
    if code == 3:
        bad = [r.removeprefix('hash check failed: ') for r in reds if r.startswith('hash check failed: ')]
        what = (f'{len(bad)} file(s) fail the NCA\'s own hash check ({", ".join(bad[:3])}{", …" if len(bad) > 3 else ""})' if bad else
                'its filesystem tables fail the NCA\'s own hash check')
        raise Error(f'{where}: {what}. The archive\'s own hashes pass, so the NCA was already damaged when it was packed (by the decrypter or its source); pack it again from a good '
                    'dump, or pass --allow-damaged to pack them as read', 'nca_hash')
    if code == 4: raise Error(f'{where}: the base game\'s program is sparse (the decrypter left out data its update carries): it runs only with its update; pack an update version '
                              '(--version <N> / -p v<N>)', 'sparse')
    if code == 5: raise Error(f'{where}: its content meta cannot be read: {first}', 'nca')
    if code == 6: raise Error(f'{where}: a section still asks for keys ({first}): it is not a decrypted NCA', 'nca')
    if code in (7, 8): raise Error(f'{where}: {first}', 'nca')
    raise Error(f'nx_extract stopped with exit code {code}' + (f' (log: {log})' if log else f': {first}'), 'tool')


def probe(n, a, snaps):
    """Each NCA snapshot's own content meta (<content ID>.cnmt.nca, at most META_MAX) read in one nx_extract --contents run, against the Catalog: a base game is Application a.id, an
    update Patch a.id | 0x800, a DLC AddOnContent, each of the snapshot's version. A DLC's add-on title ID comes from there (s.title_id)"""
    todo = []
    for s in snaps:
        files = dict(native_files(n, s))
        name = s.content_id.hex() + '.cnmt.nca'
        if (i := files.get(name)) is None: raise Error(f'{s.name}: no {name}, the content meta its catalog row names', 'nca')
        if n.size(i) > META_MAX: raise Error(f'{s.name}: {name} is {n.size(i):,} bytes, larger than a content meta NCA ({META_MAX:,} at most)', 'nca')
        if nca_head(n, s, name, i) != CT_META: raise Error(f'{s.name}: {name} is not a Meta NCA', 'nca')
        todo.append((s, name, i))
    nat = _native(n)   # the files are what an NCA snapshot holds: only now is nx_extract needed
    def run(root):
        try:
            for j, (s, name, i) in enumerate(todo):
                stage(n, [(name, i, CT_META)], root / f's{j}', fresh=False)
            return _run(n, ['--plain', '--contents', *(root / f's{j}' for j in range(len(todo)))], timeout=CONTENTS_TIMEOUT)
        finally: shutil.rmtree(root, ignore_errors=True)
    if nat.tmp is not None: code, text = run(Path(nat.tmp) / 'nca' / 'meta')
    else:
        with tempfile.TemporaryDirectory(prefix='nx_meta_') as td: code, text = run(Path(td) / 'meta')
    if code not in (0, 5): _failed(None, code, text, None)
    got, why, cur = {}, {}, None
    for line in text.splitlines():
        if m := re.fullmatch(r'package (\d+) s\d+', line): cur = int(m.group(1)); got[cur] = []
        elif cur is not None and (m := re.fullmatch(r'content (\w+) ([0-9a-f]{16}) (\d+)', line)): got[cur].append((m.group(1), int(m.group(2), 16), int(m.group(3))))
        elif cur is not None and line.startswith('[RED] '): why[cur] = shown(line[6:])
    for j, (s, name, i) in enumerate(todo):
        rows = got.get(j, [])
        if len(rows) != 1: raise Error(f'{s.name}: its content meta cannot be read: ' + (why.get(j) or f'{name} holds {len(rows)} content metas'), 'nca')
        kind, tid, ver = rows[0]
        want, wid = {BASE: ('Application', a.id), UPDATE: ('Patch', a.id | 0x800), DLC: ('AddOnContent', None)}[s.type]
        if kind != want or (wid is not None and tid != wid) or ver != s.version:
            raise Error(f'{s.name}: its catalog row says {want}{f" {wid:016X}" if wid is not None else ""} version {s.version}, its content meta says {shown(kind)} {tid:016X} version {ver}',
                        'nca')
        if s.type == DLC: s.title_id = tid


def _digest(n, k, kind, ids):
    """What an NCA snapshot's output is made from: the tool's source, NATIVE_PACKER, romfs_image.py, the IDs and every root file's name, size and SHA-256. Not this script's bytes:
    an edit elsewhere in it would stage and extract every NCA snapshot again (tens of GB for a game)"""
    h = hashlib.sha256(kind.encode() + b'\0' + nx_extract_source_sha().encode() + str(NATIVE_PACKER).encode() + b'\0' + Path(romfs_image.__file__).read_bytes() + repr(ids).encode())
    for name, i in sorted(native_files(n, k)): h.update(struct.pack('<IQ', len(name), n.size(i)) + name.encode() + n.sha(i))
    return h.hexdigest()


def _sha_file(p):
    with open(p, 'rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def _stamp(out, digest):   # out/native.inputs.json: the digest, RomFS.img's file identity and the SHA-256 of every other file written
    files = {p.relative_to(out).as_posix(): _sha_file(p) for p in sorted(out.rglob('*')) if p.is_file() and p.name not in (STAMP, 'RomFS.img')}
    (out / STAMP).write_text(json.dumps({'digest': digest, 'image': romfs_image.file_identity(out / 'RomFS.img'), 'files': files}))


def _kept(out, digest):   # whether out is what the stamp says inputs with this digest made, still as written
    try:
        st = json.loads((out / STAMP).read_text())
        if st['digest'] != digest or romfs_image.file_identity(out / 'RomFS.img') != st['image']: return False
        return all('..' not in Path(rel).parts and _sha_file(out / rel) == sha for rel, sha in st['files'].items())
    except (OSError, ValueError, KeyError, TypeError, AttributeError): return False


def _space(k, need, where):   # stop before staging when the volume cannot hold what is staged and written, with 1 GiB kept free; returns the free bytes
    free = free_bytes(where)
    if free < need + GiB: raise Error(f'{k.name}: {need / 2**30:,.1f} GB to stage and write and {free / 2**30:,.1f} GB free on the volume of {where} (1 GB is kept free)', 'io')
    return free


def _control_fallback(k, out, say, note=None):   # what the Control NCA did not give (no Control NCA, no icon in it) from the archive's Media: the snapshot's own, else its exact base's
    nacp, icon = out / 'control.nacp', out / 'icon.jpg'
    if not (nacp.is_file() and icon.is_file()):
        meta = media_meta(k, base_of(k), note or say)
        if not nacp.is_file() and meta['nacp']: nacp.write_bytes(meta['nacp'])
        if not icon.is_file() and meta['icon']: icon.write_bytes(meta['icon'])
    if not nacp.is_file():
        say(f'{k.name}: the archive has no NACP for this version' + ('' if k.type == BASE else ' or its base game') + ': the game\'s name and languages come from elsewhere (its profile)')


def _display(k, out, say):
    """An NCA snapshot's output, as extracted or as its stamp kept it: title.txt (the archive's display title, without a NACP) and EDITED_ICON (an icon set in NXConvert's sidebar, set-metadata,
    which keeps the NCA files as they are: the snapshot's own icon in the archive, when it differs from the icon.jpg its Control NCA gave; never its base game's). Written after the stamp and on
    every run, so an edit to the archive's display metadata (it appends a generation) needs no new extraction, and undoing it brings the game's icon back"""
    title_file(out, media_meta(k, base_of(k), say)['title'] if not (out / 'control.nacp').is_file() else None)
    own, icon, edited = k.nx.meta(k)['icon'], out / 'icon.jpg', out / EDITED_ICON
    # a new icon clears the record's localized icons (NXConvert's CLI.md, set-metadata): while they still hold the Control NCA's icon, the record's default is the game's own in another
    # language (as NXConvert picked it, not an edit), and the Control NCA's is kept as before
    if own and icon.is_file() and own != (got := icon.read_bytes()) and got not in k.nx.localized_icons(k):
        edited.write_bytes(own)
        pack_nup.tell(k, f"{k.name}: the archive's icon for it is not its Control NCA's (set in NXConvert's sidebar or with set-metadata): the app takes the archive's ({EDITED_ICON})", say)
    else: edited.unlink(missing_ok=True)


def _one(k, pattern, text, what):   # the one line of nx_extract's output that matches pattern; a second is refused (text from the NCAs is printed escaped, so none can forge one)
    found = list(re.finditer(f'^{pattern}$', text, re.M))
    if len(found) > 1: raise Error(f'{k.name}: nx_extract printed {len(found)} {what} lines', 'nca')
    return found[0] if found else None


def _extract_args(k, src, out, a, p, *more):
    return ['--plain', src, src if k.type == UPDATE else '-', out, '--app', f'{a.id:016x}', f'--program={p.id:016x}', *more]


def pack_native(n, k, base, app, out, say=print, step=lambda s: None, note=None):
    """NCA snapshot k (a base game or an update) → out/ExeFS, out/RomFS.img, its control data and out/html/, through nx_extract --plain on its staged NCA files; the ExeFS and RomFS are
    an update's laid over its base game's (BKTR). Returns 'kept' (the stamp matches: nothing staged or run) or 'packed'. note: where the lines about the control data go (pack_version)"""
    note = note or say
    nat, a, p = _native(n), k.app, n.programs[k.program]
    damaged = ['--allow-damaged'] if nat.allow_damaged else []
    digest = _digest(n, k, 'NX-native-version', (a.id, p.id, app, k.type, k.version, nat.allow_damaged))
    if _kept(out, digest):
        _display(k, out, note); return 'kept'
    files = chosen(n, k, GAME_TYPES)
    staged = sum(n.size(i) for _, i, _ in files)
    _space(k, staged + version_bytes(n, k, base), out.parent)
    tmp = Path(nat.tmp or out.parent.parent / 'tmp') / 'nca' / out.name
    logs = Path(nat.logs or out.parent.parent / 'logs')
    part = out.with_name(out.name + '.partial')
    try:
        shutil.rmtree(part, ignore_errors=True)
        step('staging the NCA files'); say(f'staging {len(files)} NCA files of {k.name} ({staged / 2**30:,.2f} GB) → {tmp}')
        stage(n, files, tmp)
        step('reading the NCA files')
        log = logs / f'extract_{out.name}.log'
        bound, limit = version_bytes(n, k, base), run_timeout(staged)
        code, text = _run(n, _extract_args(k, tmp, part, a, p, '--romfs-image', '--max-bytes', write_cap(bound, out.parent), *damaged), log, limit)
        if code: _failed(k, code, text, log)
        for line in _reds(text): say(f'{k.name}: {line}')   # files written as read (--allow-damaged)
        m = _one(k, r'title ([0-9a-f]{16})(?:, update ([0-9a-f]{16}))?', text, 'title')
        if not m or int(m.group(1), 16) != p.id or (k.type == UPDATE) != bool(m.group(2)) or (m.group(2) and int(m.group(2), 16) != p.id):
            raise Error(f'{k.name}: the archive says program {p.id:016X}, nx_extract read ' + (shown(m.group(0)) if m else 'no program'), 'nca')
        if k.flags & 1:   # BUILD_ID_PRESENT: the catalog describes these NCAs only when their main is that build
            got = _one(k, r'main build id ([0-9a-f]+)', text, 'main build id')
            if not got or got.group(1) != k.build_id[:16].hex():
                raise Error(f'{k.name}: the archive says main is build {k.build_id[:16].hex()}, its Program NCA holds {got.group(1) if got else "no main"}', 'nca')
        if not (part / 'ExeFS/main').is_file() or not (part / 'ExeFS/main.npdm').is_file(): raise Error(f'{k.name}: its Program NCA has no ExeFS main and main.npdm', 'nca')
        html = part / 'html'
        if any(t == CT_MANUAL for _, _, t in files):   # the offline HTML pages (the update's, then the base game's), as extract_html leaves an NSP's
            step('reading the HTML pages')
            hp = part / 'html.partial'; hp.mkdir()
            hlog = logs / f'extract_html_{out.name}.log'
            code, text = _run(n, _extract_args(k, tmp, hp, a, p, '--html', '--max-bytes', write_cap(bound, out.parent), *damaged), hlog, limit)
            if code: _failed(k, code, text, hlog)
            for line in _reds(text): say(f'{k.name}: {line}')
            hp.rename(html)
        else: html.mkdir()
        _control_fallback(k, part, say, note)
        _stamp(part, digest)
        shutil.rmtree(out, ignore_errors=True); part.rename(out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True); shutil.rmtree(part, ignore_errors=True)
    _display(k, out, note)
    return 'packed'


def pack_native_dlc(n, app, tid, k, img, say=print):
    """NCA snapshot k of DLC tid → the image img (nx_extract --plain --aoc on its staged Meta and data NCAs), stamped as romfs_image stamps one; 'kept' when the stamp matches"""
    nat, dst = _native(n), str(img)
    digest = _digest(n, k, 'NX-native-aoc', (app, tid, k.version))
    if romfs_image.reusable(dst, digest): return 'kept'
    files = chosen(n, k, DLC_TYPES)
    staged = sum(n.size(i) for _, i, _ in files)
    _space(k, staged + version_bytes(n, k), img.parent)
    tmp = Path(nat.tmp or img.parent.parent / 'tmp') / 'nca' / f'aoc{img.stem}'
    logs = Path(nat.logs or img.parent.parent / 'logs')
    try:
        img.parent.mkdir(parents=True, exist_ok=True)
        Path(dst + '.inputs.json').unlink(missing_ok=True); img.unlink(missing_ok=True)
        stage(n, files, tmp)
        log = logs / f'aoc_{img.stem}.log'
        code, text = _run(n, ['--plain', '--aoc', tmp, img, f'{tid:016x}', '--romfs-image', '--max-bytes', write_cap(version_bytes(n, k), img.parent)], log, run_timeout(staged))
        if code: _failed(k, code, text, log)
        if not re.search(f'^add-on content {tid:016x}$', text, re.M) or not img.is_file(): raise Error(f'{k.name}: nx_extract read no add-on content {tid:016X}', 'nca')
        romfs_image.stamp(dst, digest, romfs_image.file_identity(img))
    finally: shutil.rmtree(tmp, ignore_errors=True)
    say(f'  DLC {tid:016X}: {img}')
    return 'packed'


def survey_native(n, k, base, out, say=print):
    """NCA snapshot k's files for a survey (build_ipa_from_nsp.py's survey_nup for an NX): out/ExeFS, out/romfs_manifest.tsv, out/romfs_nro/ and the control data, through
    nx_extract --plain --manifest (no RomFS written). out must not exist. Returns the files listed"""
    nat, a, p = _native(n), k.app, n.programs[k.program]
    files = chosen(n, k, GAME_TYPES - {CT_MANUAL})
    staged, bound = sum(n.size(i) for _, i, _ in files), sum(n.size(i) for _, i, t in files if t in (CT_PROGRAM, CT_CONTROL))   # ExeFS, NROs, control data, the manifest's rows
    _space(k, staged + bound, out.parent)
    tmp = Path(nat.tmp or out.parent / 'tmp') / 'nca' / 'survey'
    logs = Path(nat.logs or out.parent / 'logs')
    try:
        stage(n, files, tmp)
        log = logs / 'survey_extract.log'
        code, text = _run(n, _extract_args(k, tmp, out, a, p, '--manifest', '--max-bytes', write_cap(bound, out.parent), *(['--allow-damaged'] if nat.allow_damaged else [])), log,
                          run_timeout(staged))
        if code: _failed(k, code, text, log)
        _control_fallback(k, out, say)
        _display(k, out, say)
    finally: shutil.rmtree(tmp, ignore_errors=True)
    return max(0, (out / 'romfs_manifest.tsv').read_bytes().count(b'\n') - 1)


def main():
    ap = argparse.ArgumentParser(description='Pack a game in an NX archive into the extraction layout of build_ipa_from_nsp.py')
    ap.add_argument('nx', type=Path, help='the .nx file')
    ap.add_argument('--version', type=int, help='the version to pack (default: the newest in the archive; the base game\'s own, 0 for most, packs the base game)')
    ap.add_argument('--title-id', help='the game to pack when the archive holds several: its application ID, 16 hex digits, with :switch1, :switch2 or :unknown after it when the archive '
                    'holds that ID on two platforms')
    ap.add_argument('--work-dir', type=Path, help='the build folder (default: <folder of the .nx>/<title ID>_build; <title ID>-<platform>_build for an ID the archive holds on two platforms)')
    ap.add_argument('--list', action='store_true', help='list the applications and snapshots, and pack nothing')
    ap.add_argument('--verify', action='store_true', help='check the whole archive (every Media record, every block with its CRC-32C at about 17 MiB/s, and every file), and pack nothing')
    ap.add_argument('--crc', action='store_true', help='also check every block\'s CRC-32C as it is read when packing (about 17 MiB/s in Python)')
    ap.add_argument('--allow-damaged', action='store_true', help='an NCA snapshot whose files fail the NCA\'s own hash check: pack them as read (nx_extract --allow-damaged)')
    a = ap.parse_args()
    path = a.nx.resolve()
    try:
        sel = parse_title_id(a.title_id) if a.title_id else (None, None)
        if sel is None: raise Error(f'--title-id takes a title ID, 16 hex digits, optionally with :switch1, :switch2 or :unknown after it: {a.title_id}', 'select')
        with Nx(path, crc=a.crc) as n:
            nat = n.nca_tool = Native(allow_damaged=a.allow_damaged)   # NCA snapshots (nxconvert pack): nx_extract, found when the first one is touched
            for line in n.notes: print(shown(line), flush=True)
            told = len(n.notes)
            if a.list:
                print('\n'.join(listing(n))); return
            if a.verify:
                tty = sys.stdout.isatty()
                try: n.verify(progress=(lambda i, t, what: print(f'\r  {i:,} / {t:,} {what}   ', end='', flush=True)) if tty else None)
                finally:
                    if tty: print('\r' + ' ' * 40 + '\r', end='', flush=True)
                print(f'{path.name}: verified ({len(n.files):,} files, {n.nblocks:,} blocks, every CRC-32C)'); return
            app, base, vers, dlc = scan(n, *sel)
            for line in n.notes[told:]: print(shown(line), flush=True)
            have = dict(vers)
            if base is not None: have[base.version] = base
            ver = a.version if a.version is not None else max(vers, default=base.version if base is not None else 0)
            if ver not in have: raise Error(f'no version {ver} in {path.name} (have: {", ".join(map(str, sorted(have))) or "none"})', 'select')
            k = have[ver]
            tag = platform_tag(n, k.app)
            work = (a.work_dir or path.parent / f'{app:016X}{"-" + tag if tag else ""}_build').resolve()
            out = work / 'extract' / f'v{ver}'
            nat.tmp, nat.logs = work / 'tmp', work / 'logs'
            need = sum(version_bytes(n, x, base) for x in [k, *dlc.values()]) + max(staging_bytes(n, x) for x in [k, *dlc.values()])   # dedup lets a small archive declare far more
            if not (out / 'RomFS.img').exists() and (free := free_bytes(work)) < need + (1 << 30):
                raise Error(f'{need / 2**30:,.1f} GB to write and {free / 2**30:,.1f} GB free on the volume of {work} (1 GB is kept free)', 'io')
            print(f'{app:016X} version {ver} ({PLATFORMS[k.app.platform]}): {k.name}', flush=True)
            say = lambda s: print(s, flush=True)
            pack_version(n, k, base, app, out, say)
            pack_dlc(n, app, dlc, work / 'aoc', say)
    except (pack_nup.Error, OSError, ValueError) as e: sys.exit(f'[RED] {shown(str(e))}')
    print(f'done: {out}' + (f', {len(dlc)} DLC in {work / "aoc"}' if dlc else ''))


if __name__ == '__main__':
    main()
