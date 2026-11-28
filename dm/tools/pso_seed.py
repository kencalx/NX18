#!/usr/bin/env python3
"""A game's prewarm seed list (dm/games/<id>/pso_manifest.tsv, docs/development.md "Prewarm lists") checked, or grown from recorded lists: a Mac run's DM_PSO_RECORD file or a
device's own Documents/pso_user.tsv, which hold the same rows (S shader, R render pipeline, C compute pipeline, M native task / mesh pipeline, G geometry pair with no mesh library).
Each row is read as the host's warm_parse (dm/gfx/nvn/nvn_mtl.m) and pso_skey_parse / pso_mesh_skey_parse (dm/gfx/nvn/nvn_pso_skey.h) read it, and must also:
  · name only library keys <16 hex digits>_b of the profile's shader map (shader_map.tsv, column 4, as shmap_load reads it), each at the stage the map gives it
    (stage_of: vertex 0, pixel 1, geometry 2, hull / task 3, domain / mesh 4, compute 5): a key of another game version, or of another game, is refused
  · carry nothing of the device that wrote it: no path, no pointer (pso_skey_from clears the shader and specialized-fragment pointers), the bytes after each key's end,
    the description's padding and border_spare zero, the flags (merged, fz, border) 0 or 1
The rows keep their order (the order of first use, which is the prepare step's order: never sort them); a line repeated, or an R row whose key is an earlier one's, is left out
as the host leaves it out.
Usage:
  pso_seed.py check (--game <id> | --map <shader_map.tsv>) [<list>...]       every row of the lists (default: the game's pso_manifest.tsv); exit 1 on a refused row
  pso_seed.py add (--game <id> | --map <shader_map.tsv> --manifest <file>) [--note <text>]... [--drop-invalid] [--keep-s] <recorded list>...
      appends to the manifest the rows of the recorded lists it does not name yet, below its rows and the notes (one comment line each; {S} {R} {C} {M} {G} {rows} are the counts
      of the rows added). The provisional profile's line "empty until recorded" goes. A refused row stops it (nothing written) unless --drop-invalid leaves those rows out.
      S rows of the recorded lists are skipped, not checked and not refused, and their number printed: the host ignores them (DM_PSO_DROP_S, on by default: nvn_mtl.m
      drop_s_on), so an old device list or upstream capture still adds its other rows. --keep-s, or DM_PSO_DROP_S=0 in the environment, adds them as before
  pso_seed.py strip-s (--game <id> | --manifest <file>)...
      takes the S rows out of committed lists, comments and the other rows as they are, and refuses (writes nothing) a list whose game's shader-build digest (dmsh_chain.py
      inputs: G and K rows only) or whose offline archive rows (pso_offline.py: C, M and R rows) the cut would change"""
import argparse, os, re, struct, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.append(str(REPO / 'dm/gfx/tools'))
from pso_skey_layout import SKEY, KEY as DESC, LENGTHS   # noqa: E402 (sizeof(pso_skey), where its pso_key starts, the row lengths pso_skey_parse reads: one place for this and pso_offline.py)
STAGES = {'vertex': 0, 'pixel': 1, 'geometry': 2, 'hull': 3, 'task': 3, 'domain': 4, 'mesh': 4, 'compute': 5}   # stage_of in nvn_mtl.m
KEY = re.compile(r'[0-9a-f]{16}_b\Z')   # a library's name: <map key>_b
BORDER = DESC + 416   # pso_key.border, then border_spare
PROVISIONAL = '# Provisional profile: empty until recorded'


def drop_s_default():   # the host's DM_PSO_DROP_S: on unless =0
    return os.environ.get('DM_PSO_DROP_S') != '0'


def is_s(row):
    return row.startswith('S\t')


def read_map(path):
    """{key: stage name} of a shader map, as shmap_load reads it"""
    out = {}
    for line in Path(path).read_text(encoding='utf-8').split('\n'):
        if not line or line.startswith(('#', 'package')): continue
        c = line.split('\t')
        if len(c) > 3: out[c[3]] = c[2]
    return out


def key_problem(key, shmap, stage):
    """Why a library key is refused (None: it is fine); stage: the stage number the row gives it, or a stage name it must have"""
    if not KEY.match(key): return f'not a <map key>_b library key, which the prewarm drops (warm_map_stage): {key!r}'
    have = shmap.get(key[:-2])
    if have is None: return f'not in the shader map: {key}'
    want = stage if isinstance(stage, int) else STAGES.get(stage)
    if STAGES.get(have) != want: return f'{key} is a {have} shader in the shader map, the row says stage {stage}'
    return None


