#!/usr/bin/env python3
"""A game's mods, packed into its app by the NSP script (scripts/build_ipa_from_nsp.py, MODS / --mods; by default the folder named mods beside the game's files):
  · code patches: Atmosphère IPS / IPS32 files named after a module's build ID (atmosphere/exefs_patches/<mod>/<build ID>.ips) and IPSwitch text patches (*.pchtxt, which name
    their build in an @nsobid line), as yuzu, Ryujinx and Atmosphère apply them, written into the decompressed code module (main, subsdk*, sdk, rtld) before the rewriter
    (patch_nso.py) reads it. An iPhone app's code pages are signed, so this is the only way a code patch (a 60 fps patch, a resolution patch) reaches the game there;
  · RomFS file replacements (LayeredFS): every file under a folder named romfs (atmosphere/contents/<title ID>/romfs/..., <mods>/<title ID>/<mod>/romfs/...) replaces the
    game file of the same path, or is added; the game's RomFS image (DMROMFS1, romfs_image.py) gets a new index that names them, its own data kept as it was;
  · cheats: Atmosphère cheat files under a folder named cheats, <build ID>.txt; a .txt with another name is taken as the packed build's. They are packed into the app, which copies
    them into its cheats folder (the iPhone's Documents/cheats), where the in-game menu turns them on.
What belongs to the game: a folder named with a title ID belongs to that title (and its updates and DLC, which share all but the last three hex digits), so a whole SD card
(atmosphere/contents/<title ID>/...), Ryujinx's mods folder or yuzu's load folder can be given as it is; anything else under the mods folder counts. A file or folder whose name
starts with '.' or '-' is skipped, so renaming a mod's folder to -name turns it off without deleting it.
Usage on its own (a check, nothing written): game_mods.py <mods folder> <title ID> [ExeFS folder]"""
import hashlib, os, re, shutil, struct, sys
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
    """component names a title (16 hex digits): whether it is this game's (base, update, DLC or another program of it share all but the last three digits)"""
    return int(component, 16) & ~0xFFF == title_id & ~0xFFF


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
                if TITLE.fullmatch(e.name) and not same_title(e.name, title_id): continue   # another game's
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


def code_patches(found, modules):
    """{module name: [(source description, [(offset, bytes)])]} of the patch files that name one of the modules' builds, in path order, and the report lines"""
    plan, report = {}, []
    for p in found.ips:
        rel = p.relative_to(found.root)
        if p.suffix.lower() == '.pchtxt':
            try: bid, patches = parse_pchtxt(p.read_text(encoding='utf-8', errors='replace'), str(rel))
            except ModError as e: report.append(f'skipped {rel}: {e}'); continue
            if not bid: report.append(f'skipped {rel}: no @nsobid line names its build'); continue
            mod = next((m for m, (_, mo) in modules.items() if build_matches(bid, mo.build_id)), None)
            if not mod: report.append(f'not for this version: {rel} (build {bid[:16]})'); continue
            for tp in patches:
                if tp.enabled: plan.setdefault(mod, []).append((f'{rel}: {tp.name}', tp.records))
                else: report.append(f'off in its file (@disabled): {rel}: {tp.name}')
            continue
        bid = p.name.split('.')[0]
        mod = next((m for m, (_, mo) in modules.items() if build_matches(bid, mo.build_id)), None)
        if not mod:
            report.append(f'not for this version: {rel}' + ('' if HEX.fullmatch(bid) else ' (an .ips is named after the build ID of the module it patches)'))
            continue
        try: plan.setdefault(mod, []).append((str(rel), parse_ips(p.read_bytes(), str(rel))))
        except ModError as e: report.append(f'skipped {rel}: {e}')
    return plan, report


def patch_exefs(exefs, dst, found):
    """dst: a copy of the ExeFS folder with the code patches written into its modules (other files hard-linked, never written through). Returns the report lines,
    and the names of the modules changed (none: dst is a plain copy)"""
    modules = nso_modules(exefs)
    plan, report = code_patches(found, modules)
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
