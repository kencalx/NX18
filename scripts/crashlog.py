#!/usr/bin/env python3
# The crash summary of an iPhone or iPad crash report, off the device: what the app logs in log.txt when a crash report arrives (dm/host/crash_summary.h, DmMetrics.m), from the
# report in the app's Documents/metrics folder (<…>-diagnostic-crash.json, MetricKit's JSON: MetricManager's on iOS 27, or MXMetricManager's). The exception, signal and
# termination reason by name, the memory region info's first lines, the crashed run's pid, build and time, the crashed thread's newest frames, and the switchable mods that run had
# in place. iOS names a frame of the game's own code only by its address (its binary UUID is all zeros: the game's modules are not images the system knows), and the modules' bases
# change from run to run, so a frame is named as module+offset and the part of the module it is in (text, patch area, writable part, a switchable mod's page) by the layout of the
# run that crashed:
#   run_layouts.txt (Documents, beside log.txt; the app writes a block per run, the newest 8, dm/host/run_layout.h): the record with the report's pid. These lines are the ones log.txt has.
#   log.txt: the modules' 'base' and 'gates ... patch_off' lines (the latter with key_page and text_end from builds that log them). When the log is of another run (its
#            'run layout: pid' line names another pid, or its bases do not fit the game frames or the report's memory regions), the bases are inferred from the report's memory
#            regions, which list the faulting address's region and one neighbour on each side: a 16 KB read-only row is a module's key page (exact, by its key_page), a writable row
#            right after an executable one starts where its text ends (exact, by its text_end), a writable region followed by another object ends where its patch area begins
#            (exact, by its patch_off); a writable region that ends with the key page, with nothing listed after it, gives the base only if the patch area follows the key page
#            directly (it may start up to 0xc000 later), and the line says so. The other modules are taken to have moved with it. Inferred bases are said to be inferred.
#   neither: run_layouts.txt, then log.prev.txt and log.txt, are looked for beside the report and in the folder above it (Documents/metrics -> Documents); with none, the frames
#            are raw addresses, with the report's own region for those in it (no base can be inferred without a module's patch_off, which only a log or a record gives).
# Usage: python3 scripts/crashlog.py CRASH.json [run_layouts.txt | log.txt]. Exit code 0 when the report was summarized, 1 when it cannot be read or holds no crash, 2 for wrong arguments.
import calendar, json, re, sys
from pathlib import Path

PAGE = 0x4000
KEEP = 8
MAXV = 1 << 48   # run_layout.h DM_RUNLOG_MAXV: a record line with a number past every address is left out
FRAMES = 16   # the newest frames shown of the crashed thread (crash_summary.h DM_CS_FRAMES)

EXC = [None, 'EXC_BAD_ACCESS', 'EXC_BAD_INSTRUCTION', 'EXC_ARITHMETIC', 'EXC_EMULATION', 'EXC_SOFTWARE', 'EXC_BREAKPOINT', 'EXC_SYSCALL', 'EXC_MACH_SYSCALL', 'EXC_RPC_ALERT',
       'EXC_CRASH', 'EXC_RESOURCE', 'EXC_GUARD', 'EXC_CORPSE_NOTIFY']
KERN = {1: 'KERN_INVALID_ADDRESS', 2: 'KERN_PROTECTION_FAILURE', 3: 'KERN_NO_SPACE', 4: 'KERN_INVALID_ARGUMENT', 5: 'KERN_FAILURE', 8: 'KERN_NO_ACCESS', 9: 'KERN_MEMORY_FAILURE',
        10: 'KERN_MEMORY_ERROR', 50: 'KERN_CODESIGN_ERROR', 0x101: 'EXC_ARM_DA_ALIGN', 0x102: 'EXC_ARM_DA_DEBUG', 0x103: 'EXC_ARM_SP_ALIGN', 0x104: 'EXC_ARM_SWP',
        0x105: 'EXC_ARM_PAC_FAIL'}   # <mach/arm/exception.h>
FP = ['EXC_ARM_FP_UNDEFINED', 'EXC_ARM_FP_IO', 'EXC_ARM_FP_DZ', 'EXC_ARM_FP_OF', 'EXC_ARM_FP_UF', 'EXC_ARM_FP_IX', 'EXC_ARM_FP_ID']
SIGNALS = [None, 'SIGHUP', 'SIGINT', 'SIGQUIT', 'SIGILL', 'SIGTRAP', 'SIGABRT', 'SIGEMT', 'SIGFPE', 'SIGKILL', 'SIGBUS', 'SIGSEGV', 'SIGSYS', 'SIGPIPE', 'SIGALRM', 'SIGTERM',
           'SIGURG', 'SIGSTOP', 'SIGTSTP', 'SIGCONT', 'SIGCHLD', 'SIGTTIN', 'SIGTTOU', 'SIGIO', 'SIGXCPU', 'SIGXFSZ', 'SIGVTALRM', 'SIGPROF', 'SIGWINCH', 'SIGINFO', 'SIGUSR1',
           'SIGUSR2']   # Darwin's numbers


def exc_name(t):
    return EXC[t] if 0 < t < len(EXC) else None


def code_name(t, c):
    if t == 1: return KERN.get(c)
    if t == 2 and c == 1: return 'EXC_ARM_UNDEFINED'
    if t == 3 and 0 <= c <= 6: return FP[c]
    if t == 6 and c == 1: return 'EXC_ARM_BREAKPOINT'
    return None


def signal_name(s):
    return SIGNALS[s] if 0 < s < len(SIGNALS) else None


