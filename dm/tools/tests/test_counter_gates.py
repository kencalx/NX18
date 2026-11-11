"""The counter-timer reads the rewriter sends to the host gate (patch_nso.py) and the gate kinds the host knows (hle.c gate_register): every kind one emits the other takes,
and mrs cntpct_el0 / cntvct_el0 / cntfrq_el0 are each classified, cntfrq_el0 returning the guest's frequency (19.2 MHz, 31.25 MHz for the Switch 2), not the host's register
(unless DM_CNTFRQ=0). The real rewriter's blocks for these reads are run instruction by instruction against a model of dm_gate (entry.S), which writes back x0..x28 but not
x18, and of gate_dispatch, which writes a read into x18 into thread slot K18, the guest's x18. The rewriter without its cntfrq rule (as before it) rewrites a module without
mrs cntfrq_el0, or with mrs x18, cntfrq_el0 only in an exclusive window, to the same bytes"""
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))   # its sibling test module, also when the file runs alone (python -m unittest <file>, as CI does)
from test_nso_match import image, RET   # noqa: E402

REPO = Path(__file__).resolve().parents[3]
PATCH = (REPO / 'dm/tools/patch_nso.py').read_text()
HLE = (REPO / 'dm/host/hle.c').read_text()


class CounterGates(unittest.TestCase):
    def test_every_gate_kind_the_rewriter_emits_is_known_to_the_host(self):
        emitted = set(re.findall(r"site_gate\(ins, '(\w+)'", PATCH))
        for group in re.findall(r"elif k in \(([^)]*)\): st = site_gate\(ins, k", PATCH):
            emitted |= set(re.findall(r"'(\w+)'", group))
        known = set(re.findall(r'!strcmp\(kind, "(\w+)"\)', HLE))
        self.assertTrue({'svc', 'cntpct', 'cntvct', 'cntfrq'} <= emitted, emitted)
        self.assertEqual(emitted - known, set(), 'a gate kind the host would refuse at load ("unknown gate kind")')

    def test_the_frequency_is_the_guests(self):
        case = HLE[HLE.index('case G_CNTFRQ:'):]
        case = case[:case.index('}')]
        self.assertIn('cntfrq_value()', case); self.assertIn('pthread_setspecific(g_key18', case, 'a read into x18 reaches thread slot K18')
        value = HLE[HLE.index('static uint64_t cntfrq_value(void)'):]
        value = value[:value.index('\n}\n')]
        self.assertIn('dm_sdk_ounce() ? 31250000 : 19200000', value)
        self.assertIn('getenv("DM_CNTFRQ")', value, "the switch back to the host's register")
        self.assertIn('guest_ns() / 32 : guest_ns() * 12 / 625', (REPO / 'dm/host/hle_os.c').read_text(), 'the ticks the frequency describes: 31.25 MHz and 19.2 MHz')


# The module: one function of the reads, at 0x100
SITES = {0x100: (0xD53BE032, 'cntpct'),   # mrs x18, cntpct_el0
         0x104: (0xD53BE052, 'cntvct'),   # mrs x18, cntvct_el0
         0x108: (0xD53BE012, 'cntfrq'),   # mrs x18, cntfrq_el0
         0x10c: (0xD53BE000, 'cntfrq'),   # mrs x0, cntfrq_el0
         0x110: (0xD53BE023, 'cntpct'),   # mrs x3, cntpct_el0
         0x114: (0xD4000241, 'svc')}      # svc #0x12: an SVC number, not a register
TICKS, FREQ, HOST_FREQ, SVC_RESULT = 0x123456789, 19200000, 1000000000, 0x5e   # HOST_FREQ: CNTFRQ_EL0 as a development Mac read it (dm/gfx/nvn/nvn_entry.S)
TSD, GATE, STALE, HOST_X18 = 0x200000, 0x7000000, 0x5151, 0xAAAA   # Apple's tpidrro_el0, the thread's gate stub, the guest's x18 before the read, Apple's platform register
KEYS = {'K18': 200, 'KTLS': 201, 'KTLR': 202, 'KGATE': 203}   # the thread slots the loader claimed (any numbers: the key page holds number × 8)


