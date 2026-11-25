// The short host waits' WFET (dm_spin.h, DM_HOST_SPIN): a wait ends when the word moves and not before, gives up at its budget, DM_HOST_SPIN=0 keeps the yield spin, and the bench
// compares how fast a waiter sees a store (yield spin, WFET, blocking on os_sync_wait_on_address) and what each costs the process (RUSAGE_INFO_V6: cycles, instructions, energy).
// M4 Max, P cores (2026-11-22, --bench): wake p50 83 ns for the yield spin, 42-83 ns for WFET, 5.5-6.1 µs blocked; process energy per 5 µs wait 57 / 32 / 50 µJ, per 20 µs wait
// 233 / 127 / 108, per 100 µs 1,144 / 625 / 493 (the producer's own busy wait is in each figure). The bench prints; the checks are the behaviour and a loose latency bound
#include "../dm_spin.h"
#include <assert.h>
#include <libproc.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)
static uint64_t ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int cmp64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

static _Alignas(128) _Atomic uint64_t g_word;
static _Alignas(128) _Atomic uint64_t g_tstore;
static _Alignas(128) _Atomic int g_go;
static _Alignas(128) _Atomic uint32_t g_w32;

// 1-3: behaviour
static uint64_t g_delay_ns;
static void *store_later(void *arg) { (void)arg; uint64_t t = ns(); while (ns() - t < g_delay_ns) {} atomic_store(&g_word, 5); return NULL; }
static void *store32_later(void *arg) { (void)arg; uint64_t t = ns(); while (ns() - t < 3000) {} atomic_store(&g_w32, 9); return NULL; }

