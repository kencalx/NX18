// The wait-list trims (DM_WAIT_TRIM, hle_thread.c pick_more) wake the same waiters in the same order as the rescans they replace: ArbitrateUnlock, SignalProcessWideKey and
// SignalToAddress over random wait lists (kinds, keys, addresses, priorities, counts, values), run once with each mode from the same seed and compared wake by wake, with every
// waiter's state and every guest word after each call; and the kernel order on a few lists written out by hand.
// Built with DM_TEST_WAIT_TRIM_BAD (a waiter count off by one), --expect-mismatch passes only if the comparison catches it: the negative control.
// --bench: ns per call under G with 48 blocked threads, best of 5
#include "../hle_thread.c"
#include <assert.h>

enum { NPOOL = 48, NW = 4, MAXLOG = 1 << 16 };
static thr_t pool[NPOOL];
static _Atomic uint32_t locks[NW], keys[NW], addrs[NW];
static uint64_t g_log[MAXLOG]; static int g_nlog;
static void rec(uint64_t v) { assert(g_nlog < MAXLOG); g_log[g_nlog++] = v; }
void dm_test_woken(thr_t *t) { rec(0xAA00000000ull | (uint64_t)(t - pool)); }

static uint64_t rng;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static void reset(void) {
    g_lock(); g_wait = NULL; g_unlock();
    for (int i = 0; i < NPOOL; i++) { memset(&pool[i], 0, sizeof pool[i]); pthread_cond_init(&pool[i].cv, NULL); pthread_cond_init(&pool[i].pcv, NULL); pool[i].mask = 2; }
}
static void block_fake(thr_t *t, int kind) {   // what block() does to the list, for a thread that never runs
    g_lock(); t->wkind = kind; t->woke = 0; t->next = g_wait; g_wait = t; t->wseq = ++g_wseq; g_unlock();
}
static uint64_t g_seq0;
static void snapshot(void) {
    g_lock();
    for (int i = 0; i < NW; i++) { rec(atomic_load(&locks[i])); rec(atomic_load(&keys[i])); rec(atomic_load(&addrs[i])); }
    for (int i = 0; i < NPOOL; i++) { thr_t *t = &pool[i]; rec((uint64_t)t->wkind << 56 | (uint64_t)t->woke << 48 | (t->wseq ? t->wseq - g_seq0 : 0)); rec(t->waddr); rec(t->wtag); }
    for (thr_t *t = g_wait; t; t = t->next) rec(0xBB00000000ull | (uint64_t)(t - pool));
    g_unlock();
}
static void call(int num, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    uint64_t r[32] = {a0, a1, a2, a3};
    rec(0xCC00000000ull | (uint64_t)num);
    svc_thread_impl(num, r);
    thr_t *me = pthread_getspecific(g_keythr); if (me) me->yield_pending = 0;
    rec(r[0]); snapshot();
}
// One random scenario and call sequence, logged
static void scenario(uint64_t seed, int trim) {
    g_wait_trim = trim; g_nlog = 0; rng = seed; reset(); g_seq0 = g_wseq;
    for (int i = 0; i < NW; i++) { atomic_store(&locks[i], rnd() % 3 ? (uint32_t)(0x2000 + i) | WAITERS_BIT : 0); atomic_store(&keys[i], 1); atomic_store(&addrs[i], (uint32_t)(rnd() % 4)); }
    static const int prios[] = { 28, 30, 30, 44, 44, 44, 59 };
    int n = (int)(rnd() % (NPOOL + 1));
    for (int i = 0; i < n; i++) {
        thr_t *t = &pool[i]; int kind = 1 + (int)(rnd() % 3); int w = (int)(rnd() % NW);
        t->prio = prios[rnd() % (sizeof prios / sizeof prios[0])]; t->wtag = 0x1000 + (uint32_t)i;
        if (kind == 1) t->waddr = (uint64_t)&locks[w];
        else if (kind == 2) { t->wkey = (uint64_t)&keys[w]; t->waddr = (uint64_t)&locks[rnd() % NW]; }
        else t->waddr = (uint64_t)&addrs[w];
        block_fake(t, kind);
    }
    snapshot();
    static const int counts[] = { -1, 0, 1, 1, 2, 3, 5 };
    for (int op = 0; op < 16; op++) {
        int w = (int)(rnd() % NW), cnt = counts[rnd() % (sizeof counts / sizeof counts[0])];
        switch (rnd() % 3) {
        case 0: call(0x1B, (uint64_t)&locks[w], 0, 0, 0); break;
        case 1: call(0x1D, (uint64_t)&keys[w], (uint64_t)(int64_t)cnt, 0, 0); break;
        default: { int type = (int)(rnd() % 3); uint32_t v = rnd() % 4 ? atomic_load(&addrs[w]) : (uint32_t)(rnd() % 4);
                   call(0x35, (uint64_t)&addrs[w], (uint64_t)type, v, (uint64_t)(int64_t)cnt); }
        }
    }
    for (int i = 0; i < NPOOL; i++) { pthread_cond_destroy(&pool[i].cv); pthread_cond_destroy(&pool[i].pcv); }
}
static uint64_t g_old[MAXLOG]; static int g_nold;
static int differential(int seeds) {
    int bad = 0; long wakes = 0;
    for (int s = 1; s <= seeds && !bad; s++) {
        uint64_t seed = 0x9e3779b97f4a7c15ull * (uint64_t)s;
        scenario(seed, 0); memcpy(g_old, g_log, sizeof g_log[0] * (size_t)g_nlog); g_nold = g_nlog;
        scenario(seed, 1);
        for (int i = 0; i < g_nlog; i++) wakes += (g_log[i] >> 32) == 0xAA;
        if (g_nold != g_nlog || memcmp(g_old, g_log, sizeof g_log[0] * (size_t)g_nlog)) {
            int i = 0; while (i < g_nlog && i < g_nold && g_old[i] == g_log[i]) i++;
            printf("seed %d: the modes differ at log entry %d (rescans %#llx, trimmed %#llx)\n", s, i, i < g_nold ? (unsigned long long)g_old[i] : 0ull, i < g_nlog ? (unsigned long long)g_log[i] : 0ull);
            bad = 1;
        }
    }
    if (!bad) printf("PASS: %d random wait lists, %ld wakes: the same waiters woken in the same order, the same waiter states and guest words with DM_WAIT_TRIM on and off\n", seeds, wakes);
    return !bad;
}
// The kernel order written out: lower priority number first, at equal priority the earlier wait first
static int kernel_order(void) {
    int ok = 1;
    for (int trim = 0; trim <= 1; trim++) {
        g_wait_trim = trim; g_nlog = 0; reset();
        atomic_store(&addrs[0], 0);
        int prio[] = { 44, 30, 30, 59, 30 };
        for (int i = 0; i < 5; i++) { pool[i].prio = prio[i]; pool[i].waddr = (uint64_t)&addrs[0]; block_fake(&pool[i], 3); }
        pool[5].prio = 10; pool[5].waddr = (uint64_t)&addrs[1]; block_fake(&pool[5], 3);   // another address: not woken
        uint64_t r[32] = {(uint64_t)&addrs[0], 0, 0, (uint64_t)-1}; svc_thread_impl(0x35, r);
        const int want[] = { 1, 2, 4, 0, 3 }; int got = 0;
        for (int i = 0; i < g_nlog; i++) if ((g_log[i] >> 32) == 0xAA) { ok &= got < 5 && (int)(g_log[i] & 0xffffffff) == want[got]; got++; }
        ok &= got == 5 && !pool[5].woke && g_wait == &pool[5];
        // two lock waiters: the first gets the lock with the waiters bit, the second without it
        g_nlog = 0; atomic_store(&locks[0], 0x2000 | WAITERS_BIT);
        pool[6].prio = 44; pool[6].waddr = (uint64_t)&locks[0]; pool[6].wtag = 0x1006; block_fake(&pool[6], 1);
        pool[7].prio = 30; pool[7].waddr = (uint64_t)&locks[0]; pool[7].wtag = 0x1007; block_fake(&pool[7], 1);
        r[0] = (uint64_t)&locks[0]; svc_thread_impl(0x1B, r); ok &= atomic_load(&locks[0]) == (0x1007 | WAITERS_BIT) && pool[7].woke && !pool[6].woke;
        r[0] = (uint64_t)&locks[0]; svc_thread_impl(0x1B, r); ok &= atomic_load(&locks[0]) == 0x1006 && pool[6].woke;
        r[0] = (uint64_t)&locks[0]; svc_thread_impl(0x1B, r); ok &= atomic_load(&locks[0]) == 0;
        // SignalProcessWideKey with one of two waiters: the key stays 1; with the last, it goes to 0
        atomic_store(&keys[0], 1); atomic_store(&locks[1], 0);
        for (int i = 8; i < 10; i++) { pool[i].prio = 44; pool[i].wkey = (uint64_t)&keys[0]; pool[i].waddr = (uint64_t)&locks[1]; pool[i].wtag = 0x1000 + (uint32_t)i; block_fake(&pool[i], 2); }
        r[0] = (uint64_t)&keys[0]; r[1] = 1; svc_thread_impl(0x1D, r); ok &= atomic_load(&keys[0]) == 1 && pool[8].woke && atomic_load(&locks[1]) == 0x1008;
        r[0] = (uint64_t)&keys[0]; r[1] = 1; svc_thread_impl(0x1D, r); ok &= atomic_load(&keys[0]) == 0 && pool[9].wkind == 1 && atomic_load(&locks[1]) == (0x1008 | WAITERS_BIT);
        thr_t *me = pthread_getspecific(g_keythr); if (me) me->yield_pending = 0;
        for (int i = 0; i < NPOOL; i++) { pthread_cond_destroy(&pool[i].cv); pthread_cond_destroy(&pool[i].pcv); }
    }
    printf("%s: kernel order of wakes, the lock's waiters bit and the condition key in both modes\n", ok ? "PASS" : "FAIL");
    return ok;
}
// Under G per call, 48 blocked threads on other addresses and one waiter on this one (re-blocked after each wake)
static double bench(int trim, int which) {
    g_wait_trim = trim; reset(); g_nlog = 0;
    for (int i = 1; i < NPOOL; i++) { pool[i].prio = 44; pool[i].waddr = (uint64_t)&addrs[1 + i % 3]; block_fake(&pool[i], 3); }
    thr_t *t = &pool[0]; t->prio = 44; t->wtag = 0x1000;
    enum { N = 200000 };
    double best = 1e9;
    for (int r = 0; r < 5; r++) {
        uint64_t ns = 0;
        for (int i = 0; i < N; i++) {
            g_nlog = 0;
            if (which == 0) { atomic_store(&locks[0], 0x2000 | WAITERS_BIT); t->waddr = (uint64_t)&locks[0]; block_fake(t, 1); }
            else if (which == 1) { atomic_store(&keys[0], 1); atomic_store(&locks[0], 0); t->wkey = (uint64_t)&keys[0]; t->waddr = (uint64_t)&locks[0]; block_fake(t, 2); }
            else { t->waddr = (uint64_t)&addrs[0]; block_fake(t, 3); }
            uint64_t q[32] = { which == 0 ? (uint64_t)&locks[0] : which == 1 ? (uint64_t)&keys[0] : (uint64_t)&addrs[0], which == 1 ? 1 : 0, 0, which == 1 ? 0 : 1 };
            uint64_t t0 = now_ns(); svc_thread_impl(which == 0 ? 0x1B : which == 1 ? 0x1D : 0x35, q); ns += now_ns() - t0;
            if (t->wkind) { g_lock(); wait_unlink(t); t->wkind = 0; g_unlock(); }
        }
        double v = (double)ns / N; if (v < best) best = v;
    }
    thr_t *me = pthread_getspecific(g_keythr); if (me) me->yield_pending = 0;
    return best;
}

int main(int argc, char **argv) {
    svc_thread_main_init();
    if (argc > 1 && !strcmp(argv[1], "--bench")) {
        const char *what[] = { "ArbitrateUnlock, one waiter", "SignalProcessWideKey(1), one waiter", "SignalToAddress(0, 1), one waiter" };
        for (int w = 0; w < 3; w++) printf("%s among 48 blocked: rescans %.0f ns, trimmed %.0f ns\n", what[w], bench(0, w), bench(1, w));
        return 0;
    }
    int expect_mismatch = argc > 1 && !strcmp(argv[1], "--expect-mismatch");
    int same = differential(expect_mismatch ? 2000 : 5000);
    if (expect_mismatch) { printf("%s: the off-by-one waiter count is caught\n", same ? "FAIL" : "PASS"); return same; }
    int ok = kernel_order();
    return !(same && ok);
}
