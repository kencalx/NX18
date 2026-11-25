// The GPU probe (nvn_mtl.m mtl_gpu_probe_tick / mtl_gpu_probe_line, DM_GPU_PROBE): the first tick has its pipeline made off the calling thread; then every other tick starts one
// probe, never a second while one runs, and the power line's call says the window's fastest probe, its mean and slowest, and the ratio to the session's fastest, then starts a new
// window. DM_GPU_PROBE=0 (the Makefile's second run) makes nothing. It also prints what a probe costs here: its GPU time, an empty command buffer's beside it, and the calling
// thread's CPU time per tick that starts one (the plan asks for the probe to stay tiny)
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <time.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static int wait_for(_Atomic int *v, int want, int ms) { for (int i = 0; i < ms && atomic_load(v) != want; i++) usleep(1000); return atomic_load(v) == want; }
static double thread_cpu_us(void) { struct timespec ts; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts); return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3; }
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
int main(void) { @autoreleasepool {
    mtl_init();
    char line[240] = "";
    const char *e = getenv("DM_GPU_PROBE");
    if (e && *e == '0') {
        for (int i = 0; i < 4; i++) mtl_gpu_probe_tick();
        CHECK(atomic_load(&g_probe_state) == -2 && !g_probe_ps, "switched off: no pipeline is made");
        CHECK(!atomic_load(&g_probe_busy) && !g_probe.total && !mtl_gpu_probe_line(line, sizeof line), "switched off: no probe runs and the power line says nothing");
        printf("t_gpu_probe (DM_GPU_PROBE=0): %d checks, %d failed\n", checks, failed);
        return failed != 0;
    }
    CHECK(!mtl_gpu_probe_line(line, sizeof line), "before any tick the power line says nothing");
    mtl_gpu_probe_tick();
    CHECK(wait_for(&g_probe_state, 2, 10000), "the first tick has the pipeline made off the calling thread");
    CHECK(!mtl_gpu_probe_line(line, sizeof line), "with no probe yet the power line says nothing");
    mtl_gpu_probe_tick();
    CHECK(atomic_load(&g_probe_busy) == 1, "the next tick starts a probe");
    CHECK(wait_for(&g_probe_busy, 0, 5000), "the probe completes");
    mtl_gpu_probe_tick();
    CHECK(!atomic_load(&g_probe_busy) && g_probe.total == 1, "the tick after it starts none (every other tick)");
    atomic_store(&g_probe_busy, 1); mtl_gpu_probe_tick(); usleep(20000);
    CHECK(g_probe.total == 1, "a tick while a probe runs starts no second one");
    CHECK(mtl_gpu_probe_line(line, sizeof line) && strstr(line, "fastest") && strstr(line, "of 1 ") && strstr(line, "1.00x the session's fastest"), "the power line says the window's probe");
    printf("line: %s\n", line);
    CHECK(mtl_gpu_probe_line(line, sizeof line) && strstr(line, "has not finished"), "a window whose only probe is still running says so");
    atomic_store(&g_probe_busy, 0);
    CHECK(!mtl_gpu_probe_line(line, sizeof line), "an empty window says nothing");
    // Cost: 40 probes one after another (two ticks each), the calling thread's CPU for the tick that starts one, and each probe's GPU time
    enum { N = 40 }; double gpu[N], cpu[N], empty[N];
    for (int i = 0; i < N; i++) {
        mtl_gpu_probe_tick();   // the odd tick, which starts none
        double c0 = thread_cpu_us(); mtl_gpu_probe_tick(); cpu[i] = thread_cpu_us() - c0;
        CHECK(wait_for(&g_probe_busy, 0, 5000), "each probe completes");
        os_unfair_lock_lock(&g_probe_lk); gpu[i] = g_probe.n ? g_probe.max / 1e3 : -1; g_probe.n = g_probe.min = g_probe.max = g_probe.sum = 0; os_unfair_lock_unlock(&g_probe_lk);
    }
    for (int i = 0; i < N; i++) {   // an empty command buffer's GPU span, through the same one-off path: what of a probe's time is not the job
        NvOnce *o = once_new(0); id<MTL4ComputeCommandEncoder> ce = [o->cb computeCommandEncoder]; [ce endEncoding];
        __block _Atomic int done = 0; once_commit(o, ^(int ok) { (void)ok; atomic_store(&done, 1); }); wait_for(&done, 1, 5000);
        empty[i] = (o->gpu1 - o->gpu0) * 1e6;
    }
    qsort(gpu, N, sizeof *gpu, dcmp); qsort(cpu, N, sizeof *cpu, dcmp); qsort(empty, N, sizeof *empty, dcmp);
    CHECK(gpu[0] > 0 && gpu[N / 2] < 1000, "a probe takes more than nothing and less than 1 ms of GPU time");
    CHECK(cpu[N / 2] < 1000, "a tick that starts one takes less than 1 ms of the calling thread's CPU");
    printf("cost on %s: probe GPU time min %.1f / median %.1f / max %.1f us; an empty command buffer's %.1f / %.1f / %.1f us; CPU of the tick that starts one median %.1f us, max %.1f us\n",
           g_dev.name.UTF8String, gpu[0], gpu[N / 2], gpu[N - 1], empty[0], empty[N / 2], empty[N - 1], cpu[N / 2], cpu[N - 1]);
    printf("t_gpu_probe: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