def parse_skey(text):
    """A pso_skey hex as the host reads it: (bytes padded to the whole key, None) or (None, why it is refused)"""
    if len(text) not in LENGTHS: return None, f'a pipeline key of {len(text)} hex digits (the host reads {", ".join(map(str, LENGTHS))})'
    if not re.fullmatch(r'[0-9a-fA-F]*', text): return None, 'a pipeline key that is not hex'
    b = bytes.fromhex(text)
    return b + bytes(SKEY - len(b)), None


def name_field(raw):
    """A key field (char[24]): (its text, whether every byte after its end is zero)"""
    end = raw.find(b'\0')
    if end < 0: end = len(raw)
    return raw[:end].decode('ascii', 'replace'), not any(raw[end:])


def skey_problem(b, shmap, mesh=False):
    """Why an R (or, mesh, an M) row's decoded key is refused, or None"""
    (vs, vclean), (fs, fclean) = name_field(b[0:24]), name_field(b[24:48])
    vs_stage, fs_stage, merged, fz = b[48:52]
    if not vclean or not fclean: return 'bytes after a shader key\'s end (device memory)'
    if any(b[86:DESC]): return 'padding bytes that are not zero (device memory)'
    if struct.unpack_from('<QQ', b, DESC) != (0, 0) or struct.unpack_from('<Q', b, DESC + 336)[0]: return 'a pointer of the device that wrote it'
    border, spare = struct.unpack_from('<2I', b, BORDER)
    if spare: return 'border_spare bytes that are not zero (device memory)'
    if merged > 1 or fz > 1 or border > 1: return f'flags merged {merged} / fz {fz} / border {border} (0 or 1)'
    if not fz and any(b[52:86]): return 'a specialized fragment description without the fz flag'
    if not vs: return 'no vertex shader'
    if mesh and (vs_stage != 4 or merged or fz): return 'not a task / mesh pipeline (pso_mesh_skey_parse)'
    if not mesh and vs_stage == 4: return 'a mesh shader in an R row'
    why = key_problem(vs, shmap, vs_stage)
    if why: return why
    if fs: return key_problem(fs, shmap, fs_stage) if fs_stage == 1 else f'fragment {fs} at stage {fs_stage}'
    if fs_stage: return f'no fragment shader but fragment stage {fs_stage}'
    return None


def row_problem(line, shmap):
    """Why a list's row is refused, or None"""
    if '/' in line or '\\' in line: return 'a path'
    if '\r' in line: return 'a carriage return: the host splits lines at \\n only, and drops an R or C row that ends in \\r'
    c = line.split('\t')
    kind = c[0]
    if kind == 'S':
        if len(c) != 3 or not re.fullmatch(r'[0-5]', c[2]): return 'an S row is S<TAB>key<TAB>stage 0-5'
        return key_problem(c[1], shmap, int(c[2]))
    if kind == 'C':
        if len(c) != 2: return 'a C row is C<TAB>key'
        return key_problem(c[1], shmap, 'compute')
    if kind == 'R':
        if len(c) != 2: return 'an R row is R<TAB>pipeline key'
        b, why = parse_skey(c[1])
        return why or skey_problem(b, shmap)
    if kind == 'M':
        if len(c) != 3: return 'an M row is M<TAB>task key or -<TAB>pipeline key'
        if c[1] != '-' and (why := key_problem(c[1], shmap, 'task')): return why
        b, why = parse_skey(c[2])
        return why or skey_problem(b, shmap, mesh=True)
    if kind == 'G':   # a lean geometry pair drawn with no mesh library (nvn_geometry.inc geo_mesh_fn): dmsh_chain.mesh_pairs builds its library, the host does not prewarm it
        if len(c) != 3 or not all(re.fullmatch(r'[0-9a-f]{16}', k) for k in c[1:]): return 'a G row is G<TAB>vertex key<TAB>geometry key (16 hex digits each)'
        return key_problem(c[1] + '_b', shmap, 'vertex') or key_problem(c[2] + '_b', shmap, 'geometry')
    if kind == 'K':   # a one-draw pass's vertex / pixel pair with no pass-as-compute kernel (nvn_mtl.m pcm_kernel): dmsh_chain.pc_pairs builds its kernel; the prewarm starts its pipeline
        if len(c) != 3 or not all(re.fullmatch(r'[0-9a-f]{16}', k) for k in c[1:]): return 'a K row is K<TAB>vertex key<TAB>pixel key (16 hex digits each)'
        return key_problem(c[1] + '_b', shmap, 'vertex') or key_problem(c[2] + '_b', shmap, 'pixel')
    return f'an unknown row kind {kind!r}'


