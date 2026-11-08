#!/usr/bin/env python3
"""A game's mods, packed into its app by the NSP script (scripts/build_ipa_from_nsp.py, MODS / --mods; by default the folder named mods beside the game's files):
  · code patches: Atmosphère IPS / IPS32 files named after a module's build ID (atmosphere/exefs_patches/<mod>/<build ID>.ips) and IPSwitch text patches (*.pchtxt, which name
    their build in an @nsobid line), as yuzu, Ryujinx and Atmosphère apply them, written into the decompressed code module (main, subsdk*, sdk, rtld) before the rewriter
    (patch_nso.py) reads it. An iPhone app's code pages are signed, so this is the only way a code patch (a 60 fps patch, a resolution patch) reaches the game there. A patch
    (one @enabled block of a .pchtxt, or one IPS file) that writes outside the module's text, ro and data (a code cave in its bss, which only an emulator runs), or whose code
    branches out of the module's text, is left out whole, with a [RED] line; of a patch that holds a code cave and the hook into it, only those (judge_patches);
  · RomFS file replacements (LayeredFS): every file under a folder named romfs (atmosphere/contents/<title ID>/romfs/..., <mods>/<title ID>/<mod>/romfs/...) replaces the
    game file of the same path, or is added; the game's RomFS image (DMROMFS1, romfs_image.py) gets a new index that names them, its own data kept as it was;
  · cheats: Atmosphère cheat files under a folder named cheats, <build ID>.txt; a .txt with another name is taken as the packed build's. They are packed into the app, which copies
    them into its cheats folder (the iPhone's Documents/cheats), where the in-game menu turns them on.
What belongs to the game: a folder named with a title ID belongs to that title and its update (the title ID + 0x800), so a whole SD card (atmosphere/contents/<title ID>/...),
Ryujinx's mods folder or yuzu's load folder can be given as it is; anything else under the mods folder counts. A game of several programs (Super Mario 3D All-Stars) packs each
program with the folders of its own title ID, the application's + the program's index. A DLC's folder (the application's title ID + 0x1000 + its index) is not the game's: a DLC's
RomFS is not modded, and the report says so. A file or folder whose name starts with '.' or '-' is skipped, so renaming a mod's folder to -name turns it off without deleting it.
Usage on its own (a check, nothing written): game_mods.py <mods folder> <title ID> [ExeFS folder]"""
import bisect, hashlib, os, re, shutil, struct, sys
from array import array
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import a64_words as a64
import nso

NSO_HEADER = 0x100   # IPS offsets count from the NSO's header, as Atmosphère's loader patches the module (ldr_patcher.cpp: the header is protected, the module's memory follows)
HEX = re.compile(r'[0-9A-Fa-f]+')
TITLE = re.compile(r'[0-9A-Fa-f]{16}')
JUNK = {'.ds_store', 'thumbs.db', 'desktop.ini'}


class ModError(ValueError):
    pass


# ---------- patch formats ----------

def parse_ips(d, name='patch'):
    """[(offset, bytes)] of an IPS ("PATCH", 24-bit offsets, "EOF") or IPS32 ("IPS32", 32-bit offsets, "EEOF") patch, RLE records expanded; offsets as the file gives them
    (from the start of the NSO header). Raises ModError on a file that is not one or is cut short"""
    if d[:5] == b'IPS32': width, tail = 4, b'EEOF'
    elif d[:5] == b'PATCH': width, tail = 3, b'EOF'
    else: raise ModError(f'{name}: not an IPS or IPS32 patch (it starts {bytes(d[:5])!r})')
    recs, pos = [], 5
    while True:
        if d[pos:pos + width] == tail: return recs   # the reader stops here, as Atmosphère's does (a 24-bit offset 0x454F46 cannot be patched in IPS)
        if pos + width + 2 > len(d): raise ModError(f'{name}: cut short at {pos:#x} (no {tail.decode()} at its end)')
        off = int.from_bytes(d[pos:pos + width], 'big'); size = int.from_bytes(d[pos + width:pos + width + 2], 'big'); pos += width + 2
        if size:
            if pos + size > len(d): raise ModError(f'{name}: a record at {off:#x} is cut short')
            recs.append((off, bytes(d[pos:pos + size]))); pos += size
        else:   # RLE: a 16-bit count and the byte to repeat
            if pos + 3 > len(d): raise ModError(f'{name}: an RLE record at {off:#x} is cut short')
            recs.append((off, bytes([d[pos + 2]]) * int.from_bytes(d[pos:pos + 2], 'big'))); pos += 3


def _pchtxt_string(s):
    """The bytes of a quoted pchtxt value (s starts after the opening quote): C escapes as yuzu reads them, up to the closing quote"""
    esc = {'a': 7, 'b': 8, 'f': 12, 'n': 10, 'r': 13, 't': 9, 'v': 11, '\\': 92, "'": 39, '"': 34, '?': 63, '0': 0}
    out, i = bytearray(), 0
    while i < len(s) and s[i] != '"':
        if s[i] == '\\' and i + 1 < len(s) and s[i + 1] in esc: out.append(esc[s[i + 1]]); i += 2
        else: out += s[i].encode(); i += 1
    return bytes(out)


@dataclass
class TextPatch:
    name: str
    enabled: bool
    records: list = field(default_factory=list)   # [(offset as an IPS gives it, bytes)]


def parse_pchtxt(text, name='patch'):
    """(build ID hex or '', [TextPatch]) of an IPSwitch text patch, as yuzu's IPSwitchCompiler reads it: @nsobid-<build ID>, @flag offset_shift <n> (added to each offset),
    @little-endian / @big-endian (a hex value's byte order), @enabled / @disabled (a patch, named by the line before it), @stop; '//' starts a comment"""
    bid, shift, little, patches, cur = '', 0, False, [], None
    lines = text.splitlines()
    for i, raw in enumerate(lines):
        line = raw.strip()
        if line.startswith('@stop'): break
        if line.startswith('@nsobid-'): m = HEX.match(line[8:]); bid = m.group(0).upper() if m else ''; continue
        if line.startswith('@little-endian'): little = True; continue
        if line.startswith('@big-endian'): little = False; continue
        if line.startswith('@flag'):
            parts = line.split()
            if len(parts) >= 3 and parts[1] == 'offset_shift':
                try: shift = int(parts[2], 0)
                except ValueError: raise ModError(f'{name}: line {i + 1}: offset_shift {parts[2]!r} is not a number') from None
            continue
        if line.startswith(('@enabled', '@disabled')):
            title = next((p.strip() for p in reversed(lines[:i]) if p.strip()), '') if i else ''
            title = title.removeprefix('//').strip().strip('[]').strip() or f'patch at line {i + 1}'
            cur = TextPatch(title, line.startswith('@enabled')); patches.append(cur); continue
        if not line or line.startswith(('@', '#', '//')) or cur is None: continue
        m = re.match(r'([0-9A-Fa-f]{8})\s+(.*)$', line)   # an offset of 8 hex digits, as yuzu reads it
        if not m: continue
        off, value = int(m.group(1), 16) + shift, m.group(2)
        if value.startswith('"'): data = _pchtxt_string(value[1:])
        else:
            value = re.sub(r'\s+', '', value.split('//')[0])
            if not value or len(value) % 2 or not HEX.fullmatch(value): raise ModError(f'{name}: line {i + 1}: {m.group(2)!r} is not a hex value or a quoted string')
            data = bytes.fromhex(value)
            if little: data = data[::-1]
        cur.records.append((off, data))
    return bid, patches