// The bench: the waiter announces each round, the producer busy-waits delay_ns, stamps the time and stores; the waiter stamps when it saw it
enum { M_YIELD, M_WFET, M_BLOCK };
static const char *const mname[] = {"yield spin", "WFET", "blocked"};
static int g_mode, g_n; static uint64_t *g_lat;
static void *waiter(void *arg) {
    (void)arg; pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    for (int i = 1; i <= g_n; i++) {
        atomic_store(&g_go, i);
        if (g_mode == M_BLOCK) { uint64_t v; while ((v = atomic_load(&g_word)) < (uint64_t)i) os_sync_wait_on_address(&g_word, v, 8, OS_SYNC_WAIT_ON_ADDRESS_NONE); }
        else { dm_spin_v = g_mode == M_WFET; while (!dm_spin_ge64(&g_word, (uint64_t)i, 1000000000ull, 1 << 30)) {} }
        uint64_t t = ns(); g_lat[i - 1] = t - atomic_load(&g_tstore);
    }
    return NULL;
}
static struct rusage_info_v6 ru(void) { struct rusage_info_v6 r; memset(&r, 0, sizeof r); proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r); return r; }
static uint64_t bench(int mode, uint64_t delay_ns, int n, int print) {
    g_mode = mode; g_n = n; g_lat = calloc((size_t)n, sizeof *g_lat); atomic_store(&g_word, 0); atomic_store(&g_go, 0);
    struct rusage_info_v6 r0 = ru();
    pthread_t th; pthread_create(&th, NULL, waiter, NULL);
    for (int i = 1; i <= n; i++) {
        while (atomic_load(&g_go) != i) {}
        uint64_t t = ns(); while (ns() - t < delay_ns) {}
        atomic_store(&g_tstore, ns()); atomic_store(&g_word, (uint64_t)i);
        if (mode == M_BLOCK) os_sync_wake_by_address_any(&g_word, 8, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    }
    pthread_join(th, NULL);
    struct rusage_info_v6 r1 = ru();
    qsort(g_lat, (size_t)n, sizeof *g_lat, cmp64);
    uint64_t p50 = g_lat[n / 2];
    if (print) printf("  wait %5.1f µs, %-10s: wake after the store p50 %5llu / p95 %5llu / p99 %5llu ns; per wait (both threads) %7.0f cycles, %7.0f instructions, %6.1f µJ\n", delay_ns / 1e3, mname[mode],
                      (unsigned long long)p50, (unsigned long long)g_lat[n * 95 / 100], (unsigned long long)g_lat[n * 99 / 100],
                      (double)(r1.ri_cycles - r0.ri_cycles) / n, (double)(r1.ri_instructions - r0.ri_instructions) / n, (double)(r1.ri_energy_nj - r0.ri_energy_nj) / 1e3 / n);
    free(g_lat);
    return p50;
}

int main(int argc, char **argv) {
    int big = argc > 1 && !strcmp(argv[1], "--bench");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    // DM_HOST_SPIN=0: the yield spin, whatever the CPU
    setenv("DM_HOST_SPIN", "0", 1); CHECK(dm_spin_wfet() == 0, "DM_HOST_SPIN=0 did not turn WFET off");
    dm_spin_v = -1; unsetenv("DM_HOST_SPIN");
    int f = 0; size_t fn = sizeof f; int have = !sysctlbyname("hw.optional.arm.FEAT_WFxT", &f, &fn, NULL, 0) && f;
    CHECK(dm_spin_wfet() == have, "DM_HOST_SPIN unset: WFET %d where the CPU has FEAT_WFxT %d", dm_spin_wfet(), have);
    printf("FEAT_WFxT %d; WFET %s\n", have, dm_spin_wfet() ? "on" : "off");

    for (int mode = M_YIELD; mode <= M_WFET; mode++) {
        if (mode == M_WFET && !have) break;
        dm_spin_v = mode == M_WFET;
        // 1. A store within the budget ends the wait, after the store
        atomic_store(&g_word, 0); g_delay_ns = 3000; pthread_t th; uint64_t t0 = ns();
        pthread_create(&th, NULL, store_later, NULL);
        int ok = dm_spin_ge64(&g_word, 5, 200000, 1 << 30); uint64_t dt = ns() - t0;
        pthread_join(th, NULL);
        CHECK(ok && atomic_load(&g_word) == 5, "%s: the wait did not see the store", mname[mode]);
        CHECK(dt >= 2500, "%s: the wait returned after %llu ns, before the store", mname[mode], (unsigned long long)dt);
        // 2. No store: the WFET wait gives up at its budget, not much later (the yield spin counts passes instead)
        atomic_store(&g_word, 0); t0 = ns();
        ok = dm_spin_ge64(&g_word, 1, 10000, 4096); dt = ns() - t0;
        CHECK(!ok, "%s: a wait with no store reported the word reached", mname[mode]);
        if (mode == M_WFET) CHECK(dt >= 10000 && dt < 200000, "WFET: a 10 µs wait with no store took %llu ns", (unsigned long long)dt);
        // dm_spin_ne64: a change ends it with the new value, none returns the old one
        atomic_store(&g_word, 7); g_delay_ns = 2000; pthread_create(&th, NULL, store_later, NULL);
        uint64_t v = 7; for (int k = 0; k < 1000 && v == 7; k++) v = dm_spin_ne64(&g_word, 7, 100000, 1 << 20);
        pthread_join(th, NULL);
        CHECK(v == 5, "%s: dm_spin_ne64 returned %llu, want the stored 5", mname[mode], (unsigned long long)v);
        CHECK(dm_spin_ne64(&g_word, 5, 5000, 2000) == 5, "%s: dm_spin_ne64 with no change did not return the old value", mname[mode]);
    }
#if defined(__aarch64__)
    if (have) {   // 3. the 32-bit look (thr_free's sig_pend)
        atomic_store(&g_w32, 1); pthread_t th; pthread_create(&th, NULL, store32_later, NULL);
        uint64_t dl = dm_cntvct() + dm_cnt_ticks(1000000); uint32_t v = 1;
        while (v == 1 && dm_cntvct() < dl) v = dm_wfe_once32(&g_w32, v, dl);
        pthread_join(th, NULL);
        CHECK(v == 9, "dm_wfe_once32 returned %u, want 9", v);
    }
#endif
    // 4. The bench (latency checks only: energy depends on what else the Mac runs)
    static const uint64_t delays[] = {2000, 5000, 20000, 100000};
    int n = big ? 20000 : 2000;
    printf("wake latency and cost by wait length (%d waits each):\n", n);
    for (unsigned d = 0; d < sizeof delays / sizeof *delays; d++) {
        if (!big && d > 2) break;
        uint64_t y = bench(M_YIELD, delays[d], n, 1), w = have ? bench(M_WFET, delays[d], n, 1) : 0; bench(M_BLOCK, delays[d], n, 1);
        if (have) CHECK(w < y + 1000 && w < 5000, "WFET's wake p50 %llu ns against the yield spin's %llu ns (want within 1 µs of it, under 5 µs)", (unsigned long long)w, (unsigned long long)y);
    }
    printf("t_host_spin: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