def c_strtoll(s, unsigned=False):
    """C's strtoll / strtoull with base 0 over the longest prefix that is a number (0 for none), as the app reads the record"""
    m = re.match(r'[ \t\n\r\f\v]*([+-]?)(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)', s)
    if not m: return 0
    d = m.group(2)
    v = int(d, 16) if d[:2].lower() == '0x' else int(d, 8) if d.startswith('0') else int(d)
    v = -v if m.group(1) == '-' else v
    return v % (1 << 64) if unsigned else max(-(1 << 63), min(v, (1 << 63) - 1))


def term_hint(t):
    i = t.find('Code ')
    code = c_strtoll(t[i + 5:], unsigned=True) if i >= 0 else 0
    if 'CODESIGNING' in t: return 'code signing: an invalid page, the run executed a page that is not signed code, such as a writable one' if code == 2 else 'code signing'
    if 'JETSAM' in t: return 'the system ended the app for memory'
    if code == 0x8badf00d: return "the system's watchdog: the app did not answer in time"
    if code == 0xdead10cc: return 'the app held a file lock or a database while in the background'
    return None


def parse_time(s):
    """ISO 8601 (2026-11-06T02:15:36Z) or MXMetricManager's (2020-07-07 10:25:00 +0000) to unix seconds; -1 for neither"""
    m = re.match(r'(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})', s)
    if not m or not 1 <= int(m.group(2)) <= 12 or not 1 <= int(m.group(3)) <= 31: return -1
    Y, M, D, h, mi, se = map(int, m.groups())
    days = calendar.timegm((Y, M, 1, 0, 0, 0)) // 86400 + D - 1   # D may run past the month's end, as the app's day count lets it
    rest, off = s[19:], 0
    if rest.startswith('.'): rest = re.sub(r'^\.\d*', '', rest)
    rest = rest.lstrip(' ')
    z = re.match(r'([+-])(\d{2})(?::?(\d{2}))?', rest)
    if z: off = (int(z.group(2)) * 3600 + (int(z.group(3)) * 60 if z.group(3) else 0)) * (-1 if z.group(1) == '-' else 1)
    return days * 86400 + h * 3600 + mi * 60 + se - off


def ctext(v, n):
    """A JSON string as the app reads it into n bytes: whole characters up to n - 1 bytes, a lone surrogate as U+FFFD; '' for anything else"""
    if not isinstance(v, str): return ''
    v = ''.join('\ufffd' if 0xD800 <= ord(c) < 0xE000 else c for c in v)
    b = v.encode('utf-8')
    return v if len(b) <= n - 1 else b[:n - 1].decode('utf-8', 'ignore')


class Real(float):
    """A JSON real, with whether the app reads it exactly (no exponent: its integral part)"""
    exact = True


def real(text):
    r = Real(text); r.exact = 'e' not in text.lower(); return r


ABSENT = object()   # a key the report does not have (a key it has with null is still there, as the app sees it)