def build_matches(name_hex, build_id):
    """Whether a file's build ID (a prefix of the module's, as mod sites shorten them: at least 16 hex digits) names the module whose build ID is build_id (bytes)"""
    h = name_hex.upper()
    return 16 <= len(h) <= 64 and bool(HEX.fullmatch(h)) and build_id.hex().upper().startswith(h)


def apply_records(image, recs, header=NSO_HEADER):
    """Writes the records (offsets from the NSO header) into a module's memory image (bytearray): (bytes written, records outside the image)"""
    n = outside = 0
    for off, data in recs:
        at = off - header
        if at < 0: data, at = data[-at:], 0   # the header itself is never patched
        if not data: continue
        if at + len(data) > len(image): outside += 1; data = data[:max(0, len(image) - at)]
        if data: image[at:at + len(data)] = data; n += len(data)
    return n, outside


def nso_with_image(d, image):
    """The NSO file d with its text, ro and data taken from image (its memory image, patched), stored uncompressed with fresh hashes: the header and the module name are kept,
    so the build ID and the layout are the module's own (nso.py loads it as Horizon would)"""
    stored = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    first = min(fo for fo, _, _ in stored)
    out = bytearray(d[:first])
    flags = struct.unpack_from('<I', out, 0xc)[0] & ~(0x7 | nso.NSO_ZSTD)   # nothing compressed; the check-hash bits stay, with the new hashes
    for i, (_, mo, sz) in enumerate(stored):
        seg = bytes(image[mo:mo + sz])
        struct.pack_into('<I', out, 0x10 + i * 0x10, len(out)); struct.pack_into('<I', out, 0x60 + 4 * i, sz)
        out[0xa0 + 0x20 * i:0xc0 + 0x20 * i] = hashlib.sha256(seg).digest()
        out += seg
    struct.pack_into('<I', out, 0xc, flags)
    return bytes(out)


# ---------- finding a game's mods ----------

def skipped(name): return name.startswith(('.', '-')) or name.lower() in JUNK


def same_title(component, title_id):
    """component names a title (16 hex digits): whether it is this program's, title_id itself or its update (+ 0x800). Another program of the application (the same digits but
    the last three, another index) is not; nor is a DLC (the application's + 0x1000 + its index, dlc_title)"""
    return int(component, 16) & ~0x800 == title_id & ~0x800


def dlc_title(component, title_id):
    """component names a title (16 hex digits): whether it is a DLC of title_id's application (the application's title ID + 0x1000 + the DLC's index)"""
    return int(component, 16) & ~0xFFF == (title_id & ~0xFFF) + 0x1000


@dataclass
class Found:
    root: Path
    ips: list = field(default_factory=list)       # code patch files: .ips / .ips32 (named after a build ID) and .pchtxt
    romfs: list = field(default_factory=list)     # folders named romfs, in path order (a later one wins a file both replace)
    cheats: list = field(default_factory=list)    # .txt files in folders named cheats
    ignored: list = field(default_factory=list)   # (path, why)

    def any(self): return bool(self.ips or self.romfs or self.cheats)


def scan(root, title_id):
    """The mods for title_id (int) under root, by the rules in this file's description"""
    root = Path(root)
    f = Found(root)
    def walk(d, in_cheats):
        try: entries = sorted(os.scandir(d), key=lambda e: e.name.lower())
        except OSError as e: f.ignored.append((Path(d), f'cannot read: {e.strerror}')); return
        for e in entries:
            p = Path(e.path)
            if skipped(e.name):
                if not e.name.startswith('.') and e.name.lower() not in JUNK: f.ignored.append((p, 'its name starts with -: turned off'))
                continue
            if e.is_dir():
                if TITLE.fullmatch(e.name) and not same_title(e.name, title_id):
                    if dlc_title(e.name, title_id): f.ignored.append((p, 'a DLC\'s folder: a DLC\'s RomFS is not modded'))
                    continue   # another game's, or another program's of this game
                low = e.name.lower()
                if low == 'romfs':   # one with no file changes nothing
                    if any(not skipped(fn) for _, _, files in os.walk(p) for fn in files): f.romfs.append(p)
                    continue
                walk(p, in_cheats or low == 'cheats'); continue
            low = e.name.lower()
            if low.endswith(('.ips', '.ips32', '.pchtxt')): f.ips.append(p)
            elif in_cheats and low.endswith('.txt'): f.cheats.append(p)
            elif p.parent.name.lower() == 'exefs' and (low in ('main', 'rtld', 'sdk') or re.fullmatch(r'subsdk\d+', low)):
                f.ignored.append((p, 'a whole code module replaces nothing here: give the change as an .ips or .pchtxt patch'))
    if root.is_dir(): walk(root, root.name.lower() == 'cheats')
    return f


# ---------- code patches ----------

def nso_modules(exefs):
    """{name: (path, nso.Module)} of the code modules in an ExeFS folder"""
    out = {}
    for p in sorted(Path(exefs).iterdir()):
        if not p.is_file() or p.suffix: continue
        with open(p, 'rb') as fh:
            if fh.read(4) != b'NSO0': continue
        out[p.name] = (p, nso.read(p))
    return out


class Item(NamedTuple):
    """One code patch, written or left out whole: an @enabled block of a .pchtxt, or an IPS / IPS32 file"""
    what: str        # its name in the report: '<file>: <block>', or the file
    records: list    # [(offset as the file gives it, bytes)]
    mod: str         # the mod it belongs to (mod_name): a patch that needs another one of its mod is looked for there


class LeftOut(NamedTuple):
    """A patch patch_exefs did not write, and why (its [RED] line in the report)"""
    module: str
    what: str
    mod: str
    why: str


