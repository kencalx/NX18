// The dirty-page tracker's address index (DM_NVN_DIRTY_INDEX, nvn_dirty.c idx_find / idx_edit): the page-fault hook and the host pre-write hook find the ranges holding an address
// through a sorted index instead of scanning every slot, and so does find_span, the containing range the replay's readers ask for (S2Arm 985c4fae). This test checks both against
// the scan and times them.
// 1. Lookup: about 5,000 ranges laid out as pools are (4 KB aligned, so neighbours share their rounded host pages), with nested and equal ranges mixed in; at every range's edges
//    (start - 1, start, end - 1, end) and random addresses, points and spans, the index names exactly the live slots the scan finds; again after random retirements and
//    registrations (slots reused for other memory).
// 2. Faults: a write to a host page two ranges share releases and stamps both (the scan's rule); a write at a range's last byte is caught; the hook's counter moves.
// 3. Concurrency: with 5,000 other ranges live, one thread keeps registering, protecting and retiring pools (each change rewrites the index) while others write them directly
//    (faults), prepare host writes into them, and a sentinel thread protects and writes a pool of its own and checks each write is seen. No hang, no crash, no missed write.
// 4. Benchmark (printed, not judged beyond the index being faster): the lookup alone, scan against index, with 5,000 ranges; and real faults, each a write to a protected page,
//    the hook's time per fault through either path (the same counter the log line reads); and the time of an index rewrite.
// `./t_dirty_index` runs all four; DM_NVN_DIRTY_INDEX=0 runs 2 and 3 through the scan (1 and 4 compare both paths in any case).
#include "../nvn/nvn_dirty.c"
#include <stdio.h>

module_t *g_mod;
int g_nmod;
module_t *module_of(const void *p) { (void)p; return NULL; }
void crash_install(void);

static int g_fail;
#define EXPECT(name, want, got) do { \
    long long want_ = (long long)(want), got_ = (long long)(got); \
    printf("%-62s expected %-6lld → got %-6lld %s\n", name, want_, got_, want_ == got_ ? "✓" : "✗"); \
    if (want_ != got_) g_fail++; \
} while (0)

static uint32_t rnd(uint32_t *s) { *s ^= *s << 13; *s ^= *s >> 17; *s ^= *s << 5; return *s; }
static double ns_of(uint64_t ticks) { return (double)ticks * g_tb.numer / g_tb.denom; }
static int cmp_u32(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return x < y ? -1 : x > y; }

// The scan's answer: every live slot whose range overlaps [a, e)
static int scan_find(uintptr_t a, uintptr_t e, uint32_t *out, int cap) {
    int k = 0, n = atomic_load(&g_nr);
    for (int i = 0; i < n; i++) { range_t *r = rg(i); if (live_at(i) && rb(r) < e && re(r) > a) { if (k < cap) out[k] = (uint32_t)i; k++; } }
    return k;
}
// The index's candidates, filtered as the hooks filter them (live, the slot's own bounds), against the scan
static long g_checked;
static int same(uintptr_t a, uintptr_t e) {
    uint32_t hi[IDX_HITS], sc[256]; int k = idx_find(a, e, hi), m = scan_find(a, e, sc, 256);
    if (k < 0) return m > IDX_HITS;   // the index declines only for more candidates than it carries
    int j = 0;
    for (int i = 0; i < k; i++) { range_t *r = rg((int)hi[i]); if (live_at((int)hi[i]) && rb(r) < e && re(r) > a) hi[j++] = hi[i]; }
    g_checked++;
    if (j != m) return 0;
    qsort(hi, (size_t)j, sizeof *hi, cmp_u32);   // the scan's are in slot order
    return !memcmp(hi, sc, (size_t)j * sizeof *hi);
}
// find_span (the containing range for the replay's readers) against the scan's rule: the lowest live slot that holds [a, e) whole
static long g_span_checked;
static int same_span(uintptr_t a, uintptr_t e) {
    int n = atomic_load(&g_nr); range_t *want = NULL;
    for (int i = 0; i < n && !want; i++) { range_t *r = rg(i); if (live_at(i) && a >= rb(r) && e <= re(r)) want = r; }
    g_span_checked++;
    return find_span(a, e - a) == want && find_span(a, e - a) == want;   // twice: the second may come from the thread's cache
}
// Every edge of every live range, and random points and spans
static int check_all(uint8_t *arena, size_t size, uint32_t *s, int randoms) {
    int bad = 0, n = atomic_load(&g_nr);
    for (int i = 0; i < n; i++) {
        if (!live_at(i)) continue;
        uintptr_t b = rb(rg(i)), e = re(rg(i)), pts[4] = {b - 1, b, e - 1, e};
        for (int k = 0; k < 4; k++) { bad += !same(pts[k], pts[k] + 1); bad += !same(pts[k], pts[k] + 4096); }
        bad += !same(b, e);
        bad += !same_span(b, e); bad += !same_span(b, b + 1); bad += !same_span(e - 1, e); bad += !same_span(b - 1, b + 1);
    }
    for (int k = 0; k < randoms; k++) {
        uintptr_t a = (uintptr_t)arena + rnd(s) % size;
        bad += !same(a, a + 1); bad += !same(a, a + 1 + rnd(s) % (256 * 1024));
        bad += !same_span(a, a + 1 + rnd(s) % (64 * 1024));
    }
    return bad;
}

