// Power detail (DM_POWER_DETAIL; hle_nvn.c power_line): where the process's CPU time and energy went in a power window, by core type, and how long its threads waited for a core.
// proc_pid_rusage(RUSAGE_INFO_V6) gives, for the whole process: CPU time (user + system) and the part of it on performance cores (ri_user_ptime + ri_system_ptime), cycles and the
// part on performance cores (ri_cycles, ri_pcycles), energy and the part on performance cores (ri_energy_nj, ri_penergy_nj, the same total as task_energy), and the time its threads
// were runnable (ri_runnable_time). The times are in Mach absolute units (on a Mac: 12 threads spinning 1 s each read 288 M units, 12.0 s at the 125/3 timebase), and the runnable
// time counts running as well as waiting (48 threads spinning 1 s each on 16 cores: 49 s runnable, 16.4 s of CPU), so the time spent waiting for a core is runnable minus CPU.
// A cluster's clock is its cycles over its CPU time: it tells a thread parked on the efficiency cores (their clock, most of the time there) from a performance core held at a low clock.
// make -C dm/gfx/tests GAME=<id> t_power_detail checks the arithmetic and the units on the Mac
#pragma once
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/resource.h>
#include <unistd.h>
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);   // libproc.h, which the iOS SDK does not have (as hle_svc.c)

typedef struct { uint64_t cpu_ns, pcpu_ns, run_ns, cycles, pcycles, energy_nj, penergy_nj; } nvn_pd;   // the process's totals so far