def rows_of(text, strip_cr=True):
    """The rows of a list (no comments, no blank lines), with '\\r' line ends taken off (add's sources); strip_cr off: as the host reads them (check)"""
    if not strip_cr: return [ln for ln in text.split('\n') if ln and not ln.startswith('#')]
    return [ln.rstrip('\r') for ln in text.split('\n') if ln.rstrip('\r') and not ln.startswith('#')]


def identity(line):
    """What makes two rows one for the host: the line, or an R row's key read whole (a row from before attr_hi is the same key with those bytes zero)"""
    c = line.split('\t')
    if c[0] == 'R' and len(c) == 2:
        b, why = parse_skey(c[1])
        if not why: return ('R', b)
    return line


def collect(lines, shmap, known=()):
    """(rows to keep in order, [(row, why refused)]): each row once, less those whose identity is in known"""
    seen, keep, bad = set(known), [], []
    for line in lines:
        ident = identity(line)
        if ident in seen: continue
        seen.add(ident)
        why = row_problem(line, shmap)
        if why: bad.append((line, why))
        else: keep.append(line)
    return keep, bad


def counts(rows):
    out = dict.fromkeys('SRCM', 0)   # G rows only when there are any
    for r in rows: out[r.split('\t', 1)[0]] = out.get(r.split('\t', 1)[0], 0) + 1
    out['rows'] = len(rows)
    return out


def g_count(n):   # ', G <n>' / ', K <n>' in a count line when the rows hold G or K rows, else nothing (the lists without any print as before)
    return (', G %d' % n['G'] if 'G' in n else '') + (', K %d' % n['K'] if 'K' in n else '')


def report(bad, limit=10):
    for line, why in bad[:limit]: print(f'  {why}: {line[:120]}', file=sys.stderr)
    if len(bad) > limit: print(f'  ... and {len(bad) - limit} more', file=sys.stderr)


def add(manifest, sources, shmap, notes=(), drop_invalid=False, keep_s=None, skipped=None):
    """Appends to manifest the valid rows of sources it does not name yet (see the module's note). Returns (rows added, rows refused); writes nothing when a row is refused
    and drop_invalid is off. keep_s: add S rows too (None: as DM_PSO_DROP_S says, on: skipped); skipped: a list the skipped S rows are appended to"""
    if keep_s is None: keep_s = not drop_s_default()
    text = manifest.read_text(encoding='utf-8') if manifest.is_file() else ''
    known = {identity(r) for r in rows_of(text)}
    recorded = [r for src in sources for r in rows_of(Path(src).read_text(encoding='utf-8'))]
    if not keep_s:
        if skipped is not None: skipped.extend(r for r in recorded if is_s(r))
        recorded = [r for r in recorded if not is_s(r)]
    new, bad = collect(recorded, shmap, known)
    if (bad and not drop_invalid) or not new: return new, bad
    n = counts(new)
    kept = [ln.rstrip('\r') for ln in text.split('\n') if ln.rstrip('\r') and not ln.startswith(PROVISIONAL)]   # the list as it is, its notes where they stand
    notes = [t.format(**{'G': 0, **n}) if t.startswith('#') else '# ' + t.format(**{'G': 0, **n}) for t in notes]
    manifest.write_text('\n'.join(kept + notes + new) + '\n', encoding='utf-8')
    return new, bad


def strip_s(manifest, game=None):
    """Takes the S rows out of manifest (comments, blank lines and the other rows stay where they are). game: the profile, whose shader-build digest (dmsh_chain.inputs) must
    not change. Returns (S rows taken out, why it was refused or None); writes nothing when refused or when there is no S row"""
    sys.path.insert(0, str(REPO / 'dm/gfx/tools'))
    import dmsh_chain, pso_offline   # noqa: E402 (what reads the list besides the host: the shader build's digest and the archive made offline)
    raw = manifest.read_bytes()
    lines = raw.decode('utf-8').split('\n')
    kept = [ln for ln in lines if not is_s(ln)]
    n = len(lines) - len(kept)
    if not n: return 0, None
    out = '\n'.join(kept).encode('utf-8')
    tmp = manifest.with_name(manifest.name + '.strip-s')
    tmp.write_bytes(out)
    try:
        def same(read): return read([str(manifest)]) == read([str(tmp)])
        if not (same(lambda ms: pso_offline.read_computes([], ms)) and same(pso_offline.read_meshes) and same(pso_offline.read_layouts)):
            return n, 'the offline archive\'s rows (pso_offline.py) would change'
        if game is not None:
            before = dmsh_chain.inputs(game)
            os.replace(tmp, manifest)
            try: after = dmsh_chain.inputs(game)
            except BaseException: manifest.write_bytes(raw); raise
            if after != before:
                manifest.write_bytes(raw)
                return n, f'the shader-build digest would change ({before} to {after})'
            return n, None
        os.replace(tmp, manifest)
        return n, None
    finally:
        tmp.unlink(missing_ok=True)