def num_of(v, lo, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or (isinstance(v, Real) and not v.exact): return None
    v = int(v)
    return v if lo <= v <= hi else None


def cint(v):
    """A JSON number as the app takes it as a signed 64-bit value (an integer, or a real's integral part); None for anything else"""
    return num_of(v, -(1 << 63), (1 << 63) - 1)


def cuint(v):
    """The same, unsigned (an address)"""
    return num_of(v, 0, (1 << 64) - 1)


def has(o, k):
    return isinstance(o, dict) and k in o


def shex(v):
    return f'{"-" if v < 0 else ""}0x{abs(v):x}'


def roles_name(r):
    return ('none', 'fps', 'ultrawide', 'fps+ultrawide')[r & 3]


def roles_of(s):
    return (1 if 'fps' in s else 0) | (2 if 'ultrawide' in s else 0)


def role_label(r):
    return ('none', 'High frame rate', 'Ultrawide', 'High frame rate and Ultrawide')[r & 3]


# ---------- run_layouts.txt ----------
def field(line, key, n=40):
    for tok in line.split(' '):
        if len(tok) > len(key) and tok[len(key)] == '=' and tok.startswith(key): return tok[len(key) + 1:][:n - 1]
    return None


def is_line(line, word):
    return line == word or line.startswith(word + ' ')


def small(v):
    return -MAXV < v < MAXV


def parse_layouts(text):
    """The complete blocks of a run_layouts.txt, oldest first: dicts of the run's fields with 'modules', 'pieces' and 'jit' (None, or the JIT code memory's base, size, image)"""
    runs, cur = [], None
    num = lambda line, k: c_strtoll(field(line, k) or '')
    unum = lambda line, k: c_strtoll(field(line, k) or '', unsigned=True)
    for line in text.split('\n'):
        if is_line(line, 'run'):
            mods = field(line, 'mods', 64)
            cur = {'pid': num(line, 'pid'), 'start': num(line, 'start'), 'utc': field(line, 'utc', 32) or '', 'commit': field(line, 'commit', 64) or '',
                   'title': field(line, 'title', 40) or '', 'mods': roles_of(mods) if mods is not None else 0, 'modules': [], 'pieces': [], 'jit': None}
        elif cur is not None and is_line(line, 'module'):
            m = {'name': field(line, 'name', 32) or '', 'build': field(line, 'build', 40) or '', 'base': unum(line, 'base'), 'size': unum(line, 'size'),
                 'text_end': unum(line, 'text_end'), 'key': unum(line, 'key'), 'fps': unum(line, 'fps'), 'back': unum(line, 'back'),
                 'back_len': unum(line, 'back_len'), 'patch_len': unum(line, 'patch_len'), 'patch': num(line, 'patch'), 'nro': num(line, 'nro')}
            if all(m[k] < MAXV for k in ('base', 'size', 'text_end', 'key', 'fps', 'back', 'back_len', 'patch_len')) and small(m['patch']): cur['modules'].append(m)
        elif cur is not None and is_line(line, 'jit'):
            j = {'base': unum(line, 'base'), 'size': unum(line, 'size'), 'image': unum(line, 'image')}
            if all(v < MAXV for v in j.values()): cur['jit'] = j
        elif cur is not None and is_line(line, 'piece'):
            roles = field(line, 'roles', 32)
            pc = {'module': field(line, 'module', 32) or '', 'off': num(line, 'off'), 'len': unum(line, 'len'), 'code': field(line, 'kind', 32) == 'code',
                  'roles': roles_of(roles) if roles is not None else 0}
            if small(pc['off']) and pc['len'] < MAXV: cur['pieces'].append(pc)
        elif cur is not None and is_line(line, 'end'):
            runs.append(cur); cur = None
    return runs


def find_run(runs, pid, lo, hi):
    """(run, later) for a crash in [lo, hi] (unix seconds, -1 when not known), as run_layout.h dm_runlog_find: the newest block of that pid that started before hi (a minute's
    slack); later None when it is the crashed run's, or the pid of a run that started after it and a minute or more before lo (one instance of the app runs at a time: the block is
    of an earlier run of that pid). (None, None) when no block has the pid"""
    best, other = None, None
    for r in runs:
        if r['pid'] != pid:
            if lo >= 0 and r['start'] <= lo - 60 and (other is None or r['start'] > other['start']): other = r
            continue
        if (hi >= 0 and r['start'] > hi + 60) or (best is not None and r['start'] < best['start']): continue
        best = r
    return best, (other['pid'] if best is not None and other is not None and other['start'] > best['start'] else None)


def page_up(v):
    return (v + PAGE - 1) & ~(PAGE - 1)


GAP = 'gap before its base (not code: read-write on the iPhone, inaccessible on the Mac)'   # the reservation's anonymous memory between a front patch area and the base


def where(run, a):
    """(description, known, roles of the switchable-mod piece holding it) of a game address by a run's layout (crash_summary.h dm_cs_where); description None when it is in no module
    nor in the JIT code memory"""
    for m in run['modules']:
        if m['base'] <= a < m['base'] + m['size']: off = a - m['base']
        elif a < m['base'] and m['patch'] < 0 and m['base'] - a <= -m['patch']: off = a - m['base']
        else: continue
        known, writable, name = True, False, m['name']
        if m['patch'] < 0 and off < 0: part = 'patch area' if off - m['patch'] < m['patch_len'] else GAP
        elif m['patch'] >= 0 and off >= m['patch']: part = 'patch area'
        elif m['back_len'] and m['back'] <= off < m['back'] + m['back_len']: part = 'back patch area'
        elif not m['text_end']: part, known = 'text or writable part (the layout gives no text end)', False
        elif off < page_up(m['text_end']): part = 'text'
        elif m['key'] and m['key'] <= off < m['key'] + PAGE: part = 'key page (read-only)'
        elif m['fps'] and m['fps'] <= off < m['fps'] + PAGE: part = 'frame step state page (writable, not executable)'
        else: part, writable = 'writable part (not executable)', True
        s, hit = f"{name}{'' if off < 0 else '+'}{shex(off)}, {name}'s {part}", 0
        for p in run['pieces']:
            if p['module'] != name or off < p['off'] or off - p['off'] >= p['len']: continue
            s += f", in a switchable mod's {'code page' if p['code'] else 'data'} ({role_label(p['roles'])})"
            hit = p['roles'] or 3
            break
        if writable and m['patch'] > 0 and 0 <= off < m['patch']: s += f", 0x{m['patch'] - off:x} below its patch area"
        return s, known, hit
    j = run.get('jit')
    if j and j['size'] and j['base'] <= a < j['base'] + j['size']:
        off = a - j['base']
        return (f"jit+0x{off:x}, " + ('the JIT code memory, in its served image (code made by the game\'s JIT plugin, built on the Mac)' if off < j['image']
                                      else 'the JIT code memory, past its served image (not code)'), True, 0)
    return None, False, 0


# ---------- the report ----------
def regions(info):
    """The memory region info's table rows: dicts of lo, hi, prot, type, fault (the ---> row), object (its Object_id, '' for none)"""
    out = []
    for line in info.split('\n'):
        if len(out) == 16: break
        tok = [t for t in re.split(r'[ \t]+', line) if t][:24]
        f = 1 if tok and tok[0] == '--->' else 0
        ri = next((k for k in range(f, len(tok)) if re.fullmatch(r'[0-9a-fA-F]+-[0-9a-fA-F]+', tok[k])), -1)
        prot = next((tok[k][:3] for k in range(ri + 1, len(tok)) if re.fullmatch(r'[r-][w-][x-]/[r-][w-][x-]', tok[k])), '') if ri >= 0 else ''
        if ri > f and prot:
            lo, hi = tok[ri].split('-')
            obj = next((t[10:] for t in tok[ri + 1:] if t.startswith('Object_id=')), '')
            mx = next((t[4:7] for t in tok[ri + 1:] if re.fullmatch(r'[r-][w-][x-]/[r-][w-][x-]', t)), '')
            out.append({'lo': int(lo, 16), 'hi': int(hi, 16), 'prot': prot, 'max': mx, 'type': ' '.join(tok[f:ri])[:39], 'fault': f, 'object': obj})
    return out


def zero_uuid(u):
    return all(c in '0-' for c in u)


def chain(th):
    """The frames of a thread, newest first: each frame's subFrames holds its caller"""
    roots = get(th, 'rootFrames') if has(th, 'rootFrames') else get(th, 'callStackRootFrames')
    f = roots[0] if isinstance(roots, list) and roots else ABSENT
    out = []
    while f is not ABSENT and len(out) < 1 << 20:
        out.append(f)
        sub = get(f, 'subFrames')
        f = sub[0] if isinstance(sub, list) and sub else ABSENT
    return out


def crashes(report):
    """[(diagnostic, meta, environment, time begin, time end)] of a report in either shape"""
    if not isinstance(report, dict): return []
    if 'crashDiagnostic' in report:   # MetricManager: one diagnostic per report
        c, tr = report['crashDiagnostic'], get(report, 'timeRange')
        return [(c, c, report.get('environment', ABSENT), get(tr, 'begin'), get(tr, 'end'))]
    if isinstance(report.get('crashDiagnostics'), list):   # an MXDiagnosticPayload
        return [(e, e['diagnosticMetaData'] if has(e, 'diagnosticMetaData') else e, ABSENT, report.get('timeStampBegin'), report.get('timeStampEnd')) for e in report['crashDiagnostics']]
    if 'callStackTree' in report:
        return [(report, report['diagnosticMetaData'] if 'diagnosticMetaData' in report else report, ABSENT, None, None)]
    return []


def get(o, k):
    return o.get(k) if isinstance(o, dict) else None


def report_pid(c):
    _diag, meta, env, _t0, _t1 = c
    return cint(get(env if env is not ABSENT else meta, 'pid'))


def threads_of(diag):
    tree = get(diag, 'callStackTree')
    threads = get(tree, 'callStackThreads') if has(tree, 'callStackThreads') else get(tree, 'callStacks')
    return tree, threads if isinstance(threads, list) else []


def report_when(c):
    """(lo, hi): the report's time range in unix seconds, -1 when not known (crash_summary.h dm_cs_one)"""
    w0, w1 = ctext(c[3], 64), ctext(c[4], 64)
    hi = parse_time(w1) if w1 else parse_time(w0) if w0 else -1
    return (parse_time(w0) if w0 else hi), hi


def game_addresses(c):
    _tree, threads = threads_of(c[0])
    th = next((t for t in threads if get(t, 'threadAttributed') is True), threads[0] if threads else None)
    return [cuint(get(f, 'address')) or 0 for f in chain(th) if zero_uuid(ctext(get(f, 'binaryUUID'), 48))]


def frame_text(f, info, run, rg):
    a, off = cuint(get(f, 'address')) or 0, cuint(get(f, 'offsetIntoBinaryTextSegment')) or 0
    uuid, name = ctext(get(f, 'binaryUUID'), 48), ctext(get(f, 'binaryName'), 96)
    if not name and uuid and isinstance(info, list):
        for b in info:
            if name: break
            if ctext(get(b, 'uuid'), 48) == uuid: name = ctext(get(b, 'name'), 96)
    s = f'0x{a:x} '
    if not zero_uuid(uuid): return s + (f'{name}+0x{off:x}' if name and name != '???' else f'image {uuid[:8]}+0x{off:x}'), 0
    w, known, hit = where(run, a) if run is not None else (None, False, 0)
    s += w if w else 'game code in no module of the run' if run is not None else 'game code'
    if not known:
        for r in rg:
            if r['lo'] <= a < r['hi']:
                s += f", in the report's region 0x{r['lo']:x}-0x{r['hi']:x} {r['prot']} {r['type']}{'' if r['prot'][2] == 'x' else ' (not executable)'}"
                break
    return s, hit


def summary(c, lay_text, layout=None):
    """The lines of one crash, as the app logs them; layout: (line, run) for a layout found another way than run_layouts.txt (log.txt, inferred)"""
    diag, meta, env, t0, t1 = c
    out, parts = [], []
    et, ec, sg = cint(get(meta, 'exceptionType')), cint(get(meta, 'exceptionCode')), cint(get(meta, 'signal'))
    if et is not None: parts.append(f'{exc_name(et)} ({et})' if exc_name(et) else f'exception type {et}')
    if ec is not None:
        nm = code_name(et, ec) if et is not None else None
        parts.append((', ' if parts else '') + (f'{nm} ({ec})' if nm else f'code 0x{ec % (1 << 64):x}'))
    line = ''.join(parts)
    if sg is not None: line += ('; ' if line else '') + (f'signal {signal_name(sg)} ({sg})' if signal_name(sg) else f'signal {sg}')
    term = ctext(get(meta, 'terminationReason'), 512)
    if term:
        hint = term_hint(term)
        line += ('; ' if line else '') + f'termination reason {term}' + (f' ({hint})' if hint else '')
    out.append(line or 'the report names no exception, signal or termination reason')
    why = get(meta, 'exceptionReason')
    if isinstance(why, dict):
        v = ctext(why.get('composedMessage'), 128) or ctext(why.get('exceptionName'), 128)
        if v: out.append(f'exception reason: {v}')
    info = ctext(get(meta, 'virtualMemoryRegionInfo'), 8192)
    rg = regions(info) if info else []
    shown = 0
    for raw in info.split('\n') if info else []:
        if shown == 5: break
        t = re.sub(' +', ' ', raw.replace('\t', ' ')).strip(' ')[:419]
        if t: out.append(f'memory: {t}'); shown += 1
    src = env if env is not ABSENT else meta
    pid = cint(get(src, 'pid'))
    run_parts = []
    if pid is not None: run_parts.append(f'pid {pid}')
    v = ctext(get(src, 'applicationBuildVersion' if env is not ABSENT else 'appBuildVersion'), 128)
    if v: run_parts.append(f'app build {v}')
    v = ctext(get(src, 'deviceType'), 128)
    if v: run_parts.append(v)
    osv = get(src, 'osVersion')
    if isinstance(osv, str) and ctext(osv, 128): run_parts.append(ctext(osv, 128))
    elif isinstance(osv, dict) and ctext(osv.get('number'), 128):
        bn = ctext(osv.get('buildNumber'), 64)
        run_parts.append(f"{ctext(osv.get('platform'), 64) or 'iOS'} {ctext(osv.get('number'), 128)}" + (f' ({bn})' if bn else ''))
    w0, w1 = ctext(t0, 64), ctext(t1, 64)
    if w0 and w1 and w0 != w1: run_parts.append(f'between {w0} and {w1}')
    elif w0 or w1: run_parts.append(f'at {w1 or w0}')
    out.append('run: ' + (', '.join(run_parts) or 'the report names no pid, build or time'))
    lo, hi = report_when(c)
    rec = None
    if layout is not None: out.append(layout[0]); rec = layout[1]
    elif pid is None: out.append("layout: the report names no pid, so no run's record can be matched: game frames are raw addresses")
    elif lay_text is None: out.append('layout: no run_layouts.txt (a build from before it, or it could not be read): game frames are raw addresses')
    else:
        runs = parse_layouts(lay_text)
        rec, later = find_run(runs, pid, lo, hi)
        if rec is not None and later is None:
            out.append(f"layout: the run's record in run_layouts.txt: started {rec['utc'] or '-'}, commit {rec['commit'] or '-'}, title {rec['title'] or '-'}, "
                       f"switchable mods on: {role_label(rec['mods'])}")
        elif rec is not None:
            out.append(f"layout: run_layouts.txt's record of pid {pid} is of an earlier run (started {rec['utc'] or '-'}): pid {later} started after it, before the crash, so the "
                       'crashed run left no record (it ended before writing one, or the write failed): game frames are raw addresses')
            rec = None
        else:
            pids = ', '.join(str(r['pid']) for r in runs[-KEEP * 4:])
            out.append(f'layout: run_layouts.txt has no record of pid {pid} (it holds the runs of pids {pids or "none"}): game frames are raw addresses')
    tree, threads = threads_of(diag)
    pick = next((i for i, t in enumerate(threads) if get(t, 'threadAttributed') is True), -1)
    th = threads[pick] if pick >= 0 else threads[0] if threads else None
    frames, info_list = chain(th), get(tree, 'binaryInfo')
    if not frames: out.append('the report has no call stack')
    elif pick >= 0: out.append(f"crashed thread (the report's thread {pick} of {len(threads)}), newest frame first:")
    else: out.append(f"no thread is marked as the crashed one; the report's first thread of {len(threads)}, newest frame first:")
    hit_roles, hits, nhits = 0, [], 0
    for k, f in enumerate(frames):
        s, hit = frame_text(f, info_list, rec, rg)
        if hit:
            hit_roles |= hit; nhits += 1
            if len(hits) < 4: hits.append(k)
        if k < FRAMES: out.append(f'#{k} {s}')
    if len(frames) > FRAMES:
        out.append(f'... {len(frames) - FRAMES} more frames; the oldest, #{len(frames) - 1}: {frame_text(frames[-1], info_list, rec, rg)[0]}')
    if rec is not None and rec['pieces']:
        groups, all_ = [], 0
        for roles in (1, 2, 3):
            ps = [p for p in rec['pieces'] if (p['roles'] or 3) == roles]
            if not ps: continue
            all_ |= roles
            items = [f"{p['module']} {'code page' if p['code'] else 'data'} {'' if p['off'] < 0 else '+'}{shex(p['off'])}" + ('' if p['code'] else f" ({p['len']} bytes)") for p in ps[:4]]
            groups.append(f"{role_label(roles)}: {len(ps)} piece{'' if len(ps) == 1 else 's'} (" + ', '.join(items) + (', ...' if len(ps) > 4 else '') + ')')
        if not nhits: fr = 'no frame of the crashed thread is in them'
        else: fr = f"frame{'s' if nhits > 1 else ''} " + ', '.join(f'#{h}' for h in hits) + (f' and {nhits - len(hits)} more' if nhits > len(hits) else '') + f" {'are' if nhits > 1 else 'is'} in them"
        off = hit_roles or all_
        out.append(f"switchable mods in place in that run: {'; '.join(groups)}; {fr}. Turning {role_label(off)} off in the launcher is the first thing to try"
                   + (' (one at a time, to tell which)' if off == 3 else ''))
    elif rec is not None and rec['mods']:
        out.append(f"switchable mods turned on in that run ({role_label(rec['mods'])}), but none of their pieces was put in place")
    return out


def summary_lines(report, lay_text):
    """Every crash of a report, as log.txt has them (crash_summary.h dm_crash_summary)"""
    cs, out = crashes(report), []
    for i, c in enumerate(cs):
        if len(cs) > 1 and 'crashDiagnostics' in report: out.append(f'crash {i + 1} of {len(cs)} in this report:')
        out += summary(c, lay_text)
    return out


# ---------- a layout from log.txt, or inferred ----------
def parse_log(text):
    """The modules of a log.txt's run, by its 'base' and 'gates ... patch_off' lines (with key_page and text_end from builds that log them): (pid or None, modules, switchable mods put
    in place [(module, roles text, pieces)], commit, the JIT code memory or None)"""
    mods, order, placed, pid, commit, jit = {}, [], [], None, '', None
    for line in text.splitlines():
        line = line.removeprefix('[dm] ')
        m = re.match(r'(\S+): gates \d+ patch_off (0x[0-9a-f]+)(?: keys \S+ key_page (0x[0-9a-f]+) text_end (0x[0-9a-f]+))?', line)
        if m:
            v, d = int(m.group(2), 16), mods.setdefault(m.group(1), {})
            d['patch'] = v - (1 << 64) if v >= 1 << 63 else v
            if m.group(3): d['key'], d['text_end'] = int(m.group(3), 16), int(m.group(4), 16)
            continue
        m = re.match(r'(\S+): base (0x[0-9a-f]+) size (0x[0-9a-f]+)$', line)
        if m:
            d = mods.setdefault(m.group(1), {}); d['base'], d['size'] = int(m.group(2), 16), int(m.group(3), 16)
            if m.group(1) not in order: order.append(m.group(1))
            continue
        m = re.match(r'(\S+): switchable mods put in place: (.*) \((\d+) pieces\)', line)
        if m: placed.append((m.group(1), m.group(2), int(m.group(3)))); continue
        m = re.match(r'run layout: pid (\d+)', line)
        if m: pid = int(m.group(1)); continue
        m = re.match(r"jit::CreateJitEnvironment: served from .*: code memory (0x[0-9a-f]+) \+ (0x[0-9a-f]+) \(the image's first (0x[0-9a-f]+) bytes\)", line)
        if m: jit = {'base': int(m.group(1), 16), 'size': int(m.group(2), 16), 'image': int(m.group(3), 16)}; continue
        m = re.match(r'build: commit (\S+?),', line)
        if m: commit = m.group(1)
    out = []
    for n in order:
        d = mods[n]
        p = d.get('patch', 0)
        out.append({'name': n, 'build': '', 'base': d['base'], 'size': d['size'], 'text_end': d.get('text_end', 0), 'key': d.get('key', 0), 'fps': 0, 'back': 0, 'back_len': 0,
                    'patch_len': d['size'] - p if p > 0 else -p, 'patch': p, 'nro': 0})   # a patch area before the base: the log gives no length, so all of it up to the base
    return pid, out, placed, commit, jit


def fits(modules, addrs, delta=0, jit=None):
    """How many of the game frames fall in the modules (and the JIT code memory) moved by delta"""
    def inside(a):
        return any(m['base'] + delta + min(0, m['patch']) <= a < m['base'] + delta + m['size'] for m in modules) or bool(jit and 0 <= a - jit['base'] - delta < jit['size'])
    return sum(1 for a in addrs if inside(a))


def is_key_row(r):
    """A module's key page as the report lists it: 16 KB, read-only, writable at most (loader.c install_key_page makes it read-only)"""
    return r['hi'] - r['lo'] == PAGE and r['prot'] == 'r--' and 'w' in r['max']


def spans(rows):
    """The report's rows with consecutive rows of one object (the same Object_id) joined: lo, hi, object, w (any of them writable), rows, next (the row right after it, when the
    report lists it)"""
    out = []
    for r in rows:
        if out and r['object'] and out[-1]['object'] == r['object'] and out[-1]['hi'] == r['lo']:
            s = out[-1]; s['hi'] = r['hi']; s['w'] |= 'w' in r['prot'] + r['max']; s['rows'].append(r)
        else: out.append({'lo': r['lo'], 'hi': r['hi'], 'object': r['object'], 'w': 'w' in r['prot'] + r['max'], 'rows': [r], 'next': None})
    for x, y in zip(out, out[1:]):
        if y['lo'] == x['hi']: x['next'] = y['rows'][0]
    return out


def anchors(m, rows):
    """Where module m (another run's layout: its size and patch_off, its key page and text end when known) has its base in the report's run, by the report's memory rows (the
    faulting address's region and one neighbour on each side): [(base, exact, other possible bases, reason)]. On the iPhone a module is its text (r-x), then its writable part
    (one mapping up to the patch area, the key page in it read-only), then its patch area (r-x) when that follows the image (loader.c map_image)"""
    out, name = [], m['name']
    for i, r in enumerate(rows):
        prev = rows[i - 1] if i and rows[i - 1]['hi'] == r['lo'] else None
        if m['key'] and is_key_row(r):
            out.append((r['lo'] - m['key'], True, (), f"the report's 16 KB read-only row 0x{r['lo']:x}-0x{r['hi']:x} is {name}'s key page ({shex(m['key'])} from its base)"))
        if m['text_end'] and 'w' in r['prot'] and prev is not None and prev['prot'] == 'r-x':
            t = page_up(m['text_end'])
            out.append((r['lo'] - t, True, (), f"the report's writable row 0x{r['lo']:x}-0x{r['hi']:x} begins where {name}'s text ends ({shex(t)} from its base)"))
    if m['patch'] > 0:
        for s in spans(rows):
            if not s['w']: continue
            n, b = s['next'], s['hi'] - m['patch']
            if n is not None and ('x' in n['prot'] or (s['object'] and n['object'] and n['object'] != s['object'])):
                out.append((b, True, (), f"the report's writable region 0x{s['lo']:x}-0x{s['hi']:x} ends where {name}'s patch area begins ({shex(m['patch'])} from its base)"))
            elif n is None and is_key_row(s['rows'][-1]):   # the writable part may go on past the key page, up to 0xc000 (patch_nso.py puts the patch area on a 64 KB boundary)
                out.append((b, False, (b + 0x4000, b + 0x8000, b + 0xc000),
                            f"the report's writable region 0x{s['lo']:x}-0x{s['hi']:x} ends with {name}'s key page (its 16 KB read-only row) and {name}'s patch area begins "
                            f"{shex(m['patch'])} from its base, if the patch area follows the key page directly; the report lists nothing after the key page, and writable pages "
                            f"between the two (an image that does not end in the last 16 KB of a 64 KB block) would put {name} at 0x{b + 0x4000:x}, 0x{b + 0x8000:x} or "
                            f"0x{b + 0xc000:x}, making each offset below 0x4000 to 0xc000 smaller"))
    return [x for x in out if x[0] > 0 and x[0] % PAGE == 0]


def contradiction(modules, rows, delta=0):
    """The first of the report's memory rows that the modules' layout, moved by delta, cannot have (a writable row in a module's text or patch area, an executable one in its
    writable part, a key page that is not read-only, a row across a module's base), as text; None when the rows agree with it"""
    def bad(r, lo, hi, what, ok):
        return f"its {r['prot']} row 0x{r['lo']:x}-0x{r['hi']:x} would be in {what}" if r['lo'] < hi and lo < r['hi'] and not ok(r['prot']) else None
    for m in modules:
        b, name = m['base'] + delta, m['name']
        te = page_up(m['text_end']) if m['text_end'] else PAGE   # a module's first page is text
        parts = [(b, b + te, f"{name}'s text", lambda p: p == 'r-x')]
        if m['patch'] > 0: parts.append((b + m['patch'], b + m['size'], f"{name}'s patch area", lambda p: p == 'r-x'))
        else: parts.append((b + m['patch'], b + m['patch'] + m['patch_len'], f"{name}'s patch area", lambda p: p == 'r-x'))
        if m['text_end'] and m['patch'] > 0: parts.append((b + te, b + m['patch'], f"{name}'s writable part", lambda p: 'x' not in p))
        if m['key']: parts.append((b + m['key'], b + m['key'] + PAGE, f"{name}'s key page", lambda p: p == 'r--'))
        for r in rows:
            if m['patch'] > 0 and r['lo'] < b < r['hi']: return f"its {r['prot']} row 0x{r['lo']:x}-0x{r['hi']:x} would run across {name}'s base"
            for part in parts:
                why = bad(r, *part)
                if why: return why
    return None


def fill_from_rows(m, rows):
    """A moved module's text end and key page, when its layout lacks them, from the report's rows inside it: a writable row right after an executable one starts the writable part,
    a 16 KB read-only row in it is the key page"""
    end = m['base'] + (m['patch'] if m['patch'] > 0 else m['size'])
    for i, r in enumerate(rows):
        if not m['base'] <= r['lo'] < end: continue
        prev = rows[i - 1] if i and rows[i - 1]['hi'] == r['lo'] else None
        if not m['text_end'] and 'w' in r['prot'] and prev is not None and prev['prot'] == 'r-x' and prev['lo'] >= m['base']: m['text_end'] = r['lo'] - m['base']
        if not m['key'] and is_key_row(r): m['key'] = r['lo'] - m['base']


def infer(modules, info, addrs, jit=None):
    """The layout of the report's run from another run's: {'run', 'text', 'delta', 'exact'} by the anchor (anchors) whose layout fits the most game frames, exact anchors first among
    equals, with the other modules moved with it; None when no anchor gives a layout that fits a game frame and that the report's rows do not contradict"""
    rows, best = regions(info), None
    for m in modules:
        for b, exact, alts, why in anchors(m, rows):
            delta = b - m['base']
            if contradiction(modules, rows, delta) is not None: continue
            score = fits(modules, addrs, delta, jit)
            if score and (best is None or (score, exact) > best[0]): best = ((score, exact), m, b, exact, alts, why, delta)
    if best is None: return None
    (score, _), m0, b, exact, _alts, why, delta = best
    also = [w for m in modules for bb, ex, _a, w in anchors(m, rows) if exact and ex and bb - m['base'] == delta and w != why][:1]   # another exact anchor that agrees
    run = {'pid': -1, 'start': 0, 'utc': '', 'commit': '', 'title': '', 'mods': 0, 'pieces': [], 'modules': [], 'jit': dict(jit, base=jit['base'] + delta) if jit else None}
    for m in modules:
        n = dict(m); n['base'] = m['base'] + delta
        fill_from_rows(n, rows)
        run['modules'].append(n)
    text = (f"{m0['name']} at 0x{b:x}, because {why}" + ''.join(f', and {w}' for w in also)
            + f"; the other modules moved with it ({shex(delta)}); {score} of {len(addrs)} game frames fall in them")
    return {'run': run, 'text': text, 'delta': delta, 'exact': exact}


def records_run(runs, title=''):
    """A run of run_layouts.txt to take the module layout from when the crashed run has none: the newest (of the same title when it is known)"""
    same = [r for r in runs if not title or r['title'] == title]
    return same[-1] if same else runs[-1] if runs else None


def layout_for(c, text, kind, name):
    """(line, run) for a crash by a log.txt or another run's record (kind 'log' / 'record'), or None to leave it to run_layouts.txt's own lines"""
    pid, info, addrs = report_pid(c), ctext(get(c[1], 'virtualMemoryRegionInfo'), 8192), game_addresses(c)
    if kind == 'record':
        runs = parse_layouts(text)
        rec, later = find_run(runs, pid, *report_when(c)) if pid is not None else (None, None)
        if rec is not None and later is None: return None   # the record has the run: the app's own lines
        other = records_run(runs)
        if other is None: return None
        got = infer(other['modules'], info, addrs, other['jit'])
        if got is None: return None
        why = ('the report names no pid' if pid is None else f"{name}'s record of pid {pid} is of an earlier run (pid {later} started after it, before the crash)"
               if rec is not None else f'{name} has no record of pid {pid}')
        return (f"layout: inferred, not recorded: {why}; from the module layout of its run of pid {other['pid']} (started {other['utc'] or '-'}, commit {other['commit'] or '-'}): "
                f"{got['text']}", got['run'])
    lpid, modules, placed, commit, jit = parse_log(text)
    if not modules: return (f"layout: {name} has no module 'base' lines: game frames are raw addresses", None)
    run = {'pid': lpid if lpid is not None else -1, 'start': 0, 'utc': '', 'commit': commit, 'title': '', 'mods': 0, 'pieces': [], 'modules': modules, 'jit': jit}
    said = '; '.join(f'{m}: {r} ({n} pieces)' for m, r, n in placed)
    mods_note = f"; that log's run had switchable mods in place: {said}" if said else ''
    ends = all(m['text_end'] for m in modules)
    if lpid is not None and lpid == pid:
        return (f"layout: {name} of that run (pid {pid}): bases from its 'base' lines" + ('' if ends else ', which give no text ends') + mods_note, run)
    rows = regions(info)
    bad, n_fit, got = contradiction(modules, rows), fits(modules, addrs, 0, jit), infer(modules, info, addrs, jit)
    if lpid is None and addrs and n_fit == len(addrs) and bad is None and not (got and got['exact'] and got['delta']):
        lead = (f"layout: {name} names no pid; its 'base' lines fit every game frame and the report's memory regions confirm them" if got and got['exact'] else
                f"layout: assumed, not recorded: {name} names no pid; its 'base' lines fit every game frame and the report's memory regions do not contradict them, so they are taken "
                "as that run's")
        return (lead + ('' if ends else ' (no text ends)') + mods_note, run)
    why = (f'it is the log of pid {lpid}' if lpid is not None else f"its bases contradict the report's memory regions: {bad}" if bad
           else f'its bases fit {n_fit} of {len(addrs)} game frames' if n_fit != len(addrs) else "the report's memory regions place its modules elsewhere")
    if got is None:
        return (f"layout: {name} is of another run ({why}), and no base could be inferred from the report's memory regions" + ('' if ends else " (its 'gates' lines give no key "
                "pages or text ends, which a later build logs)") + ': game frames are raw addresses', None)
    return (f"layout: inferred, not recorded: {name} is of another run ({why}); from its modules' sizes and patch_off" + (', key pages and text ends' if ends else '') + f": {got['text']}"
            + (f"; the log's run had switchable mods in place ({said}), whether the crashed run did is not known" if said else ''), got['run'])


NO_LAYOUT = ("layout: no run_layouts.txt or log.txt given or found beside the report: game frames are raw addresses (no base can be inferred without a module's patch_off: give "
             "run_layouts.txt, or the log.txt of any start of the same build)")


def main(argv):
    if not 1 <= len(argv) <= 2 or argv[0] in ('-h', '--help'):
        print('usage: python3 scripts/crashlog.py CRASH.json [run_layouts.txt | log.txt]: the crash summary of an iPhone or iPad crash report (Documents/metrics)', file=sys.stderr)
        return 2
    rp = Path(argv[0])
    try: report = json.loads(rp.read_text(encoding='utf-8'), parse_float=real)
    except RecursionError: print(f"[RED] crashlog: {rp} is nested deeper than Python's JSON reader goes", file=sys.stderr); return 1
    except (OSError, UnicodeDecodeError, ValueError) as e: print(f'[RED] crashlog: {rp} cannot be read as JSON: {e}', file=sys.stderr); return 1
    cs = crashes(report)
    if not cs: print(f'[RED] crashlog: {rp} holds no crash diagnostic', file=sys.stderr); return 1
    given = Path(argv[1]) if len(argv) == 2 else None
    found = [given] if given else [d / n for d in (rp.parent, rp.parent.parent) for n in ('run_layouts.txt', 'log.prev.txt', 'log.txt')]
    src, text, kind = None, None, None
    for p in found:
        try: t = p.read_text(encoding='utf-8', errors='replace')
        except OSError:
            if given: print(f'[RED] crashlog: {p} cannot be read', file=sys.stderr); return 1
            continue
        k = 'record' if re.search(r'(?m)^run pid=', t) else 'log' if re.search(r'(?m)^(\[dm\] )?\S+: base 0x[0-9a-f]+ size ', t) else None
        if k is None:
            if given: print(f'[RED] crashlog: {p} is neither a run_layouts.txt nor a log.txt with module base lines', file=sys.stderr); return 1
            continue
        src, text, kind = p, t, k
        break
    print(f'crash report {rp}' + (f', layout from {src}' + ('' if given else ' (found beside the report)') if src else ', no run_layouts.txt or log.txt given or found beside it'))
    for i, c in enumerate(cs):
        if len(cs) > 1 and 'crashDiagnostics' in report: print(f'crash {i + 1} of {len(cs)} in this report:')
        lay = layout_for(c, text, kind, src.name) if src and text is not None and kind else (NO_LAYOUT, None)
        print('\n'.join(summary(c, text if kind == 'record' else None, lay)))
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
