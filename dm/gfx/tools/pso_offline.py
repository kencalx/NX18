#!/usr/bin/env python3
# The pipeline archive made offline: the base of every shader pair, as the host's pipeline prebuild makes it on the device (pre_desc / pre_pair in dm/gfx/nvn/nvn_mtl.m), compiled on the Mac
# by metal-tt into one Metal 4 pipeline archive per GPU architecture, so an iPhone takes the bases from the app bundle instead of compiling them on its first start.
# The host matches libraries by content, so the archive serves the libraries the app ships (msl/b-<chain>); measurements are in dm/games/01007EF00011E000/README.md.
# Per pair (vertex key, pixel key) of the profile's shader_pairs.tsv and pso_pairs.tsv, read in that order with repeated lines dropped, as the host reads them:
#   · the vertex shader's pulling library <key>_bp (a vertex shader without stage inputs: its own <key>_b), entry `entry`, or `entry_z` for the near = 0 depth mode, from its reflection
#     <key>_b.json; the pixel shader's <key>_b, entry `entry` (main0); no vertex descriptor, one sample, every colour attachment unspecialized
#   · left out as the host leaves them out (to the draws): a reflection of another chain version or none, a vertex shader with stage inputs and no pulling library, a vertex library that
#     writes the layer (its reflection's layer_out, dmsh_entry.py layer_out: its pipelines take an input primitive class), a pixel shader that reads the primitive ID (its reflection's
#     raster.primitive_id: the host builds its pipelines whole, since through a base every primitive reads 0), a missing library or entry point
#   · a pair with no pixel key (a line "<vertex key><TAB>") is a depth-only program's: its base has the host's empty fragment, dm_nop of dm/gfx/msl/nop_frag.metal, as pso_desc4 gives
#     such a draw (Metal 4 needs a fragment function whenever rasterization is on). That library is not among the game's: it is compiled here as the host compiles its own shaders
#     (host_msl.py: the SDK of the platform, the host's minimum OS, MSL_MIN_<sdk> in dm/host/Makefile), since the archive finds a function by its hash, which the minimum OS changes
#     and the file's path does not. The split writes no such pairs yet
#   · a function that declares function constants is specialized as the host's prebuild specializes it (pre_fn in nvn_mtl.m): the border colour corrections' dm_border_off set (true:
#     off), the specialization the draws that bind no sampler with a twin share (fn_off). metal-tt specializes a <key>_b or <key>_bp function, cut by dmsh_side.cut or not, and the host
#     finds that base by its specialized descriptor (checked on Ocarina of Time's libraries, macOS 27.2, metal-tt 32023). It cannot lower a function unspecialized ("cannot lower module
#     with unresolved function constants"), and failed with "cannot find private metadata" on a side library (<key>_bx), which no base uses. A pair whose functions declare any other
#     constant is left to the device (rest_pairs.tsv), as before (HOST_CONSTANTS)
# And a compute pipeline per compute shader, which depends on its function alone (the host makes it from the function, cps_new in nvn_mtl.m; the threadgroup size is the dispatch's):
# the C rows of the profile's prewarm list (pso_manifest.tsv, recorded, in order), then every compute shader of its shader map (shader_map.tsv, stage compute), so a game whose list
# names none (a provisional profile) still has them; per shader <key>_b, entry `entry`. Left out as the host would not find them: a reflection of another chain version or none, a
# missing library or entry point, a function with a function constant other than HOST_CONSTANTS (the host specializes it with an MTL4SpecializedFunctionDescriptor and compiles it
# through its MTL4Compiler on the device). One with the border corrections' constant is specialized as for the bases, as the host's common dispatch and its prewarm take it (cps_new_b)
# And a native task / mesh pipeline per M row of the prewarm lists (pso_manifest.tsv), whole, as the host's mtk_build describes it (mtk_desc4 in nvn_geometry.inc): its object function
# (the task shader's entry, or the mesh shader's own entry_object when the row has no task), the mesh shader's entry (entry_z for near = 0), the pixel shader's entry, the threads and
# payload of the reflection's mesh_stage, and the colour attachments pso_desc makes from the row's key, fully specialized. Without them a fresh install built every one at its first
# draw or in the prepare step through the MTLDevice: 1.9-5 s each on an iPad Pro (M5), 2.1 s for one in Ocarina of Time's play on an iPhone 18 Pro Max. Left out as the host's
# descriptor could not be matched or would not be built: a key that does not parse, a reflection of another chain version or none, stages that do not fit (a task row whose mesh shader
# has its own object entry, or the reverse), a missing library or entry point, a function with a function constant other than HOST_CONSTANTS, or with the border corrections' when
# the row keeps them (its key's border: mtk_desc4 then takes the functions unspecialized) or in the mesh shader's own object entry (taken as noted), no pixel shader (the host's own empty fragment, dm/gfx/msl/mesh_nop.metal, is not among the game's libraries), the alpha test or a logic
# operation (their fragments come from side libraries), a colour format the script cannot name. They go into groups of their own (batches.<arch>/m<index>/); a group metal-tt
# refuses is left out of the archive with a red line and the rest is shipped, since its pipelines are still built on the device as before (GitHub issue #283: one refused pipeline
# failed the whole archive). The refusal is kept by the key of that group's own inputs (refused.<arch> in its folder) and the archive's key is written, so the next build reuses the
# archive and repeats neither the refused compile nor the merge of every group (3.5 GB for Ocarina of Time's g19p); a group whose inputs change (new rows, a new toolchain) is
# compiled again. The key names the groups it left out, so removing one's refused.<arch> makes the archive stale and the next build tries that group again (the reused archive
# compiles nothing and would never read the file). A full volume or a compiler that did not exit by itself is no refusal: no key then, and the next build tries the group again
# And the base of every R row of the prewarm lists (pso_manifest.tsv): a pipeline with a vertex layout, as pso_desc / pso_desc4 make its base (plan_layout: the vertex function, or its
# shadow-input one from <key>_bv; the vertex descriptor of vfmt / vfmt_for_ct / VB_SLOT, the zero buffer at 30 and the CPU conversion's slots from 1; the fragment entry the colour
# targets call for; samples and alpha to coverage; colour unspecialized; the empty fragment for depth only). The host's plain lookups ask the bundle for them (arch_lookup_in), so a
# first start takes them from the app instead of compiling them. Left out as the host's descriptor could not be matched or metal-tt would refuse it (plan_layout), counted in the
# output and archive.tsv (layout_rows). Groups of their own (batches.<arch>/l<index>/); one metal-tt refuses is compiled again in halves (l<index>/a, l<index>/b, ...) down to
# single bases, so only the bases it refuses are left out, each refusal kept by its own inputs as a task / mesh group's is. --no-layout: none
# Output folder (what the app bundles as pso/, the host's DM_PSO_BUNDLE):
#   <arch>.mtl4a     one archive per GPU architecture (applegpu_g18p = A19 / A19 Pro); the host opens the one named after its device's architecture
#   prebuilt.tsv     what the archives cover, in the host's stamp format (pso_prebuild): chain version, depth mode, the pair lists' size and SHA-256. The host skips its prebuild when
#                    it matches and a probe of a few bases finds them in the archive
#   rest_pairs.tsv   the pairs the device still builds (only when there are any)
#   archive.tsv      what was built: architectures, OS minimum, toolchain, bases, compute and task / mesh pipelines, layout bases, the R rows and those left out by reason, and per
#                    architecture the groups left out (refused by metal-tt) (for people and logs; the host does not read it)
# Each archive is made again only when its compiler inputs change (key.<arch> in the work folder): the complete pipeline configuration without library locations,
# the referenced libraries' bytes, architecture, platform, minimum OS and metal-tt version. Chain/profile stamps are validated and refreshed independently.
# More bases than --batch-size are compiled in sequential groups (batches.<arch>/<index>/ in the work folder, each cached by its own inputs) and merged with metal-pack: one metal-tt on
# Super Mario Odyssey's 32,864 bases runs an 8 GB Mac out of paging space (docs/reference/shaders.md, Bounded groups for the offline pipeline compiler). The output is the same single file.
# With compute pipelines, they and the bases are separate groups (batches.<arch>/c<index>/ and <index>/) merged the same way, so new pairs leave the compute pipelines compiled, and the
# reverse. The compute groups are small (COMPUTE_BATCH) and run --jobs at a time: one metal-tt keeps about three cores busy.
# Usage: pso_offline.py --msl <b-<chain> folder> --out <folder> --work <folder> [--game <id>] [--pairs <shader_pairs.tsv> [--pairs <pso_pairs.tsv>]] [--gpu g18p[,g17p]]
#          [--depth gl|zero] [--platform ios|macos] [--os-min 27.3] [--script-only] [--batch-size N] [--shader-map <shader_map.tsv>] [--manifest <pso_manifest.tsv>] [--no-compute] [--no-mesh] [--no-layout] [--jobs N]
#   --game: the profile (DM_GAMES_DIR as for game.py) whose shader_pairs.tsv and pso_pairs.tsv are the pairs, whose shader_map.tsv and pso_manifest.tsv name the compute shaders and the
#   task / mesh pipelines and layout bases, and whose depth_mode key the depth mode, unless --pairs / --shader-map / --manifest / --depth say; --no-compute: no compute pipelines;
#   --no-mesh: no task / mesh pipelines; --no-layout: no layout bases (the R rows); --jobs: metal-tt runs at a time for the compute, task / mesh and layout groups;
#   --gpu: architectures, with or without the applegpu_ prefix (default g19p); --depth: the game's NVN depth mode (gl = near -w, NVN's default; zero = near 0, which the game sets
#   with nvnDeviceSetDepthMode: the host knows it only at run time, so the profile says it; a wrong one costs the device its own prebuild, as without the archive);
#   --os-min: the archives' system (default: for iOS the app's deployment target, deploymentTarget in dm/ios/project.yml (27.3), or the SDK's major version without it; for macOS
#   the major version this Mac runs, since the Mac app is built for the Mac that builds it).
#   A device opens only an archive of its own major version (macOS 27.2 refused archives made for 26.0 and 26.6 and opened those for 27.0 and 27.2), and builds the bases itself
#   otherwise: the SDK's version on a Mac whose system is older than its Xcode's SDK (macOS 26.6 with Xcode 27.1) left that Mac without them (GitHub issue #673)
import argparse, concurrent.futures, filecmp, hashlib, json, os, re, shutil, struct, subprocess, sys, time
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romfs, shader_lib   # the libraries may be one file (shader_lib.py), read in place; metal-tt alone needs files of its own (real_libraries)
import dmsh_abi as abi

# The function constants the host's prebuild sets in a base's functions (nvn_mtl.m pre_fn), by name: (index, bool value). A pair whose functions declare another constant is left to the
# device: the host leaves it at its default, which metal-tt can do too, but no other constant was tried there, and one function metal-tt fails fails its whole group
HOST_CONSTANTS = {'dm_border_off': (abi.BORDER_FC, True)}