def main(argv=None):
    ap = argparse.ArgumentParser(description=(__doc__ or '').split('\n')[0])   # python3 -OO strips the docstring
    ap.add_argument('action', choices=('check', 'add', 'strip-s'))
    ap.add_argument('lists', nargs='*', help='check: the lists to check (default: the game\'s pso_manifest.tsv); add: the recorded lists')
    ap.add_argument('--game', help='the profile under dm/games: its shader_map.tsv and pso_manifest.tsv')
    ap.add_argument('--map', help='the shader map (default: the game\'s)')
    ap.add_argument('--manifest', help='add: the seed list to append to (default: the game\'s)')
    ap.add_argument('--note', action='append', default=[], help='add: a comment line above the added rows; {S} {R} {C} {M} {G} {rows} are their counts')
    ap.add_argument('--drop-invalid', action='store_true', help='add: leave refused rows out instead of writing nothing')
    ap.add_argument('--keep-s', action='store_true', help='add: add the recorded S rows too, as before DM_PSO_DROP_S (the default skips them; DM_PSO_DROP_S=0 keeps them too)')
    a = ap.parse_args(argv)
    gdir = REPO / 'dm/games' / a.game if a.game else None
    if a.action == 'strip-s':
        if not (a.game or a.manifest): ap.error('strip-s: --game or --manifest')
        g = None
        if a.game:
            sys.path.insert(0, str(REPO / 'dm/games')); import game as game_mod   # noqa: E402
            g = game_mod.load(a.game)
        p = Path(a.manifest) if a.manifest else g.table('pso_manifest.tsv') if g is not None else None
        if p is None: ap.error('strip-s: --game or --manifest')
        n, why = strip_s(p, g)
        if why: print(f'[RED] {p}: {n} S rows not taken out: {why}', file=sys.stderr); return 1
        print(f'{p}: {n} S rows taken out' + (' (the shader-build digest and the offline archive\'s rows unchanged)' if g is not None else ' (the offline archive\'s rows unchanged)'))
        return 0
    if a.map: shmap = read_map(a.map)
    elif gdir: shmap = read_map(gdir / 'shader_map.tsv')
    else: ap.error('--game or --map')
    if a.action == 'check':
        paths = a.lists or ([gdir / 'pso_manifest.tsv'] if gdir else [])
        if not paths: ap.error('check: a list, or --game')
        status = 0
        for p in paths:
            rows = rows_of(Path(p).read_bytes().decode('utf-8'), strip_cr=False)   # bytes as they are: read_text would turn \r\n into \n, which the host does not
            keep, bad = collect(rows, shmap)
            n = counts(keep)
            print(f'{p}: {len(rows)} rows, {n["rows"]} kept (S {n["S"]}, R {n["R"]}, C {n["C"]}, M {n["M"]}{g_count(n)}), {len(rows) - len(keep) - len(bad)} repeated, {len(bad)} refused')
            if bad: status = 1; report(bad)
        return status
    if not a.lists: ap.error('add: the recorded lists')
    manifest = Path(a.manifest) if a.manifest else gdir / 'pso_manifest.tsv' if gdir else None
    if not manifest: ap.error('add: --manifest, or --game')
    skipped = []
    new, bad = add(manifest, a.lists, shmap, a.note, a.drop_invalid, keep_s=True if a.keep_s else None, skipped=skipped)
    n = counts(new)
    if skipped: print(f'{len(skipped)} S rows of the recorded lists skipped: the host ignores them (DM_PSO_DROP_S; --keep-s adds them)')
    if bad:
        print(f'[RED] {len(bad)} rows refused' + (', left out:' if a.drop_invalid else ': nothing written (--drop-invalid leaves them out)'), file=sys.stderr)
        report(bad)
        if not a.drop_invalid: return 1
    print(f'{manifest}: {n["rows"]} rows added (S {n["S"]}, R {n["R"]}, C {n["C"]}, M {n["M"]}{g_count(n)})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
