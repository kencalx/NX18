#!/usr/bin/env python3
"""Developer tool, for iterating on dmsh_pcomp.py without a shader build: builds pass-as-compute kernels (dmsh_pcomp.py): reads the pairs a host log named ("pass-as-compute: no kernel for pair <vk> <fk>"),
takes both shaders' MSL from the game's shader library (b-<chain>.img or its folder) and writes <vk>_<fk>_pc.metallib into the output folder for the
host's DM_NVN_PCM_DIR. Mac only, with the Mac build's compile flags (dmsh_build.py MAC_METAL). The shader build makes them itself (dmsh_build.py pc_finish).
Usage: dmsh_pcomp_build.py <shader library b-<chain>> <host log> <out folder>"""
import os, re, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../tools'))
import dmsh_pcomp
import shader_lib

METAL = ['xcrun', '-sdk', 'macosx', 'metal', '-O1', '-mmacosx-version-min=27.3', '-std=metal4.1', '-fpreserve-invariance', '-fwrapv']


def source(lib, name):
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(shader_lib.__file__), 'shader_lib.py'), 'cat', lib, name], capture_output=True)
    return r.stdout.decode() if r.returncode == 0 else None


def main():
    lib, log, out = sys.argv[1:4]
    os.makedirs(out, exist_ok=True)
    pairs = sorted({(a[:16], b[:16]) for a, b in re.findall(r'pass-as-compute: no kernel for pair (\w+) (\w+)', open(log, errors='ignore').read())})   # the host's 16-digit keys
    stats = {}
    for vk, fk in pairs:
        dst = os.path.join(out, f'{vk}_{fk}_pc.metallib')
        if os.path.exists(dst): stats['present'] = stats.get('present', 0) + 1; continue
        vs, fs = (source(lib, (k if k.endswith('_b') else k + '_b') + '.metal') for k in (vk, fk))   # the host names a shader by its library (<key>_b)
        if vs is None or fs is None: stats['no source'] = stats.get('no source', 0) + 1; continue
        try: msl, _ = dmsh_pcomp.compose(vs, fs)
        except ValueError as e:
            why = str(e).split(':')[1].strip() if ':' in str(e) else str(e)
            stats['refused: ' + why[:50]] = stats.get('refused: ' + why[:50], 0) + 1; continue
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, 'k.metal'); open(p, 'w').write(msl)
            r = subprocess.run(METAL + [p, '-o', dst], capture_output=True, text=True)
        if r.returncode:
            stats['failed to compile'] = stats.get('failed to compile', 0) + 1
            print(f'[RED] {vk} {fk}: ' + (r.stderr.strip().split('\n')[0] if r.stderr else '')[:200])
            continue
        stats['built'] = stats.get('built', 0) + 1
    print(f'pairs {len(pairs)}: ' + ', '.join(f'{k} {v}' for k, v in sorted(stats.items())))


if __name__ == '__main__':
    main()
