"""DM_SIGNPOST's Instruments lanes (dm/host/dm_signpost.h), checked in the sources: the names the code emits are exactly docs/development.md's table, each interval begins and ends
in the same category, names and formats are string literals, no macro argument has a side effect (off, the arguments are not evaluated, so one would make the game run differently
with the switch on), and the switch is read once, in host_preload, before any thread that emits.

The macros themselves (only DM_SIGNPOST=1 turns them on; off, no os_signpost call and no argument evaluated) run in dm/host/tests/t_signpost.c (make signpost)."""
from pathlib import Path
import re
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[3]
CATEGORY = {'DM_SP_POI': 'PointsOfInterest', 'DM_SP_FRAME': 'Frame', 'DM_SP_GPU': 'GPU', 'DM_SP_DISPLAY': 'Display', 'DM_SP_SHADERS': 'Shaders'}


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def call_args(src, start):
    """The text between the parentheses that open at src[start], strings skipped"""
    depth, i, q = 0, start, None
    while i < len(src):
        c = src[i]
        if q:
            if c == '\\': i += 1
            elif c == q: q = None
        elif c in '"\'': q = c
        elif c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if not depth: return src[start + 1:i]
        i += 1
    raise AssertionError('unbalanced call at %d' % start)


def split_args(text):
    out, depth, cur, q, i = [], 0, '', None, 0
    while i < len(text):
        c = text[i]
        if q:
            cur += c
            if c == '\\': cur += text[i + 1]; i += 1
            elif c == q: q = None
        elif c in '"\'': q = c; cur += c
        elif c in '([{': depth += 1; cur += c
        elif c in ')]}': depth -= 1; cur += c
        elif c == ',' and not depth: out.append(cur.strip()); cur = ''
        else: cur += c
        i += 1
    out.append(cur.strip())
    return out