def code_patches(found, modules, files=None, adapt=None):
    """{module name: [Item]} of the patch files that name one of the modules' builds, in path order, and the report lines.
    files: the patch files to take (default: all of found's); adapt(records, what, report) may change a file's records (the ultrawide aspect, adapt_aspect)"""
    plan: dict[str, list[Item]] = {}
    report = []
    for p in (found.ips if files is None else files):
        rel, mod = p.relative_to(found.root), mod_name(p, found.root)
        if p.suffix.lower() == '.pchtxt':
            try: bid, patches = parse_pchtxt(p.read_text(encoding='utf-8', errors='replace'), str(rel))
            except ModError as e: report.append(f'skipped {rel}: {e}'); continue
            if not bid: report.append(f'skipped {rel}: no @nsobid line names its build'); continue
            module = next((m for m, (_, mo) in modules.items() if build_matches(bid, mo.build_id)), None)
            if not module: report.append(f'not for this version: {rel} (build {bid[:16]})'); continue
            for tp in patches:
                what = f'{rel}: {tp.name}'
                if tp.enabled: plan.setdefault(module, []).append(Item(what, adapt(tp.records, what, report) if adapt else tp.records, mod))
                else: report.append(f'off in its file (@disabled): {what}')
            continue
        bid = p.name.split('.')[0]
        module = next((m for m, (_, mo) in modules.items() if build_matches(bid, mo.build_id)), None)
        if not module:
            report.append(f'not for this version: {rel}' + ('' if HEX.fullmatch(bid) else ' (an .ips is named after the build ID of the module it patches)'))
            continue
        try: recs = parse_ips(p.read_bytes(), str(rel)); plan.setdefault(module, []).append(Item(str(rel), adapt(recs, str(rel), report) if adapt else recs, mod))
        except ModError as e: report.append(f'skipped {rel}: {e}')
    return plan, report


# A patch is judged before anything is written (judge_patches), since what it does is one change, and its records only together:
#  · (a) its records, past the NSO header, must write only the module's text, ro and data. A byte in its bss (a code cave there: on a Switch Atmosphère maps the bss writable
#    and not executable, so only an emulator runs it), in the padding between two segments (the module's file does not hold it) or past the module is a change Nintanium cannot
#    carry, and the patch is left out whole. A zero byte there changes nothing (that memory is zero at start, or is not the module's) and is not counted: apply_records cuts
#    those past the data with its note, as before. One exception, the shape of a hook and its cave in one block: when each run of those records (records within NEAR bytes of
#    each other) is entered by a direct branch of the patch's own code in the text, the cave and the records of the patch's text that branch or refer into it (to a fixpoint)
#    are left out, and the rest is kept as a patch of its own (judged as one by (b) and (c)), unless nothing is left or a record left lies within NEAR bytes of a record taken out
#    of the text (a hook's neighbour belongs to the hook);
#  · (b) the direct branches its code makes (the aligned words of the text it writes, all or part of, as they read once the patches kept are in: B / BL, B.cond, CBZ / CBNZ,
#    TBZ / TBNZ) must land in the text: the iPhone runs only the module's signed pages, so a branch into its ro, data or bss ends the app. A word several patches write is
#    blamed on the last of them without whose bytes it would be no such branch (_culprit), so an earlier patch fine on its own is judged again without the later one. A word
#    that a literal load of the patches' code reads is data and is not decoded. Indirect jumps (an address made by ADRP / ADR or loaded, then BR / BLR) are not followed;
#  · (c) a patch whose code refers (any of the above, or an ADR, an ADRP with its ADD / LDR / STR, a literal load) into what a left-out part of the same mod and module writes is
#    left out too, to a fixpoint: a hook in one block whose cave is another block.
# ro and data are never decoded as code. A patch that writes only the module's segments (and zeros), and whose branches stay in its text, is written as before, byte for byte.
SEGMENT_NAMES = ('text', 'ro', 'data')
ADRP_USER_WORDS = 8   # an add / ldr / str up to 8 instructions after an adrp takes the page's low bits (nso_match's and cheat_anchor's rule)
NEAR = 16   # records closer than this belong together: the runs of a code cave, a hook and the records beside it


class Verdict(NamedTuple):
    """judge_patches' verdict on one patch: the indices of its records to write (all of them, none, or those left once its code cave is taken out), and each part of it left
    out, as (its name, its [RED] report line)"""
    write: tuple
    left: tuple


class _Part(NamedTuple):   # a patch, or one of the two parts of a patch whose code cave is taken out
    item: int     # the patch's index
    recs: list    # [(index into the patch's records, image offset, bytes)]
    what: str
    mod: str


def _image_records(recs, header=NSO_HEADER):
    """[(index, image offset, bytes)] of the records as they land in the module's memory image: the header's part cut (it is never patched), empty ones dropped
    (apply_records' rule)"""
    out = []
    for i, (off, data) in enumerate(recs):
        at = off - header
        if at < 0: data, at = data[-at:], 0
        if data: out.append((i, at, bytes(data)))
    return out


def _first_outside(m, at, d):
    """The first image offset of the record (at, d) that is in none of module m's segments and is not zero, or None. Two segments that touch, with no padding between them,
    count as one; a zero byte outside them changes nothing (its memory is zero at start, or is not the module's)"""
    k, n = at, at + len(d)
    while k < n:
        seg = next(((mo, sz) for mo, sz in m.segments if mo <= k < mo + sz), None)
        if seg: k = seg[0] + seg[1]; continue
        hi = min([mo for mo, _ in m.segments if mo > k] + [n])
        nz = next((j for j in range(k - at, hi - at) if d[j]), None)
        if nz is not None: return at + nz
        k = hi
    return None


def _bss_end(m):
    (do, ds) = m.segments[2]
    return (do + ds + m.bss + 0xfff) & ~0xfff


def _offset(module, a):
    return f'{module}+{a:#x}' if a >= 0 else f'{module}-{-a:#x}'


def _where(m, a):
    """What lies at image offset a of module m (nso.Module): one of its segments, the padding between two, its bss, or nothing of it"""
    (_, _), (ro, _), (do, _) = m.segments
    if a < 0: return 'before the module'
    for name, (mo, sz) in zip(SEGMENT_NAMES, m.segments):
        if mo <= a < mo + sz: return f'in its {name}'
    if a < ro: return 'in the padding between its text and ro, which the module\'s file does not hold'
    if a < do: return 'in the padding between its ro and data, which the module\'s file does not hold'
    if a < _bss_end(m): return 'in its bss, past its data (memory the module\'s file does not hold)'
    return 'past the module\'s end (after its bss)'


def _cannot(m, a):
    """Why Nintanium cannot carry a byte at image offset a, outside module m's segments (_where says where that is)"""
    if m.text_end <= a < (m.text_end + 0xfff) & ~0xfff: return 'a Switch runs code there, in the rest of its text\'s last page, but Nintanium carries only what the module\'s file holds'
    if a < m.segments[2][0]: return 'Nintanium carries only what the module\'s file holds'
    return 'Nintanium cannot carry a code cave or a bss write, which only an emulator runs'


def _text_with(m, recs):
    """Module m's text, [0, text_end) of its image, with the records recs [(index, image offset, bytes)] written over it in order (what lies past the text cut)"""
    te = m.text_end; text = bytearray(m.image[:te])
    for _, at, d in recs:
        hi = min(at + len(d), te)
        if at < hi: text[at:hi] = d[:hi - at]
    return text


