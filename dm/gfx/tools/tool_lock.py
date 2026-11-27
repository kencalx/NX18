#!/usr/bin/env python3
# The translation chain's tools against their lock file dm/gfx/tools/dmsh_chain.lock: the translator (its native executable, which holds Ryujinx's shader library, and the source digest it embeds), SPIRV-Cross and the Metal compilers (macOS / iOS).
# The lock is part of the chain version (dmsh_chain.py); these checks are not: they decide no shader's output, so a fix to a check or its message neither changes V nor the shaders' cache keys
# (dmsh_build.py CODE_FP). dmsh_build.py runs check_tools before it builds anything; own_compilers.py replaces it for a player's Mac.
# Usage: tool_lock.py --check-tools   verify that the actual tools match the lock file; on mismatch print [RED] lines and exit 1
#        tool_lock.py --update-lock   rewrite the lock file from the actual tools (run after rebuilding the translator (dm/tools/native_tools.sh) or spirv-cross, or changing Xcode, then dmsh_chain.py --header; both are committed)
# The Metal compilers are a list: one metal_<sdk> line per tested Xcode, "metal_<sdk>\t<metal --version's first line>\t<Xcode N.N>" (Xcode 27.2's and 27.3's), and the build takes
# any of them. --update-lock records the selected Xcode's (DEVELOPER_DIR or xcode-select) in place of that Xcode's line and keeps the other Xcodes' lines. Which compiler built a shader
# is in each shader's cache key (dmsh_build.py METAL_FP, dmsh_mtlcache.compiler_id), so the two keep separate cache entries
import os, sys, hashlib, subprocess, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmsh_chain import LOCK, XLATE_DIR, SPIRV_CROSS, xlate_source_sha

def sha16(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()[:16]

METAL_KEYS = ('metal_macosx', 'metal_iphoneos')

def read_lock(path=None):
    """{key: [(fingerprint, Xcode or '')]}: one entry for a tool, one per tested Xcode for the Metal compilers, in the file's order"""
    out: dict = {}
    with open(path or LOCK) as f:
        for l in f:
            if '\t' not in l or l.startswith('#'): continue
            k, v, *x = l.rstrip('\n').split('\t')
            out.setdefault(k, []).append((v, x[0] if x else ''))
    return out

def accepted(lock, key):   # the fingerprints the lock takes for a key
    return [v for v, _ in lock.get(key, [])]

def tested(lock, key):   # 'A (Xcode 27.3) or B (Xcode 27.2)', as the messages name the lock's entries; 'None' for a key the lock lacks
    return ' or '.join(f'{v} ({x})' if x else v for v, x in lock.get(key, [])) or 'None'

def selected_xcode_version():   # 'Xcode 27.3' (major.minor of xcodebuild -version, which follows DEVELOPER_DIR as xcrun does), '' when it cannot be read
    try: first = (subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True).stdout.splitlines() or [''])[0]
    except OSError: return ''
    parts = first.split()
    return f'Xcode {".".join(parts[1].split(".")[:2])}' if len(parts) >= 2 and parts[0] == 'Xcode' else ''

def tools_now():
    """Actual tool fingerprints: the translator (a native executable that holds the Ryujinx shader library), spirv-cross, metal compiler (macOS / iOS)"""
    xl = os.path.join(XLATE_DIR, 'dmsh_xlate')
    t: dict = {'dmsh_xlate': sha16(xl) if os.path.isfile(xl) else 'missing'}
    t['xlate_source'] = xlate_embedded()
    sc = shutil.which(SPIRV_CROSS)
    t['spirv-cross'] = sha16(sc) if sc else 'missing'
    for sdk in ('macosx', 'iphoneos'):
        t['metal_' + sdk] = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '--version'], capture_output=True, text=True).stdout.splitlines()[0:1] or ['missing']
        t['metal_' + sdk] = t['metal_' + sdk][0]
    return t

NO_RUN = 'does not run'
def xlate_embedded():
    """The source digest the translator embeds (dmsh_xlate --source-sha), or 'does not run (<its first error line>)', so a translator that cannot start (missing, not executable, a download
    quarantined by macOS) is named as such rather than read as an empty digest and a stale translator"""
    try: r = subprocess.run([os.path.join(XLATE_DIR, 'dmsh_xlate'), '--source-sha'], capture_output=True, text=True, errors='replace', timeout=60)
    except (OSError, subprocess.SubprocessError) as e: return f'{NO_RUN} ({e})'
    if r.returncode == 0 and r.stdout.strip(): return r.stdout.strip()
    return '%s (%s)' % (NO_RUN, (r.stderr.strip().splitlines() or r.stdout.strip().splitlines() or [f'exit code {r.returncode}'])[0])

def no_run_message(embedded): return f'the translator {embedded}: {os.path.join(XLATE_DIR, "dmsh_xlate")} is the committed native executable (dm/tools/native_tools.sh builds it); check out the repository again if it is missing or damaged'

def check_tools():
    lock = read_lock()
    now = tools_now(); ran = not now['xlate_source'].startswith(NO_RUN)
    bad = [f'{k}: lock {tested(lock, k)} / actual {v}' for k, v in now.items() if v not in accepted(lock, k) and (ran or k != 'xlate_source')]
    if not ran: bad.append(no_run_message(now['xlate_source']))
    elif now['xlate_source'] != xlate_source_sha(): bad.append(f'the translator was not built from the in-repo source: embedded source {now["xlate_source"]} / in repo {xlate_source_sha()} (rebuild it: dm/tools/native_tools.sh dmsh_xlate)')
    return bad

def update_lock():
    """--update-lock: the lock file from the actual tools; the selected Xcode's Metal compilers replace that Xcode's lines, the other Xcodes' lines stay"""
    t = tools_now()
    if t['xlate_source'].startswith(NO_RUN): sys.exit('[RED] ' + no_run_message(t['xlate_source']))
    if t['xlate_source'] != xlate_source_sha(): sys.exit(f'[RED] the translator was not built from the in-repo source (embedded {t["xlate_source"]} / in repo {xlate_source_sha()}): rebuild it first (dm/tools/native_tools.sh dmsh_xlate)')
    xcode = selected_xcode_version()
    if not xcode: sys.exit('[RED] the selected Xcode\'s version cannot be read (xcodebuild -version): select an Xcode first (DEVELOPER_DIR or xcode-select)')
    old = read_lock() if os.path.isfile(LOCK) else {}
    lines = []
    for k, v in t.items():
        if k not in METAL_KEYS: lines.append(f'{k}\t{v}\n'); continue
        keep = [(ov, ox) for ov, ox in old.get(k, []) if ox and ox != xcode]   # the other Xcodes' compilers stay tested
        lines += [f'{k}\t{ov}\t{ox}\n' for ov, ox in sorted(keep + [(v, xcode)], key=lambda e: [int(n) for n in e[1].split()[-1].split('.')], reverse=True)]   # newest Xcode first
    with open(LOCK, 'w') as f:
        f.write('# Translation chain tool fingerprints (written by tool_lock.py --update-lock; regenerate after changing tools and commit it).\n'
                '# metal_<sdk>: one line per tested Xcode, any of which the build takes (tool_lock.py)\n' + ''.join(lines))
    print('wrote', LOCK)

if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['--update-lock']: update_lock()
    elif a == ['--check-tools']:
        bad = check_tools()
        for b in bad: print('[RED] translation chain tools do not match the lock file: ' + b)
        sys.exit(1 if bad else 0)
    else: sys.exit('usage: tool_lock.py --check-tools | --update-lock')