def sources():
    files = subprocess.run(['git', 'ls-files', 'dm'], cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
    return [f for f in files if f.endswith(('.c', '.m', '.h', '.inc')) and '/tests/' not in f and f != 'dm/host/dm_signpost.h' and (REPO / f).is_file()]


def uses():
    """[(file, kind, category, name, args)] for every DM_SP_BEGIN / END / EVENT in the shipped sources"""
    out = []
    for f in sources():
        src = read(f)
        for m in re.finditer(r'\bDM_SP_(BEGIN|END|EVENT)\s*(?=\()', src):
            a = split_args(call_args(src, m.end()))
            out.append((f, m.group(1), a[0], a[1], a))
    return out


def table():
    """{name: (category, kind)} from the table in docs/development.md's Instruments lanes section"""
    doc = read('docs/development.md')
    sec = doc[doc.index('### Instruments lanes (`DM_SIGNPOST`)'):]
    sec = sec[:sec.index('\n### ', 5)]
    return {m.group(1): (m.group(2), m.group(3)) for m in re.finditer(r'^\| `([a-z-]+)` \| (\w+) \| (interval|event) \|', sec, re.M)}


class Wiring(unittest.TestCase):
    def setUp(self):
        self.uses = uses(); self.table = table(); self.hdr = read('dm/host/dm_signpost.h')

    def test_there_are_lanes_to_check(self):
        self.assertGreater(len(self.uses), 40); self.assertEqual(len(self.table), 22)

    def test_names_and_formats_are_literals_of_a_known_category(self):
        for f, kind, cat, name, a in self.uses:
            with self.subTest(f=f, name=name):
                self.assertIn(cat, CATEGORY)
                self.assertRegex(name, r'^"[a-z-]+"$')
                fmt = a[3] if kind != 'EVENT' else a[2]
                self.assertRegex(fmt, r'^"[^"]*"$', 'the format must be one string literal')

    def test_the_sources_emit_exactly_the_documented_names(self):
        seen = {}
        for f, kind, cat, name, a in self.uses:
            n = name.strip('"'); want = (CATEGORY[cat], 'event' if kind == 'EVENT' else 'interval')
            self.assertIn(n, self.table, f'{f}: {n} is not in docs/development.md')
            self.assertEqual(self.table[n], want, f'{f}: {n}')
            seen.setdefault(n, set()).add(kind)
        self.assertEqual(set(seen), set(self.table), 'a documented name nothing emits')
        for n, kinds in seen.items():
            if self.table[n][1] == 'interval': self.assertEqual(kinds, {'BEGIN', 'END'}, f'{n} needs both a begin and an end')

    def test_no_argument_has_a_side_effect(self):   # off, the arguments are not evaluated
        bad = re.compile(r'\+\+|--|(?<![=!<>])=(?!=)|_take\s*\(|atomic_(exchange|fetch|store|compare)|\bside\(')
        for f, kind, cat, name, a in self.uses:
            for arg in a[2:]:
                plain = re.sub(r'"(\\.|[^"\\])*"', '""', arg)
                with self.subTest(f=f, name=name, arg=arg): self.assertNotRegex(plain, bad)

    def test_on_the_lanes_ask_nothing_again_and_hold_no_lock_the_game_takes(self):   # on, a site must not call state-changing or locking code a second time, nor emit under a lock
        for f in sources():
            for ln in read(f).splitlines():
                m = re.search(r'\bDM_SP_(BEGIN|END|EVENT)\s*\(', ln)
                if m:
                    with self.subTest(f=f, line=ln.strip()[:80]): self.assertNotIn('pthread_mutex_unlock(', ln[m.start():], 'emitted with a lock held: emit after the unlock')
        nvn = read('dm/gfx/nvn/hle_nvn.c')
        hold = [ln for ln in nvn.splitlines() if '"hold"' in ln]
        self.assertEqual(len(hold), 1)
        self.assertNotIn('present_itv(', hold[0], 'present_itv takes thermal_capped\'s lock and samples the heat state: reuse the value g_hold_ring stores')
        self.assertIn('int itv = present_itv(o); g_hold_ring[o->presents % 16] = (uint8_t)itv;', nvn)
        mtl = read('dm/gfx/nvn/nvn_mtl.m')
        self.assertGreater(mtl.index('DM_SP_END(DM_SP_GPU, "gpu-present"'), mtl.index('present_gpu_note(f.GPUEndTime - f.GPUStartTime, fx_kind); pthread_mutex_unlock(&g_pq_mu);'),
                           'the gpu-present handler goes after the one that releases the ticket the game\'s acquire waits for')

    def test_categories_and_subsystem_agree_with_the_docs(self):
        self.assertIn('enum { DM_SP_POI, DM_SP_FRAME, DM_SP_GPU, DM_SP_DISPLAY, DM_SP_SHADERS, DM_SP_NLOG };', self.hdr)
        self.assertIn('{OS_LOG_CATEGORY_POINTS_OF_INTEREST, "Frame", "GPU", "Display", "Shaders"}', self.hdr)   # in the enum's order
        self.assertIn('#define DM_SP_SUBSYSTEM "org.nintanium.host"', self.hdr)
        doc = read('docs/development.md')
        self.assertIn('subsystem `org.nintanium.host`', doc)
        self.assertIn('subsystem `org.nintanium.host`; categories PointsOfInterest, Frame, GPU, Display, Shaders', read('docs/env_switches.tsv'))

    def test_only_the_exact_value_1_turns_it_on_and_off_costs_a_branch(self):
        self.assertIn("return v && v[0] == '1' && !v[1];", self.hdr)
        self.assertIn('dm_sp_env_on(getenv("DM_SIGNPOST"))', self.hdr)
        self.assertIn('#define DM_SP_ON() __builtin_expect(dm_sp.on, 0)', self.hdr)
        for m in ('BEGIN', 'END', 'EVENT'): self.assertRegex(self.hdr, r'#define DM_SP_%s\(c, [^)]*\) do \{ if \(DM_SP_ON\(\)\) os_signpost_' % m)
        self.assertIn('#define DM_SP_ID(c) (DM_SP_ON() ? os_signpost_id_generate(DM_SP_LOG(c)) : OS_SIGNPOST_ID_NULL)', self.hdr)

    def test_the_switch_is_read_once_in_host_preload(self):
        main = read('dm/host/main.c')
        pre = main[main.index('static void host_preload(int argc, char **argv) {'):]
        self.assertRegex(pre, r'^static void host_preload\(int argc, char \*\*argv\) \{\n    g_t0_ns = proc_start_mono_ns\(\);\n    flags_init\(\);\n    if \(dm_sp_init\(\)\) LOG\(')
        callers = [f for f in sources() if 'dm_sp_init(' in read(f)]
        self.assertEqual(callers, ['dm/host/main.c'])

    def test_builds_and_tests_know_the_header(self):
        self.assertRegex(read('dm/host/Makefile'), r'\ndmhost: [^\n]* dm_signpost\.h ')
        mk = read('dm/host/tests/Makefile')
        run = mk[mk.index('\nrun: '):mk.index('\nrun: ', mk.index('\nrun: ') + 1) + 1]
        for t in ('t_signpost_stub', 't_signpost_none', 't_signpost'): self.assertIn(f'\t$(B)/{t}\n', run)
        self.assertIn('-DT_SP_STUB -Isignpost_stub', mk)
        self.assertIn('-DDM_SP_NONE', mk)


if __name__ == '__main__':
    unittest.main()
