#!/usr/bin/env python3
"""A game's mods, packed into its app by the NSP script (scripts/build_ipa_from_nsp.py, MODS / --mods; by default the folder named mods beside the game's files):
  · code patches: Atmosphère IPS / IPS32 files named after a module's build ID (atmosphere/exefs_patches/<mod>/<build ID>.ips) and IPSwitch text patches (*.pchtxt, which name
    their build in an @nsobid line), as yuzu, Ryujinx and Atmosphère apply them, written into the decompressed code module (main, subsdk*, sdk, rtld) before the rewriter
    (patch_nso.py) reads it. An iPhone app's code pages are signed, so this is the only way a code patch (a 60 fps patch, a resolution patch) reaches the game there;
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
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
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


def code_patches(found, modules, files=None, adapt=None):
    """{module name: [(source description, [(offset, bytes)])]} of the patch files that name one of the modules' builds, in path order, and the report lines.
    files: the patch files to take (default: all of found's); adapt(records, what, report) may change a file's records (the ultrawide aspect, adapt_aspect)"""
    plan, report = {}, []
    for p in (found.ips if files is None else files):
        rel = p.relative_to(found.root)
        if p.suffix.lower() == '.pchtxt':
            try: bid, patches = parse_pchtxt(p.read_text(encoding='utf-8', errors='replace'), str(rel))
            except ModError as e: report.append(f'skipped {rel}: {e}'); continue
            if not bid: report.append(f'skipped {rel}: no @nsobid line names its build'); continue
            mod = next((m for m, (_, mo) in modules.items() if build_matches(bid, mo.build_id)), None)
            if not mod: report.append(f'not for this version: {rel} (build {bid[:16]})'); continue
            for tp in patches:
                if tp.enabled: plan.setdefault(mod, []).append((f'{rel}: {tp.name}', adapt(tp.records, f'{rel}: {tp.name}', report) if adapt else tp.records))
                else: report.append(f'off in its file (@disabled): {rel}: {tp.name}')
            continue
        bid = p.name.split('.')[0]
        mod = next((m for m, (_, mo) in modules.items() if build_matches(bid, mo.build_id)), None)
        if not mod:
            report.append(f'not for this version: {rel}' + ('' if HEX.fullmatch(bid) else ' (an .ips is named after the build ID of the module it patches)'))
            continue
        try: recs = parse_ips(p.read_bytes(), str(rel)); plan.setdefault(mod, []).append((str(rel), adapt(recs, str(rel), report) if adapt else recs))
        except ModError as e: report.append(f'skipped {rel}: {e}')
    return plan, report


def patch_exefs(exefs, dst, found, files=None, adapt=None):
    """dst: a copy of the ExeFS folder with the code patches written into its modules (other files hard-linked, never written through). Returns the report lines,
    and the names of the modules changed (none: dst is a plain copy). files / adapt: as code_patches"""
    modules = nso_modules(exefs)
    plan, report = code_patches(found, modules, files, adapt)
    dst = Path(dst); dst.mkdir(parents=True, exist_ok=True)
    for p in sorted(Path(exefs).iterdir()):
        if p.is_file() and p.name not in plan: link_or_copy(p, dst / p.name)
    for mod, items in plan.items():
        path, m = modules[mod]
        image = bytearray(m.image)
        written: dict[int, str] = {}
        for what, recs in items:
            for off, data in recs:   # a byte two patches both write: the later one (in path order) wins, and the report says so
                for k in range(off, off + len(data)):
                    if k in written and written[k] != what: report.append(f'[RED] {what} overwrites {written[k]} at {mod}+{k - NSO_HEADER:#x}'); break
                for k in range(off, off + len(data)): written[k] = what
            n, outside = apply_records(image, recs)
            report.append(f'{mod}: {what}: {n} bytes in {len(recs)} records' + (f', {outside} records past the module\'s end ignored' if outside else ''))
        out = nso_with_image(path.read_bytes(), image)
        check = nso.load(out, f'{mod} (patched)')
        assert check.image == image and check.build_id == m.build_id
        tmp = dst / (mod + '.part'); tmp.write_bytes(out); os.replace(tmp, dst / mod)
    return report, sorted(plan)


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


def file_pieces(fixups, size):
    """The pieces of a rewritten module's file as gen_embed.py maps them (patch_nso.py's fixups.tsv header): [(file start, file end, image start, code?)].
    Code: the text with its first ro page, and the patch area(s); the rest (ro, data) is the writable part"""
    hdr = dict(l[2:].split() for l in Path(fixups).read_text().splitlines() if l.startswith('# ') and len(l[2:].split()) == 2)
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
    size, or when a data run touches a word the loader relocates (image: the variant module's memory image, for its relocations)"""
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
        plan, rep = code_patches(found, nso_modules(sys.argv[3]))
        for line in rep: print(line)
        for mod, items in plan.items():
            for what, recs in items: print(f'{mod}: {what}: {len(recs)} records')