enum { NPOOL = 5000 };
static size_t g_page;

static void test_lookup(void) {
    printf("lookup against the scan:\n");
    size_t size = (size_t)NPOOL * 96 * 1024;   // reserved, never touched: the lookups read no guest memory
    uint8_t *arena = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (arena == MAP_FAILED) { perror("mmap"); exit(2); }
    uint32_t s = 0x2545f491; uint8_t *pool[NPOOL + 64]; int np = 0;
    // Pools laid end to end at 4 KB granularity, a gap now and then: neighbours share a rounded host page
    size_t off = 0;
    while (np < NPOOL && off + 128 * 1024 < size) {
        size_t len = (1 + rnd(&s) % 20) * 4096;
        pool[np++] = arena + off; nvn_dirty_add_range(arena + off, len);
        off += len + (rnd(&s) % 8 == 0 ? (rnd(&s) % 4) * 4096 : 0);
    }
    // Nested ranges (a pool inside another's memory), one holding many, and two with the same start
    for (int k = 0; k < 40; k++) { size_t o = (rnd(&s) % (off / 4096 - 64)) * 4096, len = (1 + rnd(&s) % 48) * 4096; pool[np++] = arena + o + 4096 * (k & 1); nvn_dirty_add_range(arena + o + 4096 * (k & 1), len); }
    pool[np++] = arena + 8 * 4096; nvn_dirty_add_range(arena + 8 * 4096, 2048 * 4096);
    pool[np++] = arena + 9 * 4096 + 512; nvn_dirty_add_range(arena + 9 * 4096 + 512, 4096);
    EXPECT("index on (default)", 1, nvn_dirty_index_on());
    int bad = check_all(arena, off, &s, 20000);
    EXPECT("registered: index = scan at every edge and random point/span", 0, bad);
    // Retire and register at random: slots are reused for other memory and the index is rewritten each time
    for (int k = 0; k < 3000; k++) {
        int j = (int)(rnd(&s) % (uint32_t)np);
        nvn_dirty_remove_range(pool[j]);
        size_t o = (rnd(&s) % (off / 4096 - 32)) * 4096 + (rnd(&s) % 3) * 1024, len = (1 + rnd(&s) % 24) * 4096;
        pool[j] = arena + o; nvn_dirty_add_range(arena + o, len);
    }
    bad = check_all(arena, off, &s, 20000);
    EXPECT("after 3,000 retirements and registrations: index = scan", 0, bad);
    uint32_t hi[IDX_HITS]; int k = idx_find((uintptr_t)arena + off + 64 * 1024 * 1024, (uintptr_t)arena + off + 64 * 1024 * 1024 + 1, hi);
    EXPECT("an address past every range: no candidate", 0, k);
    printf("  (%ld lookups and %ld containing-range lookups compared, %d ranges live)\n", g_checked, g_span_checked, atomic_load(&g_live));
    for (int j = 0; j < np; j++) nvn_dirty_remove_range(pool[j]);
    EXPECT("all retired: index empty", 0, atomic_load(&g_idx[atomic_load(&g_idx_cur) & 1].n));
    munmap(arena, size);
}