def sx(v, bits): return v - (1 << bits) if v >> (bits - 1) & 1 else v


def nro(words):   # one function at 0x100, in an NRO as test_nro_header.py makes it
    raw = image({0x100: words + [RET]})
    raw[0x1100:0x111c] = raw[0x20:0x3c]
    struct.pack_into('<I', raw, 4, 0x1100)
    struct.pack_into('<ii', raw, 0x1110, 0x3000 - 0x1100, 0x3014 - 0x1100)
    raw[0x10:0x14] = b'NRO0'
    struct.pack_into('<I', raw, 0x18, len(raw))
    struct.pack_into('<6I', raw, 0x20, 0, 0x1000, 0x1000, 0x2000, 0x3000, 0x1000)
    return raw


# The rewriter before its cntfrq rule: mrs xN, cntfrq_el0 stayed in place, mrs x18, cntfrq_el0 was an x18 site, and the functions analysed for x18 sites those that hold one
BEFORE = (("if w & 0xFFFFFFE0 == 0xD53BE000: kinds[o] = ('cntfrq', w & 31); continue", "pass"),
          ("is18 = lambda k, arg: k == 'x18' or (k, arg) == ('cntfrq', 18)", "is18 = lambda k, arg: k == 'x18'"))


def rewrite(raw, before=False):
    """patch_nso.py on the NRO raw (with before, its source with BEFORE applied, run as the file itself) → {output file: bytes}"""
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / 'input.nro'; src.write_bytes(raw)
        tool = [str(REPO / 'dm/tools/patch_nso.py')]
        if before:
            code = (REPO / 'dm/tools/patch_nso.py').read_text()
            for a, b in BEFORE:
                assert code.count(a) == 1, f'the rule this test puts back moved: {a}'
                code = code.replace(a, b)
            (Path(tmp) / 'before.py').write_text(code)
            tool = ['-c', "import os, sys, __main__ as m; m.__file__, f = sys.argv[1:3]; sys.argv = [m.__file__] + sys.argv[3:]; sys.path[0] = os.path.dirname(m.__file__); "
                           "exec(compile(open(f).read(), m.__file__, 'exec'), vars(m))", tool[0], str(Path(tmp) / 'before.py')]   # in __main__: the rewriter's pool pickles its functions by name
        run = subprocess.run([sys.executable, *tool, str(src), tmp, 'nro0'], env=os.environ | {'DM_GAME': '010015100B514000'}, capture_output=True, text=True)
        if run.returncode: raise AssertionError(run.stdout + run.stderr)
        return {f.name: f.read_bytes() for f in Path(tmp).iterdir() if f.name not in ('input.nro', 'before.py')}