def _word(text, a):
    """The aligned word at image offset a of a text (_text_with)"""
    return int.from_bytes(text[a:a + 4], 'little')


def _literal_size(w):
    """The bytes a literal load (a PC-relative LDR, LDRSW, or LDR of an FP / SIMD register) reads: 4, 8 or 16; 0 for a PRFM or any other word"""
    if w & 0x3b000000 != 0x18000000: return 0
    return ((4, 8, 4, 0), (4, 8, 16, 0))[w >> 26 & 1][w >> 30]


def _refers(m, text, a, w):
    """(lo, hi): the bytes the word w at image offset a refers to (pc_relative_target: a branch's target, the bytes a literal load reads, an ADRP's page or the address it makes
    with the add / ldr / str after it that takes its low bits), or None for a word that refers to nothing"""
    lo = a64.pc_relative_target(w, a)
    if lo is None: return None
    if w & 0x3b000000 == 0x18000000: n = _literal_size(w); return (lo, lo + n) if n else None   # a PRFM reads nothing
    if not a64.is_adrp(w): return lo, lo + 1
    for k in range(1, ADRP_USER_WORDS + 1):
        if a + 4 * k + 4 > m.text_end: break
        u = _word(text, a + 4 * k); low = a64.adrp_user_lo(u, w & 31)
        if low is not None: return lo + low, lo + low + 1
        if a64.ends_pairing(u, w & 31): break
    return lo, lo + 0x1000


def _written_by(ranges, lo, hi):
    """The name of the first patch of ranges [(start, end, name)] that writes a byte of [lo, hi), or None"""
    return next((what for a, b, what in ranges if lo < b and a < hi), None)


def _bad_branch(w, a, te):
    t = a64.direct_branch_target(w, a)
    return t is not None and not 0 <= t < te


def _culprit(m, writers, a):
    """The part to blame for the aligned word at a, a direct branch out of the text: writers [(part, image offset, bytes)] are the kept parts' records that cross the word,
    in the order they are written. Of the parts whose bytes the word holds, the last one without whose bytes (each back to what was there before it) the word is no such branch;
    if there is none, the last of them"""
    stack = [[(-1, m.image[k])] for k in range(a, a + 4)]
    for p, at, d in writers:
        for k in range(max(a, at), min(a + 4, at + len(d))): stack[k - a].append((p, d[k - at]))
    own = sorted({s[-1][0] for s in stack} - {-1}, reverse=True)
    for c in own:
        w = bytes(next(v for p, v in reversed(s) if p != c) for s in stack)
        if not _bad_branch(int.from_bytes(w, 'little'), a, m.text_end): return c
    return own[0]


def _cave_split(m, recs, first):
    """Rule (a)'s exception: (the indices of the records to take out, None) when a patch's records outside module m's segments are a code cave its own code enters, else
    (None, None, or (the offset of a record left, of a record of the text taken out) when the first lies next to the second). recs: the patch's _image_records; first:
    {index: its _first_outside}"""
    te = m.text_end
    full = _text_with(m, recs)
    cut = {i for i, _, _ in recs if first[i] is not None}
    while True:   # the records of the text whose words, as they read with the records left, branch or refer into those taken out: the hook
        text = _text_with(m, [r for r in recs if r[0] not in cut])
        cave = [(at, at + len(d), 'cave') for i, at, d in recs if i in cut]
        more = set()
        for i, at, d in recs:
            if i in cut: continue
            for a in range(at & ~3, min(at + len(d), te - 3), 4):
                ref = _refers(m, text, a, _word(text, a))
                if ref and _written_by(cave, *ref): more.add(i); break
        if not more: break
        cut |= more
    hooks = sorted((at, at + len(d)) for i, at, d in recs if i in cut and first[i] is None)
    entries = {a64.direct_branch_target(_word(full, a), a) for lo, hi in hooks for a in range(lo & ~3, min(hi, te - 3), 4)}
    runs: list[list[int]] = []
    for at, n in sorted((at, len(d)) for i, at, d in recs if first[i] is not None):
        if runs and at < runs[-1][1] + NEAR: runs[-1][1] = max(runs[-1][1], at + n)
        else: runs.append([at, at + n])
    if not all(any(t is not None and lo <= t < hi for t in entries) for lo, hi in runs): return None, None   # not a cave its code enters: a write, or another patch's cave
    rest = sorted((at, at + len(d)) for i, at, d in recs if i not in cut)
    if not rest: return None, None
    near = next(((r[0], h[0]) for r in rest for h in hooks if r[0] < h[1] + NEAR and h[0] < r[1] + NEAR), None)
    return (None, near) if near else (cut, None)