BATCH = 1000   # bases per metal-tt run: Odyssey's largest compiler lifetime footprint at this size was 2.065 GiB on an 8 GB M2
COMPUTE_BATCH = 16   # compute pipelines per metal-tt run, JOBS runs at a time: one metal-tt keeps about 2-3 cores busy: Star Fox's 233 took 268 s in 16 groups against 453 s in one run (M5 Pro, background priority, a loaded Mac)
JOBS = max(1, (os.cpu_count() or 2) // 2)
COLOUR = ('pixel_format', 'write_mask', 'blending_state', 'alpha_blend_operation', 'rgb_blend_operation', 'destination_alpha_blend_factor', 'destination_rgb_blend_factor',
          'source_alpha_blend_factor', 'source_rgb_blend_factor')
MESH_BATCH = 16   # task / mesh pipelines per metal-tt run, --jobs runs at a time, as the compute groups; a group metal-tt refuses costs only its own pipelines
LAYOUT_BATCH = 64   # layout bases (the R rows') per metal-tt run, --jobs runs at a time; a group metal-tt refuses costs only its own bases, as a task / mesh group

# The colour formats a render target can have, MTLPixelFormat's value → the script's name (metal4-pipelines-script(5), PIXEL FORMAT: the enumerator less its MTLPixelFormat prefix).
# The key stores the value (pso_key.cfmt); a value not here leaves its row to the device
PIXEL_FORMATS = {
    1: 'A8Unorm', 10: 'R8Unorm', 11: 'R8Unorm_sRGB', 12: 'R8Snorm', 13: 'R8Uint', 14: 'R8Sint', 20: 'R16Unorm', 22: 'R16Snorm', 23: 'R16Uint', 24: 'R16Sint', 25: 'R16Float',
    30: 'RG8Unorm', 31: 'RG8Unorm_sRGB', 32: 'RG8Snorm', 33: 'RG8Uint', 34: 'RG8Sint', 40: 'B5G6R5Unorm', 41: 'A1BGR5Unorm', 42: 'ABGR4Unorm', 43: 'BGR5A1Unorm',
    53: 'R32Uint', 54: 'R32Sint', 55: 'R32Float', 60: 'RG16Unorm', 62: 'RG16Snorm', 63: 'RG16Uint', 64: 'RG16Sint', 65: 'RG16Float',
    70: 'RGBA8Unorm', 71: 'RGBA8Unorm_sRGB', 72: 'RGBA8Snorm', 73: 'RGBA8Uint', 74: 'RGBA8Sint', 80: 'BGRA8Unorm', 81: 'BGRA8Unorm_sRGB',
    90: 'RGB10A2Unorm', 91: 'RGB10A2Uint', 92: 'RG11B10Float', 93: 'RGB9E5Float', 94: 'BGR10A2Unorm', 103: 'RG32Uint', 104: 'RG32Sint', 105: 'RG32Float',
    110: 'RGBA16Unorm', 112: 'RGBA16Snorm', 113: 'RGBA16Uint', 114: 'RGBA16Sint', 115: 'RGBA16Float', 123: 'RGBA32Uint', 124: 'RGBA32Sint', 125: 'RGBA32Float',
    552: 'BGRA10_XR', 553: 'BGRA10_XR_sRGB', 554: 'BGR10_XR', 555: 'BGR10_XR_sRGB'}
UINT_FORMATS = {13, 23, 53, 33, 63, 73, 91, 113, 123}   # mtl_fmt_uint in nvn_mtl.m
SINT_FORMATS = {14, 24, 54, 34, 64, 74, 114, 124}   # with UINT_FORMATS, pf_int_kind's integer formats: never blended
# NVN's blend functions (NVNblendFunc) → MTLBlendFactor, as bfac maps them (anything else: One); its equations (NVNblendEquation) → MTLBlendOperation, as bop does (anything else: Add)
BLEND_FACTORS = {1: 'Zero', 2: 'One', 3: 'SourceColor', 4: 'OneMinusSourceColor', 5: 'SourceAlpha', 6: 'OneMinusSourceAlpha', 7: 'DestinationAlpha', 8: 'OneMinusDestinationAlpha',
                 9: 'DestinationColor', 10: 'OneMinusDestinationColor', 11: 'SourceAlphaSaturated', 0x10: 'Source1Color', 0x11: 'OneMinusSource1Color', 0x12: 'Source1Alpha',
                 0x13: 'OneMinusSource1Alpha', 0x61: 'BlendColor', 0x62: 'OneMinusBlendColor', 0x63: 'BlendAlpha', 0x64: 'OneMinusBlendAlpha'}
BLEND_OPS = {2: 'Subtract', 3: 'ReverseSubtract', 4: 'Min', 5: 'Max'}
B_ZERO, B_ONE, B_SA, B_ISA, B_DA, B_IDA = 1, 2, 5, 6, 7, 8
B_SRC1 = {0x10: B_ZERO, 0x12: B_ZERO, 0x11: B_ONE, 0x13: B_ONE}   # blend_zero_src1: an unwritten second source counts as zero
# adv_blend: the Porter-Duff advanced modes (NVNblendAdvancedMode) with their fixed-function factors, {mode: (colour source, colour destination, alpha source, alpha destination)}
ADV_BLEND = {5: (B_ZERO, B_ZERO, B_ZERO, B_ZERO), 6: (B_ONE, B_ZERO, B_ONE, B_ZERO), 7: (B_ZERO, B_ONE, B_ZERO, B_ONE), 8: (B_ONE, B_ISA, B_ONE, B_ISA), 9: (B_IDA, B_ONE, B_IDA, B_ONE),
             10: (B_DA, B_ZERO, B_DA, B_ZERO), 11: (B_ZERO, B_SA, B_ZERO, B_SA), 12: (B_IDA, B_ZERO, B_IDA, B_ZERO), 13: (B_ZERO, B_ISA, B_ZERO, B_ISA),
             14: (B_DA, B_ISA, B_ZERO, B_ONE), 15: (B_IDA, B_SA, B_ONE, B_ZERO), 16: (B_IDA, B_ISA, B_IDA, B_ISA), 17: (B_ONE,) * 4, 18: (B_ONE,) * 4, 19: (B_ONE,) * 4}
# pso_skey (dm/gfx/nvn/nvn_pso_skey.h) as the host writes it, little-endian: vs[24], fs[24], vs_stage, fs_stage, merged, fz, the fz description (34 bytes), padding to 88, then pso_key:
# two pointers, cfmt[8], dfmt, sfmt, samples, blend_en, chmask, a2c, blend_st[8] (8 bytes each), attr[16], stream[16] (8 bytes each), lmap[8], a pointer, atest, logic, attr_hi[16],
# border, border_spare. Rows from before border, before attr_hi, and also before atest / logic, are shorter and read with those fields zero, as pso_skey_parse reads them (LENGTHS)
from pso_skey_layout import SKEY, KEY, LENGTHS   # noqa: E402 (beside this file, as dmsh_abi)
D16, D32, S8, D32S8, X32S8 = 250, 252, 253, 260, 261   # nvn_pso_ds.h


# The host's empty fragment (nvn_mtl.m nop_fragment): its library's name here (no game library has it: theirs are <key>_b / <key>_bp) and its function. HOST_LIBS: the host libraries
# a build compiled (host_libraries), by name; every other library is <name>.metallib in the game's library folder
NOP_LIB, NOP_ENTRY = 'host_nop_frag', 'dm_nop'
HOST_MSL = {NOP_LIB: 'nop_frag.metal'}
HOST_MSL_STD = '-std=metal4.1'   # host_msl.py's STD: the host compiles its own shaders as MSL 4.1
HOST_LIBS = {}
DM = Path(__file__).resolve().parents[2]


def lib_path(lib_dir, lib):
    """Where a base's library is: a host library compiled for this build (HOST_LIBS), else <lib>.metallib in lib_dir"""
    return HOST_LIBS[lib] if lib in HOST_LIBS else os.path.join(lib_dir, f'{lib}.metallib')


def host_msl_min(platform):
    """The minimum OS the host compiles its own shaders for (host_msl.py --min): iOS dm/host/Makefile's MSL_MIN_iphoneos, macOS MACOS_MIN of dm/mac/min_os.mk (the Makefile's MSL_MIN_macosx)"""
    path, var = (DM / 'host' / 'Makefile', 'MSL_MIN_iphoneos') if platform == 'ios' else (DM / 'mac' / 'min_os.mk', 'MACOS_MIN')
    try: m = re.search(rf'^{var}\s*:?=\s*(\S+)', path.read_text(encoding='utf-8'), re.M)
    except OSError: m = None
    if not m: sys.exit(f'[RED] pso_offline: no {var} in {path}: the host\'s minimum OS for its shaders')
    return m.group(1)


def host_libraries(bases, platform, work, pipes=()):
    """Compiles the host libraries the bases and pipelines name (the empty fragment of depth-only pairs and layout bases) into work/host, as host_msl.py compiles them for the host, and
    notes them in HOST_LIBS. Each compile gives the file another identifier, so the archive's key takes their function hashes (library_digest), which the same source, compiler and
    minimum OS keep"""
    HOST_LIBS.clear()
    names = sorted({fl for _, _, fl, _ in bases if fl in HOST_MSL} | {lib for p in pipes for lib in pipe_libs(p) if lib in HOST_MSL})
    if not names: return
    folder = Path(work) / 'host'; folder.mkdir(parents=True, exist_ok=True)
    flag = f'-m{"ios" if platform == "ios" else "macosx"}-version-min={host_msl_min(platform)}'   # and host_msl.py's language, HOST_MSL_STD
    for name in names:
        src, out = DM / 'gfx' / 'msl' / HOST_MSL[name], folder / f'{name}.metallib'
        cmd = ['xcrun', '-sdk', sdk(platform), 'metal', flag, HOST_MSL_STD, '-o', str(out), str(src)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode or not out.is_file(): sys.exit(f'[RED] pso_offline: the host library {src} does not compile ({" ".join(cmd)}): {(r.stderr or r.stdout).strip()}')
        HOST_LIBS[name] = str(out)


class MeshPipe(NamedTuple):
    """A native task / mesh pipeline as mtk_desc4 describes it: (library, entry) of the object, mesh and fragment functions, the threads and payload, the raster state and the
    eight colour attachments, each its values of COLOUR in that order"""
    obj: tuple
    mesh: tuple
    frag: tuple
    obj_threads: int
    mesh_threads: int
    payload: int
    samples: int
    a2c: bool
    colours: tuple


def arch_name(a):   # 'g18p' → 'applegpu_g18p'
    a = a.strip()
    return a if a.startswith('applegpu_') else f'applegpu_{a}'


def pair_text(paths):
    """The pair lists as the host reads them: their bytes one after the other (shader_pairs.tsv, then pso_pairs.tsv when it exists)"""
    return b''.join(Path(p).read_bytes() for p in paths if p and Path(p).is_file())


def read_pairs(text):
    """(vertex key, pixel key) per line, in order, without empty lines, comments and repeated lines (pso_prebuild's reading)"""
    seen, out = set(), []
    for line in text.decode('utf-8').split('\n'):
        if not line or line.startswith('#') or line in seen: continue
        seen.add(line); c = line.split('\t')
        if len(c) >= 2: out.append((c[0], c[1]))
    return out


def read_computes(maps, manifests):
    """The compute shaders by the library the host loads each from (<key>_b, as shader_load names it): the prewarm lists' C rows in their order, then the shader maps' rows of stage
    compute (column 3; the key is column 4, as shmap_load reads it), each once. Missing files are skipped"""
    out = {}
    for path, kind in [*((p, 'C') for p in manifests or ()), *((p, 'map') for p in maps or ())]:
        if not path or not Path(path).is_file(): continue
        for line in Path(path).read_text(encoding='utf-8').split('\n'):
            c = line.rstrip('\r').split('\t')
            if kind == 'C' and len(c) >= 2 and c[0] == 'C' and c[1]: out.setdefault(c[1], None)
            elif kind == 'map' and len(c) > 3 and c[2] == 'compute' and c[3]: out.setdefault(c[3] + '_b', None)
    return list(out)


def stamp(chain, zero, text):
    """The host's prebuild stamp (pso_prebuild in nvn_mtl.m): chain version, depth mode, and the pair lists' length in bytes and SHA-256 (first 16 hex digits)"""
    return f'chain\t{chain}\ndepth\t{"near=0" if zero else "near=-w"}\npairs\t{len(text)}\t{hashlib.sha256(text).hexdigest()[:16]}\n'


def functions(path, hashes=False):
    """{entry name: declares function constants} of a .metallib (constants). hashes: {entry name: its HASH tag} instead, what an archive finds the function by. Raises ValueError on a
    file it cannot read"""
    return constants(path, hashes=True) if hashes else {k: bool(v) for k, v in constants(path).items()}


def _constant_names(cnst):
    """The names in a CNST tag: a 16-bit count, then per constant its name (NUL-terminated), a type byte, a 16-bit index and a byte"""
    n, p, out = struct.unpack_from('<H', cnst, 0)[0], 2, []
    for _ in range(n):
        end = cnst.index(b'\0', p); out.append(cnst[p:end].decode()); p = end + 1 + 4
    if p > len(cnst): raise ValueError('a truncated CNST tag')
    return tuple(out)


def constants(path, hashes=False):
    """{entry name: the names of the function constants it declares, a tuple, empty for none} of a .metallib, from its header: the function list (NAME tags) and each function's public
    metadata (a CNST tag lists its constants). hashes: {entry name: its HASH tag} instead. Raises ValueError on a file it cannot read"""
    with romfs.open(path, 'rb') as f: b = f.read(1 << 20)
    if b[:4] != b'MTLB' or len(b) < 0x58: raise ValueError(f'{path}: not a Metal library')
    fo, _, po, ps = struct.unpack_from('<QQQQ', b, 0x18)
    def tags(p, end):
        t = {}
        while p + 4 <= end:
            tag = b[p:p + 4]; p += 4
            if tag == b'ENDT': return t
            n = struct.unpack_from('<H', b, p)[0]; p += 2; t[tag] = b[p:p + n]; p += n
        raise ValueError(f'{path}: unterminated tag list')
    try:
        count = struct.unpack_from('<I', b, fo)[0]; p = fo + 4; names, hs = [], []
        for _ in range(count):   # each entry: its size (counting the size field), then tags
            size = struct.unpack_from('<I', b, p)[0]; t = tags(p + 4, p + size); names.append(t[b'NAME'].rstrip(b'\0').decode()); hs.append(t.get(b'HASH', b'').hex()); p += size
        if hashes: return dict(zip(names, hs))
        consts, p = [], po
        for _ in range(count):   # each entry: its size (not counting the size field), then tags
            size = struct.unpack_from('<I', b, p)[0]; t = tags(p + 4, p + 4 + size); consts.append(_constant_names(t[b'CNST']) if b'CNST' in t else ()); p += 4 + size
        if p != po + ps: raise ValueError(f'{path}: public metadata does not match the function list')
    except (struct.error, KeyError, UnicodeDecodeError) as e: raise ValueError(f'{path}: unreadable function list ({e})') from e
    return dict(zip(names, consts))


def plan(lib_dir, chain, pairs, zero):
    """The bases the archive holds: [(vertex library, vertex entry, pixel library, pixel entry)], the pairs left to the device (function constants), and counts of the pairs left out"""
    lib_dir = romfs.Path(lib_dir); js, fns = {}, {}
    def refl(key):
        if key not in js:
            try: js[key] = json.loads((lib_dir / f'{key}_b.json').read_bytes())
            except (OSError, ValueError): js[key] = None
        return js[key]
    def fn(lib):
        if lib == NOP_LIB: return {NOP_ENTRY: ()}   # the host's, compiled with the build (host_libraries); it declares no constants
        if lib not in fns:
            try: fns[lib] = constants(lib_dir / f'{lib}.metallib')
            except (OSError, ValueError): fns[lib] = None
        return fns[lib]
    bases, rest, seen, left = [], [], set(), dict.fromkeys(('reflection', 'mesh', 'stage inputs', 'library', 'layer', 'primitive ID', 'entry'), 0)
    for vk, fk in pairs:
        depth = not fk   # a depth-only pair: the host's empty fragment
        vj, fj = refl(vk), {'chain': chain, 'entry': NOP_ENTRY} if depth else refl(fk)
        if not vj or not fj or vj.get('chain') != chain or fj.get('chain') != chain: left['reflection'] += 1; continue
        if vj.get('mesh_stage'): left['mesh'] += 1; continue   # a mesh shader's pair (shader_split.py var_pairs, for its padding): its pipelines are mesh pipelines, built at the draw (nvn_geometry.inc mtk_pso)
        ventry = vj['entry_z'] if zero and vj.get('entry_z') else vj.get('entry'); fentry = fj.get('entry') or 'main0'
        pull = isinstance(vj.get('pull'), dict)
        if not pull and vj.get('vertex_inputs'): left['stage inputs'] += 1; continue
        if vj.get('layer_out'): left['layer'] += 1; continue
        if (fj.get('raster') or {}).get('primitive_id'): left['primitive ID'] += 1; continue
        vl, fl = vk + ('_bp' if pull else '_b'), NOP_LIB if depth else fk + '_b'
        vf, ff = fn(vl), fn(fl)
        if vf is None or ff is None: left['library'] += 1; continue
        if ventry not in vf or fentry not in ff: left['entry'] += 1; continue
        if any(c not in HOST_CONSTANTS for c in vf[ventry] + ff[fentry]): rest.append((vk, fk)); continue   # script specializes HOST_CONSTANTS as the host does
        b = (vl, ventry, fl, fentry)
        if b not in seen: seen.add(b); bases.append(b)
    return bases, rest, left


def plan_compute(lib_dir, chain, shaders):
    """The compute pipelines the archive holds, [(library, entry)]: each of shaders (<key>_b) with its reflection's entry; and counts of
    the shaders left out as the host would not find their pipeline (reflection, library, entry point, function constants)"""
    lib_dir = romfs.Path(lib_dir); pipes, seen = [], set(); left = dict.fromkeys(('reflection', 'library', 'entry', 'constants'), 0)
    for pc in shaders:
        try: j = json.loads((lib_dir / f'{pc}.json').read_bytes())
        except (OSError, ValueError): j = None
        if not isinstance(j, dict) or j.get('chain') != chain or j.get('stage', 'cs') != 'cs': left['reflection'] += 1; continue
        entry = j.get('entry') or 'main0'
        try: fs = constants(lib_dir / f'{pc}.metallib')
        except (OSError, ValueError): left['library'] += 1; continue
        if entry not in fs: left['entry'] += 1; continue
        if any(c not in HOST_CONSTANTS for c in fs[entry]): left['constants'] += 1; continue   # script specializes HOST_CONSTANTS, as cps_new looks the pipeline up
        if (pc, entry) not in seen: seen.add((pc, entry)); pipes.append((pc, entry))
    return pipes, left


def read_meshes(manifests):
    """The native task / mesh pipelines of the prewarm lists' M rows, [(task shader key or None, pso_skey hex)], in their order, each once (the host takes a row of exactly three columns)"""
    out = {}
    for path in manifests or ():
        if not path or not Path(path).is_file(): continue
        for line in Path(path).read_bytes().decode('utf-8').split('\n'):   # bytes as they are, split on \n alone, as warm_parse: read_text would turn \r\n into \n, which the host does not
            c = line.split('\t')   # a row ending in \r keeps it in its key, which parse_mesh_key refuses as pso_mesh_skey_parse does
            if len(c) == 3 and c[0] == 'M' and c[1] and c[2]: out.setdefault((None if c[1] == '-' else c[1], c[2]), None)
    return list(out)


def parse_mesh_key(text):
    """An M row's pso_skey hex as pso_mesh_skey_parse reads it: a dict of the fields the pipeline's descriptor depends on, or None where the host refuses the row"""
    if len(text) not in LENGTHS: return None
    try: b = bytes.fromhex(text)
    except ValueError: return None
    b += bytes(SKEY - len(b))
    def cstr(raw): return raw.split(b'\0')[0].decode('ascii', 'replace')
    vs, fs, (vs_stage, fs_stage, merged, fz) = cstr(b[0:24]), cstr(b[24:48]), b[48:52]
    vptr, fptr = struct.unpack_from('<QQ', b, KEY)
    cfmt = list(struct.unpack_from('<8I', b, KEY + 16))
    dfmt, sfmt, samples, blend_en, chmask, a2c = struct.unpack_from('<6I', b, KEY + 48)
    raw = struct.unpack_from('<8Q', b, KEY + 72)
    fsfn, = struct.unpack_from('<Q', b, KEY + 336)
    atest, logic = struct.unpack_from('<2I', b, KEY + 344)
    border, = struct.unpack_from('<I', b, KEY + 416)   # 1: the draw binds a sampler with a twin, so mtk_desc4 keeps the border corrections (fn4_of_b)
    # pso_ds_pair, then the checks of pso_mesh_skey_parse (a mesh shader in the vertex place, a pixel shader or none, no merged pass, tile fragment or pointer, valid depth / stencil)
    if not dfmt and sfmt == D32S8: dfmt = D32S8
    if not sfmt and dfmt == D32S8: sfmt = D32S8
    ds_ok = (not dfmt or dfmt in (D16, D32, D32S8)) and (not sfmt or sfmt in (S8, D32S8, X32S8)) and (dfmt == sfmt if D32S8 in (dfmt, sfmt) else True)
    if not vs or vs_stage != 4 or (fs and fs_stage != 1) or merged or fz or vptr or fptr or fsfn or not ds_ok: return None
    blend = []
    for i, v in enumerate(raw):   # blend_st's bit fields (nvn_obj.h), lowest first; pso_key_norm drops them where blending is off or the target absent
        on = blend_en >> i & 1 and cfmt[i]
        blend.append({'src_rgb': v >> 3 & 0x7f, 'dst_rgb': v >> 10 & 0x7f, 'src_a': v >> 17 & 0x7f, 'dst_a': v >> 24 & 0x7f, 'eq_rgb': v >> 31 & 7, 'eq_a': v >> 34 & 7,
                      'adv': v >> 37 & 0x3f, 'adv_npm': v >> 43 & 1, 'adv_ovl': v >> 44 & 3} if on else dict.fromkeys(('src_rgb', 'dst_rgb', 'src_a', 'dst_a', 'eq_rgb', 'eq_a', 'adv', 'adv_npm', 'adv_ovl'), 0))
    for i in range(8):
        if not cfmt[i]: blend_en &= ~(1 << i); chmask &= ~(0xf << 4 * i)
    return {'vs': vs, 'fs': fs, 'cfmt': cfmt, 'samples': samples, 'blend_en': blend_en, 'chmask': chmask, 'a2c': a2c, 'blend': blend, 'atest': atest, 'logic': logic, 'border': border}


def adv_blend(b):
    """adv_blend in nvn_mtl.m: a Porter-Duff advanced mode as fixed-function factors with the ADD equation; another mode keeps the state's own functions, as the host does"""
    f = ADV_BLEND.get(b['adv']) if b['adv'] else None
    if not f or b['adv_ovl'] or (b['adv_npm'] and f[0] not in (B_ONE, B_ZERO)): return b
    return dict(b, src_rgb=B_SA if b['adv_npm'] and f[0] == B_ONE else f[0], dst_rgb=f[1], src_a=f[2], dst_a=f[3], eq_rgb=1, eq_a=1)


def write_mask(m):
    return 'All' if m == 15 else 'None' if not m else ' '.join(n for bit, n in ((1, 'Red'), (2, 'Green'), (4, 'Blue'), (8, 'Alpha')) if m & bit)


DEFAULT_COLOUR = ('Invalid', 'All', 'Disabled', 'Add', 'Add', 'Zero', 'Zero', 'One', 'One')   # pso_col4 of an absent target: MTLRenderPipelineColorAttachmentDescriptor's defaults


def fragment_entry(k, fj, funcs):
    """pso_desc's fragment entry point for a pipeline that is not merged and has no specialized fragment: the integer (entry_u, pso_all_uint), mixed (entry_m, pso_mixed_uint) or
    dual-source (entry_d, pso_reads_src1) one where the targets call for it, else the shader's entry. (entry, dual, dual_fn), or a reason the row is left out ('entry', 'constants').
    A base leaves the colour state open but not its fragment function, so a layout base (plan_layout) takes this choice as the pipeline's colour targets make it"""
    raster = fj.get('raster') if isinstance(fj.get('raster'), dict) else {}
    colors = raster.get('colors'); known = isinstance(colors, list)
    mask = sum(1 << c for c in set(colors) if isinstance(c, int) and 0 <= c < 8) if known else 0
    cfmt, entry = k['cfmt'], fj.get('entry')
    def has(name): return bool(name) and name in funcs
    written = [i for i in range(8) if cfmt[i] and (not known or mask >> i & 1)]
    all_uint = bool(written) and all(cfmt[i] in UINT_FORMATS for i in written)
    mask_m = fj.get('uint_mask_m') if isinstance(fj.get('uint_mask_m'), int) else 0
    mixed = (all((cfmt[i] in UINT_FORMATS) == bool(mask_m >> i & 1) for i in written)
             and any(cfmt[i] in UINT_FORMATS for i in written) and any(cfmt[i] not in UINT_FORMATS for i in written))
    fn = entry
    if has(fj.get('entry_u')) and all_uint: fn = fj['entry_u']
    elif has(fj.get('entry_m')) and mixed: fn = fj['entry_m']
    b0 = adv_blend(k['blend'][0])
    src1 = cfmt[0] and k['blend_en'] & 1 and any(b0[x] in B_SRC1 for x in ('src_rgb', 'dst_rgb', 'src_a', 'dst_a'))
    dual = bool(known and mask & 2 and fn == entry and src1 and not k.get('logic'))   # a logic operation takes the place of blending
    dual_fn = bool(dual and has(fj.get('entry_d')))
    if dual_fn: fn = fj['entry_d']
    if not has(fn): return 'entry'
    if funcs[fn]: return 'constants'
    return fn, dual, dual_fn


def mesh_fragment(k, fj, funcs):
    """pso_desc's fragment entry and colour attachments for a native mesh pipeline (no vertex shader, not merged, no specialized fragment): the entry point of fragment_entry,
    write masks limited to the outputs the shader writes and maps, blending only on written float targets, an unwritten second source as zero.
    (entry, colours), or a reason the row is left out"""
    raster = fj.get('raster') if isinstance(fj.get('raster'), dict) else {}
    colors = raster.get('colors'); known = isinstance(colors, list)
    mask = sum(1 << c for c in set(colors) if isinstance(c, int) and 0 <= c < 8) if known else 0
    omap = raster.get('omap') if isinstance(raster.get('omap'), int) and not isinstance(raster.get('omap'), bool) else None
    cfmt = k['cfmt']
    chosen = fragment_entry(k, fj, funcs)
    if isinstance(chosen, str): return chosen
    fn, dual, dual_fn = chosen
    colours = []
    for i in range(8):
        f = cfmt[i]
        if not f: colours.append(DEFAULT_COLOUR); continue
        if f not in PIXEL_FORMATS: return 'format'
        m = k['chmask'] >> 4 * i & 0xf
        unwritten = known and (not mask >> i & 1 or (dual_fn and i == 1))
        if unwritten: m = 0
        elif omap is not None: m &= omap >> 4 * i & 0xf
        if k['blend_en'] >> i & 1 and not unwritten and f not in UINT_FORMATS and f not in SINT_FORMATS:
            bl = adv_blend(k['blend'][i])
            if known and (not mask & 2 or (dual and not dual_fn)): bl = dict(bl, **{x: B_SRC1.get(bl[x], bl[x]) for x in ('src_rgb', 'dst_rgb', 'src_a', 'dst_a')})
            fac = {x: BLEND_FACTORS.get(bl[x], 'One') for x in ('dst_a', 'dst_rgb', 'src_a', 'src_rgb')}
            colours.append((PIXEL_FORMATS[f], write_mask(m), 'Enabled', BLEND_OPS.get(bl['eq_a'], 'Add'), BLEND_OPS.get(bl['eq_rgb'], 'Add'),
                            fac['dst_a'], fac['dst_rgb'], fac['src_a'], fac['src_rgb']))
        else: colours.append((PIXEL_FORMATS[f], write_mask(m), *DEFAULT_COLOUR[2:]))
    return fn, tuple(colours)


def plan_mesh(lib_dir, chain, rows, zero):
    """The native task / mesh pipelines the archive holds, [MeshPipe], from the M rows (read_meshes) as the host's prewarm builds them (mtk_build), and counts of the rows left out"""
    lib_dir = romfs.Path(lib_dir); js, fns = {}, {}
    def refl(key):
        if key not in js:
            try: js[key] = json.loads((lib_dir / f'{key}.json').read_bytes())
            except (OSError, ValueError): js[key] = None
            if not isinstance(js[key], dict) or js[key].get('chain') != chain: js[key] = None
        return js[key]
    def fn(lib):
        if lib not in fns:
            try: fns[lib] = constants(lib_dir / f'{lib}.metallib')
            except (OSError, ValueError): fns[lib] = None
        return fns[lib]
    # A function's constants the script cannot specialize as the host does: any but HOST_CONSTANTS, or any at all where the host takes the function unspecialized (no border
    # variant: the mesh shader's own object entry, which mtk_desc4 takes by fn4_of; every function of a row that keeps the border corrections)
    def other(cs, plain=False): return any(plain or c not in HOST_CONSTANTS for c in cs)
    pipes, seen = [], set()
    left: dict[str, int] = dict.fromkeys(('key', 'reflection', 'stages', 'library', 'entry', 'constants', 'no pixel shader', 'side library', 'format'), 0)
    for task, text in rows:
        k = parse_mesh_key(text)
        if not k: left['key'] += 1; continue
        if k['atest'] or k['logic']: left['side library'] += 1; continue
        if not k['fs']: left['no pixel shader'] += 1; continue
        mj, fj, tj = refl(k['vs']), refl(k['fs']), refl(task) if task else None
        if not mj or not fj or (task and not tj): left['reflection'] += 1; continue
        ms, ts = mj.get('mesh_stage'), tj.get('mesh_stage') if tj else None
        if not isinstance(ms, dict) or ms.get('kind') == 'ts' or (task and (not isinstance(ts, dict) or ts.get('kind') != 'ts')) or bool(task) != bool(ms.get('task')):   # as warm_task takes a row
            left['stages'] += 1; continue
        ments = [k['vs'], mj['entry_z'] if zero and mj.get('entry_z') else mj.get('entry')]
        obj = [task, (tj or {}).get('entry')] if task else [k['vs'], mj.get('entry_object')]
        mf, of, ff = fn(k['vs']), fn(obj[0]), fn(k['fs'])
        if mf is None or of is None or ff is None: left['library'] += 1; continue
        if ments[1] not in mf or obj[1] not in of: left['entry'] += 1; continue
        plain = bool(k['border'])
        if other(mf[ments[1]], plain) or other(of[obj[1]], plain or not task): left['constants'] += 1; continue
        if fj.get('entry') in ff and other(ff[fj['entry']], plain): left['constants'] += 1; continue   # shader_load specializes every entry point of such a shader
        frag = mesh_fragment(k, fj, {e: other(cs, plain) for e, cs in ff.items()})
        if isinstance(frag, str): left[frag] += 1; continue
        u16 = lambda d, x: int(d.get(x) or 0) & 0xffff   # NvShader keeps the threads and payload as uint16_t
        p = MeshPipe(tuple(obj), tuple(ments), (k['fs'], frag[0]), u16(ts, 'threads') if task else 1, u16(ms, 'threads'), (u16(ts, 'payload') + 15) & ~15 if task else 16,
                     k['samples'] or 1, bool(k['a2c']), frag[1])
        if p not in seen: seen.add(p); pipes.append(p)
    return pipes, left


class LayoutBase(NamedTuple):
    """The base of a pipeline with a vertex layout as pso_desc / pso_desc4 describe it (nvn_mtl.m): (library, entry) of the vertex and fragment functions, the vertex descriptor
    (attributes: ((index, format, offset, buffer index), ...); layouts: ((buffer index, stride, step function, step rate), ...), each sorted), the sample count and alpha to coverage;
    every colour attachment unspecialized"""
    vert: tuple
    frag: tuple
    attributes: tuple
    layouts: tuple
    samples: int
    a2c: bool


# vfmt in nvn_mtl.m: NVN's vertex formats (NVNformat) → MTLVertexFormat, by the script's names (metal4-pipelines-script(5), ATTRIBUTE FORMAT: the enumerator less its prefix);
# the *_UI2F / *_I2F formats (vconv_i2f) are read through the integer format of the same layout (vfmt_name)
VFMT = {0x01: 'UCharNormalized', 0x02: 'CharNormalized', 0x03: 'UChar', 0x04: 'Char', 0x05: 'Half', 0x06: 'UShortNormalized', 0x07: 'ShortNormalized', 0x08: 'UShort', 0x09: 'Short',
        0x0A: 'Float', 0x0B: 'UInt', 0x0C: 'Int', 0x0D: 'UChar2Normalized', 0x0E: 'Char2Normalized', 0x0F: 'UChar2', 0x10: 'Char2', 0x11: 'Half2', 0x12: 'UShort2Normalized',
        0x13: 'Short2Normalized', 0x14: 'UShort2', 0x15: 'Short2', 0x16: 'Float2', 0x17: 'UInt2', 0x18: 'Int2', 0x19: 'UChar3Normalized', 0x1A: 'Char3Normalized', 0x1B: 'UChar3',
        0x1C: 'Char3', 0x1D: 'Half3', 0x1E: 'UShort3Normalized', 0x1F: 'Short3Normalized', 0x20: 'UShort3', 0x21: 'Short3', 0x22: 'Float3', 0x23: 'UInt3', 0x24: 'Int3',
        0x25: 'UChar4Normalized', 0x26: 'Char4Normalized', 0x27: 'UChar4', 0x28: 'Char4', 0x29: 'Half4', 0x2A: 'UShort4Normalized', 0x2B: 'Short4Normalized', 0x2C: 'UShort4',
        0x2D: 'Short4', 0x2E: 'Float4', 0x2F: 'UInt4', 0x30: 'Int4', 0x3D: 'UInt1010102Normalized', 0x69: 'Int1010102Normalized', 0x3F: 'FloatRG11B10', 0x9A: 'UChar4Normalized_BGRA'}
VF_U = ('UChar', 'UChar2', 'UChar3', 'UChar4', 'UShort', 'UShort2', 'UShort3', 'UShort4', 'UInt', 'UInt2', 'UInt3', 'UInt4')   # vfmt_for_ct's U / I / F
VF_I = ('Char', 'Char2', 'Char3', 'Char4', 'Short', 'Short2', 'Short3', 'Short4', 'Int', 'Int2', 'Int3', 'Int4')
VF_F = ('Float', 'Float2', 'Float3', 'Float4')
VF_P = {'UCharNormalized': 0, 'CharNormalized': 0, 'UChar2Normalized': 1, 'Char2Normalized': 1, 'UChar3Normalized': 2, 'Char3Normalized': 2, 'UChar4Normalized': 3,   # vfmt_for_ct's P
        'Char4Normalized': 3, 'UChar4Normalized_BGRA': 3, 'UShortNormalized': 4, 'ShortNormalized': 4, 'Half': 4, 'UShort2Normalized': 5, 'Short2Normalized': 5, 'Half2': 5,
        'UShort3Normalized': 6, 'Short3Normalized': 6, 'Half3': 6, 'UShort4Normalized': 7, 'Short4Normalized': 7, 'Half4': 7, 'UInt1010102Normalized': 8,
        'Int1010102Normalized': 8, 'FloatRG11B10': 8}
# The formats the script can name (metal4-pipelines-script(5), ATTRIBUTE FORMAT): FloatRG11B10 is not among them, so a row whose layout has it is left to the device
SCRIPT_VFORMATS = {*VF_U, *VF_I, *VF_F, *(n for n in VF_P if n != 'FloatRG11B10'), 'Invalid'}
CT_FLOAT, CT_UINT, CT_INT = 0, 1, 2   # nvn_refl.h NVN_CT_*


def vformat_size(name):   # bytes of one element of a vertex format (the script's name)
    if name in ('UInt1010102Normalized', 'Int1010102Normalized', 'UChar4Normalized_BGRA', 'FloatRG11B10'): return 4
    base = name.replace('Normalized', '')
    n = int(base[-1]) if base[-1].isdigit() else 1
    return n * (1 if 'Char' in base else 2 if 'Short' in base or 'Half' in base else 4)
VCONV_SLOT0, VCONV_MAX, ZERO_SLOT = 1, 12, 30   # nvn_mtl.m: the converted attributes' buffer slots, the zero buffer's


def vconv_ncomp(f):   # nvn_mtl.m vconv_ncomp: components of a float-type format that an integer input takes converted; 0 = not one
    return (1 if f in (0x01, 0x02, 0x05, 0x06, 0x07, 0x0A) else 2 if f in (0x0D, 0x0E, 0x11, 0x12, 0x13, 0x16) else 3 if f in (0x19, 0x1A, 0x1D, 0x1E, 0x1F, 0x22, 0x3F)
            else 4 if f in (0x25, 0x26, 0x29, 0x2A, 0x2B, 0x3D, 0x69, 0x9A) else 0)


def vconv_int(f):   # nvn_mtl.m vconv_int: (components, bits, signed) of an 8 / 16-bit integer format, None for any other
    t = (0x03, 0x04, 0x08, 0x09, 0x0F, 0x10, 0x14, 0x15, 0x1B, 0x1C, 0x20, 0x21, 0x27, 0x28, 0x2C, 0x2D)
    if f not in t: return None
    i = t.index(f); return i // 4 + 1, 16 if i & 2 else 8, i & 1


def vconv_i2f(f):   # nvn_mtl.m vconv_i2f: (components, bits, signed) of an integer-read-as-float format (0x51-0x68), None for any other
    if f < 0x51 or f > 0x68: return None
    i = (f - 0x51) >> 1; return i // 3 + 1, 8 << (i % 3), (f - 0x51) & 1


def vfmt_name(f):   # nvn_mtl.m vfmt: the format's name, None for MTLVertexFormatInvalid
    if f in VFMT: return VFMT[f]
    c = vconv_i2f(f)
    if not c: return None
    n, bits, sgn = c
    return (VF_I if sgn else VF_U)[(0 if bits == 8 else 4 if bits == 16 else 8) + n - 1]


def vfmt_for_ct(f, ct):   # nvn_mtl.m vfmt_for_ct: the format corrected by the input's component type
    iu = VF_U.index(f) if f in VF_U else -1; ii = VF_I.index(f) if f in VF_I else -1; iff = VF_F.index(f) if f in VF_F else -1
    if ct == CT_UINT:
        if iu >= 0: return f
        if ii >= 0: return VF_U[ii]
        if iff >= 0: return VF_U[8 + iff]
    elif ct == CT_INT:
        if ii >= 0: return f
        if iu >= 0: return VF_I[iu]
        if iff >= 0: return VF_I[8 + iff]
    else:
        if iu < 0 and ii < 0: return f
        if 8 <= iu < 12 or 8 <= ii < 12: return VF_F[(iu if iu >= 8 else ii) - 8]
    if ct in (CT_UINT, CT_INT) and f in VF_P: return (VF_U if ct == CT_UINT else VF_I)[VF_P[f]]
    return f


def parse_render_key(text):
    """An R row's pso_skey hex as pso_skey_parse reads it (pso_key_norm applied): the fields pso_desc's descriptor of a base depends on, or None where the host refuses the row"""
    if len(text) not in LENGTHS: return None
    try: b = bytes.fromhex(text)
    except ValueError: return None
    b += bytes(SKEY - len(b))
    def cstr(raw): return raw.split(b'\0')[0].decode('ascii', 'replace')
    vs, fs, (vs_stage, fs_stage, merged, fz) = cstr(b[0:24]), cstr(b[24:48]), b[48:52]
    cfmt = list(struct.unpack_from('<8I', b, KEY + 16))
    border, = struct.unpack_from('<I', b, KEY + 416)   # 1: the draw binds a sampler with a twin, so pso_build keeps the border corrections (off = !border)
    _, _, samples, blend_en, chmask, a2c = struct.unpack_from('<6I', b, KEY + 48)
    raw = struct.unpack_from('<8Q', b, KEY + 72)
    attr = [struct.unpack_from('<I', b, KEY + 136 + 4 * i)[0] for i in range(16)] + [struct.unpack_from('<I', b, KEY + 352 + 4 * i)[0] for i in range(16)]
    stream = [struct.unpack_from('<2I', b, KEY + 200 + 8 * i) for i in range(16)]
    atest, logic = struct.unpack_from('<2I', b, KEY + 344)
    if not merged:   # pso_key_norm: an absent target has no blending and no channels
        for i in range(8):
            if not cfmt[i]: blend_en &= ~(1 << i); chmask &= ~(0xf << 4 * i)
    blend = []
    for i, v in enumerate(raw):
        on = blend_en >> i & 1
        blend.append({'src_rgb': v >> 3 & 0x7f, 'dst_rgb': v >> 10 & 0x7f, 'src_a': v >> 17 & 0x7f, 'dst_a': v >> 24 & 0x7f, 'eq_rgb': v >> 31 & 7, 'eq_a': v >> 34 & 7,
                      'adv': v >> 37 & 0x3f, 'adv_npm': v >> 43 & 1, 'adv_ovl': v >> 44 & 3} if on else dict.fromkeys(('src_rgb', 'dst_rgb', 'src_a', 'dst_a', 'eq_rgb', 'eq_a', 'adv', 'adv_npm', 'adv_ovl'), 0))
    return {'vs': vs, 'fs': fs, 'vs_stage': vs_stage, 'fs_stage': fs_stage, 'merged': merged, 'fz': fz, 'cfmt': cfmt, 'samples': samples, 'blend_en': blend_en, 'chmask': chmask,
            'a2c': a2c, 'blend': blend, 'attr': [(a & 0xff, a >> 8 & 0x7ffff, a >> 27 & 0x1f) for a in attr], 'stream': stream, 'atest': atest, 'logic': logic,
            'border': border}


def read_layouts(manifests):
    """The R rows of the prewarm lists (pso_manifest.tsv), [pso_skey hex], in their order, each once (the host's warm list takes a row of two columns or more)"""
    out = {}
    for path in manifests or ():
        if not path or not Path(path).is_file(): continue
        for line in Path(path).read_bytes().decode('utf-8').split('\n'):   # as read_meshes: a two-column row ending in \r is refused by parse_render_key, as pso_skey_parse refuses it
            c = line.split('\t')
            if len(c) >= 2 and c[0] == 'R' and c[1]: out.setdefault(c[1], None)
    return list(out)


def vertex_inputs(vj):
    """The reflection's vertex inputs as nvn_refl.m reads them: [(location = NVN attribute = Metal attribute, component type, {component type: shadow attribute index})], and whether
    the shader has shadow inputs (has_vin); None for a reflection the host refuses"""
    ins = []
    for v in vj.get('vertex_inputs') or ():
        loc, t = int(v.get('location', -1)), str(v.get('msl_type', ''))
        if not 0 <= loc < 32: return None
        ins.append((loc, CT_UINT if t.startswith('uint') else CT_INT if t.startswith('int') else CT_FLOAT, {}))
    vin = vj.get('vin') if isinstance(vj.get('vin'), dict) else {}
    used = False
    for e in vin.get('shadow') or ():
        hit = [x for x in ins if x[0] == int(e.get('location', -1))]
        if not hit or hit[0][1] == CT_FLOAT: return None
        for name, ct in (('float', CT_FLOAT), ('sint', CT_INT), ('uint', CT_UINT)):
            if name in e: hit[0][2][ct] = int(e[name]); used = True
    return ins, used


def vin_ct(v, f, on):   # nvn_mtl.m vin_ct: the class input v takes its attribute as
    _, ct, sh = v
    if not on or ct == CT_FLOAT: return ct
    c = vconv_int(f)
    want = CT_FLOAT if vconv_ncomp(f) else (CT_INT if c[2] else CT_UINT) if c else ct
    return want if want != ct and want in sh else ct


def vconv_wanted(v, f, on):   # nvn_mtl.m vconv_wanted: input v of this pipeline takes the CPU's converted data
    _, ct, _ = v
    if vconv_i2f(f): return True
    c = vconv_int(f)
    if ct == CT_FLOAT: return bool(c)
    if vin_ct(v, f, on) != ct: return False
    return bool(vconv_ncomp(f) or (c and c[2] != (ct == CT_INT)))


def vertex_descriptor(k, ins, on):
    """pso_desc's MTLVertexDescriptor for key k (parse_render_key) and the shader's inputs (vertex_inputs), on: the shadow inputs are used (vin_on). (attributes, layouts) as
    LayoutBase holds them, or the reason the row is left out: 'format' (a format the script cannot name), 'stride' (an attribute metal-tt would refuse)"""
    attrs, layouts, nconv = {}, {}, 0
    def zero(i, ct): attrs[i] = ('UInt4' if ct == CT_UINT else 'Int4' if ct == CT_INT else 'Float4', 0, ZERO_SLOT); layouts[ZERO_SLOT] = (16, 'Constant', 0)
    def step(st):
        stride, div = k['stream'][st] if st < 16 else (0, 0)
        return ('Constant', 0) if stride == 0 else ('PerInstance', div) if div else ('PerVertex', 1)
    for v in ins:
        loc, vct, sh = v
        fmt, off, st = k['attr'][loc] if loc < 32 else (0, 0, 0)
        vf = vfmt_name(fmt) if loc < 32 else None
        ct = vin_ct(v, fmt, 1) if on else vct
        at = loc if ct == vct else sh[ct]
        if on:
            if at != loc: zero(loc, vct)
            for q in (CT_FLOAT, CT_UINT, CT_INT):
                if q in sh and sh[q] != at: zero(sh[q], q)
        if vf is None: zero(at, ct); continue
        if vconv_wanted(v, fmt, on) and nconv < VCONV_MAX:
            slot = VCONV_SLOT0 + nconv; nconv += 1
            attrs[loc] = ('UInt4' if vct == CT_UINT else 'Int4' if vct == CT_INT else 'Float4', 0, slot); layouts[slot] = (16, *step(st))
            continue
        vf = vfmt_for_ct(vf, ct)
        slot = 16 + st if st < 14 else st
        attrs[at] = (vf, off, slot)
        stride = k['stream'][st][0] if st < 16 else 0
        layouts[slot] = (stride or 4, *step(st))
    if any(a[0] not in SCRIPT_VFORMATS for a in attrs.values()): return 'format'
    # metal-tt refuses an attribute that does not fit its buffer's stride ("the attribute offset (0) + attribute size (8) must be <= the stride of the buffer (4)"), which the device's
    # compiler takes (a constant stream: pso_desc gives it stride 4 whatever its format), and its refusal cost the whole group: such a row is left to the device
    if any(off + vformat_size(f) > layouts[b][0] for f, off, b in attrs.values() if b in layouts): return 'stride'
    return tuple((i, *a) for i, a in sorted(attrs.items())), tuple((i, *l) for i, l in sorted(layouts.items()))


def plan_layout(lib_dir, chain, rows, zero, pair_bases=()):
    """The bases of the prewarm lists' R rows, [LayoutBase], as the host's prewarm builds them (warm_task: pso_build(pso_desc(...)), the base pso_desc4 makes with the colour state
    unspecialized), and counts of the rows left out: a key that does not parse, a merged pass, a specialized fragment (fz: the merge's own function, or the mark of transform
    feedback, geometry capture, rasterizer discard or view amplification, which pso_desc builds with another vertex function or none), the alpha test or a logic operation (side libraries), a reflection of another chain version or none, a mesh shader, a vertex
    shader that writes the layer (an input primitive class), a pixel shader that reads the primitive ID (built whole), a missing library or entry point, a function with function
    constants other than HOST_CONSTANTS, or with any when the row keeps the border corrections (its key's border: pso_build then takes the functions unspecialized), which are
    specialized on the device, a vertex format the script cannot name, an attribute that does not fit its buffer's stride (metal-tt refuses it). A row whose vertex shader has no stage input has no layout: its base is the pair base when the
    pair lists name it (pair_bases), else one of these with no vertex descriptor"""
    lib_dir = romfs.Path(lib_dir); js, fns = {}, {}
    def refl(key):
        if key not in js:
            try: js[key] = json.loads((lib_dir / f'{key}.json').read_bytes())
            except (OSError, ValueError): js[key] = None
            if not isinstance(js[key], dict) or js[key].get('chain') != chain: js[key] = None
        return js[key]
    def fn(lib):
        if lib == NOP_LIB: return {NOP_ENTRY: ()}
        if lib not in fns:
            try: fns[lib] = constants(lib_dir / f'{lib}.metallib')
            except (OSError, ValueError): fns[lib] = None
        return fns[lib]
    def other(cs, plain): return any(plain or c not in HOST_CONSTANTS for c in cs)   # as plan_mesh: script specializes HOST_CONSTANTS where pso_build takes fn_off's function
    pairs = set(pair_bases); out, seen = [], set()
    left: dict[str, int] = dict.fromkeys(('key', 'merged', 'specialized', 'side library', 'reflection', 'mesh', 'layer', 'primitive ID', 'library', 'entry', 'constants', 'format',
                                          'stride'), 0)
    for text in rows:
        k = parse_render_key(text)
        if not k or not k['vs'] or k['vs_stage'] != 0 or (k['fs'] and k['fs_stage'] != 1): left['key'] += 1; continue
        if k['fz']: left['specialized'] += 1; continue   # pso_skey.fz: a specialized fragment (bf_fn) or a mark (transform feedback, geometry capture, rasterizer discard, amplification)
        if k['merged']: left['merged'] += 1; continue   # a merged pass: lmap maps its outputs, which the base's fragment choice and the alpha test depend on
        if k['atest'] or k['logic']: left['side library'] += 1; continue
        vj, fj = refl(k['vs']), refl(k['fs']) if k['fs'] else {'entry': NOP_ENTRY}
        ins = vertex_inputs(vj) if vj else None
        if not vj or not fj or ins is None: left['reflection'] += 1; continue
        if vj.get('mesh_stage'): left['mesh'] += 1; continue
        if vj.get('layer_out'): left['layer'] += 1; continue
        if (fj.get('raster') or {}).get('primitive_id'): left['primitive ID'] += 1; continue
        ins, has_vin = ins
        ventry = vj['entry_z'] if zero and vj.get('entry_z') else vj.get('entry')
        vf = fn(k['vs'])
        if vf is None: left['library'] += 1; continue
        if ventry not in vf: left['entry'] += 1; continue
        plain = bool(k['border'])
        if other(vf[ventry], plain): left['constants'] += 1; continue
        vlib = k['vs']
        need = has_vin and any(vin_ct(v, k['attr'][v[0]][0], 1) != v[1] for v in ins)
        bv = fn(k['vs'][:-2] + '_bv') if need else None   # vin_fn: <key less _b>_bv; no library or entry point there keeps the conversion
        on = bool(bv and ventry in bv)
        if on:
            if other(bv[ventry], plain): left['constants'] += 1; continue
            vlib = k['vs'][:-2] + '_bv'
        if k['fs']:
            ff = fn(k['fs'])
            if ff is None: left['library'] += 1; continue
            if fj.get('entry') in ff and other(ff[fj['entry']], plain): left['constants'] += 1; continue   # shader_load specializes every entry point of such a shader
            chosen = fragment_entry(k, fj, {e: other(cs, plain) for e, cs in ff.items()})
            if isinstance(chosen, str): left[chosen] += 1; continue
            frag = (k['fs'], chosen[0])
        else: frag = (NOP_LIB, NOP_ENTRY)   # a depth-only program: pso_desc4's nop_fragment
        vd = vertex_descriptor(k, ins, on)
        if isinstance(vd, str): left[vd] += 1; continue
        b = LayoutBase((vlib, ventry), frag, *vd, k['samples'] or 1, bool(k['a2c']))
        if not b.attributes and not b.layouts and b.samples == 1 and not b.a2c and (vlib, ventry, *frag) in pairs: continue   # the pair base
        if b not in seen: seen.add(b); out.append(b)
    return out, left


def pipe_libs(p):
    """The libraries a compute pipeline (library, entry), a task / mesh pipeline (MeshPipe) or a layout base (LayoutBase) is made of"""
    return (p.obj[0], p.mesh[0], p.frag[0]) if isinstance(p, MeshPipe) else (p.vert[0], p.frag[0]) if isinstance(p, LayoutBase) else (p[0],)


def mesh_descriptor(p, fd):
    return {'object_function_descriptor': fd(*p.obj), 'mesh_function_descriptor': fd(*p.mesh), 'fragment_function_descriptor': fd(*p.frag),
            'max_total_threads_per_object_threadgroup': p.obj_threads, 'max_total_threads_per_mesh_threadgroup': p.mesh_threads, 'payload_memory_length': p.payload,
            'raster_sample_count': p.samples, 'alpha_to_coverage_state': 'Enabled' if p.a2c else 'Disabled',
            'color_attachments': [dict(zip(COLOUR, c)) for c in p.colours]}


def layout_descriptor(p, fd):
    """A layout base's render pipeline descriptor as pso_desc4 makes it: its functions, the vertex descriptor (attributes and layouts indexed by attribute and buffer index, the
    entries pso_desc leaves alone at MTLVertexDescriptor's defaults), the sample count and alpha to coverage, every colour attachment unspecialized"""
    d = {'vertex_function_descriptor': fd(*p.vert), 'fragment_function_descriptor': fd(*p.frag)}
    if p.attributes or p.layouts:
        attrs, layouts = [{} for _ in range(max((a[0] for a in p.attributes), default=-1) + 1)], [{} for _ in range(max((l[0] for l in p.layouts), default=-1) + 1)]
        for i, f, off, b in p.attributes: attrs[i] = {'format': f, 'offset': off, 'buffer_index': b}
        for i, stride, step, rate in p.layouts: layouts[i] = {'stride': stride, 'step_function': step, 'step_rate': rate}
        d['vertex_descriptor'] = {'attributes': attrs, 'layouts': layouts}
    if p.samples != 1: d['raster_sample_count'] = p.samples
    if p.a2c: d['alpha_to_coverage_state'] = 'Enabled'
    d['color_attachments'] = [dict.fromkeys(COLOUR, 'Unspecialized') for _ in range(8)]
    return d


def script(lib_dir, bases, computes=()):
    """A Metal 4 pipelines script (metal4-pipelines-script(5), the .mtl4-json format metal-tt reads) with one render pipeline descriptor per base, and one compute pipeline descriptor per
    compute pipeline (library, entry) that names the function alone, as the host's lookup does (cps_bundle in nvn_mtl.m: no threadgroup size, no indirect command buffers), and one mesh
    render pipeline descriptor per task / mesh pipeline (MeshPipe among computes) as mtk_desc4 makes it, and one render pipeline descriptor per layout base (LayoutBase among
    computes). A function that declares constants is named through its specialization by HOST_CONSTANTS (a pair or a row with other constants is not among them: plan, plan_mesh)"""
    meshes = [p for p in computes if isinstance(p, MeshPipe)]; layouts = [p for p in computes if isinstance(p, LayoutBase)]
    computes = [p for p in computes if not isinstance(p, (MeshPipe, LayoutBase))]
    libs, fns, specs, declared, pipes = {}, {}, {}, {}, []
    def fd(lib, entry):
        if lib not in libs:
            libs[lib] = {'label': lib, 'path': str(Path(lib_path(lib_dir, lib)).resolve())}
            try: declared[lib] = constants(lib_path(lib_dir, lib))
            except (OSError, ValueError): declared[lib] = {}   # plan read every base's libraries; one it could not read is not among them
        label = f'{lib}.{entry}'
        if label not in fns: fns[label] = {'label': label, 'library': f'lib:{lib}', 'name': entry}
        cs = declared[lib].get(entry, ())
        if not cs: return f'fnd:{label}'
        if label not in specs:
            specs[label] = {'label': f'{label}.host', 'function_descriptor': f'fnd:{label}',
                            'constant_values': [{'id_type': 'FunctionConstantIndex', 'id': {'data': i}, 'value_type': 'ConstantBool', 'value': {'data': v}}
                                                for i, v in sorted(HOST_CONSTANTS[c] for c in cs if c in HOST_CONSTANTS)]}
        return f'fnd:{label}.host'
    for vl, ve, fl, fe in bases:
        pipes.append({'vertex_function_descriptor': fd(vl, ve), 'fragment_function_descriptor': fd(fl, fe),
                      'color_attachments': [dict.fromkeys(COLOUR, 'Unspecialized') for _ in range(8)]})
    for p in layouts: pipes.append(layout_descriptor(p, fd))
    descriptors = {'render_pipeline_descriptors': pipes}
    if computes: descriptors['compute_pipeline_descriptors'] = [{'compute_function_descriptor': fd(lib, entry)} for lib, entry in computes]   # none: the script of bases alone, as before
    if meshes: descriptors['mesh_render_pipeline_descriptors'] = [mesh_descriptor(p, fd) for p in meshes]
    functions_ = {'library_function_descriptors': list(fns.values())}
    if specs: functions_['specialized_function_descriptors'] = list(specs.values())   # none: the script as before, so other games' archive keys hold
    return {'libraries': list(libs.values()), 'function_descriptors': functions_, 'pipeline_descriptors': descriptors}


def write_script(path, configuration):
    """Stream the script to disk beside the previous one (<name>.partial, written again by the next run if this one is killed), which it replaces only when the two differ: an unchanged file keeps its time"""
    part = path.with_name(path.name + '.partial')
    try:
        with part.open('w', encoding='utf-8', newline='\n') as out: json.dump(configuration, out, indent=1)
        if not path.is_file() or not filecmp.cmp(path, part, shallow=False): os.replace(part, path)
    finally: part.unlink(missing_ok=True)


def library_digest(lib_dir, bases, computes=()):
    """The bytes metal-tt consumes: a profile/chain stamp does not change when the same shaders are rebuilt by another Metal compiler."""
    h = hashlib.sha256()
    for name in sorted({lib for vl, _, fl, _ in bases for lib in (vl, fl)} | {lib for p in computes for lib in pipe_libs(p)}):
        h.update(name.encode() + b'\0')
        lib = hashlib.sha256()
        if name in HOST_LIBS:   # compiled with this build, each time with another identifier: its functions by their hashes
            lib.update(json.dumps(sorted(functions(HOST_LIBS[name], hashes=True).items())).encode()); h.update(lib.digest()); continue
        with romfs.open(os.path.join(lib_dir, f'{name}.metallib'), 'rb') as f:
            while chunk := f.read(1 << 20): lib.update(chunk)
        h.update(lib.digest())
    return h.hexdigest()


def space_needed(bases):   # what metal-tt is let start with, an estimate: its temporary files (TMPDIR, one .airp per base) and the archive (about 41 KB per base at 15,767 bases); Cruis'n Blast's 33,858 bases failed with 366 MB free
    return max(2 << 30, bases * (96 << 10))


def clear_temporaries(work):   # what a failed or killed metal-tt leaves in its TMPDIR (the work folder): translate-*, *.airp, multiple-functions-input-*.metallib
    for f in [*work.glob('translate-*'), *work.glob('*.airp'), *work.glob('multiple-functions-input-*.metallib')]:
        shutil.rmtree(f) if f.is_dir() else f.unlink(missing_ok=True)


def archive_key(configuration, libraries, arch, platform, osmin, toolchain):
    """Identity of metal-tt's inputs, independent of chain labels and library locations.

    The generated configuration includes all entry points and pipeline settings; the
    library digest covers every referenced file's name and bytes. Only absolute
    library paths are replaced: moving identical inputs cannot change the GPU code.
    Version this format if a future input is not represented here. Legacy keys miss
    once; runtime stamps are rewritten even when the compiled archive is reused.
    """
    config = dict(configuration, libraries=[dict(lib, path=lib['label'] + '.metallib') for lib in configuration['libraries']])
    inputs = {'format': 1, 'configuration': config, 'libraries': libraries,
              'arch': arch, 'platform': platform, 'os_min': osmin, 'toolchain': toolchain}
    digest = hashlib.sha256()
    for chunk in json.JSONEncoder(sort_keys=True, separators=(',', ':')).iterencode(inputs):
        digest.update(chunk.encode())
    return digest.hexdigest()


def sdk(platform):
    return 'iphoneos' if platform == 'ios' else 'macosx'


def tool_version(platform):
    r = subprocess.run(['xcrun', '-sdk', sdk(platform), 'metal-tt', '-version'], capture_output=True, text=True)
    if r.returncode: raise SystemExit(f'[RED] pso_offline: metal-tt is not available ({(r.stderr or r.stdout).strip()}); install the Metal toolchain: xcodebuild -downloadComponent MetalToolchain')
    return r.stdout.strip().splitlines()[0]


IOS_PROJECT = Path(__file__).resolve().parents[2] / 'ios' / 'project.yml'


def ios_deployment_target(project=IOS_PROJECT):
    """The app's deployment target, options.deploymentTarget.iOS of dm/ios/project.yml; None when this checkout has none"""
    try: text = project.read_text(encoding='utf-8')
    except OSError: return None
    m = re.search(r'^\s*deploymentTarget:[^\n]*\n\s*iOS:\s*["\']?(\d+(?:\.\d+)*)', text, re.M)
    return m.group(1) if m else None


def os_min_default(platform):
    # iOS: the app's deployment target (27.3), the system every device that runs the app has at least and the one its libraries are built for (ios_metal.py, host_msl.py),
    # so the archives open on all of them; the SDK's major version only without the project. It was the SDK's major version (27.0), which a device on 27.3 opens as well
    # (same major version), but which no longer matched what the app is built for. A changed minimum is in each archive's key: the archives are made again once
    if platform != 'macos' and (v := ios_deployment_target()): return v
    cmd = ['sw_vers', '-productVersion'] if platform == 'macos' else ['xcrun', '-sdk', sdk(platform), '--show-sdk-version']
    v = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
    return v.split('.')[0] + '.0'


class Refused(SystemExit):
    """metal-tt ran and refused its input: an exit of its own with room left on the volume, which the same input meets again (not a full volume, nor a compiler killed)"""


def compile_archive(js, part, work, arch, platform, osmin, count):
    """One compiler invocation, with its temporaries on the work volume. Never publish a failed output."""
    part.unlink(missing_ok=True)
    clear_temporaries(work)
    need, free = space_needed(count), shutil.disk_usage(work).free
    if free < need: sys.exit(f'[RED] pso_offline: {free / 2**30:.1f} GB free on the volume of {work}, metal-tt needs about {need / 2**30:.0f} GB for {count} bases: free some space and run again')
    cmd = ['xcrun', '-sdk', sdk(platform), 'metal-tt', '-arch', arch, f'-{platform}-version-min', osmin, str(js), '-o', str(part)]
    log_path = work / f'metal-tt.{arch}.log'
    with log_path.open('w') as log:
        r = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ, TMPDIR=str(work)))
    if r.returncode or not part.is_file() or not part.stat().st_size:
        free = shutil.disk_usage(work).free
        clear_temporaries(work); part.unlink(missing_ok=True)
        full = f' ({free / 2**30:.1f} GB free on the volume of {work} when it failed: likely out of disk space)' if free < 1 << 30 else ''
        text = f'[RED] pso_offline: metal-tt failed for {arch} (exit {r.returncode}){full}: {log_path.read_text()[-2000:]}'
        raise Refused(text) if r.returncode > 0 and not full else SystemExit(text)