static void test_faults(void) {
    printf("faults through the hook (%s):\n", nvn_dirty_index_on() ? "index" : "scan");
    size_t pg = g_page;
    uint8_t *m = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    uint8_t *a = m, *b = m + pg - 4096;   // a: [m, m + pg - 4 KB); b from there for 2 pages: both round to m's first host page
    nvn_dirty_add_range(a, pg - 4096); nvn_dirty_add_range(b, 2 * pg);
    uint64_t c0, n0; nvn_dirty_fault_stats(&c0, &n0);
    uint64_t st = nvn_dirty_now();
    nvn_dirty_protect(a, 16); nvn_dirty_protect(b, pg); nvn_dirty_protect(m + 2 * pg, pg);   // the shared page protected in both ranges (b's span runs past a's end), b's second and third pages
    a[100] = 1;   // one write to the shared page
    EXPECT("shared page: range a sees the write", 1, nvn_dirty_since(a, 16, st));
    EXPECT("shared page: range b sees it too (both released)", 1, nvn_dirty_since(b, pg, st));
    EXPECT("b's second page not written", 0, nvn_dirty_since(m + pg, 16, st));
    EXPECT("b's third page not written yet", 0, nvn_dirty_since(m + 2 * pg, 16, st));
    m[3 * pg - 1] = 2;   // the last byte of b's (rounded) range
    EXPECT("a write at the range's last byte is seen", 1, nvn_dirty_since(m + 2 * pg, 16, st));
    uint64_t c1, n1; nvn_dirty_fault_stats(&c1, &n1);
    EXPECT("the hook counted the two faults", 2, c1 - c0);
    EXPECT("and some time in them", 1, n1 > n0);
    nvn_dirty_remove_range(a); nvn_dirty_remove_range(b);
    m[0] = 3; m[3 * pg] = 4;   // writable after retirement
    munmap(m, 4 * pg);
}

