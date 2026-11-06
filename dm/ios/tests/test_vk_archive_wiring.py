"""The Vulkan layer's pipeline archive (DM_VK_ARCHIVE, dm/gfx/vk/hle_vk.m and vk_archive.h), checked in the sources off the device: off by default and then nothing of it runs,
the hooks that tell its crash guard the app is away, the guard's defaults and its own record, the order of a start (the guard's verdict before Metal reads an archive), the
archive API it uses (classic MTLBinaryArchive, a miss compiling as without it), its names, its switches' rows, its CPU test in CI and the [vk] pipelines line that devlog.py reads.

Its plain-C parts run in dm/gfx/tests/t_vk_archive.c (make vk-archive), and the time at Metal's compiler and the hits it reports in t_vk_pending.c (make vk-pending). What none of
them runs: Metal's binary archives themselves (an Apple-silicon Mac or a device), the iOS scene's calls (test_pso_guard_wiring.py) and a cold and a warm start of a Vulkan game."""
from pathlib import Path
import importlib.util
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
LIT = re.compile(r'"((?:[^"\\]|\\.)*)"\s*')
CONV = re.compile(r'%([-+ #0]*\d*(?:\.\d+)?)(?:ll|l|z|h)?([diuxXfgs%])')


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the C function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


def code(src):
    """src without its // comments (none of the files checked has // inside a string)"""
    return re.sub(r'//[^\n]*', '', src)


def c_format(src, start):
    """The C format string that starts with start, its adjacent literals joined, as a Python %-format"""
    i = src.index('"' + start); out = ''
    while m := LIT.match(src, i): out += m.group(1); i = m.end()
    return CONV.sub(lambda m: '%' + m.group(1) + ('d' if m.group(2) in 'iu' else m.group(2)), out.replace('\\"', '"'))