static inline uint64_t nvn_pd_abs_ns(uint64_t t) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    return (uint64_t)((__uint128_t)t * tb.numer / tb.denom);
}
// The totals now → 1, or 0 when the system does not give RUSAGE_INFO_V6
static inline int nvn_pd_read(nvn_pd *s) {
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri)) return 0;
    s->cpu_ns = nvn_pd_abs_ns(ri.ri_user_time + ri.ri_system_time); s->pcpu_ns = nvn_pd_abs_ns(ri.ri_user_ptime + ri.ri_system_ptime);
    s->run_ns = nvn_pd_abs_ns(ri.ri_runnable_time);
    s->cycles = ri.ri_cycles; s->pcycles = ri.ri_pcycles; s->energy_nj = ri.ri_energy_nj; s->penergy_nj = ri.ri_penergy_nj;
    return 1;
}
static inline uint64_t nvn_pd_d(uint64_t a, uint64_t b) { return b > a ? b - a : 0; }   // a counter's growth (0 if it went back)
// One cluster of a window: "performance cores 2.31 W, 3.62 GHz, 1.12 cores busy", or "... idle" with no CPU time there
static inline size_t nvn_pd_cluster(char *out, size_t n, const char *name, uint64_t nj, uint64_t cyc, uint64_t ns, double secs) {
    if (!ns) return (size_t)snprintf(out, n, "%s idle", name);
    return (size_t)snprintf(out, n, "%s %.2f W, %.2f GHz, %.2f cores busy", name, nj / 1e9 / secs, (double)cyc / (double)ns, ns / 1e9 / secs);
}
// A window from a to b, secs long: each cluster's energy, clock and cores' worth of CPU, then the time threads were runnable but not running, in ms per second
static inline size_t nvn_pd_text(char *out, size_t n, const nvn_pd *a, const nvn_pd *b, double secs) {
    if (!n) return 0;
    if (secs <= 0) return (size_t)snprintf(out, n, "no time passed");
    uint64_t cpu = nvn_pd_d(a->cpu_ns, b->cpu_ns), p = nvn_pd_d(a->pcpu_ns, b->pcpu_ns), cyc = nvn_pd_d(a->cycles, b->cycles), pc = nvn_pd_d(a->pcycles, b->pcycles);
    uint64_t en = nvn_pd_d(a->energy_nj, b->energy_nj), pe = nvn_pd_d(a->penergy_nj, b->penergy_nj), run = nvn_pd_d(a->run_ns, b->run_ns);
    if (p > cpu) p = cpu;
    if (pc > cyc) pc = cyc;
    if (pe > en) pe = en;
    size_t o = nvn_pd_cluster(out, n, "performance cores", pe, pc, p, secs);
    if (o < n) o += (size_t)snprintf(out + o, n - o, "; ");
    if (o < n) o += nvn_pd_cluster(out + o, n - o, "efficiency cores", en - pe, cyc - pc, cpu - p, secs);
    if (o < n) o += (size_t)snprintf(out + o, n - o, "; threads waited for a core %.0f ms/s", nvn_pd_d(cpu, run) / 1e6 / secs);
    return o < n ? o : n - 1;
}
// A cluster's clock in a window: "3.62 GHz", or "idle" with no CPU time there
static inline size_t nvn_pd_clock(char *out, size_t n, uint64_t cyc, uint64_t ns) {
    return ns ? (size_t)snprintf(out, n, "%.2f GHz", (double)cyc / (double)ns) : (size_t)snprintf(out, n, "idle");
}
// The power tick's text (hle_nvn.c power_tick) for a window from a to b, secs long (a NULL: the platform gives no RUSAGE_INFO_V6): CPU energy, CPU time (100% = one core) and its share
// on performance cores, each cluster's clock, then frames per second, GPU time per second summed over command buffers and as the union of the frames' spans (gpu_ms, span_ms in the
// window; both approximate), and the acquiring thread's frames checked and demoted, when it was checked
static inline size_t nvn_pd_tick_text(char *out, size_t n, const nvn_pd *a, const nvn_pd *b, double secs, uint64_t frames, double gpu_ms, double span_ms, uint64_t chk, uint64_t dem) {
    if (!n) return 0;
    if (secs <= 0) return (size_t)snprintf(out, n, "no time passed");
    size_t o;
    if (a) {
        uint64_t cpu = nvn_pd_d(a->cpu_ns, b->cpu_ns), p = nvn_pd_d(a->pcpu_ns, b->pcpu_ns), cyc = nvn_pd_d(a->cycles, b->cycles), pc = nvn_pd_d(a->pcycles, b->pcycles);
        if (p > cpu) p = cpu;
        if (pc > cyc) pc = cyc;
        o = (size_t)snprintf(out, n, "CPU energy %.2f W; CPU %.0f%% (100 = one core), %.0f%% of it on performance cores; performance cores ", nvn_pd_d(a->energy_nj, b->energy_nj) / 1e9 / secs,
                             cpu / 1e7 / secs, cpu ? 100.0 * (double)p / (double)cpu : 0);
        if (o < n) o += nvn_pd_clock(out + o, n - o, pc, p);
        if (o < n) o += (size_t)snprintf(out + o, n - o, ", efficiency cores ");
        if (o < n) o += nvn_pd_clock(out + o, n - o, cyc - pc, cpu - p);
    } else o = (size_t)snprintf(out, n, "CPU by core type: not on this platform");
    if (o < n) o += (size_t)snprintf(out + o, n - o, "; %.1f fps; GPU about %.1f ms/s summed over command buffers, about %.1f ms/s as the union of the frames' spans (both approximate)",
                                     frames / secs, gpu_ms / secs, span_ms / secs);
    if (o < n && chk) o += (size_t)snprintf(out + o, n - o, "; acquiring thread demoted in %llu of %llu frames", (unsigned long long)dem, (unsigned long long)chk);
    return o < n ? o : n - 1;
}
// The front end's power state (dm_power_source: known bit 1 battery, bit 2 Low Power Mode; state 1 on battery, 2 charging, 3 full and plugged in, 4 plugged in but not charging
// (a Mac held below full by optimized charging), 0 unknown; pct -1 unknown): "battery 63%, on battery; Low Power Mode off". A part the platform does not give says so once (told: the parts said)
static inline size_t nvn_pd_power_text(char *out, size_t n, int known, int pct, int state, int lpm, int *told) {
    static const char *const st[] = {"charging state unknown", "on battery", "charging", "full, plugged in", "plugged in, not charging"};
    size_t o = 0; if (!n) return 0; out[0] = 0;
    if (known & 1) {
        if (pct >= 0) o += (size_t)snprintf(out + o, n - o, "battery %d%%, %s", pct, st[state >= 0 && state <= 4 ? state : 0]);
        else o += (size_t)snprintf(out + o, n - o, "battery level unknown, %s", st[state >= 0 && state <= 4 ? state : 0]);
    } else if (!(*told & 1)) { *told |= 1; o += (size_t)snprintf(out + o, n - o, "battery: not on this platform"); }
    if (o < n && (known & 2)) o += (size_t)snprintf(out + o, n - o, "%sLow Power Mode %s", o ? "; " : "", lpm ? "on" : "off");
    else if (o < n && !(*told & 2)) { *told |= 2; o += (size_t)snprintf(out + o, n - o, "%sLow Power Mode: not on this platform", o ? "; " : ""); }
    return o < n ? o : n - 1;
}
