// The upload-only unwire (DM_NVN_UNWIRE_UP, nvn_mtl.m up_unwire_sweep): a memory pool that only texture uploads have read leaves the residency set once every upload batch that reads
// it has come back, so its file pages are no longer wired and the kernel may drop them; any later GPU use puts it back before the command buffer that uses it is committed. With real
// Metal, pools over the test's own memory (anonymous, and file-backed as the guest's files are) and a fake clock for the sweep's rules (g_unw_skew):
//  1. the census: an upload's lookup is never cached, so a later other use on the same thread is counted (n_other) and the pool stays;
//  2. a pool the upload made resident stays while the batch's feedback is held back, and leaves (out of the committed set too) once it is back and 3 s have passed;
//  3. the batch floor (up_back_floor) over three slots coming back out of order, and the note of a batch flushed partway through a texture (pool_up_note);
//  4. a later GPU use (a buffer copy) puts the pool back, and every queue commit after it sees the re-add committed (g_q4_commit_hook), whatever the encode thread, held
//     submissions, the residency worker and the prewire do (the Makefile runs the switch matrix); the copy lands;
//  5. the raw gate: an addressed pool stays while no raw pool table exists (U2 in the census line, by how its address was given), so the first table puts nothing back; a pool
//     addressed only after the sweep took it out reads its next upload through a batch buffer, the table puts it back (counted as such) before the queue commit, and once a table
//     exists an addressed pool stays;
// 12. overlapping pools: the note of a batch flushed partway (pool_up_note) lands on the entry whose buffer the upload reads, not on another entry holding the address, and the
//     sweep keeps that pool while the batch is out;
//  6. an upload after the unwire reads through a batch buffer of its own (g_up_big_srcs), the pool stays out, and the batch buffer leaves the set with its batch;
//  7. the back-off: re-adds within 10 s hold the pool back 10, then 20 s, and the third makes it sticky;
//  8. =m changes nothing and counts what would go;
//  9. byte-exact texels and copies under the stress setting (a sweep at every submission, no idle rule), with Metal's validation (the Makefile's runs);
// 10. "stress": lookups on two other threads while the submit thread sweeps and builds the raw table, checking after each round that a pool marked resident is committed (ASan, TSan);
// 13. the default is =m (counts, changes nothing) with the switch unset or empty, and the 10 s line is written then; =0 writes no line and walks no pools; =1 on;
// 11. a file-backed pool's wiring falls when it leaves, and its clean pages can then be dropped; a later upload pages in only the texture's range (numbers printed; asserts only the fall)
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <libproc.h>
#include <mach/mach_vm.h>
static unsigned uwired(const void *p, size_t n) { mach_vm_address_t a = (mach_vm_address_t)p, e = a + n; unsigned hi = 0; while (a < e) { mach_vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64; if (mach_vm_region_recurse(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &c) || a >= e) break; if (info.user_wired_count > hi) hi = info.user_wired_count; a += sz; } return hi; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static const uint64_t SEC = 1000000000ull;

static uint8_t *file_mem(size_t n) {
    const char *td = getenv("TMPDIR"); char path[512]; snprintf(path, sizeof path, "%s/t_pool_unwire.XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); if (fd < 0) abort(); unlink(path);
    if (ftruncate(fd, (off_t)n)) abort();
    uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (m == MAP_FAILED) abort();
    close(fd); return m;
}
static uint8_t *anon_mem(size_t n) { uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m == MAP_FAILED) abort(); return m; }
static pool_ent pent(const void *mem) { mu_lock(); int i = pool_peek((uint64_t)(uintptr_t)mem); pool_ent e = i >= 0 ? g_pools[i] : (pool_ent){0}; pthread_mutex_unlock(&g_mu); return e; }
static int in_objects(id b) { if (!b) return 0; res_mu_lock(); int r = [g_res_objects containsObject:b]; res_mu_unlock(); return r; }
static int committed(id b) { if (!b) return 0; res_commit_lock(); int r = [g_res containsAllocation:b]; res_commit_unlock(); return r; }
static void settle(void) { res_commit(); dispatch_sync(res_commit_q(), ^{}); res_commit(); }
static void sub_empty(void) { mtl_sub_begin(); CHECK("an empty submission completes", mtl_wait(mtl_sub_commit(), 10 * SEC)); }
static void tick(uint64_t ns) { g_unw_skew += ns; }
static void upload_lookup(const void *mem, uint64_t len) { void *b; uint64_t o; t_tex_upload_lookup = 1; mtl_addr((uint64_t)(uintptr_t)mem, len, &b, &o); t_tex_upload_lookup = 0; settle(); }

// A texture over [mem, mem + its size) in pool, filled with a pattern through the CPU's swizzle
typedef struct { tex_t t; uint8_t *ref; size_t bytes; } upl;
static void make(upl *u, uint8_t *mem, pool_t *pool, size_t off, unsigned w, unsigned h, unsigned seed) {
    static uint64_t serial = 91000;
    memset(u, 0, sizeof *u);
    u->t = (tex_t){.magic = MAGIC('T', 'E', 'X', 0), .has_layout = 1, .serial = serial++};
    u->t.d = (nvn_texdesc){.target = 1, .format = NVN_FORMAT_RGBA8, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&u->t.d, &u->t.L);
    u->t.pool = pool; u->t.mem = mem + off; u->t.off = off;
    u->bytes = (size_t)w * h * 4; u->ref = malloc(u->bytes);
    uint32_t *p = (uint32_t *)u->ref; for (size_t i = 0; i < u->bytes / 4; i++) p[i] = (uint32_t)(i * 2654435761u + seed * 40503u);
    dm_guest_write_prepare(u->t.mem, u->t.L.size);
    CHECK("reference swizzle succeeds", !nvn_swizzle(&u->t.d, 0, 0, u->ref, w * 4, u->t.mem));
}
static int same_texels(id<MTLTexture> tex, const upl *u) {
    unsigned w = u->t.d.width, h = u->t.d.height;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:u->bytes options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); t4_use(cb, tex); t4_use(cb, rb);
    id<MTL4ComputeCommandEncoder> ce = t4_copy(cb);
    [ce copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:rb destinationOffset:0
        destinationBytesPerRow:w * 4 destinationBytesPerImage:u->bytes options:MTLBlitOptionNone];
    t4_end(cb, ce);
    return t4_wait(cb) == MTLCommandBufferStatusCompleted && !memcmp(rb.contents, u->ref, u->bytes);
}
static id<MTLTexture> upload_sub(upl *u) {   // one texture uploaded in a submission of its own, its batch back once this returns
    mtl_sub_begin(); id<MTLTexture> t = tex_mtl(&u->t);
    CHECK("the upload's submission completes", mtl_wait(mtl_sub_commit(), 10 * SEC)); mtl_drain(); settle();
    CHECK("no GPU error", !mtl_last_commit_error());
    return t;
}
// Shared buffers in the residency set over any page of [lo, hi) other than `except` (the batch buffers up_big_src made)
static int bufs_over(const void *lo, size_t n, id except) {
    int k = 0; res_mu_lock();
    for (id<MTLAllocation> o in g_res_objects.allObjects) { if (o == except || ![(id)o conformsToProtocol:@protocol(MTLBuffer)]) continue; id<MTLBuffer> b = (id<MTLBuffer>)o;
        if (b.storageMode != MTLStorageModeShared) continue; uintptr_t c = (uintptr_t)b.contents; if (c < (uintptr_t)lo + n && c + b.length > (uintptr_t)lo) k++; }
    res_mu_unlock(); return k;
}

