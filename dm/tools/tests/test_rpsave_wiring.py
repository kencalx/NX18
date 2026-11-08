"""The render-pass savings outside the TBDR mode (DM_NVN_CLEAR_FMTMASK, DM_NVN_LOAD_COVER, DM_NVN_OMIT_UNWRITTEN, nvn_mtl.m) and the depth / stencil store switch
DM_NVN_UDC_DS_STORE, checked in the sources: each is a class switch read through sw_mode with default 0 (so `ab` works with DM_AB and unset changes nothing), each path asks its switch
before it changes an action, the safety nets are in place (a draw that writes a slot left out ends the pass, a clear reopens it, a pass that ends before its covering draw logs red), and
the counters reach the log line and the TSV. The decisions themselves run in dm/gfx/tests/t_rpsave.c (plain C, CI's CPU subset); the GPU checks are listed in NINTANIUM.md.

Also frame_history queued (hle_vi.c, game.py): the profile value and DM_VI_FRAME_HISTORY=queued map to 2, Luigi's Mansion 3's profile keeps off in this branch, a bad value stops
the header. t_vi_history.c runs the answer itself (make -C dm/host/tests GAME=0100DCA0064A6000)."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SWITCHES = ('DM_NVN_CLEAR_FMTMASK', 'DM_NVN_LOAD_COVER', 'DM_NVN_OMIT_UNWRITTEN', 'DM_NVN_UDC_DS_STORE')


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def func(src, signature):
    """The body of the function whose definition starts with signature (braces matched, strings and comments skipped)"""
    i = src.index(signature); j = src.index('{', i); depth, q, k = 0, None, j
    while k < len(src):
        c = src[k]
        if not q and src.startswith('//', k): k = src.index('\n', k); continue
        if not q and src.startswith('/*', k): k = src.index('*/', k) + 2; continue
        if q:
            if c == '\\': k += 1
            elif c == q: q = None
        elif c in '"\'': q = c
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if not depth: return src[j:k + 1]
        k += 1
    raise AssertionError('unbalanced ' + signature)


class Switches(unittest.TestCase):
    def setUp(self):
        self.mtl = read('dm/gfx/nvn/nvn_mtl.m'); self.tsv = read('docs/env_switches.tsv')

    def test_each_is_read_once_through_sw_mode_off_by_default(self):
        for name in SWITCHES:
            with self.subTest(name=name):
                self.assertEqual(len(re.findall(r'sw_mode\("' + name + r'", 0\)', self.mtl)), 1)
                self.assertNotIn('getenv("' + name + '")', self.mtl)
                row = [l for l in self.tsv.splitlines() if l.startswith(name + '\t')]
                self.assertEqual(len(row), 1); self.assertEqual(row[0].split('\t')[1], 'switch')
                self.assertRegex(row[0], r'off by default|Off by default')

    def test_every_change_asks_its_switch(self):
        rp = func(self.mtl, 'static id<MTL4RenderCommandEncoder> rp_begin_ex_(int clear_only) {')
        self.assertIn('int lcov = !tbdr_on() && sw_on(lcov_mode());', rp)   # latched once per pass, never in the TBDR mode
        self.assertIn('int lc = !tbdr_on() && lcov && ', rp)
        self.assertIn('uint32_t omit = g_rp_omit && ', rp)   # only what draw asked for
        dr = func(self.mtl, 'static void draw_(const p_draw *dw, const p_draw_idx *di) {')
        self.assertEqual(dr.count('g_rp_omit = '), 2)   # set before the pass opens, cleared after
        self.assertRegex(dr, r'&& sw_on\(omit_mode\(\)\)\) \{\s*uint32_t present')
        self.assertIn('if (!whole && !g_enc && sw_on(cfm_mode())) {', self.mtl)
        self.assertIn('int udc_dead = udc_on() && t->load && !t->wrote && !(t->depth && udc_ds_store());', self.mtl)   # only takes a DontCare away

    def test_the_safety_nets(self):
        dr = func(self.mtl, 'static void draw_(const p_draw *dw, const p_draw_idx *di) {')
        guard = dr.index('if (g_enc && g_pass.omit && (prog_color_wmask(pr) & g_pass.omit)) {')
        self.assertLess(guard, dr.index('rp_begin_ex(mode)'), 'a draw that writes a slot left out must end the pass before it opens or uses one')
        self.assertIn('if (g_enc && g_pass.omit && g_fb_tseq == g_draw_seq && g_fb_tfn) {', dr)   # a tile read needs every attachment
        self.assertIn('if (g_fd_pend && !g_defer_replaying) { g_fd_done = g_fd_pend; g_fd_pend = 0; }', dr)   # the covering draw was encoded (not a deferred draw replayed first)
        self.assertLess(dr.index('if (g_fd_pend && !g_defer_replaying) { g_fd_done'), dr.index('udc_note_draw(pr, raster_mask);'))
        # a covering draw that returned unencoded (no pipeline): the next draw ends the pass before it could land on the skipped loads, and so does a clear drawn as a triangle
        nenc = dr.index('if (g_enc && g_fd_pend && !g_defer_replaying) {')
        self.assertLess(nenc, dr.index('rp_begin_ex(mode)')); self.assertLess(nenc, dr.index('if (g_fd_pend && !g_defer_replaying) { g_fd_done'))
        self.assertIn('rp_end(); }', dr[nenc:nenc + 200])
        self.assertIn('if (g_enc && (g_rp_aw || g_fd_pend)) rp_end();', func(self.mtl, 'static id<MTL4RenderCommandEncoder> rp_begin(void) {'))
        self.assertEqual(dr.count('if (orph & ~g_fd_done) fd_lost(orph & ~g_fd_done);'), 2)   # a draw encoded again (texture upgrade, range retry) that covers again loses nothing
        tri = func(self.mtl, 'static void clear_color_tri(const p_clear_color *c) {')
        self.assertIn('(g_pass.omit >> slot & 1)', tri)
        end = func(self.mtl, 'static void rp_end(void) {')
        self.assertIn('g_fd_orphan |= g_fd_pend; g_fd_pend = 0;', end)
        self.assertIn('fd_lost(g_fd_orphan)', self.mtl)
        self.assertIn('RED_ONCE(158, "a pass whose colour load was skipped', self.mtl)
        m = re.search(r'static int g_red_once\[(\d+)\];', self.mtl); self.assertIsNotNone(m)
        if m: self.assertGreater(int(m.group(1)), 158)
        cov = func(self.mtl, 'static int first_draw_covers(int i, id<MTLTexture> t, NSUInteger level) {')
        self.assertIn('return g_fd_why = 12, 0;', cov); self.assertIn('return g_fd_why = 13, 0;', cov)
        # the depth plane counts toward the pass's size (nvn_rp_omit) only when it is surely attached: a native depth / stencil format, not drawn through a colour view
        plan = func(self.mtl, 'static uint32_t rp_omit_plan(uint32_t want) {')
        self.assertIn('if (t && mtl_fmt_depth(t.pixelFormat) && !bcrt_view(t, &R.rt.dview, R.rt.has_dview, &sf_)) { has_d = 1;', plan)

    def test_counters_reach_the_log_and_the_tsv(self):
        nvn = read('dm/gfx/nvn/hle_nvn.c')
        self.assertIn('[nvn] render-pass savings up to frame %llu, per frame: format-complete clears taken whole', nvn)
        for col in ('@clear_fmt_mb', '@cover_skip_mb', '@omit_mb'): self.assertIn('"' + col + '"', nvn)
        self.assertIn('void mtl_rpsave_stats(uint64_t s[9])', self.mtl)
        self.assertIn('DM_SP_EVENT(DM_SP_GPU, "rp-save"', self.mtl)
        # a left-out slot's store is counted saved only where DM_NVN_UNWRITTEN_DC would have kept it (its rule, per encoded draw), not twice its bytes up front
        self.assertNotIn('g_omit_bytes += 2 *', self.mtl)
        self.assertIn('(!udc_on() || (g_omit_udcw >> i & 1))) g_omit_bytes += g_omit_ab[i];', func(self.mtl, 'static void rp_end(void) {'))
        self.assertIn('if (g_pass.omit) g_omit_udcw |= udc_rule_writes(pr) & g_pass.omit;', func(self.mtl, 'static void draw_(const p_draw *dw, const p_draw_idx *di) {'))

    def test_the_pure_test_is_built_and_run_by_ci(self):
        self.assertRegex(read('dm/gfx/tests/Makefile'), r'(?m)^t_rpsave: t_rpsave\.c \.\./nvn/nvn_rpsave\.h')
        self.assertRegex(read('.github/workflows/tests.yml'), r'tests="[^"]*\bt_rpsave\b')
        hdr = read('dm/gfx/nvn/nvn_rpsave.h')
        for name in SWITCHES[:3]: self.assertIn(name, hdr)


ID = '0100000000F0F000'
TSV = ('title_id\t' + ID + '\nname\tTest\nprogram_id\t' + ID + '\nmodules\tmain\nromfs_marker\tromfs.img\n'
       'mem_reserve\t0x100000\nmem_alias\t0x100000\nmem_stack\t0x100000\napp_pool\t0x100000\n')


def header(rows):
    """game.py header of a synthetic profile with these extra rows: (exit code, output, the header)"""
    with tempfile.TemporaryDirectory() as d:
        Path(d, ID).mkdir(); (Path(d, ID) / 'game.tsv').write_text(TSV + rows); h = Path(d, ID) / 'game.h'
        r = subprocess.run([sys.executable, str(REPO / 'dm/games/game.py'), 'header', ID, str(h)], env={**os.environ, 'DM_GAMES_DIR': d}, capture_output=True, text=True)
        return r.returncode, (r.stderr + r.stdout).strip(), h.read_text() if h.exists() else ''


class FrameHistoryQueued(unittest.TestCase):
    def test_profile_values(self):
        for rows, want in (('', 1), ('frame_history\ton\n', 1), ('frame_history\toff\n', 0), ('frame_history\tqueued\n', 2)):
            rc, out, h = header(rows)
            with self.subTest(rows=rows):
                self.assertEqual(rc, 0, out); self.assertIn('#define DM_GAME_FRAME_HISTORY %d' % want, h)
        rc, out, _ = header('frame_history\tQueued\n')
        self.assertNotEqual(rc, 0); self.assertIn('frame_history must be on, off or queued', out)

    def test_the_host_parses_queued_and_lm3_keeps_off(self):
        vi = read('dm/gfx/hle_vi.c')
        self.assertIn('else if (!strcmp(e, "queued")) set = 2;', vi)
        self.assertIn('#define VFH_LEAD_NS 500000ull', vi)
        self.assertRegex(vi, r'if \(mode == 2\) \{[^}]*o\[0\] = 2;')
        self.assertRegex(read('dm/games/0100DCA0064A6000/game.tsv'), r'(?m)^frame_history\toff$')
        self.assertIn('`queued`', [l for l in read('docs/env_switches.tsv').splitlines() if l.startswith('DM_VI_FRAME_HISTORY\t')][0])


if __name__ == '__main__':
    unittest.main()