def judge_patches(module, m, items):
    """[Verdict] of the patches of module (nso.Module m), one per item, by the rules above. items: [Item] in the order they are written"""
    te = m.text_end
    parts: list[_Part] = []
    out: dict[int, str] = {}   # the parts left out: their [RED] lines
    for i, it in enumerate(items):
        recs = _image_records(it.records)
        first = {k: _first_outside(m, at, d) for k, at, d in recs}
        bad = [f for f in first.values() if f is not None]
        if not bad: parts.append(_Part(i, recs, it.what, it.mod)); continue
        f = min(bad); cut, near = _cave_split(m, recs, first)
        if cut is None:
            why = '' if near is None else (f'; its other records are left out with them, as its record at {_offset(module, near[0])} lies next to its code that enters '
                                           f'them, at {_offset(module, near[1])}, and may belong to it')
            out[len(parts)] = (f'[RED] {module}: {it.what}: left out: {len(bad)} of its {len(recs)} records lie outside {module}\'s text, ro and data, the first at '
                               f'{_offset(module, f)}, {_where(m, f)}: {_cannot(m, f)}{why}')
            parts.append(_Part(i, recs, it.what, it.mod)); continue
        hooks = sorted(at for k, at, _ in recs if k in cut and first[k] is None)
        nr = len(recs) - len(cut)
        out[len(parts)] = (f'[RED] {module}: {it.what}: left out of it: its code cave, {len(bad)} records outside {module}\'s text, ro and data from {_offset(module, f)}, '
                           f'{_where(m, f)}, and {"the record" if len(hooks) == 1 else f"the {len(hooks)} records"} of its code in the text that '
                           f'{"leads" if len(hooks) == 1 else "lead"} there, at {_offset(module, hooks[0])}{"" if len(hooks) == 1 else " and on"}: {_cannot(m, f)}. '
                           f'The rest of it, {nr} of its {len(recs)} records, is kept as a patch of its own')
        parts.append(_Part(i, [r for r in recs if r[0] in cut], f'{it.what}: its code cave at {_offset(module, f)} and the code that enters it', it.mod))
        parts.append(_Part(i, [r for r in recs if r[0] not in cut], it.what, it.mod))
    while True:   # the parts kept so far, written in order: who writes each byte of the text last, and the words as they then read
        kept = [p for p in range(len(parts)) if p not in out]
        text = _text_with(m, [r for p in kept for r in parts[p].recs])
        owner = array('i', [-1]) * te
        for p in kept:
            for _, at, d in parts[p].recs:
                hi = min(at + len(d), te)
                if at < hi: owner[at:hi] = array('i', [p]) * (hi - at)
        words = sorted({a for p in kept for _, at, d in parts[p].recs for a in range(at & ~3, min(at + len(d), te - 3), 4)})
        data: set[int] = set()   # the words a literal load of those reads: data, not code
        for a in words:
            w = _word(text, a); n = _literal_size(w)
            t = a64.pc_relative_target(w, a) if n else None
            if t is not None: data.update(range((t + 3) & ~3, t + n - 3, 4))
        left: dict[str, list] = {}   # what each mod's parts left out write
        for p in out:
            for _, at, d in parts[p].recs: left.setdefault(parts[p].mod, []).append((at, at + len(d), parts[p].what))
        new: dict[int, str] = {}
        for a in words:
            own = set(owner[a:a + 4]) - {-1}
            if a in data or own <= new.keys(): continue
            w = _word(text, a); t = a64.direct_branch_target(w, a)
            if t is not None and not 0 <= t < te:
                c = _culprit(m, [(p, at, d) for p in kept for _, at, d in parts[p].recs if at < a + 4 and a < at + len(d)], a)
                if c not in new:
                    cave = _written_by(left.get(parts[c].mod, []), t, t + 1)
                    new[c] = (f'[RED] {module}: {parts[c].what}: left out: the patch\'s code at {_offset(module, a)} branches to {_offset(module, t)}, outside the module\'s code '
                              f'({_where(m, t)}{f", where {cave} puts its code" if cave else ""}): the iPhone runs only signed pages')
                continue
            ref = _refers(m, text, a, w)
            if ref is None: continue
            for p in sorted(own - new.keys()):
                dep = _written_by(left.get(parts[p].mod, []), *ref)
                if dep: new[p] = (f'[RED] {module}: {parts[p].what}: left out: its code at {_offset(module, a)} refers to {_offset(module, ref[0])}, which {dep} writes, and that '
                                  'is left out (this code may need it, as a hook needs its cave)')
        if not new: break
        out.update(new)
    verdicts = []
    for i, it in enumerate(items):
        ps = [p for p in range(len(parts)) if parts[p].item == i]
        whole = len(ps) == 1 and ps[0] not in out
        write = tuple(range(len(it.records))) if whole else tuple(sorted(k for p in ps if p not in out for k, _, _ in parts[p].recs))
        verdicts.append(Verdict(write, tuple((parts[p].what, out[p]) for p in ps if p in out)))
    return verdicts


def patch_exefs(exefs, dst, found, files=None, adapt=None):
    """dst: a copy of the ExeFS folder with the code patches written into its modules (other files hard-linked, never written through). Returns the report lines,
    the names of the modules changed (none: dst is a plain copy) and the patches left out ([LeftOut], judge_patches; each has its [RED] line in the report, in its
    place). A module whose patches kept write nothing once some are left out is not changed. files / adapt: as code_patches"""
    modules = nso_modules(exefs)
    notes: dict[str, list[str]] = {}
    def noting(recs, what, rep, adapt=adapt):   # adapt's lines by patch: a patch left out whole loses its line, which would read as if its change were in
        assert adapt is not None
        n = len(rep); out = adapt(recs, what, rep); notes.setdefault(what, []).extend(rep[n:]); return out
    plan, report = code_patches(found, modules, files, noting if adapt else None)
    verdict = {mod: judge_patches(mod, modules[mod][1], items) for mod, items in plan.items()}
    for mod, items in plan.items():
        for it, v in zip(items, verdict[mod]):
            if v.left and not v.write:
                for line in notes.pop(it.what, []): report.remove(line)
    def writes(mod):   # the bytes the patches kept write into the module's image
        size = len(modules[mod][1].image)
        return sum(max(0, min(len(d), size - at)) for it, v in zip(plan[mod], verdict[mod]) for _, at, d in _image_records([it.records[k] for k in v.write]))
    changed = sorted(mod for mod in plan if not any(v.left for v in verdict[mod]) or writes(mod))
    dst = Path(dst); dst.mkdir(parents=True, exist_ok=True)
    for p in sorted(Path(exefs).iterdir()):
        if p.is_file() and p.name not in changed: link_or_copy(p, dst / p.name)
    left = []
    for mod, items in plan.items():
        path, m = modules[mod]
        image = bytearray(m.image)
        written: dict[int, str] = {}
        for it, v in zip(items, verdict[mod]):
            for name, line in v.left: report.append(line); left.append(LeftOut(mod, name, it.mod, line))
            if v.left and not v.write: continue
            recs = [it.records[k] for k in v.write]
            for off, data in recs:   # a byte two patches both write: the later one (in path order) wins, and the report says so
                for k in range(off, off + len(data)):
                    if k in written and written[k] != it.what: report.append(f'[RED] {it.what} overwrites {written[k]} at {mod}+{k - NSO_HEADER:#x}'); break
                for k in range(off, off + len(data)): written[k] = it.what
            n, outside = apply_records(image, recs)   # outside: records cut at the image's end, past which judge_patches kept only zeros (no change)
            report.append(f'{mod}: {it.what}: {n} bytes in {len(recs)}{"" if len(recs) == len(it.records) else f" of its {len(it.records)}"} records'
                          + (f', {outside} records past the module\'s end ignored' if outside else ''))
        if mod not in changed: continue
        out = nso_with_image(path.read_bytes(), image)
        check = nso.load(out, f'{mod} (patched)')
        assert check.image == image and check.build_id == m.build_id   # every byte written that the file does not hold is zero, as it was (judge_patches)
        tmp = dst / (mod + '.part'); tmp.write_bytes(out); os.replace(tmp, dst / mod)
    return report, changed, left