class Rewrite(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        files = rewrite(nro([w for w, _ in SITES.values()]))
        out = lambda ext: files[f'nro0.{ext}'].decode()
        cls.code = files['nro0.patched.bin']
        cls.sites = {int(a, 16): k for a, k in (line.split('\t')[:2] for line in out('sites.tsv').splitlines())}
        cls.gates = {int(r, 16): (k, int(arg), int(o, 16)) for r, k, arg, o in (line.split('\t') for line in out('gates.tsv').splitlines())}
        fx = dict(line[2:].split('\t') for line in out('fixups.tsv').splitlines() if line.startswith('# '))
        cls.key_page = int(fx['KEY_PAGE_OFF'], 16)
        assert int(fx['PATCH_OFF'], 16) > 0   # the file holds the image and then the patch area at its offset
        cls.key_idx = {k: int(fx[f'KEY_{k}_IDX']) for k in KEYS}

    def run_site(self, a):
        """Runs the rewritten code from the site at a to a + 4. dm_gate as entry.S has it: the gate frame holds x0..x30, the handler writes regs[arg], x0..x17 and x19..x28 are read
        back (x18 is not), x29 / x30 come back as the gate block's sp and the return point; gate_dispatch writes a counter read into x18 into slot K18 (pthread_setspecific).
        → the registers, the guest's x18 (slot K18), the gates entered"""
        x = [0x1000 + i for i in range(31)]; x[18] = HOST_X18
        sp0 = sp = 0x80000
        mem = {self.key_page + 8 * self.key_idx[k]: 8 * n for k, n in KEYS.items()}
        mem[TSD + 8 * KEYS['K18']] = STALE; mem[TSD + 8 * KEYS['KGATE']] = GATE
        entered, pc = [], a
        for _ in range(200):
            if pc == a + 4: break
            if pc == GATE:
                ret = x[30]
                self.assertIn(ret, self.gates, 'the gate is entered from a return point gates.tsv names')
                kind, arg, orig = self.gates[ret]
                self.assertEqual(orig, a)
                self.assertEqual(sp % 16, 0)
                self.assertEqual(mem[sp], 0x1000 + 29, "dm_gate takes the guest's x29 from the gate block's sp (the crash backtrace walks the x29 chain)")
                regs = x[:29]
                if kind == 'svc': regs[0] = SVC_RESULT   # arg is the SVC's number
                elif arg == 18: mem[TSD + 8 * KEYS['K18']] = FREQ if kind == 'cntfrq' else TICKS   # pthread_setspecific(g_key18, ...): Apple's TSD slot of that key
                else: regs[arg] = FREQ if kind == 'cntfrq' else TICKS
                for i in range(29):
                    if i != 18: x[i] = regs[i]
                x[29], x[30] = sp, ret
                entered.append((kind, arg)); pc = ret; continue
            w = struct.unpack_from('<I', self.code, pc)[0]
            t, n, t2 = w & 31, (w >> 5) & 31, (w >> 10) & 31
            pair = {0xA9000000: (0, 'off'), 0xA9400000: (1, 'off'), 0xA9800000: (0, 'pre'), 0xA9C00000: (1, 'pre'), 0xA8800000: (0, 'post'), 0xA8C00000: (1, 'post')}.get(w & 0xFFC00000)
            if pair:   # stp / ldp xT, xT2, [xN|sp, #imm] (offset, pre-index, post-index)
                base = sp if n == 31 else x[n]; imm = sx((w >> 15) & 0x7F, 7) * 8
                at = base if pair[1] == 'post' else base + imm
                if pair[0]: x[t], x[t2] = mem[at], mem[at + 8]
                else: mem[at], mem[at + 8] = x[t], x[t2]
                if pair[1] != 'off':
                    if n == 31: sp = base + imm
                    else: x[n] = base + imm
            elif w & 0xFFC00000 in (0xF9400000, 0xF9000000):   # ldr / str xT, [xN|sp, #imm]
                at = (sp if n == 31 else x[n]) + ((w >> 10) & 0xFFF) * 8
                if w & 0x400000: x[t] = mem[at]
                else: mem[at] = x[t]
            elif w & 0xFFFFFFE0 == 0xD53BD060: x[t] = TSD          # mrs xT, tpidrro_el0
            elif w & 0xFFFFFFE0 == 0xD53BE000: x[t] = HOST_FREQ    # mrs xT, cntfrq_el0: the host's register
            elif w & 0x9F000000 == 0x90000000:                     # adrp
                x[t] = (pc & ~0xFFF) + (sx((((w >> 5) & 0x7FFFF) << 2) | ((w >> 29) & 3), 21) << 12)
            elif w & 0xFFE0FC00 == 0x8B000000: x[t] = x[n] + x[(w >> 16) & 31]   # add xT, xN, xM
            elif w & 0xFFFFFC1F == 0xD63F0000: x[30], pc = pc + 4, x[n]; continue   # blr
            elif w & 0xFC000000 == 0x14000000: pc += sx(w & 0x3FFFFFF, 26) * 4; continue   # b
            else: self.fail(f'{w:08x} at {pc:#x}: an instruction this model does not run')
            self.assertNotIn(31, (t,) if not pair else (t, t2))
            pc += 4
        else: self.fail(f'the site at {a:#x} does not come back to {a + 4:#x}')
        self.assertEqual(sp, sp0)
        self.assertEqual(x[18], HOST_X18, "Apple's platform register is left alone")
        return x, mem[TSD + 8 * KEYS['K18']], entered

    def unchanged(self, x, but=()):
        for i in range(31):
            if i != 18 and i not in but: self.assertEqual(x[i], 0x1000 + i, f'x{i}')

    def test_counter_registers_are_classified(self):
        self.assertEqual(self.sites, {a: k for a, (_, k) in SITES.items()})

    def test_a_counter_read_into_x18_reaches_the_guests_x18(self):
        for a, kind, value in ((0x100, 'cntpct', TICKS), (0x104, 'cntvct', TICKS), (0x108, 'cntfrq', FREQ)):
            with self.subTest(kind=kind):
                x, x18, entered = self.run_site(a)
                self.assertEqual(entered, [(kind, 18)])
                self.assertEqual(x18, value)
                self.unchanged(x)

    def test_a_counter_read_into_another_register(self):
        for a, kind, reg, value in ((0x10c, 'cntfrq', 0, FREQ), (0x110, 'cntpct', 3, TICKS)):
            with self.subTest(kind=kind):
                x, x18, entered = self.run_site(a)
                self.assertEqual(entered, [(kind, reg)])
                self.assertEqual((x[reg], x18), (value, STALE))
                self.unchanged(x, but=(reg,))

    def test_svc_0x12_is_a_number_not_x18(self):
        x, x18, entered = self.run_site(0x114)
        self.assertEqual(entered, [('svc', 0x12)])
        self.assertEqual((x[0], x18), (SVC_RESULT, STALE))
        self.unchanged(x, but=(0,))


class Before(unittest.TestCase):
    """Only a module with mrs cntfrq_el0 outside an exclusive window rewrites differently from before"""
    def test_a_module_without_cntfrq_is_rewritten_as_before(self):
        other = {0xD53BE012: 0x91000652, 0xD53BE000: 0xD503201F}   # add x18, x18, #1 and nop instead of the two reads; and a window of x18
        raw = nro([other.get(w, w) for w, _ in SITES.values()] + [0x885FFC08, 0x91000652, 0x8809FC08, 0x35FFFFA9])
        self.assertEqual(rewrite(raw, before=True), rewrite(raw))

    def test_cntfrq_into_x18_in_an_exclusive_window_is_copied_with_the_window_as_before(self):
        # the function's only x18 word: still analysed, so the window is copied (site_window) and no gate is entered between the ldaxr and the stlxr
        raw = nro([0xD503201F, 0x885FFC08, 0xD53BE012, 0x8809FC08, 0x35FFFFA9])   # nop; ldaxr w8, [x0]; mrs x18, cntfrq_el0; stlxr w9, w8, [x0]; cbnz w9, <the ldaxr>
        now = rewrite(raw)
        self.assertEqual((now['nro0.sites.tsv'], now['nro0.gates.tsv']), (b'0x104\tW\t0x114\n', b''))
        self.assertEqual(rewrite(raw, before=True), now)

    def test_cntfrq_was_an_x18_site_or_left_in_place(self):
        before = rewrite(nro([w for w, _ in SITES.values()]), before=True)
        self.assertIn(b'0x108\tx18\n', before['nro0.sites.tsv'])
        self.assertNotIn(b'0x10c\t', before['nro0.sites.tsv'])   # mrs x0, cntfrq_el0: the host's register
        self.assertEqual(struct.unpack_from('<I', before['nro0.patched.bin'], 0x10c)[0], 0xD53BE000)


if __name__ == '__main__':
    unittest.main()