def real_libraries(lib_dir, bases, work, computes=()):
    """Where metal-tt finds the bases' libraries: it takes file paths, so the libraries of one file get a temporary folder of what this compile reads, which clear_real_libraries removes after it.
    An archive whose key still holds compiles nothing and gets none"""
    if os.path.isdir(lib_dir): return lib_dir
    real = Path(work) / 'libraries'; shutil.rmtree(real, ignore_errors=True); real.mkdir(parents=True)
    for name in sorted({lib for vl, _, fl, _ in bases for lib in (vl, fl)} | {lib for p in computes for lib in pipe_libs(p)}):
        if name in HOST_LIBS: continue   # in its own folder (lib_path)
        with romfs.open(os.path.join(lib_dir, f'{name}.metallib'), 'rb') as f, open(real / f'{name}.metallib', 'wb') as o: shutil.copyfileobj(f, o)
    return real


def clear_real_libraries(work): shutil.rmtree(Path(work) / 'libraries', ignore_errors=True)


def compile_batch(lib_dir, bases, work, arch, platform, osmin, toolchain, computes=(), keep_refusal=False):
    """Cache one bounded group by its actual libraries and descriptors; also used for an isolated pilot. keep_refusal (a task / mesh group): a refusal is kept by the group's key
    (refused.<arch>), and a group refused with the same key raises Refused again without running metal-tt"""
    work.mkdir(parents=True, exist_ok=True)
    configuration = script(lib_dir, bases, computes)
    js = work / 'bases.mtl4-json'; write_script(js, configuration)
    key = archive_key(configuration, library_digest(lib_dir, bases, computes), arch, platform, osmin, toolchain)
    del configuration
    dst, kf = work / f'{arch}.mtl4a', work / f'key.{arch}'
    if dst.is_file() and dst.stat().st_size and kf.is_file() and kf.read_text().strip() == key: return dst, True
    kf.unlink(missing_ok=True)
    rf = work / f'refused.{arch}'
    if keep_refusal and rf.is_file() and rf.read_text().strip() == key: raise Refused(f'metal-tt refused it before with the same inputs (remove {rf} to try again)')
    rf.unlink(missing_ok=True)
    part = work / f'{arch}.mtl4a.partial'
    write_script(js, script(real_libraries(lib_dir, bases, work, computes), bases, computes))
    try: compile_archive(js, part, work, arch, platform, osmin, len(bases) + len(computes))
    except Refused:
        if keep_refusal: rf.write_text(key + '\n')
        raise
    finally: clear_real_libraries(work)
    os.replace(part, dst); kf.write_text(key + '\n')
    return dst, False