class Wiring(unittest.TestCase):
    def setUp(self):
        self.vk = read('dm/gfx/vk/hle_vk.m'); self.h = read('dm/gfx/vk/vk_archive.h'); self.hle = read('dm/gfx/nvn/hle_nvn.c'); self.guard = read('dm/gfx/nvn/nvn_pso_guard.h')
        self.why = {k: int(v) for k, v in re.findall(r'PSG_AWAY_(\w+) = (\d+)', self.guard)}

    def test_off_by_default_and_then_nothing_runs(self):
        init = body(self.vk, 'static void va_init(void) {')
        first = init.split('\n')[1:3]
        self.assertIn('getenv("DM_VK_ARCHIVE")', first[0])
        self.assertIn('if (!e || !*e || !strcmp(e, "0")) return;', first[1])   # unset, empty or 0: return before anything is read, made or written
        self.assertEqual(init.count('atomic_store(&g_va_on, 1)'), 1)
        self.assertTrue(init.rstrip('}\n ').endswith('atomic_store(&g_va_on, 1); atomic_store(&g_va_hook, 1);'))   # on only once everything is in place
        self.assertIn('va_init();', body(self.vk, 'static void dev_init_once(void) {'))
        make = body(self.vk, 'static VkPipeline pipe_make(')
        self.assertIn('if (atomic_load_explicit(&g_va_on, memory_order_relaxed)) va_attach(p, pd, ci);', make)
        self.assertEqual(make.count('va_note('), 1); self.assertIn('else if (p->va_new) va_note(pd, p->va_key);', make)   # only once its compile succeeded
        self.assertIn('else if (p->va_new) va_note(pd, p->va_key);', body(self.vk, 'static void pjob_step(VkPipeline p, pjob_t *j, int i) {'))
        self.assertIn('if (p->va_read) vka_read_end(&g_va_gate);', body(self.vk, 'static void pipe_done(VkPipeline p, id<MTLRenderPipelineState> pso, int slot) {'))   # every path that ends a compile ends its read
        frame = body(self.vk, 'static void frame_end(void) {')
        self.assertIn('if (atomic_load_explicit(&g_va_hook, memory_order_relaxed)) va_frame();', frame)   # one plain load per frame without the switch
        self.assertNotIn('va_', code(frame).replace('g_va_hook', '').replace('va_frame()', ''))
        report = body(self.vk, 'static void pipe_report(uint64_t quiet) {')
        self.assertIn('char va[512] = ""; if (atomic_load_explicit(&g_va_on, memory_order_relaxed)) va_line(&r, va, sizeof va);', report)
        self.assertIn('if (atomic_load_explicit(&g_va_hook, memory_order_relaxed)) va_burst_end();', report)
        attach = body(self.vk, 'static void va_attach(')
        self.assertIn('pd.binaryArchives = g_va_list;', attach)   # the only place a descriptor names an archive
        self.assertEqual(self.vk.count('binaryArchives = g_va_list'), 1)
        # vk_pending.h's hand-over time, taken for every Vulkan game: read before the pool's lock, so the lock is held no longer than before
        pend = read('dm/gfx/vk/vk_pending.h')
        for fn in ('static inline int vkp_start(', 'static inline vkp_t *vkp_end('):
            b = body(pend, fn)
            self.assertLess(b.index('vkp_clock()'), b.index('pthread_mutex_lock(&g->mu)'), fn)
        self.assertNotIn('vkp_clock', body(pend, 'static inline void vkp_run('))

    def test_the_gate_takes_every_compile(self):   # no write begins while a compile of the layer is under way, in the start that writes the first file (no archive to name) too
        attach = code(body(self.vk, 'static void va_attach('))
        self.assertIn('if (!vka_read_begin(&g_va_gate)) return;', attach)
        self.assertLess(attach.index('vka_read_begin'), attach.index('g_va_list.count'))   # a reader whether or not there are archives to name
        self.assertIn('p->va_read = 1;\n    if (g_va_list.count) { pd.binaryArchives = g_va_list;', attach)
        self.assertIn('p->va_new = !known && !atomic_load_explicit(&g_va_stop, memory_order_relaxed);', attach)   # nothing held once the writes have stopped
        self.assertIn('if (atomic_load_explicit(&g_va_stop, memory_order_relaxed)) return;', body(self.vk, 'static void va_note('))
        stop = body(self.vk, 'static void va_stop_writes(void) {')
        self.assertIn('atomic_store(&g_va_stop, 1);', stop); self.assertIn('[g_va_pend removeAllObjects];', stop)
        write = code(body(self.vk, 'static void va_write(void) {'))
        self.assertNotRegex(write, r'g_va_stop\s*=')   # stopped through va_stop_writes, which lets the held pipelines go
        self.assertEqual(write.count('va_stop_writes();'), 2)   # a failed write, VKA_FILES
        self.assertIn('uint32_t during = vka_write_end(&g_va_gate);', write)   # the compiles that overlapped the write, on its line
        self.assertIn('VLOG("pipeline archive: all written, nothing waiting', write)

    def test_a_miss_compiles_as_without_it(self):   # classic Metal pipelines on a classic device: MTLBinaryArchive, without failing on a miss
        self.assertIn('mtl_device_classic()', self.vk)
        self.assertFalse(re.search(r'FailOnBinaryArchiveMiss|MTL4Archive|MTLPipelineOption', code(self.vk)), 'an option or an archive call that fails on a miss')
        for call in ('newRenderPipelineStateWithDescriptor:pd error:&err]', 'newRenderPipelineStateWithDescriptor:pd completionHandler:'):
            self.assertIn(call, self.vk)   # the same calls as without the archive (no options)
        write = body(self.vk, 'static void va_write(void) {')
        self.assertIn('[g_dev newBinaryArchiveWithDescriptor:[MTLBinaryArchiveDescriptor new] error:&err]', write)   # a new archive for each file: none is added to after a read
        self.assertIn('pd.binaryArchives = nil;', write)
        self.assertLess(write.index('vka_write_begin(&g_va_gate)'), write.index('addRenderPipelineFunctionsWithDescriptor'))
        self.assertLess(write.index('serializeToURL'), write.index('vka_write_end(&g_va_gate)'))

    def test_the_guard_reads_first(self):
        init = body(self.vk, 'static void va_init(void) {')
        self.assertLess(init.index('vka_scan('), init.index('va_guard_begin('))   # an old archive's files go before anything reads one
        self.assertLess(init.index('va_guard_begin('), init.index('[g_dev newBinaryArchiveWithDescriptor:'))   # the record is written before Metal reads the archive
        self.assertIn('int guard = ge && *ge ? strcmp(ge, "0") != 0 : TARGET_OS_IPHONE;', init)   # on by default on iOS, off on the Mac; DM_VK_ARCHIVE_GUARD 0 / 1
        self.assertIn('getenv("DM_VK_ARCHIVE_GUARD")', init)
        begin = body(self.vk, 'static int va_guard_begin(')
        self.assertIn('va_path(@"guard.tsv")', begin)   # its own record, beside the archive's files, not the bundled archive's
        self.assertIn('psg_begin(&g_va_psg, rec.fileSystemRepresentation, os, ident, 1)', begin)   # one early end leaves it out: the layer never had an archive
        self.assertIn('static psg_guard g_va_psg = PSG_GUARD_INIT_FOR("the Vulkan layer\'s pipeline archive in this folder (hle_vk.m, DM_VK_ARCHIVE)");', self.vk)   # its record says so
        self.assertIn('vka_lib_id(p, s->v[VKA_SHADERS]', body(self.vk, 'static void va_stamp(vka_stamp *s) {'))   # the shader library by its function list
        self.assertFalse(re.search('pso_bundle_guard|g_psg\\b', code(self.vk)), 'the bundled archive\'s record or guard')
        self.assertIn('psg_unused(&g_va_psg)', init)   # Metal took none of the files: nothing of that archive ran
        self.assertIn('va_mark();', body(self.vk, 'static void va_write(void) {'))   # the window runs from the first burst's writes
        self.assertIn('if (!atomic_load(&g_va_on)) { va_mark(); return; }', body(self.vk, 'static void va_burst_end(void) {'))   # and for the start the guard runs without it

    def test_the_away_hooks(self):   # beside the bundled archive's guard, with the same reasons (hle_nvn.c passes numbers), before any wait
        self.assertEqual(self.why, {'BACKGROUND': 1, 'INACTIVE': 2, 'EXIT': 4})
        self.assertIn(f'void dm_gfx_inactive(int on) {{ mtl_pso_guard_away({self.why["INACTIVE"]}, on); dm_vk_archive_away({self.why["INACTIVE"]}, on); }}', self.hle)
        self.assertIn(f'void dm_gfx_exiting(void) {{ mtl_pso_guard_away({self.why["EXIT"]}, 1); dm_vk_archive_away({self.why["EXIT"]}, 1); }}', self.hle)
        lines = [ln.strip() for ln in body(self.hle, 'void dm_gfx_suspend(int on) {').split('\n')[1:3]]
        self.assertTrue(lines[0].startswith(f'mtl_pso_guard_away({self.why["BACKGROUND"]}, on);'))
        self.assertTrue(lines[1].startswith(f'dm_vk_archive_away({self.why["BACKGROUND"]}, on);'))
        self.assertIn('__attribute__((weak)) void dm_vk_archive_away(int why, int on) { (void)why; (void)on; }', self.hle)   # the graphics unit tests link hle_nvn.c without hle_vk.m
        self.assertEqual(len(re.findall(r'(?m)^void dm_vk_archive_away\(int why, int on\) \{', self.vk)), 1)
        away = code(body(self.vk, 'void dm_vk_archive_away(int why, int on) {'))
        # the guard notes every away, before the device and with the guard not watching too (psg_begin reads the bits), and writes a record only while it watches a start
        self.assertIn('int err = 0, was = psg_away(&g_va_psg, why, on, &err);', away)
        self.assertNotRegex(away.split('psg_away(')[0], r'return|g_va_hook|g_va_guard')
        self.assertIn('if (g->armed != PSG_NONE && old != (g->away != 0))', body(self.guard, 'static inline int psg_away('))   # no record written while not watched
        self.assertIn('g->away ? psg_left(arm, g->found) : arm', body(self.guard, 'static inline psg_start psg_begin('))
        self.assertIn('if (on && why == PSG_AWAY_BACKGROUND && !atomic_load(&g_va_exiting) && atomic_load(&g_va_on)) va_schedule(0);', away)   # a trip to the background writes what waits
        self.assertIn('if (why == PSG_AWAY_EXIT && on) atomic_store(&g_va_exiting, 1);', away)   # the graceful exit does not: it ends the process before a write could finish
        self.assertIn('if (!atomic_load(&g_va_exiting)) va_schedule(0);', body(self.vk, 'static void va_burst_end(void) {'))
        self.assertIn('atexit(va_atexit);', body(self.vk, 'static void va_init(void) {'))   # exit() on the Mac: no further file begun
        self.assertIn('if (atomic_load(&g_va_stop) || atomic_load(&g_va_exiting)) break;', body(self.vk, 'static void va_write(void) {'))

    def test_names_are_its_own(self):
        """vk_archive.h's names carry vka_ / VKA_; the archive's statics in hle_vk.m carry va_ / g_va_ and clash with nothing in the files that include hle_vk.m (t_vk_desc.m,
        t_vk_pso.m) or that hle_vk.m includes (nvn_pso_guard.h's psg_ / PSG_)"""
        defined = set(re.findall(r'^(?:static inline \w+ \**|typedef struct \{[^}]*\} |#define |static const char \*const )(\w+)', self.h, re.M))
        defined |= set(re.findall(r'\b(VKA_[A-Z0-9_]+)\s*(?:=|,|\})', self.h))
        self.assertTrue(defined)
        for name in defined: self.assertRegex(name, r'^(vka_|VKA_)', name)
        sec = self.vk[self.vk.index('// ---------- Pipeline archive (DM_VK_ARCHIVE) ----------'):self.vk.index('// DM_VK_PSO_ASYNC (on by default)')]
        mine = set(re.findall(r'(?m)^static\b[^;=({\n]*?\b(g_va_\w+|va_\w+)\s*[\[;=(,]', sec)) | set(re.findall(r'\*(g_va_\w+)', sec)) | set(re.findall(r'enum \{ (VA_\w+)', sec))
        self.assertTrue({'va_init', 'va_write', 'g_va_gate', 'g_va_psg', 'VA_CHUNK'} <= mine, mine)
        for rel in ('dm/gfx/tests/t_vk_desc.m', 'dm/gfx/tests/t_vk_pso.m', 'dm/gfx/nvn/nvn_pso_guard.h', 'dm/gfx/vk/vk_pending.h'):
            src = read(rel)
            for name in mine | defined: self.assertFalse(re.search(rf'\b{re.escape(name)}\b', src), f'{rel} uses {name}, a name of the Vulkan archive')

    def test_switch_rows_and_ci(self):
        rows = {ln.split('\t')[0]: ln for ln in read('docs/env_switches.tsv').splitlines()}
        self.assertIn('off by default', rows['DM_VK_ARCHIVE']); self.assertIn('vk_archive', rows['DM_VK_ARCHIVE'])
        self.assertIn('on by default on iOS', rows['DM_VK_ARCHIVE_GUARD']); self.assertIn('off by default on the Mac', rows['DM_VK_ARCHIVE_GUARD'])
        self.assertRegex(read('.github/workflows/tests.yml'), r'make GAME="\$GAME" vk-archive ')
        mk = read('dm/gfx/tests/Makefile')
        self.assertIn('vk-archive: t_vk_archive t_vk_archive_tsan t_vk_archive_asan', mk)
        for t in ('t_vk_desc', 't_vk_pso'): self.assertIn(f'{t}: {t}.m ../vk/hle_vk.m ../vk/vk_pending.h ../vk/vk_archive.h', mk)   # they #include hle_vk.m
        self.assertIn('../gfx/vk/*.h', read('dm/host/Makefile'))   # the Mac host rebuilds when the header changes; iOS takes it from hle_vk.m's folder (gen_build.py)

    def test_the_pipelines_line(self):   # devlog.py still reads it, with and without the archive's part
        spec = importlib.util.spec_from_file_location('devlog', REPO / 'scripts/devlog.py')
        assert spec is not None and spec.loader is not None
        devlog = importlib.util.module_from_spec(spec); spec.loader.exec_module(devlog)
        line = c_format(self.vk, 'pipelines: %llu compiled %s')
        part = c_format(self.vk, '; pipeline archive (DM_VK_ARCHIVE): %llu of them')
        for va in ('', part % (4500, 0.5, 35, 4.0, 4500, 0.5, 35, 4.0, 35, ''), part % (0, 0.0, 4535, 3.1, 0, 0.0, 4535, 3.1, 4535, ' (some left for a later start: VA_PEND)')):
            with self.subTest(archive=bool(va)):
                text = '[dm] [vk] ' + line % (4535, 'concurrently', 2.5, 0.8, 30.0, 4535, 12, 0, 3, 40.0, 20.0, 4535, 9.0, 2.0, 1.5, 9.0, 1.5, 6.5, 7.25, va)
                self.assertIn('4535 since the start; 9.00 s at Metal\'s compiler summed, 2.0 ms each, 1.50 s of it specializing (since the start 9.00 s, 1.50 s of it specializing); '
                              'the burst ended 6.50 s after the Vulkan device was made, 7.25 s after the process started', text)
                g, _, _ = devlog.scan([text])
                self.assertTrue(g['vkpso'], text)
                self.assertEqual(g['vkpso'][0][1].group(1), '4535')


if __name__ == '__main__':
    unittest.main()