# ---------- switchable mods: the launcher's High frame rate and Ultrawide ----------
# A mod whose folder name says what it does (60FPS, 120 FPS; Ultrawide, 21:9, 32.9) is not written into the modules for good: the NSP script rewrites the modules once more with
# it (a variant) and keeps only the bytes it changes, which the host puts in place when the game starts with the launcher's toggle on (loader.c dm_mod_variants_apply; on the
# iPhone the changed code pages are signed pages of their own, gen_embed.py). One mod per kind: of several (a pack's 60, 120 and 240 FPS, its 21:9 and 32:9) the one that fits
# these devices, and the others are left out with a line in the report.
ROLES = ('fps', 'ultrawide')   # their bits in the host: 1, 2 (DM_MOD_FPS, DM_MOD_ULTRAWIDE)
ROLE_BIT = {'fps': 1, 'ultrawide': 2}
FPS_NAME = re.compile(r'(\d+)\s*-?\s*fps|fps\s*-?\s*(\d+)|\bfps\b|frame\s*rate', re.I)
UW_NAME = re.compile(r'ultra\s*-?\s*wide|\b(\d{2})\s*[.:x]\s*(9|10)\b|\b(21|32)\s*[.:x]\s*9\b', re.I)
UW_RATIOS = (64 / 27, 3440 / 1440, 21 / 9, 2.4, 2560 / 1080, 32 / 9, 5120 / 1440)   # aspect values ultrawide mods are made for
DEVICE_ASPECT = 2868 / 1320   # the iPhone 18 Pro Max's screen in landscape, which Ultrawide is for (an iPad's 4:3 is taller than 16:9: the host leaves Ultrawide off there)


def mod_name(p, root):
    """The mod a patch file belongs to: the folder holding its exefs folder (yuzu, Ryujinx), or the folder it lies in (atmosphere/exefs_patches/<mod>/)"""
    d = Path(p).parent
    if d.name.lower() == 'exefs': d = d.parent
    return str(d.relative_to(root)) if d != Path(root) else d.name


def role_of(name):
    """'fps', 'ultrawide' or None, by the mod's folder name (its last component)"""
    last = Path(name).name
    if UW_NAME.search(last): return 'ultrawide'
    if FPS_NAME.search(last): return 'fps'
    return None


def _fps_of(name):
    m = FPS_NAME.search(Path(name).name)
    n = m and (m.group(1) or m.group(2))
    return int(n) if n else 60


def _uw_of(name):
    m = re.search(r'\b(\d{2})\s*[.:x]\s*(9|10)\b', Path(name).name)
    return int(m.group(1)) / int(m.group(2)) if m else 21 / 9


def split_roles(found, fps_ok=True):
    """(the patch files written for good, {role: (mod name, [its patch files])}, report lines). fps_ok False: the game's profile has the host's own Frame rate setting,
    which a frame-rate mod would fight, so such mods are left out. Of several mods of one kind: FPS the one of 60 (these screens show 60, the host paces at most 60 on
    an iPhone), else the lowest above it; Ultrawide the shape nearest the iPhone's; a mod made for Ryujinx alone ("Ryujinx" in its name) after the others"""
    by_mod: dict[str, list] = {}
    for p in found.ips: by_mod.setdefault(mod_name(p, found.root), []).append(p)
    keep, cands, report = [], {r: [] for r in ROLES}, []
    for name, files in sorted(by_mod.items()):
        r = role_of(name)
        if r == 'fps' and not fps_ok:
            report.append(f'left out: {name}: this game has the launcher\'s own Frame rate setting, which a frame-rate mod would fight'); continue
        if r: cands[r].append(name)
        else: keep += files
    chosen = {}
    for r, names in cands.items():
        if not names: continue
        ryu = lambda n: 'ryujinx' in Path(n).name.lower()
        if r == 'fps': names.sort(key=lambda n: (ryu(n), _fps_of(n) != 60, _fps_of(n) if _fps_of(n) >= 60 else 1000 + _fps_of(n), n))
        else: names.sort(key=lambda n: (ryu(n), abs(_uw_of(n) - DEVICE_ASPECT), n))
        chosen[r] = (names[0], by_mod[names[0]])
        report.append(f'switchable ({"High frame rate" if r == "fps" else "Ultrawide"} in the launcher): {names[0]}')
        report += [f'left out (one {r} mod at a time): {n}' for n in names[1:]]
    return keep, chosen, report


def adapt_aspect(records, what, report, target=DEVICE_ASPECT):
    """An ultrawide mod's records with its aspect value (a 4-byte float within 1 % of a ratio ultrawide mods are made for) set to the device's, so the wider view is not
    squeezed or stretched on a screen of another shape. A value held in instructions (fmov, movz / movk) is not found and stays: the report says so"""
    out, n = [], 0
    for off, data in records:
        if len(data) == 4:
            v = struct.unpack('<f', data)[0]
            if any(abs(v - r) <= r * 0.01 for r in UW_RATIOS):
                out.append((off, struct.pack('<f', target))); n += 1; continue
        out.append((off, data))
    report.append(f'{what}: aspect value set to {target:.4f} (the iPhone 18 Pro Max\'s screen)' if n else f'{what}: no aspect value found as a float to set to the device\'s shape: the view keeps the mod\'s shape')
    return out


def reloc_slots(image):
    """The offsets of the 8-byte words the loader relocates in a module image (DT_RELA, DT_RELR and the PLT's DT_JMPREL): a switchable mod's data bytes are put in place
    after relocation, so they must not touch these"""
    mod0 = struct.unpack_from('<I', image, 4)[0]
    if image[mod0:mod0 + 4] != b'MOD0': return set()
    dyn = mod0 + struct.unpack_from('<i', image, mod0 + 4)[0]
    tags = {}
    for i in range(4096):
        if dyn + i * 16 + 16 > len(image): break
        t, v = struct.unpack_from('<qQ', image, dyn + i * 16)
        if t == 0: break
        tags.setdefault(t, v)
    slots = set()
    for at, size in ((7, 8), (23, 2)):   # DT_RELA / DT_RELASZ, DT_JMPREL / DT_PLTRELSZ: 24-byte entries, offset first
        if at in tags and size in tags:
            for e in range(tags[at], tags[at] + tags[size], 24): slots.add(struct.unpack_from('<Q', image, e)[0])
    if 36 in tags and 35 in tags:   # DT_RELR / DT_RELRSZ: an address, then bitmaps of the next 63 words
        where = 0
        for e in range(tags[36], tags[36] + tags[35], 8):
            w = struct.unpack_from('<Q', image, e)[0]
            if not w & 1: slots.add(w); where = w + 8
            else:
                for b in range(63):
                    if w >> (b + 1) & 1: slots.add(where + 8 * b)
                where += 63 * 8
    return slots


def fixups_header(fixups):
    """{key: value text} of a rewritten module's fixups.tsv header lines ('# TEXT_END 0x...'; patch_nso.py)"""
    return dict(l[2:].split() for l in Path(fixups).read_text().splitlines() if l.startswith('# ') and len(l[2:].split()) == 2)


def file_pieces(fixups, size):
    """The pieces of a rewritten module's file as gen_embed.py maps them (patch_nso.py's fixups.tsv header): [(file start, file end, image start, code?)].
    Code: the text with its first ro page, and the patch area(s); the rest (ro, data) is the writable part"""
    hdr = fixups_header(fixups)
    PG = 0x4000; a = (int(hdr['TEXT_END'], 16) + PG - 1) & ~(PG - 1); po = int(hdr['PATCH_OFF'], 16)
    if po >= 0: return [(0, a, 0, True), (a, po, a, False), (po, size, po, True)]
    fl, bl = int(hdr['FILE_IMAGE_LEN'], 16), int(hdr.get('BACK_LEN', '0'), 16)   # patch area before the base (patch_nso.py FAR), maybe a back one (TWO)
    out = [(0, a, 0, True), (a, fl, a, False), (fl, size - bl, po, True)]
    if bl: out.append((size - bl, size, int(hdr['BACK_OFF'], 16), True))
    return out