def groups_of(bases, computes, batch_size, compute_size=COMPUTE_BATCH, mesh_size=MESH_BATCH, layout_size=LAYOUT_BATCH):
    """The groups compile_batches compiles, [(folder name, bases, other pipelines)]: the bases in groups of batch_size (00001, ...), then the compute pipelines in groups of compute_size
    of their own (c00001, ...), then the task / mesh pipelines (the MeshPipe among computes) in groups of mesh_size (m00001, ...), then the layout bases (the LayoutBase among
    computes) in groups of layout_size (l00001, ...), so that a change to one kind leaves the others' groups as they are. 0: one group of each"""
    groups, meshes, layouts = [], [p for p in computes if isinstance(p, MeshPipe)], [p for p in computes if isinstance(p, LayoutBase)]
    for prefix, items, size in (('', bases, batch_size), ('c', [p for p in computes if not isinstance(p, (MeshPipe, LayoutBase))], compute_size), ('m', meshes, mesh_size),
                                ('l', layouts, layout_size)):
        size = size or len(items) or 1
        for index, start in enumerate(range(0, len(items), size), 1):
            group = items[start:start + size]
            groups.append((f'{prefix}{index:05d}', group if not prefix else [], group if prefix else []))
    return groups


def compile_batches(lib_dir, bases, work, part, arch, platform, osmin, toolchain, batch_size, computes=(), jobs=1, compute_size=COMPUTE_BATCH):
    """Limit compiler input size, then combine every completed group into the usual single archive.

    This bounds input count, not memory: a single pipeline can still exceed Apple's compiler resources.
    On M2, merged archives passed archive-only lookups of two synthetic pipelines and all 32,864 Odyssey bases.
    Other workloads and compiler versions can have different resource use.
    The groups of bases run one after the other, as before; the compute, task / mesh and layout groups, small, jobs at a time, each in its own folder (its TMPDIR).
    A task / mesh or layout group metal-tt refuses is left out with a red line and the others are merged: its pipelines are built on the device at their first draw, as without the
    archive, where a refused base or compute group still stops the build. A refused layout group of more than one base is compiled again in halves (<group>/a and <group>/b, each
    cached and refused by its own inputs, and so on down to one base), so a row metal-tt refuses where the device's compiler takes it costs only itself: its own validation of the
    vertex descriptor is stricter (an attribute beyond its buffer's stride cost a whole group of 64 before plan_layout left such rows out). Returns the names of the groups left out
    (a half by its path, l00001/b/a): one metal-tt refused has refused.<arch> in its folder, kept by its own inputs (the caller then writes the archive's key); for any other the
    caller keeps no key, so the next build tries it again
    """
    groups = groups_of(bases, computes, batch_size, compute_size); total = len(groups); names = {name for name, _, _ in groups}
    for old in [*(work / f'batches.{arch}').glob('[0-9]*'), *(work / f'batches.{arch}').glob('c[0-9]*'), *(work / f'batches.{arch}').glob('m[0-9]*'), *(work / f'batches.{arch}').glob('l[0-9]*')]:   # the groups of a longer list than this one
        if old.name not in names: shutil.rmtree(old)
    def one(index, name, group, cgroup):
        """(the pieces, the names left out) of one group, or of a half of a refused layout group (name <group>/a ...)"""
        what = (f'{len(group)} bases' if group else f'{len(cgroup)} task / mesh pipelines' if name.startswith('m') else f'{len(cgroup)} layout bases' if name.startswith('l')
                else f'{len(cgroup)} compute pipelines') + (f', {name}' if '/' in name else '')
        print(f'pso_offline: {arch}: batch {index}/{total}: {what}, compiling or checking cache', flush=True)
        folder = work / f'batches.{arch}' / name
        try: piece, reused = compile_batch(lib_dir, group, folder, arch, platform, osmin, toolchain, cgroup, keep_refusal=name[0] in 'ml')
        except SystemExit as e:
            if name[0] not in 'ml': raise
            if name[0] == 'l' and isinstance(e, Refused) and len(cgroup) > 1:
                print(f'[RED] pso_offline: {arch}: batch {index}/{total} ({what}) refused by metal-tt: compiling it in halves, to leave out only the layout bases it refuses', flush=True)
                half = (len(cgroup) + 1) // 2
                parts = [one(index, f'{name}/{h}', [], c) for h, c in (('a', cgroup[:half]), ('b', cgroup[half:]))]
                return [p for ps, _ in parts for p in ps], [n for _, ns in parts for n in ns]
            print(f'[RED] pso_offline: {arch}: batch {index}/{total} ({what}) left out of the archive, the device builds them at their first draw: {e}', flush=True)
            return [], [name]
        if name[0] == 'l':
            for h in ('a', 'b'): shutil.rmtree(folder / h, ignore_errors=True)   # the halves of an earlier refusal of this group's former inputs
        print(f'pso_offline: {arch}: batch {index}/{total}: ready ({"reused" if reused else "compiled"})', flush=True)
        return [piece], []
    pieces = [p for i, g in enumerate(groups, 1) if g[1] for p in one(i, *g)[0]]   # a group of bases that fails stops the build: never left out
    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:   # a failed group stops the build once the others under way have finished (their pieces stay cached)
        futures = [pool.submit(one, i, *g) for i, g in enumerate(groups, 1) if not g[1]]
        done = [f.result() for f in futures]
    skipped = [n for _, names in done for n in names]
    pieces += [p for ps, _ in done for p in ps]
    if not pieces: sys.exit(f'[RED] pso_offline: no group of {arch} compiled')
    part.unlink(missing_ok=True)
    need, free = max(2 << 30, sum(p.stat().st_size for p in pieces)), shutil.disk_usage(work).free
    if free < need: sys.exit(f'[RED] pso_offline: {free / 2**30:.1f} GB free before merging; need at least {need / 2**30:.1f} GB')
    print(f'pso_offline: {arch}: merging {len(pieces)} batches', flush=True)
    cmd = ['xcrun', '-sdk', sdk(platform), 'metal-pack', '-nthreads', '1', *map(str, pieces), '-o', str(part)]
    log_path = work / f'metal-pack.{arch}.log'
    with log_path.open('w') as log:
        r = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ, TMPDIR=str(work)))
    if r.returncode or not part.is_file() or not part.stat().st_size:
        part.unlink(missing_ok=True)
        sys.exit(f'[RED] pso_offline: metal-pack failed for {arch} (exit {r.returncode}): {log_path.read_text()[-2000:]}')
    return skipped