// The queue-commit check (case 4, 5): while armed, every timed queue commit must find every change below want committed
static _Atomic uint64_t q_want; static _Atomic int q_seen, q_bad;
static void q_hook(const char *site) { (void)site; uint64_t w = atomic_load(&q_want); if (!w) return; atomic_fetch_add(&q_seen, 1); if (atomic_load(&g_res_done) < w) atomic_fetch_add(&q_bad, 1); }

static uint64_t rusage_pageins(uint64_t *wired) { struct rusage_info_v6 ru; if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ru)) return 0; if (wired) *wired = ru.ri_wired_size; return ru.ri_pageins; }
static double resident_share(const void *p, size_t n) { size_t pg = getpagesize(), np = n / pg, in = 0; char *v = malloc(np); if (mincore(p, n, v)) { free(v); return -1; } for (size_t i = 0; i < np; i++) in += (v[i] & MINCORE_INCORE) != 0; free(v); return (double)in / np; }

// ---------- 10: three threads ----------
// The submit thread sweeps (a sweep at every submission), builds the raw table now and then and makes upload lookups (re-adds) on the lower half of the pools; one thread looks pools up
// for other uses across all of them every 2 ms (re-adds that race the sweep, each pool's first such lookup making it stay), another hammers the upper half through its cache
static _Atomic int st_run, st_pause, st_parked;
typedef struct { uint8_t **mem; int n, slow; } st_arg;
static void *st_worker(void *a_) {
    st_arg *a = a_; unsigned r = 12345u + (unsigned)a->slow;
    while (atomic_load(&st_run)) {
        if (atomic_load(&st_pause)) { atomic_fetch_add(&st_parked, 1); while (atomic_load(&st_pause) && atomic_load(&st_run)) usleep(100); atomic_fetch_sub(&st_parked, 1); continue; }
        r = r * 1103515245u + 12345u; void *b; uint64_t o, g;
        uint8_t *m = a->mem[(r >> 8) % (unsigned)a->n];
        if (a->slow) { mtl_gpu_addr((uint64_t)(uintptr_t)m, 4096, &b, &o, &g); usleep(2000); }
        else mtl_addr((uint64_t)(uintptr_t)m, 4096, &b, &o);
    }
    return NULL;
}
static int stress(void) {
    enum { NP = 96, ROUNDS = 60 }; static uint8_t *mem[NP]; static id<MTLBuffer> bufs[NP]; int res[NP];
    for (int i = 0; i < NP; i++) { mem[i] = i % 2 ? file_mem(256u << 10) : anon_mem(256u << 10); memset(mem[i], i, 256u << 10); mtl_pool_add(mem[i], 256u << 10); if (i % 3 == 0) mtl_pool_addressed_k(mem[i], 256u << 10, AK_BUF); }
    for (int i = 0; i < NP; i++) upload_lookup(mem[i], 4096);
    g_unw_stress = 1;
    st_arg all = {mem, NP, 1}, upper = {mem + NP / 2, NP / 2, 0};
    atomic_store(&st_run, 1); pthread_t a, b; pthread_create(&a, NULL, st_worker, &all); pthread_create(&b, NULL, st_worker, &upper);
    int bad = 0, out = 0; unsigned r = 777;
    for (int k = 0; k < ROUNDS; k++) {
        tick(SEC);
        for (int j = 0; j < 4; j++) { r = r * 1103515245u + 12345u; void *bb; uint64_t o; t_tex_upload_lookup = 1; mtl_addr((uint64_t)(uintptr_t)mem[(r >> 8) % (NP / 2)], 4096, &bb, &o); t_tex_upload_lookup = 0; }
        if (k % 7 == 3) {   // an unaddressed pool out of the set gets its address given out (the sweep takes no addressed pool), so the table below puts it back, racing the lookups
            int pick = -1; mu_lock(); for (int i = 0; i < NP && pick < 0; i++) { int q = pool_peek((uint64_t)(uintptr_t)mem[i]); if (q >= 0 && g_pools[q].ev && !addr_meets(g_pools[q].lo, g_pools[q].hi)) pick = i; } pthread_mutex_unlock(&g_mu);
            if (pick >= 0) mtl_pool_addressed_k(mem[pick], 256u << 10, AK_BUF);
        }
        mtl_sub_begin(); if (k % 7 == 3) (void)gmem_map(); CHECK("a stress submission completes", mtl_wait(mtl_sub_commit(), 10 * SEC));
        atomic_store(&st_pause, 1); while (atomic_load(&st_parked) < 2) usleep(100);
        settle();
        mu_lock(); for (int i = 0; i < NP; i++) { int q = pool_peek((uint64_t)(uintptr_t)mem[i]); bufs[i] = q >= 0 ? g_pools[q].buf : nil; res[i] = q >= 0 && g_pools[q].res; out += q >= 0 && g_pools[q].ev; } pthread_mutex_unlock(&g_mu);
        for (int i = 0; i < NP; i++) { int ok = res[i] ? in_objects(bufs[i]) && committed(bufs[i]) : !in_objects(bufs[i]) && !committed(bufs[i]); if (!ok) bad++; }
        atomic_store(&st_pause, 0);
    }
    atomic_store(&st_run, 0); pthread_join(a, NULL); pthread_join(b, NULL);
    g_unw_stress = 0;
    printf("stress: %d rounds, pools out at the checks %d, unwired %llu, re-added (upload %llu, other %llu, raw %llu)\n", ROUNDS, out, (unsigned long long)g_unw_n,
           (unsigned long long)g_unw_re[0], (unsigned long long)g_unw_re[1], (unsigned long long)g_unw_re[2]);
    CHECK("after every round a pool marked resident is in the committed set, and one out is in neither", bad == 0);
    CHECK("the sweep took pools out during the stress", g_unw_n > 0);
    CHECK("the raw table put pools addressed after they went back during the stress", g_unw_re[UNW_RE_RAW] > 0);
    CHECK("no GPU error", !mtl_last_commit_error());
    printf("t_pool_unwire stress: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    alarm(300); setvbuf(stdout, NULL, _IONBF, 0);
    setenv("DM_NVN_DIRECT_UPLOAD", "0", 1);   // the staged deswizzle, whose staging may flush the batch partway (case 3)
    mtl_init();
    CHECK("GPU deswizzle is available", g_nvn_deswz_gpu);
    int env_mode = g_unw_mode;
    // ---------- 13: the default (unw_init read again under each value, then the run's own value back) ----------
    { const char *e0 = getenv("DM_NVN_UNWIRE_UP"); char *keep = e0 ? strdup(e0) : NULL; uint64_t r0;
      unsetenv("DM_NVN_UNWIRE_UP"); unw_init();
      CHECK("unset: the default is =m", g_unw_mode == 0 && g_unw_measure == 1);
      r0 = g_unw_reports; mtl_unwire_report(); CHECK("=m (the default) writes the 10 s line", g_unw_reports == r0 + 1);
      setenv("DM_NVN_UNWIRE_UP", "", 1); unw_init(); CHECK("empty: the default, =m", g_unw_mode == 0 && g_unw_measure == 1);
      setenv("DM_NVN_UNWIRE_UP", "0", 1); unw_init(); CHECK("=0: off, nothing counted", g_unw_mode == 0 && g_unw_measure == 0);
      r0 = g_unw_reports; mtl_unwire_report(); CHECK("=0 writes no 10 s line", g_unw_reports == r0);
      { uint64_t s0 = g_unw_sweeps; up_unwire_sweep(0); CHECK("=0: no sweep", g_unw_sweeps == s0); }
      setenv("DM_NVN_UNWIRE_UP", "1", 1); unw_init(); CHECK("=1: on", g_unw_mode == 1 && g_unw_measure == 0);
      setenv("DM_NVN_UNWIRE_UP", "m", 1); unw_init(); CHECK("=m", g_unw_mode == 0 && g_unw_measure == 1);
      if (keep) { setenv("DM_NVN_UNWIRE_UP", keep, 1); free(keep); } else unsetenv("DM_NVN_UNWIRE_UP");
      unw_init(); }
    g_unw_mode = 1; g_unw_measure = 0;   // the test drives the sweep itself (the switch's value is read once at mtl_init: printed)
    printf("DM_NVN_UNWIRE_UP read as %d; DM_NVN_RES_ASYNC %d, DM_NVN_RES_PREWIRE %d, encode thread %d\n", env_mode, rca_mode(), pw_on(), rec_on());
    g_q4_commit_hook = q_hook;
    sub_empty();   // the submit thread is known from here
    if (argc > 1 && !strcmp(argv[1], "stress")) return stress();

    // ---------- 5 (first half): no raw table yet ----------
    CHECK("no raw pool table built yet", g_gmem_buf == nil);
    pool_t qpool; uint8_t *qmem = anon_mem(4u << 20); memset(qmem, 0x5a, 4u << 20);
    qpool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .mem = qmem, .size = 4u << 20, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    { uint8_t *amem = anon_mem(1u << 20); mtl_pool_add(amem, 1u << 20); mtl_pool_addressed_k(amem, 1u << 20, AK_BUF);
      upload_lookup(amem, 4096);
      CHECK("an addressed pool an upload looked up is resident", pent(amem).res && pent(amem).ak == AK_BUF);
      uint64_t n0 = g_unw_n; tick(4 * SEC); sub_empty(); settle();
      // A late first raw table put every addressed pool the sweep had taken out back at once, in front of that draw's queue commit: none goes before a table exists
      CHECK("with no raw table, an addressed upload-only pool stays", pent(amem).res && !pent(amem).ev && committed(pent(amem).buf) && g_unw_n == n0);
      char cls[600]; pool_res_classes(cls, sizeof cls);
      CHECK("the census counts it as kept for the raw table before one is built", strstr(cls, "kept by the raw table (U2) 1 /") != NULL);
      mtl_pool_del(amem); mtl_drain(); munmap(amem, 1u << 20); }
    mtl_pool_add(qmem, 4u << 20); nvn_dirty_add_range(qmem, 4u << 20);
    upload_lookup(qmem, 4096);
    CHECK("an unaddressed pool an upload looked up is resident", pent(qmem).res);
    tick(4 * SEC); sub_empty(); settle();
    CHECK("an unaddressed upload-only pool leaves the set", !pent(qmem).res && pent(qmem).ev && !committed(pent(qmem).buf));
    mtl_pool_addressed_k(qmem, 4u << 20, AK_BUF);   // its address given out after it went
    { upl u; make(&u, qmem, &qpool, 64u << 10, 256, 128, 7); uint64_t s0 = g_up_big_srcs, n0 = g_unw_src_n;
      id<MTLTexture> t = upload_sub(&u);
      CHECK("its next upload reads through a batch buffer, and it stays out", g_up_big_srcs == s0 + 1 && g_unw_src_n == n0 + 1 && !pent(qmem).res);
      CHECK("the texels match", t && same_texels(t, &u)); mtl_tex_release(&u.t); free(u.ref); }
    { uint64_t r0 = g_unw_re[UNW_RE_RAW];
      mtl_sub_begin(); (void)gmem_map(); atomic_store(&q_seen, 0); atomic_store(&q_bad, 0); atomic_store(&q_want, atomic_load(&g_res_seq));
      CHECK("the raw table puts it back", pent(qmem).res && !pent(qmem).ev && g_unw_re[UNW_RE_RAW] == r0 + 1);
      CHECK("the submission completes", mtl_wait(mtl_sub_commit(), 10 * SEC)); mtl_drain(); atomic_store(&q_want, 0);
      printf("raw table re-add: queue commits checked %d, with the re-add not committed %d\n", atomic_load(&q_seen), atomic_load(&q_bad));
      CHECK("every queue commit after it found it committed", atomic_load(&q_seen) > 0 && atomic_load(&q_bad) == 0);
      settle(); CHECK("it is in the committed set", committed(pent(qmem).buf)); }
    { uint8_t *p2 = anon_mem(1u << 20); mtl_pool_add(p2, 1u << 20); mtl_pool_addressed_k(p2, 1u << 20, AK_TEX); upload_lookup(p2, 4096);
      tick(4 * SEC); sub_empty(); settle();
      CHECK("once a raw table exists, an addressed upload-only pool stays", pent(p2).res && !pent(p2).ev && pent(qmem).res);
      char cls[600]; pool_res_classes(cls, sizeof cls); printf("%s\n", cls);
      CHECK("the census line counts it as kept by the raw table", strstr(cls, "kept by the raw table (U2) 2 /") != NULL);
      mtl_pool_del(p2); }   // not unmapped: g_addr keeps its range, and a later pool at the same address would count as addressed

    // ---------- 12: overlapping pools, the note of a flushed batch ----------
    // Y holds the texture's whole storage, X holds its start but not its end: the upload's lookup (pool_find with the texture's length) reads Y's buffer. With g_plast cleared, as any
    // pool add or take-out on another thread does, a lookup of the address for 1 byte finds X (the last entry starting at or before it), and the note went there
    { uint8_t *ym = anon_mem(8u << 20), *xm = ym + (1u << 20); mtl_pool_add(ym, 8u << 20); mtl_pool_add(xm, 1u << 20);
      void *b; uint64_t o; t_tex_upload_lookup = 1; int ok = mtl_addr((uint64_t)(uintptr_t)xm, 2u << 20, &b, &o); t_tex_upload_lookup = 0; settle();
      int yi = -1, xi = -1; mu_lock(); for (int i = 0; i < g_npool; i++) { if (g_pools[i].key == ym) yi = i; if (g_pools[i].key == xm) xi = i; }
      id<MTLBuffer> yb = yi >= 0 ? g_pools[yi].buf : nil; pthread_mutex_unlock(&g_mu);
      CHECK("the upload's lookup reads Y's buffer", ok && yi >= 0 && xi >= 0 && (__bridge void *)yb == b);
      unsigned next = g_up_seq + 1;   // a batch opened after the lookup's, not back
      mu_lock(); g_plast = -1; unsigned x0 = g_pools[xi].up_seq; pthread_mutex_unlock(&g_mu);
      pool_up_note((uint64_t)(uintptr_t)xm, 2u << 20, b, next);
      mu_lock(); for (int i = 0; i < g_npool; i++) { if (g_pools[i].key == ym) yi = i; if (g_pools[i].key == xm) xi = i; }
      unsigned yn = g_pools[yi].up_seq, xn = g_pools[xi].up_seq; pthread_mutex_unlock(&g_mu);
      CHECK("the note lands on the pool whose buffer is read, not on another entry holding the address", yn == next && xn == x0);
      CHECK("the noted batch is not back", up_back_floor() < next);
      tick(4 * SEC); sub_empty(); settle();
      mu_lock(); int yres = 0; for (int i = 0; i < g_npool; i++) if (g_pools[i].key == ym) yres = g_pools[i].res; pthread_mutex_unlock(&g_mu);
      CHECK("the sweep keeps the read pool while that batch is out", yres && committed(yb));
      mtl_pool_del(xm); mtl_pool_del(ym); mtl_drain(); munmap(ym, 8u << 20); }

    // ---------- 1: the census ----------
    { uint8_t *a = anon_mem(1u << 20); mtl_pool_add(a, 1u << 20);
      void *b; uint64_t o, g;
      t_tex_upload_lookup = 1; mtl_addr((uint64_t)(uintptr_t)a, 4096, &b, &o); t_tex_upload_lookup = 0;
      mtl_gpu_addr((uint64_t)(uintptr_t)a, 4096, &b, &o, &g);   // on the same thread: before the census fix, a hit in the cache the upload's lookup filled (not counted)
      pool_ent e = pent(a);
      CHECK("an upload's lookup, then an other use on the same thread: both counted", e.n_tex_reads == 1 && e.n_other == 1);
      tick(4 * SEC); sub_empty(); settle();
      CHECK("a pool an other use looked up stays", pent(a).res && !pent(a).ev);
      mtl_pool_del(a); munmap(a, 1u << 20); }

    // ---------- 8: =m ----------
    uint8_t *bmem = anon_mem(1u << 20); mtl_pool_add(bmem, 1u << 20); upload_lookup(bmem, 4096);
    { uint64_t n0 = g_unw_n; g_unw_mode = 0; g_unw_measure = 1; tick(4 * SEC); sub_empty(); settle();
      CHECK("=m: nothing leaves, and the sweep counts what would", pent(bmem).res && !pent(bmem).ev && g_unw_n == n0 && g_unw_would_n >= 1);
      g_unw_mode = 1; g_unw_measure = 0; }

    // ---------- 7: the back-off ----------
    { tick(4 * SEC); sub_empty(); CHECK("an upload-only pool leaves", !pent(bmem).res && pent(bmem).ev);
      uint64_t r0 = g_unw_re[UNW_RE_UPLOAD];
      upload_lookup(bmem, 4096); uint64_t now = unw_now(); pool_ent e = pent(bmem);
      CHECK("an upload that finds it out puts it back (upload fallback)", e.res && !e.ev && g_unw_re[UNW_RE_UPLOAD] == r0 + 1);
      CHECK("a re-add within 10 s holds it back 10 s", e.ev_n == 1 && e.ev_hold >= now + 9 * SEC && e.ev_hold <= now + 10 * SEC);
      tick(4 * SEC); sub_empty(); CHECK("it stays while held", pent(bmem).res);
      tick(7 * SEC); sub_empty(); CHECK("it leaves once the hold has passed", !pent(bmem).res);
      upload_lookup(bmem, 4096); now = unw_now(); e = pent(bmem);
      CHECK("a second quick re-add holds it back 20 s", e.ev_n == 2 && e.ev_hold >= now + 19 * SEC && e.ev_hold <= now + 20 * SEC && !e.sticky);
      tick(21 * SEC); sub_empty(); CHECK("it leaves again", !pent(bmem).res);
      upload_lookup(bmem, 4096);
      CHECK("the third quick re-add makes it sticky", pent(bmem).sticky && pent(bmem).ev_n == 3);
      tick(200 * SEC); sub_empty(); CHECK("a sticky pool stays", pent(bmem).res);
      mtl_pool_del(bmem); munmap(bmem, 1u << 20); }

    // ---------- 2 and 6: the batch's feedback held back, then an upload after the unwire ----------
    const size_t PN = 16u << 20; uint8_t *pmem = file_mem(PN); memset(pmem, 0x33, PN);
    pool_t ppool = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = pmem, .size = PN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    mtl_pool_add(pmem, PN); nvn_dirty_add_range(pmem, PN);
    { upl u; make(&u, pmem, &ppool, 0, 512, 256, 21);
      g_up_src_refuse = 1;   // the upload looks the pool up (makes it resident), as when Metal refuses the batch buffer
      dispatch_semaphore_t hold = dispatch_semaphore_create(0), held = dispatch_semaphore_create(0);
      dispatch_async(g_feedback_q, ^{ dispatch_semaphore_signal(held); dispatch_semaphore_wait(hold, DISPATCH_TIME_FOREVER); });   // every feedback handler waits behind this
      dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER);
      mtl_sub_begin(); id<MTLTexture> t = tex_mtl(&u.t); uint64_t f1 = mtl_sub_commit();
      g_up_src_refuse = 0;
      pool_ent e = pent(pmem); id<MTLBuffer> pb = e.buf;
      CHECK("the upload made the pool resident and noted its batch", e.res && e.n_tex_reads == 1 && !e.n_other && e.up_seq == g_up_seq);
      tick(4 * SEC); mtl_sub_begin();   // the sweep, with the batch not back
      CHECK("held back: the pool stays, in the set", pent(pmem).res && in_objects(pb) && up_back_floor() < e.up_seq);
      uint64_t f2 = mtl_sub_commit();
      dispatch_semaphore_signal(hold);
      CHECK("both submissions complete", mtl_wait(f1, 10 * SEC) && mtl_wait(f2, 10 * SEC)); mtl_drain(); settle();
      CHECK("the batch is back", up_back_floor() >= e.up_seq);
      uint64_t s0 = atomic_load(&g_res_seq);
      tick(4 * SEC); sub_empty(); settle();
      e = pent(pmem);
      CHECK("back and idle 3 s: the pool leaves", !e.res && e.ev && !in_objects(pb));
      CHECK("the removal is committed: out of the committed set", atomic_load(&g_res_done) > s0 && !committed(pb));
      CHECK("its texels match", t && same_texels(t, &u)); mtl_tex_release(&u.t); free(u.ref); }
    { upl u; make(&u, pmem, &ppool, 4u << 20, 256, 256, 22); uint64_t s0 = g_up_big_srcs;
      id<MTLTexture> t = upload_sub(&u); pool_ent e = pent(pmem);
      CHECK("an upload after the unwire reads through a batch buffer, and the pool stays out", g_up_big_srcs == s0 + 1 && !e.res && e.ev);
      CHECK("the batch buffer has left the set with its batch", bufs_over(pmem, PN, nil) == 0);
      CHECK("its texels match", t && same_texels(t, &u)); mtl_tex_release(&u.t); free(u.ref); }

    // ---------- 4: a later GPU use puts it back before its queue commit ----------
    { uint8_t *dmem = anon_mem(1u << 20); mtl_pool_add(dmem, 1u << 20);
      pool_ent e = pent(pmem); CHECK("the pool is out before the copy", !e.res);
      for (size_t i = 0; i < 65536; i++) ((volatile uint8_t *)pmem)[(8u << 20) + i] = (uint8_t)(i * 13 + 1);
      mtl_sub_begin(); atomic_store(&q_seen, 0); atomic_store(&q_bad, 0);
      uint64_t r0 = g_unw_re[UNW_RE_OTHER];
      mtl_sub_copy((uint64_t)(uintptr_t)pmem + (8u << 20), (uint64_t)(uintptr_t)dmem, 65536);
      atomic_store(&q_want, t_res_seq);   // one past the replay's re-add
      CHECK("the copy's lookup puts it back (other use)", pent(pmem).res && g_unw_re[UNW_RE_OTHER] == r0 + 1);
      uint64_t f = mtl_sub_commit(); CHECK("the copy's submission completes", mtl_wait(f, 10 * SEC)); mtl_drain(); atomic_store(&q_want, 0);
      printf("in-flight re-add: queue commits checked %d, with the re-add not committed %d\n", atomic_load(&q_seen), atomic_load(&q_bad));
      CHECK("every queue commit from the copy's on found the re-add committed", atomic_load(&q_seen) > 0 && atomic_load(&q_bad) == 0);
      int ok = 1; for (size_t i = 0; i < 65536; i++) ok &= dmem[i] == (uint8_t)(i * 13 + 1);
      CHECK("the copy landed, no GPU error", ok && !mtl_last_commit_error());
      tick(10 * SEC); sub_empty(); CHECK("a pool an other use looked up never leaves again", pent(pmem).res);
      mtl_pool_del(dmem); munmap(dmem, 1u << 20); }

    // ---------- 3: the batch floor ----------
    { unsigned ns = g_up_nslots, seq = g_up_seq, back[UP_SLOTS_MAX]; for (unsigned j = 0; j < UP_SLOTS_MAX; j++) back[j] = atomic_load(&g_up_slot_back[j]);
      CHECK("no batch open", g_up_cb == nil);
      g_up_nslots = 3; g_up_seq = 5;   // batches 1..5: slots 0 1 2 0 1
      atomic_store(&g_up_slot_back[0], 4); atomic_store(&g_up_slot_back[1], 0); atomic_store(&g_up_slot_back[2], 3);
      CHECK("slot 1's first batch (2) not back: W 1", up_back_floor() == 1);
      atomic_store(&g_up_slot_back[1], 2);
      CHECK("slot 1's batch 5 not back: W 4", up_back_floor() == 4);
      atomic_store(&g_up_slot_back[0], 1); atomic_store(&g_up_slot_back[1], 5);
      CHECK("slot 0's batch 4 not back while slot 1's 5 is: W 3", up_back_floor() == 3);
      atomic_store(&g_up_slot_back[0], 4);
      CHECK("all back: W 5", up_back_floor() == 5);
      g_up_nslots = ns; g_up_seq = seq; for (unsigned j = 0; j < UP_SLOTS_MAX; j++) atomic_store(&g_up_slot_back[j], back[j]); }
    { const size_t RN = 224u << 20; uint8_t *rmem = anon_mem(RN);   // under BIG_MIN (256 MB since upstream 3dd1f7a65): one buffer of the whole pool; the third upload ends at 208 MB
      pool_t rpool = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = rmem, .size = RN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
      mtl_pool_add(rmem, RN); nvn_dirty_add_range(rmem, RN);
      upl u[3]; for (int i = 0; i < 3; i++) make(&u[i], rmem, &rpool, (size_t)(72 * i) << 20, 4096, 4096, 300 + i);
      g_up_src_refuse = 1; unsigned s0 = g_up_seq; id<MTLTexture> t[3];
      mtl_sub_begin(); for (int i = 0; i < 3; i++) t[i] = tex_mtl(&u[i].t); unsigned s1 = g_up_seq;
      CHECK("the staging flushed the batch partway through a texture", s1 >= s0 + 2);
      CHECK("the pool is noted with the batch that read it after the flush", pent(rmem).up_seq == s1);
      CHECK("the submission completes", mtl_wait(mtl_sub_commit(), 30 * SEC)); g_up_src_refuse = 0; mtl_drain(); settle();
      for (int i = 0; i < 3; i++) { CHECK("every texel matches", t[i] && same_texels(t[i], &u[i])); mtl_tex_release(&u[i].t); free(u[i].ref); }
      tick(4 * SEC); sub_empty(); CHECK("once its batches are back it leaves", !pent(rmem).res);
      mtl_drain(); nvn_dirty_remove_range(rmem); mtl_pool_del(rmem); mtl_drain(); munmap(rmem, RN); }

    // ---------- 9: byte-exact under the stress setting ----------
    { g_unw_stress = 1; const size_t XN = 8u << 20; uint8_t *xmem = file_mem(XN), *ymem = anon_mem(1u << 20); memset(xmem, 0, XN);
      pool_t xpool = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = xmem, .size = XN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
      mtl_pool_add(xmem, XN); nvn_dirty_add_range(xmem, XN); mtl_pool_add(ymem, 1u << 20);
      int ok = 1;
      for (int r = 0; r < 12; r++) {
          upl u; make(&u, xmem, &xpool, (size_t)(r % 6) << 20, 256 + 32 * (r % 3), 256, 500 + r);
          g_up_src_refuse = r % 2;   // every other one through the pool's own buffer (resident), the rest through a batch buffer
          id<MTLTexture> t = upload_sub(&u); g_up_src_refuse = 0;
          ok &= t && same_texels(t, &u); mtl_tex_release(&u.t); free(u.ref);
          tick(SEC);
      }
      CHECK("stress: every texel of 12 uploads matches, the pool going out and back between them", ok);
      CHECK("stress: the pool went out", g_unw_n > 0);
      g_unw_stress = 0;
      mtl_drain(); nvn_dirty_remove_range(xmem); mtl_pool_del(xmem); mtl_pool_del(ymem); mtl_drain(); munmap(xmem, XN); munmap(ymem, 1u << 20); }

    // ---------- 11: the wiring falls; clean pages can be dropped; a later upload pages in only its texture ----------
    { const size_t WN = 192u << 20; uint8_t *wmem = file_mem(WN);   // under BIG_MIN (256 MB): one buffer of the whole pool
      for (size_t i = 0; i < WN; i += 4096) wmem[i] = (uint8_t)(i >> 12);
      pool_t wpool = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = wmem, .size = WN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
      mtl_pool_add(wmem, WN); nvn_dirty_add_range(wmem, WN);
      upl u; make(&u, wmem, &wpool, 0, 512, 512, 900);   // 1 MB
      msync(wmem, WN, MS_SYNC);   // the pages clean, as the guest's texture data is once on disk
      g_up_src_refuse = 1; id<MTLTexture> t = upload_sub(&u); g_up_src_refuse = 0;
      CHECK("the large file-backed pool is resident", pent(wmem).res && uwired(wmem, WN) == 0);   // the commit's own mlock given back: only Metal pins it
      // The probe: the pages written back, then invalidated (msync MS_INVALIDATE), and the share still resident counted (mincore). Pinned pages stay; once nothing pins them they go,
      // as the kernel would take them under pressure. Metal lets a removed allocation's pages go a moment after the commit (seconds on an M-series Mac): the probe polls
      uint64_t sys0 = fw_wired(); double r0 = resident_share(wmem, WN); msync(wmem, WN, MS_SYNC); msync(wmem, WN, MS_INVALIDATE); r0 = resident_share(wmem, WN);
      for (size_t i = 0; i < WN; i += 4096) (void)((volatile uint8_t *)wmem)[i];   // back in (still pinned anyway)
      tick(4 * SEC); sub_empty(); settle();
      CHECK("the pool left the set", !pent(wmem).res && !committed(pent(wmem).buf));
      double r1 = 1; int ms = 0;
      for (; ms <= 10000 && r1 > 0.05; ms += 250) { usleep(250000); msync(wmem, WN, MS_INVALIDATE); r1 = resident_share(wmem, WN); }
      uint64_t sys1 = fw_wired();
      printf("page-ins: resident share after an invalidate: in the set %.2f, out of it %.2f (after %d ms); system wired %.1f -> %.1f MB (other processes move it too)\n", r0, r1, ms, sys0 / 1048576.0, sys1 / 1048576.0);
      CHECK("in the set the pool's pages are pinned (an invalidate keeps them)", r0 > 0.9);
      CHECK("out of it they are not: the wiring fell, the kernel can drop the clean pages", r1 < 0.05);
      upl v; make(&v, wmem, &wpool, 128u << 20, 512, 512, 901); msync(wmem, WN, MS_SYNC); msync(wmem, WN, MS_INVALIDATE);
      uint64_t p0 = rusage_pageins(NULL); id<MTLTexture> t2 = upload_sub(&v); uint64_t p1 = rusage_pageins(NULL);
      printf("page-ins: an upload of a 1 MB texture after the unwire: %llu page-ins; resident share of the pool %.3f\n", (unsigned long long)(p1 - p0), resident_share(wmem, WN));
      CHECK("its texels match", t && t2 && same_texels(t2, &v));
      mtl_tex_release(&u.t); mtl_tex_release(&v.t); free(u.ref); free(v.ref);
      mtl_drain(); nvn_dirty_remove_range(wmem); mtl_pool_del(wmem); mtl_drain(); munmap(wmem, WN); }

    { char cls[600]; pool_res_classes(cls, sizeof cls); printf("%s\n", cls); mtl_unwire_report(); }
    mtl_drain(); nvn_dirty_remove_range(pmem); nvn_dirty_remove_range(qmem); mtl_pool_del(pmem); mtl_pool_del(qmem); mtl_drain();
    printf("t_pool_unwire: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