// Concurrency: churn over a small arena among many live ranges, writers and host writers in it, and a sentinel pool protected and written over and over
enum { CPAGES = 64, CLIVE = 4 };
static uint8_t *g_carena, *g_sentinel;
static _Atomic int g_stop;
static _Atomic uint64_t g_cwrites, g_cpreps, g_sent_rounds, g_sent_missed;
static void *churn(void *arg) {
    int rounds = (int)(intptr_t)arg; uint32_t s = 0x9e3779b9; uint8_t *live[CLIVE] = {0};
    for (int k = 0; k < rounds; k++) {
        int j = k % CLIVE;
        if (live[j]) nvn_dirty_remove_range(live[j]);
        size_t first = rnd(&s) % (CPAGES / 2), len = (1 + rnd(&s) % (CPAGES / 2)) * g_page - (rnd(&s) % 4) * 4096;
        live[j] = g_carena + first * g_page + (rnd(&s) % 4) * 4096;
        nvn_dirty_add_range(live[j], len);
        nvn_dirty_protect(live[j], len);
    }
    for (int j = 0; j < CLIVE; j++) if (live[j]) nvn_dirty_remove_range(live[j]);
    atomic_store(&g_stop, 1);
    return NULL;
}
static void *writer(void *arg) {
    uint32_t s = (uint32_t)(intptr_t)arg;
    while (!atomic_load(&g_stop)) { __atomic_store_n(&g_carena[rnd(&s) % (CPAGES * g_page)], (uint8_t)s, __ATOMIC_RELAXED); atomic_fetch_add(&g_cwrites, 1); }   // atomic: the test's own threads write the same bytes (TSan)
    return NULL;
}
static void *preparer(void *arg) {
    uint32_t s = (uint32_t)(intptr_t)arg;
    while (!atomic_load(&g_stop)) {
        size_t o = rnd(&s) % (CPAGES * g_page), len = 1 + rnd(&s) % (2 * g_page); if (o + len > CPAGES * g_page) len = CPAGES * g_page - o;
        dm_guest_write_prepare(g_carena + o, len); for (size_t i = 0; i < len; i += 64) __atomic_store_n(&g_carena[o + i], (uint8_t)s, __ATOMIC_RELAXED); atomic_fetch_add(&g_cpreps, 1);
    }
    return NULL;
}
static void *sentinel(void *arg) {   // a stable pool while the index is rewritten around it: every write after a protect is seen
    int me = (int)(intptr_t)arg; uint32_t s = 77 + (uint32_t)me;   // pages of its own: a write another thread's fault is still stamping would read clean for a moment
    while (!atomic_load(&g_stop)) {
        uint64_t st = nvn_dirty_now(); size_t p = 2 * (size_t)me + rnd(&s) % 2;
        nvn_dirty_protect(g_sentinel + p * g_page, g_page);
        __atomic_store_n(&g_sentinel[p * g_page + rnd(&s) % g_page], 1, __ATOMIC_RELAXED);
        if (!nvn_dirty_since(g_sentinel + p * g_page, g_page, st)) {
            atomic_fetch_add(&g_sent_missed, 1);
            range_t *r = find_span((uintptr_t)g_sentinel, 4 * g_page);
            printf("  missed: page %zu stamp %llu now %llu gen %llu state %d\n", p, (unsigned long long)st, (unsigned long long)nvn_dirty_now(),
                   r ? (unsigned long long)atomic_load(&r->gen[((uintptr_t)g_sentinel + p * g_page - rb(r)) >> g_shift]) : 0ull, r ? atomic_load(&r->state[((uintptr_t)g_sentinel + p * g_page - rb(r)) >> g_shift]) : -1);
        }
        atomic_fetch_add(&g_sent_rounds, 1);
    }
    return NULL;
}
static void test_concurrent(int rounds) {
    printf("concurrent rewrites and faults (%s):\n", nvn_dirty_index_on() ? "index" : "scan");
    size_t bsize = (size_t)NPOOL * 8192;
    uint8_t *bg = mmap(NULL, bsize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    g_carena = mmap(NULL, CPAGES * g_page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    g_sentinel = mmap(NULL, 4 * g_page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (bg == MAP_FAILED || g_carena == MAP_FAILED || g_sentinel == MAP_FAILED) { perror("mmap"); exit(2); }
    for (int i = 0; i < NPOOL / 2; i++) nvn_dirty_add_range(bg + (size_t)i * 8192, 8192);   // below and above the arenas in the index, whichever way mmap placed them
    nvn_dirty_add_range(g_sentinel, 4 * g_page);
    for (int i = NPOOL / 2; i < NPOOL; i++) nvn_dirty_add_range(bg + (size_t)i * 8192, 8192);
    uint64_t c0, n0; nvn_dirty_fault_stats(&c0, &n0);
    pthread_t c, t[6];
    pthread_create(&t[0], NULL, writer, (void *)(intptr_t)0x1234567);
    pthread_create(&t[1], NULL, writer, (void *)(intptr_t)0x7654321);
    pthread_create(&t[2], NULL, preparer, (void *)(intptr_t)0x2345678);
    pthread_create(&t[3], NULL, preparer, (void *)(intptr_t)0x3456789);
    pthread_create(&t[4], NULL, sentinel, (void *)(intptr_t)0);
    pthread_create(&t[5], NULL, sentinel, (void *)(intptr_t)1);
    pthread_create(&c, NULL, churn, (void *)(intptr_t)rounds);
    pthread_join(c, NULL);
    for (int i = 0; i < 6; i++) pthread_join(t[i], NULL);
    uint64_t c1, n1; nvn_dirty_fault_stats(&c1, &n1);
    printf("  %d rounds, %llu writes, %llu host writes, %llu sentinel rounds, %llu hook calls\n", rounds, (unsigned long long)g_cwrites, (unsigned long long)g_cpreps,
           (unsigned long long)g_sent_rounds, (unsigned long long)(c1 - c0));
    EXPECT("sentinel writes missed", 0, g_sent_missed);
    EXPECT("sentinel ran", 1, g_sent_rounds > 0);
    nvn_dirty_remove_range(g_sentinel);
    for (int i = 0; i < NPOOL; i++) nvn_dirty_remove_range(bg + (size_t)i * 8192);
    EXPECT("pools left registered", 0, atomic_load(&g_live));
    for (size_t o = 0; o < CPAGES * g_page; o += g_page) g_carena[o] = 1;   // every page writable again (a protected one would crash here)
    for (size_t o = 0; o < 4 * g_page; o += g_page) g_sentinel[o] = 1;
    munmap(bg, bsize); munmap(g_carena, CPAGES * g_page); munmap(g_sentinel, 4 * g_page);
}

// Benchmark: NPOOL pools end to end (4 KB granular sizes), as Ocarina of Time keeps about 5,000 live
static void bench(void) {
    printf("benchmark, %d ranges live:\n", NPOOL);
    size_t size = (size_t)NPOOL * 3 * g_page;
    uint8_t *arena = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (arena == MAP_FAILED) { perror("mmap"); exit(2); }
    uint32_t s = 0x1b873593; size_t off = 0; uint8_t *pool[NPOOL]; size_t plen[NPOOL];
    for (int i = 0; i < NPOOL; i++) { plen[i] = (2 + rnd(&s) % 8) * 4096; pool[i] = arena + off; off += plen[i]; nvn_dirty_add_range(pool[i], plen[i]); }
    // Lookup alone: random addresses, the scan's loop (on_fault's before the index) against idx_find
    enum { NQ = 200000 }; uintptr_t *q = malloc(NQ * sizeof *q); for (int i = 0; i < NQ; i++) q[i] = (uintptr_t)arena + rnd(&s) % off;
    volatile uint64_t sink = 0; int n = atomic_load(&g_nr);
    uint64_t t0 = mach_absolute_time();
    for (int i = 0; i < NQ / 20; i++) { uintptr_t a = q[i]; for (int j = 0; j < n; j++) { range_t *r = rg(j); if (live_at(j) && a >= rb(r) && a < re(r)) sink += (uint64_t)j; } }
    double scan_ns = ns_of(mach_absolute_time() - t0) / (NQ / 20);
    t0 = mach_absolute_time();
    for (int i = 0; i < NQ; i++) { uint32_t hit[IDX_HITS]; int k = idx_find(q[i], q[i] + 1, hit); for (int j = 0; j < k; j++) sink += hit[j]; }
    double idx_ns = ns_of(mach_absolute_time() - t0) / NQ;
    printf("  lookup alone: scan %.0f ns, index %.1f ns (%.0fx)\n", scan_ns, idx_ns, scan_ns / idx_ns);
    EXPECT("the index lookup is faster than the scan", 1, idx_ns < scan_ns);
    // find_span (nvn_dirty_span and the replay's readers): the containing range, through the scan (index off) and the index, at addresses no thread cache holds
    double span_ns[2];
    for (int mode = 0; mode < 2; mode++) {
        atomic_store(&g_idx_on, mode); int nq = mode ? NQ : NQ / 20;
        t0 = mach_absolute_time();
        for (int i = 0; i < nq; i++) sink += (uintptr_t)find_span(q[i] & ~(uintptr_t)63, 64) != 0;
        span_ns[mode] = ns_of(mach_absolute_time() - t0) / nq;
    }
    atomic_store(&g_idx_on, 1);
    printf("  containing range (find_span): scan %.0f ns, index %.1f ns (%.0fx)\n", span_ns[0], span_ns[1], span_ns[0] / span_ns[1]);
    EXPECT("find_span through the index is faster than the scan", 1, span_ns[1] < span_ns[0]);
    // Real faults: protect pages, write each once; the hook's time per fault through either path
    enum { NF = 4000 };
    double per[2];
    for (int mode = 0; mode < 2; mode++) {
        atomic_store(&g_idx_on, mode);   // nothing registers or retires meanwhile, so the index stays as it is while off
        uint8_t *pages[NF];
        for (int i = 0; i < NF; i++) { int p = (int)(rnd(&s) % (uint32_t)NPOOL); pages[i] = pool[p] + (rnd(&s) % plen[p]); nvn_dirty_protect(pages[i], 1); }
        uint64_t c0, n0, c1, n1; nvn_dirty_fault_stats(&c0, &n0);
        uint64_t w0 = mach_absolute_time();
        for (int i = 0; i < NF; i++) *(volatile uint8_t *)pages[i] = 1;
        double wall = ns_of(mach_absolute_time() - w0);
        nvn_dirty_fault_stats(&c1, &n1);
        per[mode] = c1 > c0 ? (double)(n1 - n0) / (c1 - c0) : 0;
        printf("  real faults (%s): %llu faults, hook %.2f us each, a write with its fault %.2f us\n", mode ? "index" : "scan", (unsigned long long)(c1 - c0), per[mode] / 1e3, wall / NF / 1e3);
    }
    atomic_store(&g_idx_on, 1);
    printf("  hook time per fault: scan %.2f us -> index %.2f us; at Ocarina's ~49 faults a frame: %.3f -> %.3f ms a frame\n", per[0] / 1e3, per[1] / 1e3, per[0] * 49 / 1e6, per[1] * 49 / 1e6);
    uint64_t e0 = atomic_load(&g_idx_edits), k0 = atomic_load(&g_idx_ticks);
    for (int i = 0; i < 200; i++) { nvn_dirty_remove_range(pool[i]); nvn_dirty_add_range(pool[i], plen[i]); }
    printf("  index rewrite (one registration or retirement): %.1f us\n", ns_of(atomic_load(&g_idx_ticks) - k0) / (double)(atomic_load(&g_idx_edits) - e0) / 1e3);
    for (int i = 0; i < NPOOL; i++) nvn_dirty_remove_range(pool[i]);
    free(q); munmap(arena, size); (void)sink;
}

int main(int argc, char **argv) {
    crash_install();
    alarm(120);
    g_page = (size_t)getpagesize();
    const char *v = getenv("DM_NVN_DIRTY_INDEX"); int off = v && !strcmp(v, "0");
    if (!off) test_lookup();
    else { nvn_dirty_add_range(&g_page, 1); nvn_dirty_remove_range(&g_page); EXPECT("DM_NVN_DIRTY_INDEX=0: index off", 0, nvn_dirty_index_on()); }
    test_faults();
    test_concurrent(argc > 1 ? atoi(argv[1]) : 20000);
    if (!off) bench();
    printf("t_dirty_index: %s\n", g_fail ? "FAILED" : "ok");
    return g_fail != 0;
}