def archive_held(work, arch, kf, key):
    """Whether the archive of key.<arch> still serves: (True, the groups it left out as refused) when its key is this one and each of those groups still has its refused.<arch>;
    (None, those groups) when one of them lost it, which is how a refusal is tried again by hand (the reused archive never reaches compile_batch, the only reader of refused.<arch>);
    (False, []) otherwise. The key file holds the key, then a line `refused<TAB><group>` per group left out"""
    lines = kf.read_text().splitlines() if kf.is_file() else []
    if not lines or lines[0].strip() != key: return False, []
    refused = [l.split('\t', 1)[1] for l in lines[1:] if l.startswith('refused\t')]
    return (True if all((work / f'batches.{arch}' / name / f'refused.{arch}').is_file() for name in refused) else None), refused


def main(argv=None):
    ap = argparse.ArgumentParser(description='Build the pipeline archive of a game\'s shader pairs offline (metal-tt)')
    ap.add_argument('--msl', required=True, help='the shader libraries, b-<chain version> (with their reflection <key>_b.json)')
    ap.add_argument('--game', help='the game profile: its pair lists and depth_mode key')
    ap.add_argument('--pairs', action='append', help='shader_pairs.tsv, then pso_pairs.tsv (missing files are skipped; default: the profile\'s)')
    ap.add_argument('--out', required=True, help='the folder the app bundles (archives and stamp)')
    ap.add_argument('--work', required=True, help='the script, keys and logs')
    ap.add_argument('--gpu', default='g19p', help='GPU architectures, comma-separated (default g19p, the A20 Pro)')
    ap.add_argument('--depth', choices=('gl', 'zero'), help='the game\'s NVN depth mode (default: the profile\'s depth_mode, else gl: near = -w)')
    ap.add_argument('--platform', choices=('ios', 'macos'), default='ios')
    ap.add_argument('--os-min', help='minimum OS of the archives (default: iOS, the app\'s deployment target from dm/ios/project.yml, else the SDK\'s major version; macOS, this Mac\'s major version)')
    ap.add_argument('--script-only', action='store_true', help='write the script and the stamp, run no metal-tt')
    ap.add_argument('--batch-size', type=int, default=BATCH, help=f'compile sequential groups of at most N bases and merge with metal-pack, when there are more (default {BATCH}; 0: one compiler invocation)')
    ap.add_argument('--shader-map', action='append', help='shader_map.tsv: its compute shaders get pipelines (default: the profile\'s)')
    ap.add_argument('--manifest', action='append', help='pso_manifest.tsv: its C rows first, its M rows\' task / mesh pipelines and its R rows\' layout bases (default: the profile\'s)')
    ap.add_argument('--no-compute', action='store_true', help='no compute pipelines')
    ap.add_argument('--no-mesh', action='store_true', help='no task / mesh pipelines (the M rows)')
    ap.add_argument('--no-layout', action='store_true', help='no layout bases (the R rows: pipelines with a vertex layout)')
    ap.add_argument('--jobs', type=int, default=JOBS, help=f'metal-tt runs at a time for the compute, task / mesh and layout groups (default {JOBS}, half the logical CPUs)')
    a = ap.parse_args(argv)
    if a.batch_size < 0: ap.error('--batch-size must be zero or positive')
    if a.game:
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'games')); import game
        g = game.load(a.game)
        a.pairs = a.pairs or [str(g.table('shader_pairs.tsv')), str(g.table('pso_pairs.tsv'))]
        a.shader_map = a.shader_map or [str(g.table('shader_map.tsv'))]; a.manifest = a.manifest or [str(g.table('pso_manifest.tsv'))]
        a.depth = a.depth or g.get('depth_mode', 'gl')
        if a.depth not in ('gl', 'zero'): sys.exit(f'[RED] pso_offline: {g.id}: depth_mode must be gl or zero: {a.depth}')
    if not a.pairs: sys.exit('[RED] pso_offline: no pair lists (--pairs or --game)')
    a.depth = a.depth or 'gl'
    lib_dir, out, work = shader_lib.view(a.msl), Path(a.out), Path(a.work)
    chain = shader_lib.name_of(lib_dir)[2:] if shader_lib.name_of(lib_dir).startswith('b-') else sys.exit(f'[RED] pso_offline: {lib_dir} is not a b-<chain version> folder')
    archs = sorted({arch_name(x) for x in a.gpu.split(',') if x.strip()})
    if not archs: sys.exit('[RED] pso_offline: no GPU architecture (--gpu)')
    text = pair_text(a.pairs)
    if not text: sys.exit(f'[RED] pso_offline: no pair list ({", ".join(a.pairs)})')
    zero = a.depth == 'zero'
    t0 = time.time()
    pairs = read_pairs(text)
    bases, rest, left = plan(lib_dir, chain, pairs, zero)
    shaders = [] if a.no_compute else read_computes(a.shader_map, a.manifest)
    computes, cleft = plan_compute(lib_dir, chain, shaders)
    mesh_rows = [] if a.no_mesh else read_meshes(a.manifest)
    meshes, mleft = plan_mesh(lib_dir, chain, mesh_rows, zero)
    layout_rows = [] if a.no_layout else read_layouts(a.manifest)
    layouts, lleft = plan_layout(lib_dir, chain, layout_rows, zero, bases)
    pipes = computes + meshes + layouts   # the pipelines beside the bases: script, groups and keys tell the kinds apart (MeshPipe, LayoutBase)
    work.mkdir(parents=True, exist_ok=True); out.mkdir(parents=True, exist_ok=True)
    host_libraries(bases, a.platform, work, pipes)   # the empty fragment of depth-only pairs and rows; none without them, so no other archive's key changes
    js = work / 'bases.mtl4-json'   # metal-tt takes the format from the extension: .mtl4-json is Metal 4's (.mtlp-json is the Metal 3 format)
    configuration = script(lib_dir, bases, pipes)
    write_script(js, configuration)
    st = stamp(chain, zero, text)
    print(f'pso_offline: {len(pairs)} pairs: {len(bases)} bases, {len(rest)} left to the device (function constants), left out as the host leaves them: '
          + ', '.join(f'{k} {v}' for k, v in left.items()) + f' ({time.time() - t0:.1f} s)')
    if shaders: print(f'pso_offline: {len(shaders)} compute shaders: {len(computes)} compute pipelines, left out: '
                      + ', '.join(f'{k} {v}' for k, v in cleft.items()))
    if mesh_rows: print(f'pso_offline: {len(mesh_rows)} task / mesh rows: {len(meshes)} task / mesh pipelines, left out: ' + ', '.join(f'{k} {v}' for k, v in mleft.items()))
    if layout_rows: print(f'pso_offline: {len(layout_rows)} render rows: {len(layouts)} layout bases, left out: ' + ', '.join(f'{k} {v}' for k, v in lleft.items()))
    if a.script_only: (out / 'prebuilt.tsv').write_text(st); return 0
    if pairs and not bases and not rest and not layouts: sys.exit('[RED] pso_offline: no base to build')   # pairs, but the host would leave out every one: wrong or missing libraries
    if not pairs: print('pso_offline: no pairs (only a header)' + (': nothing to build, no archive' if not pipes else ''))   # a profile whose split found no pair (GitHub issue #338)
    if not bases and not pipes: archs = []   # no pair, or every eligible pair needs device specialization, and no compute pipeline; clear old archives and still write the stamp and the remainder list
    osmin = a.os_min or os_min_default(a.platform); tv = tool_version(a.platform) if bases or pipes else 'not used (function constants only)'
    libraries = library_digest(lib_dir, bases, pipes)
    keys = {arch: archive_key(configuration, libraries, arch, a.platform, osmin, tv) for arch in archs}
    del configuration   # the compiler reads the script from disk
    left_out = {}   # per architecture, the groups left out of its archive (archive.tsv)
    for arch, key in keys.items():
        dst, kf = out / f'{arch}.mtl4a', work / f'key.{arch}'
        held, refused = archive_held(work, arch, kf, key)
        if dst.is_file() and held:
            left_out[arch] = refused
            print(f'pso_offline: {arch}: reused ({dst.stat().st_size / 2**20:.0f} MB)')
            if refused: print(f'[RED] pso_offline: {arch}: group(s) {", ".join(refused)} left out of the archive, refused by metal-tt with these inputs; the device builds '
                              f'their pipelines at their first draw (remove batches.{arch}/<group>/refused.{arch} to try again)', flush=True)
            continue
        if held is None: print(f'pso_offline: {arch}: refused.{arch} of group(s) '
                               + ', '.join(n for n in refused if not (work / f'batches.{arch}' / n / f'refused.{arch}').is_file()) + ' removed: trying again', flush=True)
        kf.unlink(missing_ok=True); dst.unlink(missing_ok=True)
        part = work / f'{arch}.mtl4a.partial'; part.unlink(missing_ok=True)
        t1 = time.time(); print(f'pso_offline: {arch}: metal-tt, {len(bases)} bases, {len(computes)} compute pipelines, {len(meshes)} task / mesh pipelines, {len(layouts)} layout bases (minutes) ...', flush=True)
        skipped = []
        if meshes or layouts or (a.batch_size and len(groups_of(bases, pipes, a.batch_size)) > 1):   # task / mesh pipelines and layout bases always in groups: one metal-tt refuses must not cost the archive
            skipped = compile_batches(lib_dir, bases, work, part, arch, a.platform, osmin, tv, a.batch_size, pipes, a.jobs)
        else:
            write_script(js, script(real_libraries(lib_dir, bases, work, pipes), bases, pipes))
            compile_archive(js, part, work, arch, a.platform, osmin, len(bases) + len(pipes))
            clear_real_libraries(work)
        os.replace(part, dst); left_out[arch] = sorted(skipped)
        if all((work / f'batches.{arch}' / name / f'refused.{arch}').is_file() for name in skipped):   # refusals only: kept by their own inputs, and named under the key
            kf.write_text(key + '\n' + ''.join(f'refused\t{name}\n' for name in sorted(skipped)))
        print(f'pso_offline: {arch}: {dst.stat().st_size / 2**20:.0f} MB in {time.time() - t1:.0f} s')
    for f in out.glob('*.mtl4a'):   # architectures no longer asked for
        if f.stem not in archs: f.unlink()
    (out / 'prebuilt.tsv').write_text(st)
    rp = out / 'rest_pairs.tsv'
    if rest: rp.write_text(''.join(f'{v}\t{f}\n' for v, f in rest))
    else: rp.unlink(missing_ok=True)
    # layout_rows: the prewarm lists' R rows, then those left out by reason (nonzero only); left_out: an architecture's groups metal-tt refused or that failed (task / mesh, layout)
    (out / 'archive.tsv').write_text(f'# the pipeline archive made offline (dm/gfx/tools/pso_offline.py); the host reads prebuilt.tsv, not this file\narch\t{" ".join(archs)}\n'
                                     f'platform\t{a.platform}\t{osmin}\ntoolchain\t{tv}\nbases\t{len(bases)}\nrest\t{len(rest)}\ncompute\t{len(computes)}\nmesh\t{len(meshes)}\nlayout\t{len(layouts)}\n'
                                     f'layout_rows\t{len(layout_rows)}' + ''.join(f'\t{k} {v}' for k, v in lleft.items() if v) + '\n'
                                     + ''.join(f'left_out\t{arch}\t{" ".join(names)}\n' for arch, names in sorted(left_out.items()) if names))
    return 0


if __name__ == '__main__':
    sys.exit(main())
