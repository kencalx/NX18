// Short host waits on a word another thread will change (DM_HOST_SPIN): WFET instead of a yield spin.
// Apple's tuning guide asks not to keep threads busy in yield loops. A wait that usually ends within a thread switch (on the M4 Max a blocked thread's wake took 5.5 µs at p50,
// os_sync_wait_on_address / os_sync_wake_by_address_any) is better spun than blocked, but a `yield` spin keeps the core running flat out. WFET (FEAT_WFxT, Apple M4 / A18 and later)
// arms the exclusive monitor on the watched line (LDAXR) and stops the core until another core writes that line, an event arrives (the kernel's event stream, about every 1.2 µs on
// the Mac) or the deadline in CNTVCT ticks passes. Measured on the M4 Max (dm/host/tests/t_host_spin.c --bench): wake latency after the store p50 42-83 ns, as the yield spin's
// 83 ns, against 5.5-6.1 µs blocked; the process's energy (both threads, RUSAGE_INFO_V6 ri_energy_nj) per 5 µs wait 32 µJ against 57 spinning on `yield` and 50 blocked, per 20 µs
// wait 127 against 233 and 108. xnu lets EL0 run WFE / WFET
// (SCTLR_EL1.nTWE is in SCTLR_EL1_REQUIRED). DM_HOST_SPIN=0 (or yield) keeps the old yield spins; without FEAT_WFxT the old spins run too.
// The thread stays on its core while it waits (the scheduler sees it running), so callers bound the wait to a few µs and block after it, as before.
#ifndef DM_SPIN_H
#define DM_SPIN_H
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static int dm_spin_v = -1;   // per translation unit: -1 not read yet, 0 yield spins, 1 WFET
static inline int dm_spin_wfet(void) {
    int v = __atomic_load_n(&dm_spin_v, __ATOMIC_RELAXED);
    if (__builtin_expect(v >= 0, 1)) return v;
    const char *e = getenv("DM_HOST_SPIN");
    int on = !(e && (!strcmp(e, "0") || !strcmp(e, "yield") || !strcmp(e, "off")));
#if defined(__aarch64__)
    int f = 0; size_t n = sizeof f;
    if (on && (sysctlbyname("hw.optional.arm.FEAT_WFxT", &f, &n, NULL, 0) || !f)) on = 0;
#else
    on = 0;
#endif
    __atomic_store_n(&dm_spin_v, on, __ATOMIC_RELAXED);
    return on;
}
#if defined(__aarch64__)
static inline uint64_t dm_cntvct(void) { uint64_t v; __asm__ volatile("isb\n mrs %0, cntvct_el0" : "=r"(v) : : "memory"); return v; }
// CNTVCT ticks for ns nanoseconds (1 GHz on the M4 Max under macOS 27, 24 MHz on older parts)
static inline uint64_t dm_cnt_ticks(uint64_t ns) {
    static uint64_t frq;
    uint64_t f = __atomic_load_n(&frq, __ATOMIC_RELAXED);
    if (!f) { __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f)); if (!f) f = 24000000; __atomic_store_n(&frq, f, __ATOMIC_RELAXED); }
    return f == 1000000000ull ? ns : (ns * f) / 1000000000ull;
}
static inline void dm_wfet(uint64_t deadline) { register uint64_t x0 __asm__("x0") = deadline; __asm__ volatile(".inst 0xd5031000" : : "r"(x0) : "memory"); }   // wfet x0
// One WFE-armed look at *p: returns its value now; when that is still old, first waits for a write to its line, an event or the deadline (CNTVCT ticks). Callers loop and check
static inline uint64_t dm_wfe_once64(_Atomic uint64_t *p, uint64_t old, uint64_t deadline) {
    uint64_t v; __asm__ volatile("ldaxr %0, [%1]" : "=r"(v) : "r"(p) : "memory");
    if (v == old) { dm_wfet(deadline); __asm__ volatile("ldar %0, [%1]" : "=r"(v) : "r"(p) : "memory"); }
    __asm__ volatile("clrex" : : : "memory");
    return v;
}
static inline uint32_t dm_wfe_once32(_Atomic uint32_t *p, uint32_t old, uint64_t deadline) {
    uint32_t v; __asm__ volatile("ldaxr %w0, [%1]" : "=r"(v) : "r"(p) : "memory");
    if (v == old) { dm_wfet(deadline); __asm__ volatile("ldar %w0, [%1]" : "=r"(v) : "r"(p) : "memory"); }
    __asm__ volatile("clrex" : : : "memory");
    return v;
}
#endif
// Wait up to ns for *p to reach at least want (WFET, or the old yield spin with DM_HOST_SPIN=0): 1 if it did. iters: the old spin's count, used only by the yield spin
static inline int dm_spin_ge64(_Atomic uint64_t *p, uint64_t want, uint64_t ns, int iters) {
#if defined(__aarch64__)
    if (dm_spin_wfet()) {
        uint64_t dl = dm_cntvct() + dm_cnt_ticks(ns), v = atomic_load_explicit(p, memory_order_acquire);
        while (v < want) { if (dm_cntvct() >= dl) return 0; v = dm_wfe_once64(p, v, dl); }
        return 1;
    }
#endif
    (void)ns;
    for (int i = 0; i < iters; i++) {
#if defined(__aarch64__)
        __builtin_arm_yield();
#endif
        if (atomic_load_explicit(p, memory_order_acquire) >= want) return 1;
    }
    return atomic_load_explicit(p, memory_order_acquire) >= want;
}
// Wait up to ns for *p to differ from old: its value (old if it did not change). iters: the old poll's count of plain loads, used with DM_HOST_SPIN=0
static inline uint64_t dm_spin_ne64(_Atomic uint64_t *p, uint64_t old, uint64_t ns, int iters) {
    uint64_t v = atomic_load_explicit(p, memory_order_acquire);
#if defined(__aarch64__)
    if (dm_spin_wfet()) {
        uint64_t dl = dm_cntvct() + dm_cnt_ticks(ns);
        while (v == old && dm_cntvct() < dl) v = dm_wfe_once64(p, v, dl);
        return v;
    }
#endif
    (void)ns;
    for (int i = 0; i < iters && v == old; i++) v = atomic_load_explicit(p, memory_order_acquire);
    return v;
}
#endif
