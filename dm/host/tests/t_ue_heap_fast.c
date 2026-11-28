// Unreal's heap with per-thread bookkeeping (hle_uemalloc.c, DM_UE_HEAP_FAST): eight threads allocate, reallocate and free blocks of every size class at once; each keeps a block it
// just freed readable for LATE_T - 1 more of its own frees however much the others free; every byte is accounted for once the threads have ended (their exit hook gives back
// what they held and their pending count). Built with DM_TEST_UE_NO_EXIT_FLUSH (no exit hook), --expect-leak passes only if the count shows the held blocks: the negative control.
// --bench: ns per Malloc + Free pair, one and four threads, both modes and the bare zone, best of 5
#include "../hle_uemalloc.c"
#include <assert.h>

module_t *g_mod;
int g_nmod;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
int gate_obs_present(int id) { (void)id; return 0; }
void gate_obs_set(int id, void (*callback)(uint64_t *, int)) { (void)id; (void)callback; }

enum { NT = 8, ROUNDS = 20000, LIVE = 32 };
static _Atomic int g_bad, g_lost;   // g_lost: a block just freed read back changed (the shared ring of DM_UE_HEAP_FAST=0 lets other threads' frees push it out)
#include <mach/mach_time.h>
static uint64_t clock_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom; }
static uint64_t rnd(uint64_t *x) { *x ^= *x << 13; *x ^= *x >> 7; *x ^= *x << 17; return *x; }
static size_t pick_size(uint64_t *x) {
    switch (rnd(x) % 8) { case 0: return 1 + rnd(x) % 16; case 1: case 2: case 3: return 16 + rnd(x) % 1024; case 4: case 5: return 1024 + rnd(x) % 31744; case 6: return 32768 + rnd(x) % 65536; default: return 65536 + rnd(x) % 262144; }
}
static void *worker(void *arg) {
    uint64_t x = 0x9e3779b97f4a7c15ull * (uint64_t)(uintptr_t)arg + 1;
    uint8_t *live[LIVE] = {0}; size_t len[LIVE] = {0};
    for (int r = 0; r < ROUNDS; r++) {
        int k = (int)(rnd(&x) % LIVE);
        if (!live[k]) { len[k] = pick_size(&x); live[k] = m_Malloc(NULL, len[k], rnd(&x) % 4 ? 0 : 4096); memset(live[k], k, len[k] < 64 ? len[k] : 64); }
        else if (rnd(&x) % 3 == 0) {
            size_t n = pick_size(&x); uint8_t *q = m_Realloc(NULL, live[k], n, 0);
            for (size_t i = 0; i < (len[k] < n ? len[k] : n) && i < 64; i++) if (q[i] != (uint8_t)k) atomic_store(&g_bad, 1);
            live[k] = q; len[k] = n; memset(q, k, n < 64 ? n : 64);
        } else {
            // a freed small block keeps its contents through LATE_T - 1 more frees of this thread
            if (len[k] >= 8 && sz(live[k]) <= LATE_MAX && rnd(&x) % 16 == 0) {   // held by its usable size, as release decides
                uint8_t *kept = live[k]; memset(kept, 0xa5, 8); m_Free(NULL, kept);
                for (int i = 0; i < LATE_T - 2; i++) m_Free(NULL, m_Malloc(NULL, 16 + rnd(&x) % 512, 0));
                int lost = 0; for (int i = 0; i < 8; i++) lost |= kept[i] != 0xa5;
                if (lost) atomic_fetch_add(&g_lost, 1);
            } else m_Free(NULL, live[k]);
            live[k] = NULL;
        }
    }
    for (int k = 0; k < LIVE; k++) m_Free(NULL, live[k]);
    return NULL;
}
static int run(int expect_leak) {
    pthread_t t[NT];
    for (int i = 0; i < NT; i++) assert(!pthread_create(&t[i], NULL, worker, (void *)(uintptr_t)(i + 1)));
    for (int i = 0; i < NT; i++) pthread_join(t[i], NULL);
    late_flush();
    int64_t left = used_now(), peak = atomic_load(&g_peak);
    if (expect_leak) {
        int ok = left > 0;
        printf("%s: without the exit hook %lld bytes stay counted in use after the threads end\n", ok ? "PASS" : "FAIL", (long long)left);
        return ok;
    }
    int ok = !atomic_load(&g_bad) && (!g_fast || !atomic_load(&g_lost)) && left == 0 && peak > 0;
    printf("%s: %d threads x %d calls (DM_UE_HEAP_FAST %s): contents kept through reallocs %s, freed blocks read back changed %d times, %lld bytes in use after their exit, peak %.1f MB\n",
           ok ? "PASS" : "FAIL", NT, ROUNDS, g_fast ? "on" : "off", atomic_load(&g_bad) ? "no" : "yes", atomic_load(&g_lost), (long long)left, peak / 1048576.0);
    return ok;
}

// --bench
static _Atomic int g_go; static int g_mode;   // 0 the old bookkeeping, 1 per thread, 2 the bare zone
static double g_ns[4];
static void *bench_thread(void *arg) {
    int idx = (int)(uintptr_t)arg; enum { N = 400000 };
    while (!atomic_load(&g_go)) {}
    uint64_t t0 = clock_ns();
    for (int i = 0; i < N; i++) {
        size_t n = 16 + (size_t)(i & 63) * 8;
        if (g_mode == 2) { void *p = malloc_zone_malloc(g_zone, n); __asm__ volatile("" :: "r"(p) : "memory"); malloc_zone_free(g_zone, p); }
        else { void *p = m_Malloc(NULL, n, 0); __asm__ volatile("" :: "r"(p) : "memory"); m_Free(NULL, p); }
    }
    g_ns[idx] = (double)(clock_ns() - t0) / N;
    return NULL;
}
static double bench(int mode, int threads) {
    double best = 1e9;
    for (int r = 0; r < 5; r++) {
        g_zone = malloc_create_zone(0, 0); setenv("DM_UE_HEAP_FAST", mode == 1 ? "1" : "0", 1); zone_ready(); g_mode = mode;
        atomic_store(&g_go, 0); pthread_t t[4];
        for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, bench_thread, (void *)(uintptr_t)i);
        atomic_store(&g_go, 1);
        for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
        double worst = 0; for (int i = 0; i < threads; i++) if (g_ns[i] > worst) worst = g_ns[i];
        if (worst < best) best = worst;
        if (mode != 2) late_flush();
        malloc_destroy_zone(g_zone);
    }
    return best;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--bench")) {
        for (int th = 1; th <= 4; th += 3)
            printf("%d thread%s, ns per Malloc + Free: before %.1f, per thread %.1f, bare zone %.1f\n", th, th > 1 ? "s" : "", bench(0, th), bench(1, th), bench(2, th));
        return 0;
    }
    g_zone = malloc_create_zone(0, 0);
    assert(g_zone);
    zone_ready();
    int ok = run(argc > 1 && !strcmp(argv[1], "--expect-leak"));
    return !ok;
}