META = ('fixups.tsv', 'gates.tsv', 'sites.tsv', 'cuts.tsv', 'changed.tsv', 'obs.tsv', 'match.tsv')


def variant_runs(base_dir, var_dir, module, image):
    """The byte runs a variant rewrite of module changes against the base rewrite: [(kind 'c' (a code page, swapped whole on the iPhone) or 'w' (data), file offset,
    image offset, bytes)]. Raises ModError when the two rewrites differ in more than bytes (the mod changed an instruction the rewriter rewrites: its tables differ), in
    size, when a data run touches a word the loader relocates (image: the variant module's memory image, for its relocations), or when a changed word of the text is a
    direct branch out of the module's code (the text to its 16 KB page's end, and the patch areas: the iPhone runs only those signed pages). A backstop behind
    patch_exefs, which leaves such a patch out before the rewrite (judge_patches): only the text's words are decoded, never the first ro page's or the patch area's
    (before the base or after the module), nor a word a literal load of the changed words reads"""
    base_dir, var_dir = Path(base_dir), Path(var_dir)
    for f in META:
        a, b = base_dir / f'{module}.{f}', var_dir / f'{module}.{f}'
        if a.exists() != b.exists() or (a.exists() and a.read_bytes() != b.read_bytes()):
            raise ModError(f'{module}: the rewrite with the mod differs in {f}, not only in bytes (the mod changes code the rewriter rewrites)')
    x, y = (base_dir / f'{module}.patched.bin').read_bytes(), (var_dir / f'{module}.patched.bin').read_bytes()
    if len(x) != len(y): raise ModError(f'{module}: the rewrite with the mod has another size')
    sz = len(x); pieces = file_pieces(base_dir / f'{module}.fixups.tsv', sz)
    slots = sorted(reloc_slots(image))
    runs, B = [], 0x10000
    for blk in range(0, sz, B):   # whole blocks first: a mod changes a few words of a module of tens of MB
        if x[blk:blk + B] == y[blk:blk + B]: continue
        i, end = blk, min(blk + B, sz)
        while i < end:
            if x[i] == y[i]: i += 1; continue
            piece = next(p for p in pieces if p[0] <= i < p[1])
            j = i
            while j < min(end, piece[1]) and x[j] != y[j]: j += 1
            kind, img_off = ('c' if piece[3] else 'w'), piece[2] + (i - piece[0])
            k = bisect.bisect_left(slots, img_off - 7)
            if kind == 'w' and k < len(slots) and slots[k] < img_off + (j - i):
                raise ModError(f'{module}: the mod writes the data at +{img_off:#x}, a word the loader relocates')
            if runs and runs[-1][0] == kind and runs[-1][1] + len(runs[-1][3]) == i and piece[0] <= runs[-1][1]: runs[-1] = (kind, runs[-1][1], runs[-1][2], runs[-1][3] + bytes(y[i:j]))   # across a block edge
            else: runs.append((kind, i, img_off, bytes(y[i:j])))
            i = j
    te = int(fixups_header(base_dir / f'{module}.fixups.tsv')['TEXT_END'], 16)
    code = [(p[2], p[2] + p[1] - p[0]) for p in pieces if p[3]]   # image ranges the iPhone maps as signed code
    # the changed words of the text, which is at file offset = image offset (file_pieces' first piece); what a literal load of them reads is data, not code
    words = sorted({a for kind, _, io, data in runs if kind == 'c' and 0 <= io < te for a in range(io & ~3, min(io + len(data), te - 3), 4)})
    data = set()
    for a in words:
        w = struct.unpack_from('<I', y, a)[0]; n = _literal_size(w)
        t = a64.pc_relative_target(w, a) if n else None
        if t is not None: data.update(range((t + 3) & ~3, t + n - 3, 4))
    for a in words:
        t = a64.direct_branch_target(struct.unpack_from('<I', y, a)[0], a)
        if a not in data and t is not None and not any(lo <= t < hi for lo, hi in code):
            raise ModError(f'{module}: the mod\'s code at +{a:#x} branches to {"+" if t >= 0 else "-"}{abs(t):#x}, outside the module\'s code (its text and patch area): '
                           'the iPhone runs only signed pages')
    return runs


def write_variants(path, rows):
    """<module>.variants: one row per run, role, kind (c / w), file offset, image offset (negative before the base), the bytes in hex (loader.c, gen_embed.py)"""
    lines = ['# switchable mods (dm/tools/game_mods.py): role\tkind\tfile offset\timage offset\tbytes']
    for role, (kind, fo, io, data) in rows: lines.append(f'{role}\t{kind}\t{fo:#x}\t{io:#x}\t{data.hex()}')
    Path(path).write_text('\n'.join(lines) + '\n')


def read_variants(path):
    """[(role, kind, file offset, image offset, bytes)] of a <module>.variants file"""
    out = []
    for l in Path(path).read_text().splitlines():
        if not l or l.startswith('#'): continue
        r, k, fo, io, h = l.split('\t'); out.append((r, k, int(fo, 16), int(io, 0), bytes.fromhex(h)))
    return out


# ---------- RomFS ----------

def link_or_copy(src, dst):
    """dst as a hard link of src (the same volume), else a copy; a file already at dst is replaced, never written into"""
    dst = Path(dst)
    if dst.exists() or dst.is_symlink(): dst.unlink()
    try: os.link(src, dst)
    except OSError: shutil.copy2(src, dst)


def clone_or_copy(src, dst):
    """dst as an APFS clone of src (instant, its blocks shared until written), else a full copy"""
    dst = Path(dst)
    if dst.exists(): dst.unlink()
    if sys.platform == 'darwin':
        import ctypes
        try:
            if ctypes.CDLL(None, use_errno=True).clonefile(os.fsencode(src), os.fsencode(dst), 0) == 0: return 'clone'
        except (OSError, AttributeError): pass
    shutil.copyfile(src, dst)
    return 'copy'


def _image_tree(img):
    """The tree of a RomFS image: {'kids': {name bytes: node}} for a directory, {'at': (offset, size, flags)} for a file"""
    import romfs
    im = romfs.Image(img)
    def node(k):
        a, b, _, _, t, flags = im.entry(k)
        if t: return {'at': (a, b, flags)}
        return {'kids': {im.name(j): node(j) for j in range(a, a + b)}}
    return node(0), im


def overlay_files(romfs_dirs):
    """[(guest path parts as bytes, host file)] of the files under the mods' romfs folders, in order (a later folder's file wins)"""
    out = []
    for top in romfs_dirs:
        for d, subdirs, files in os.walk(top):
            subdirs[:] = sorted(s for s in subdirs if not skipped(s))
            rel = Path(d).relative_to(top).parts
            for fn in sorted(files):
                if not skipped(fn): out.append((tuple(os.fsencode(x) for x in rel + (fn,)), Path(d) / fn))
    return out


def _place(tree, parts, src, report, label):
    """Puts the host file src at parts in the tree; a name that differs only in letter case from one the game has takes the game's (Windows and macOS folders keep any case)"""
    node, where = tree, []
    for i, part in enumerate(parts):
        kids = node['kids']
        if part not in kids:
            same = [k for k in kids if k.lower() == part.lower()]
            if same: part = same[0]
        where.append(part.decode(errors='replace'))
        last = i == len(parts) - 1
        if last:
            old = kids.get(part)
            if old is not None and 'kids' in old: report.append(f'[RED] {label}: {"/".join(where)} is a folder in the game; the file replaces it')
            kids[part] = {'src': src, 'new': old is None}
            return old is None
        if part not in kids or 'kids' not in kids[part]:
            if part in kids: report.append(f'[RED] {label}: {"/".join(where)} is a file in the game; the folder replaces it')
            kids[part] = {'kids': {}}
        node = kids[part]


def overlay_image(img, dst, romfs_dirs, root=None):
    """dst: the RomFS image img with the mods' files replacing or added to its own. img's data is kept where it is (an APFS clone of it on a Mac, a copy elsewhere),
    the mods' files are appended, and a new index names them; the old index and the replaced files' bytes stay behind as unused bytes. Returns the report lines"""
    import romfs_image as ri
    tree, im = _image_tree(img)
    report, added, replaced = [], 0, 0
    files = overlay_files(romfs_dirs)
    for parts, src in files:
        label = str(src.relative_to(root)) if root else str(src)
        if _place(tree, parts, src, report, label): added += 1
        else: replaced += 1
    part = Path(str(dst) + '.part')
    how = clone_or_copy(img, part)
    with open(part, 'r+b') as out:
        _, ioff, _, _ = ri.HEAD.unpack(out.read(ri.HEAD.size))
        out.truncate(ioff); out.seek(ioff)
        ents = [[b'', tree]]   # breadth-first, each directory's children one consecutive run sorted by name, as romfs_image.py writes them
        rows, i, off = [], 0, ioff
        while i < len(ents):
            name, node = ents[i]
            if 'kids' in node:
                kids = sorted(node['kids'].items())
                rows.append((len(ents), len(kids), name, 0, 0)); ents.extend([k, v] for k, v in kids)
            elif 'src' in node:
                with open(node['src'], 'rb') as fh:
                    n = 0
                    while b := fh.read(8 << 20): out.write(b); n += len(b)
                rows.append((off, n, name, 1, 0)); off += n
            else:
                a, b, flags = node['at']; rows.append((a, b, name, 1, flags))
            i += 1
        pool, idx = bytearray(), bytearray()
        for a, b, name, t, flags in rows:
            idx += ri.ENT.pack(a, b, len(pool), len(name), t, flags); pool += name
        out.write(idx); out.write(pool)
        out.seek(0); out.write(ri.HEAD.pack(ri.MAGIC, off, len(idx) + len(pool), len(rows)))
    os.replace(part, dst)
    del im
    report.insert(0, f'RomFS: {replaced} files replaced, {added} added from {len(romfs_dirs)} romfs folder(s) (the image {"cloned" if how == "clone" else "copied"}, then its new index)')
    return report


def overlay_folder(src, dst, romfs_dirs, root=None):
    """dst: an extracted RomFS folder (an older extraction's layout) as hard links, with the mods' files in place of the game's"""
    report, n = [], 0
    for d, subdirs, files in os.walk(src):
        subdirs.sort()
        rel = Path(d).relative_to(src)
        (Path(dst) / rel).mkdir(parents=True, exist_ok=True)
        for fn in files: link_or_copy(Path(d) / fn, Path(dst) / rel / fn)
    for parts, f in overlay_files(romfs_dirs):
        to = Path(dst).joinpath(*(os.fsdecode(p) for p in parts))
        if to.is_dir(): report.append(f'[RED] {f.relative_to(root) if root else f}: a folder in the game; skipped'); continue
        to.parent.mkdir(parents=True, exist_ok=True)
        if to.exists(): to.unlink()
        shutil.copy2(f, to); n += 1
    report.insert(0, f'RomFS: {n} files from {len(romfs_dirs)} romfs folder(s)')
    return report


# ---------- cheats ----------

def pack_cheats(found, build16, dst):
    """dst: the cheat files to pack: <build ID>.txt as named; a .txt with another name is this build's (build16, main's first 16 hex digits), and several files of one build
    are joined into one (each keeps its entries; the host numbers a name that repeats). Returns the report lines and the files written"""
    by_build: dict[str, list] = {}
    report = []
    for p in found.cheats:
        stem = p.stem.upper()
        b = stem if TITLE.fullmatch(stem) else build16
        if b != stem: report.append(f'cheats: {p.relative_to(found.root)} is not named after a build ID: packed as this version\'s ({build16})')
        by_build.setdefault(b, []).append(p)
    if not by_build: return report, []
    dst = Path(dst); dst.mkdir(parents=True, exist_ok=True)
    out = []
    for b, files in sorted(by_build.items()):
        text = '\n'.join(f.read_text(encoding='utf-8', errors='replace').rstrip('\n') + '\n' for f in files)
        (dst / f'{b}.txt').write_text(text, encoding='utf-8'); out.append(dst / f'{b}.txt')
        n = sum(1 for line in text.splitlines() if re.match(r'\s*[\[{]', line))
        report.append(f'cheats: {b}.txt{" (this version)" if b == build16 else " (another version)"}: {n} entries from {len(files)} file(s)')
    return report, out


if __name__ == '__main__':
    if len(sys.argv) < 3: sys.exit(__doc__)
    found = scan(Path(sys.argv[1]).expanduser(), int(sys.argv[2], 16))
    print(f'{len(found.ips)} code patch files, {len(found.romfs)} romfs folders, {len(found.cheats)} cheat files')
    for p, why in found.ignored: print(f'ignored {p}: {why}')
    if len(sys.argv) > 3:
        modules = nso_modules(sys.argv[3])
        plan, rep = code_patches(found, modules)
        for line in rep: print(line)
        for mod, items in plan.items():   # what patch_exefs would write, and leave out with its [RED] lines
            for it, v in zip(items, judge_patches(mod, modules[mod][1], items)):
                for _, line in v.left: print(line)
                if v.write or not v.left: print(f'{mod}: {it.what}: {len(v.write)}{"" if len(v.write) == len(it.records) else f" of its {len(it.records)}"} records')
