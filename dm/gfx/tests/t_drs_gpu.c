// GPU headroom under the game's dynamic resolution (nvn_drs_gpu.h, DM_DRS_GPU_TARGET; hle_nvn.c drs_gpu_tick), on the Mac with no GPU and no game:
//  1. Ocarina of Time's level stub (patches.py drs_controller, words taken from the file by the Makefile) run natively on arm64 with a state page and a controller block of its
//     own: with no floor it climbs as before; it returns no level above the floor at +0x290, at most its lowest; it writes the level count at +0x294; off (+0x40 0) it returns 0.
//  2. The controller in a closed loop with that stub, a model of the game's update (a level moves after 2 asks down or 5 up; the load read 2 frames late), a GPU whose time per
//     frame follows the pixel count (30% fixed, 70% by the pixels of the level's scale, 0.75 to 0.333 of 2048x1152 over 10 levels) and a SoC that caps the performance cores to
//     1.44 GHz after 1 s over 85% GPU busy and gives 4.4 back after 2 s under 70%, which slows a CPU-limited frame to 48 fps (the phone's: oot-mst-1-findings.md). Traces:
//     saturation after a steady stretch, a load inside the 15-point band, a heavy scene then an area load then a light scene, a square wave of scenes, and Ocarina of Time's
//     per-second GPU time from the cooler run (60-140 s, taken as the demand at full size). Checked: the first step down within 1 s of saturation, no change in steady load
//     (no oscillation), the floor back to 0 after the load, and with the controller fewer seconds capped and more frames than without it.
//  3. The same phone seconds open loop (the logged clock, the GPU busy as logged): the clock-floor rule's steps in the capped stretch.
#include "../nvn/nvn_drs_gpu.h"
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__arm64__)
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sys/mman.h>
#include "oot_drs_stub.h"   // drs_stub_words (Makefile, from patches.py)
#endif

#define NLEVELS 10
static double pix(int l) { double s = 0.75 - l * (0.75 - 0.333) / 9.0; return (s / 0.75) * (s / 0.75); }
static int g_flat, g_cpu_cap;   // g_flat: a GPU whose time does not follow the pixel count (Ocarina of Time's scene passes on the iPhone 18 Pro Max, 2026-11-23);
                                // g_cpu_cap: the cores held at their floor from 5 s on whatever the GPU does (the game's own threads on about 1.9 cores, ea555d697)
static double cost(double d, int l) { return g_flat ? d : d * (0.3 + 0.7 * pix(l)); }   // GPU share of a 60 fps frame at level l, for a demand d at full size

// ---- the stub, natively ----
static uint8_t *g_state, g_ctl[0x200];
#if defined(__arm64__)
static void *g_fn;
static void stub_load(void) {
    g_fn = mmap(0, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0); assert(g_fn != MAP_FAILED);
    pthread_jit_write_protect_np(0); memcpy(g_fn, drs_stub_words, sizeof drs_stub_words); pthread_jit_write_protect_np(1);
    sys_icache_invalidate(g_fn, sizeof drs_stub_words);
}
static int stub_call(void) {
    register uint64_t x0 __asm__("x0") = (uint64_t)g_ctl; register uint64_t x16 __asm__("x16") = (uint64_t)g_state; void *fn = g_fn;
    __asm__ volatile("blr %2" : "+r"(x0), "+r"(x16) : "r"(fn) : "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x17", "x30", "v0", "v1", "v2", "memory", "cc");
    return (int)x0;
}
#endif
static uint32_t st32(unsigned off) { uint32_t v; memcpy(&v, g_state + off, 4); return v; }
static void st32w(unsigned off, uint32_t v) { memcpy(g_state + off, &v, 4); }
static void ctl_set(float load, int level) { float th = 83; memcpy(g_ctl + 8, &load, 4); memcpy(g_ctl + 0x10, &th, 4); int32_t lv = level, n = NLEVELS; memcpy(g_ctl + 0x174, &lv, 4); memcpy(g_ctl + 0x1a0, &n, 4); }
// The game's update around the stub: asks counted, the level one step at a time
typedef struct { int level, dn, up; float loads[3]; } game;
static int game_frame(game *g, float load_now) {
    g->loads[2] = g->loads[1]; g->loads[1] = g->loads[0]; g->loads[0] = load_now;   // the load it reads is 2 frames old
    ctl_set(g->loads[2], g->level);
#if defined(__arm64__)
    int t = stub_call();
#else
    int t = g->level;
#endif
    if (t > g->level) { g->up = 0; if (++g->dn >= 2) { g->level++; g->dn = 0; } }
    else if (t < g->level) { g->dn = 0; if (++g->up >= 5) { g->level--; g->up = 0; } }
    else g->dn = g->up = 0;
    return t;
}
static void state_reset(void) { memset(g_state, 0, 4096); st32w(0x40, 1); }

static void test_stub(void) {
#if defined(__arm64__)
    // off: 0 whatever the floor
    state_reset(); st32w(0x40, 0); st32w(0x290, 5); ctl_set(200, 3);
    assert(stub_call() == 0); assert(st32(0x294) == 0);
    // no floor: from the lowest level a load of 70 everywhere climbs to full size (9 steps), as before the floor
    state_reset(); game g = {.level = NLEVELS - 1};
    for (int f = 0; f < 3000; f++) game_frame(&g, 70);
    assert(g.level == 0 && st32(0x294) == NLEVELS);
    puts("PASS: the stub with no floor climbs from its lowest level to full size and writes the level count");
    // a floor of 3: it climbs to 3, no further
    state_reset(); g = (game){.level = NLEVELS - 1}; st32w(0x290, 3);
    for (int f = 0; f < 3000; f++) { int t = game_frame(&g, 70); assert(t >= 3); }
    assert(g.level == 3);
    // the floor at full size again: it climbs on to 0
    st32w(0x290, 0); for (int f = 0; f < 3000; f++) game_frame(&g, 70);
    assert(g.level == 0);
    // a floor past the lowest level: the lowest
    st32w(0x290, 40); for (int f = 0; f < 600; f++) { int t = game_frame(&g, 70); assert(t <= NLEVELS - 1); }
    assert(g.level == NLEVELS - 1);
    // over the threshold at the floor: its own step down still goes lower
    st32w(0x290, 2); g.level = 2; for (int f = 0; f < 600; f++) game_frame(&g, g.level < 5 ? 120 : 60);
    assert(g.level == 5);
    puts("PASS: the stub returns no level above the floor (+0x290), at most its lowest, and steps lower on its own load");
#else
    puts("SKIP: the stub runs natively on arm64 only");
#endif
}

// ---- closed loop ----
typedef struct { const char *name; double (*demand)(double t); double secs; int target; } trace;
typedef struct { int changes, downs, ups, undos, floor_hi, capped_win, frames; double first_down, end_floor, mean_busy, busy_hi; int changes_after[4]; double after_t[4]; } result;
static uint64_t g_rng = 88172645463325252ull;
static double noise(void) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17; return ((g_rng >> 11) * (1.0 / 9007199254740992.0) - 0.5) * 0.04; }   // ±2 points
static int g_verbose;
static result run(const trace *tr, double onset, const double *after, int nafter) {
    nvn_drs_gpu c; nvn_drs_gpu_init(&c, tr->target);
    state_reset(); game g = {0};
    result r = {0}; r.first_down = -1;
    double t = 0, wt0 = 0, wbusy = 0; int capped = 0, over_w = 0, under_w = 0; double busy_sum = 0; int nwin = 0;
    for (int k = 0; k < nafter; k++) r.after_t[k] = after[k];
    while (t < tr->secs) {
        double d = tr->demand(t), gshare = cost(d, g.level) + noise();
        if (gshare < 0) gshare = 0;
        double gpu_ms = gshare * 1000 / 60, fps = capped ? 48 : 60;
        if (gpu_ms > 1000 / 60.0) fps = fps < 30 ? fps : 30;   // a frame over the GPU's budget waits for a second vsync
        double dt = 1 / fps;
        game_frame(&g, (float)(gpu_ms / 0.2));
        r.frames++; wbusy += gpu_ms / 1000; t += dt;
        if (t - wt0 >= 0.25) {
            double busy = wbusy / (t - wt0); if (busy > 1) busy = 1;
            over_w = busy > 0.85 ? over_w + 1 : 0; under_w = busy < 0.70 ? under_w + 1 : 0;
            if (!capped && over_w >= 4) capped = 1; else if (capped && under_w >= 8) capped = 0;
            if (g_cpu_cap) capped = t >= 5;
            r.capped_win += capped; busy_sum += busy; nwin++; if (busy > r.busy_hi && t > 5) r.busy_hi = busy;
            double pclk = (capped ? 1.44 : 4.40) + noise();
            int was = c.floor; char why[160];
            int kind = nvn_drs_gpu_window(&c, (uint64_t)(t * 1e9), busy, pclk, g.level, NLEVELS, why, sizeof why);
            st32w(0x290, (uint32_t)c.floor); if (c.floor > r.floor_hi) r.floor_hi = c.floor;
            if (kind) {
                r.changes++; if (kind == NVN_DRS_UP || kind == NVN_DRS_UNDO) r.ups++; else r.downs++;
                if (kind == NVN_DRS_UNDO) r.undos++;
                if ((kind == NVN_DRS_DOWN_BUSY || kind == NVN_DRS_DOWN_CLOCK) && r.first_down < 0 && t >= onset) r.first_down = t - onset;
                for (int k = 0; k < nafter; k++) if (t >= after[k]) r.changes_after[k]++;
                if (g_verbose) printf("    %6.2f s floor %d → %d (level %d): %s\n", t, was, c.floor, g.level, why);
            }
            wt0 = t; wbusy = 0;
        }
    }
    r.end_floor = c.floor; r.mean_busy = nwin ? busy_sum / nwin : 0;
    return r;
}
static double d_sat(double t) { return t < 10 ? 0.70 : 0.97; }
static double d_band(double t) { (void)t; return 0.72; }
static double d_band2(double t) { (void)t; return 0.82; }
static double d_load(double t) { return t < 20 ? 0.97 : t < 25 ? 0.05 : 0.62; }
static double d_square(double t) { return fmod(t, 20) < 10 ? 0.97 : 0.55; }
static double flat80(double t) { (void)t; return 0.80; }
// Ocarina of Time, cooler run (f5ae72b99, DM_YIELD_PARK=1), power tick 60-138 s: GPU ms/s summed over command buffers, as the demand at full size
static const short k_oot[] = {727,719,725,726,721,716,717,700,691,690,688,681,677,700,704,717,699,693,697,722,734,782,788,797,877,892,709,601,627,589,590,578,597,585,584,593,
                              576,570,558,555,551,565,604,719,819,812,813,797,779,733,45,32,100,369,675,597,535,461,497,536,521,533,503,493,481,398,588,493,486,504,486,498,517,498,536,493,482,490};
static const float k_oot_clk[] = {4.34,4.45,4.40,4.39,4.41,4.51,4.62,4.40,4.30,4.28,4.41,4.42,4.14,4.26,4.28,4.40,4.29,4.30,4.46,4.55,4.64,4.63,4.59,4.18,3.04,1.95,1.44,1.44,1.45,1.46,
                                  1.44,1.44,1.44,1.44,1.44,1.45,1.45,1.45,1.44,1.45,1.44,1.44,1.44,1.44,1.52,2.31,3.18,3.71,3.96,4.02,4.22,3.72,4.08,3.77,2.24,1.44,1.44,1.45,1.45,1.44,
                                  1.44,1.44,1.44,1.44,1.45,1.84,1.55,1.44,1.44,1.44,1.44,1.44,1.44,1.44,1.44,1.44,1.44,1.44};
#define OOT_N (int)(sizeof k_oot / sizeof *k_oot)
// The phone's demand: the logged GPU time is what the capped stretches drew at 44-60 fps and at the levels the game was at, so the capped seconds (clock under 2 GHz) are taken at
// the 60 fps share of the stretch before (0.80): the demand that put the SoC there
static double d_oot(double t) { int i = (int)t; if (i >= OOT_N) i = OOT_N - 1; return k_oot_clk[i] < 2 ? 0.80 : k_oot[i] / 1000.0; }

static void report(const char *what, const result *on, const result *off) {
    printf("  %s: with the controller %d changes (%d down, %d up), end floor %.0f, first step %.2f s after the onset, capped %.1f s, %d frames, GPU busy mean %.0f%% (highest window %.0f%%);"
           " without: capped %.1f s, %d frames, GPU busy mean %.0f%%\n",
           what, on->changes, on->downs, on->ups, on->end_floor, on->first_down, on->capped_win * 0.25, on->frames, 100 * on->mean_busy, 100 * on->busy_hi, off->capped_win * 0.25, off->frames, 100 * off->mean_busy);
}

int main(void) {
    g_state = calloc(1, 4096);
#if defined(__arm64__)
    stub_load();
#endif
    // parse
    assert(nvn_drs_gpu_parse(NULL) == 75 && nvn_drs_gpu_parse("") == 75 && nvn_drs_gpu_parse("0") == 0 && nvn_drs_gpu_parse("off") == 0 && nvn_drs_gpu_parse("80") == 80);
    assert(nvn_drs_gpu_parse("49") == -1 && nvn_drs_gpu_parse("96") == -1 && nvn_drs_gpu_parse("8x") == -1);
    puts("PASS: DM_DRS_GPU_TARGET: unset 75, 0 / off off, 50-95 taken, the rest refused");
    test_stub();
#if !defined(__arm64__)
    puts("SKIP: the closed loop needs the stub natively (arm64)");
    return 0;
#else
    g_verbose = getenv("T_DRS_VERBOSE") != NULL;
    // saturation: a step down within 1 s, then steady (no change in the last 25 s), no cap, more frames than without
    { trace on = {"saturation", d_sat, 40, 75}, off = on; off.target = 0; double af[] = {15};
      result a = run(&on, 10, af, 1), b = run(&off, 10, NULL, 0); report("saturation at 10 s (97% at full size)", &a, &b);
      assert(a.first_down >= 0 && a.first_down <= 1.0);
      assert(a.changes_after[0] == 0);   // settled within 5 s, then steady
      assert(a.capped_win < b.capped_win && a.frames > b.frames);
      puts("PASS: saturation: the floor steps down within 1 s, settles, and the cores keep their clock"); }
    // inside the band: no change at all; just over the target: one or two steps, then steady
    { trace on = {"band", d_band, 120, 75}; result a = run(&on, 0, NULL, 0);
      printf("  72%% at full size for 120 s: %d changes\n", a.changes); assert(a.changes == 0);
      trace on2 = {"band2", d_band2, 120, 75}; double af[] = {20}; result b = run(&on2, 0, af, 1);
      printf("  82%% at full size for 120 s: %d changes (%d after 20 s), end floor %.0f\n", b.changes, b.changes_after[0], b.end_floor);
      assert(b.changes <= 2 && b.changes_after[0] == 0 && b.end_floor >= 1);
      puts("PASS: no oscillation: a load inside the band moves nothing, one just over the target steps once or twice and holds"); }
    // heavy, an area load, light: down at once, back to 0 after the load
    { trace on = {"load", d_load, 60, 75}, off = on; off.target = 0; double af[] = {25, 45};
      result a = run(&on, 0, af, 2), b = run(&off, 0, NULL, 0); report("heavy 20 s, a 5 s area load, light 35 s", &a, &b);
      assert(a.first_down >= 0 && a.first_down <= 1.0 && a.end_floor == 0 && a.ups >= 1 && a.changes_after[1] == 0);
      puts("PASS: after the load the floor steps back up to full size, one level at a time, and stays"); }
    // a square wave of scenes (10 s heavy, 10 s light): the back-off keeps the steps per cycle bounded
    { trace on = {"square", d_square, 200, 75}, off = on; off.target = 0;
      result a = run(&on, 0, NULL, 0), b = run(&off, 0, NULL, 0); report("10 s heavy / 10 s light for 200 s", &a, &b);
      assert(a.changes <= 4 * 10 && a.capped_win <= b.capped_win && a.frames >= b.frames);
      puts("PASS: alternating scenes: bounded steps, fewer capped seconds"); }
    // Ocarina of Time's phone seconds as the demand
    { trace on = {"oot", d_oot, OOT_N, 75}, off = on; off.target = 0;
      g_verbose = 1; result a = run(&on, 21, NULL, 0); g_verbose = getenv("T_DRS_VERBOSE") != NULL; result b = run(&off, 21, NULL, 0);
      report("Ocarina of Time, cooler run 60-138 s (offset 21 s: the tick at 81.7 s, the first second over 75%)", &a, &b);
      assert(a.capped_win < b.capped_win && a.frames > b.frames);
      puts("PASS: the phone's demand: fewer capped seconds and more frames with the controller"); }
    // open loop on the phone's own seconds: what the controller decides with the logged clock (no feedback)
    { nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); int level = 0, nclk = 0, nbusy = 0; double first_busy = -1, first_clk = -1;
      for (int i = 0; i < OOT_N; i++) for (int q = 0; q < 4; q++) {
          double t = 60.5 + i - 0.75 + q * 0.25; char why[160];   // the power tick at about 60.5 + i s closes the second; four windows in it
          int k = nvn_drs_gpu_window(&c, (uint64_t)(t * 1e9), k_oot[i] / 1000.0, k_oot_clk[i], level, NLEVELS, why, sizeof why);
          if (k == NVN_DRS_DOWN_BUSY) { nbusy++; if (first_busy < 0) first_busy = t; }
          if (k == NVN_DRS_DOWN_CLOCK) { nclk++; if (first_clk < 0) first_clk = t; }
          if (k) printf("    open loop %6.2f s floor → %d: %s\n", t, c.floor, why);
          level = c.floor;
      }
      printf("  open loop on the logged seconds: first GPU-busy step at %.2f s (the first second over 75%% is the tick at 81.7 s, the clock fell in the tick at 84.7 s), first clock-floor step at %.2f s; %d busy and %d clock steps\n",
             first_busy, first_clk, nbusy, nclk);
      assert(first_busy > 0 && first_busy <= 82.0 && first_clk > 0 && nclk <= 2 * NVN_DRS_CLOCK_MAX);
      puts("PASS: on the phone's seconds the busy rule steps before the clock fell, and the clock rule acts in the capped stretch"); }
    // a GPU whose time does not follow the resolution, busy 80% at every level: a step down, its check, back up, and no further steps while the hold lasts; no cascade to the floor
    { g_flat = 1; trace on = {"flat", d_band2, 120, 75}; on.demand = flat80; g_verbose = 1; result a = run(&on, 0, NULL, 0); g_verbose = getenv("T_DRS_VERBOSE") != NULL; g_flat = 0;
      printf("  80%% at every level for 120 s: %d downs, %d back for no gain, end floor %.0f, highest floor %d\n", a.downs, a.undos, a.end_floor, a.floor_hi);
      assert(a.downs >= 1 && a.undos == a.downs && a.end_floor == 0 && a.floor_hi <= 1 && a.downs <= 4);
      puts("PASS: no gain: a step down that does not lower the GPU's busy is taken back, and the floor never goes past one level"); }
    // a clock cap the GPU does not cause: each clock-floor step is taken back after 3 s with the cores still at their floor, and the hold keeps the floor from creeping down
    { g_cpu_cap = 1; trace on = {"cpucap", d_band, 120, 75}; g_verbose = 1; result a = run(&on, 0, NULL, 0); g_verbose = getenv("T_DRS_VERBOSE") != NULL; g_cpu_cap = 0;
      printf("  cores held at their floor for 120 s (72%% at full size): %d downs, %d back for no gain, end floor %.0f, highest floor %d\n", a.downs, a.undos, a.end_floor, a.floor_hi);
      assert(a.downs >= 1 && a.undos == a.downs && a.end_floor == 0 && a.floor_hi <= 1 && a.downs <= 4);
      puts("PASS: a clock step that does not bring the cores back is taken back, and no smaller picture is tried while its hold lasts"); }
    // the stretch family (hle_nvn.c drs_gpu_tick, DRS_SCALE_LEVELS 6, factor 1 - 0.1 L, each check 4 windows after its step): the game's own dynamic resolution follows the
    // stretched time 0.5 s late; a GPU whose time follows the pixels settles a step or two down and stays, one that does not gets each step taken back
    for (int flat = 0; flat < 2; flat++) {
        nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); c.settle_n = 4; int downs = 0, undos = 0, hi = 0, last_change_w = 0; double fq[3] = {1, 1, 1};
        for (int w = 0; w < 480; w++) {   // 120 s
            double f = 1 - 0.1 * c.floor; fq[2] = fq[1]; fq[1] = fq[0]; fq[0] = f;   // the game's picture side follows 2 windows late
            double busy = 0.92 * (flat ? 1 : 0.3 + 0.7 * fq[2] * fq[2]) + noise();
            char why[160]; int k = nvn_drs_gpu_window(&c, 1000000000ull + (uint64_t)w * 250000000ull, busy, 4.4, c.floor, 6, why, sizeof why);
            if (k == NVN_DRS_DOWN_BUSY || k == NVN_DRS_DOWN_CLOCK) downs++;
            if (k == NVN_DRS_UNDO) undos++;
            if (k) { last_change_w = w; if (g_verbose) printf("    stretch%s %6.2f s floor → %d: %s\n", flat ? " (flat)" : "", w * 0.25, c.floor, why); }
            if (c.floor > hi) hi = c.floor;
        }
        printf("  stretch family, 92%% at full size for 120 s%s: %d downs, %d back for no gain, highest floor %d, end floor %d, last change at %.1f s\n",
               flat ? ", the GPU's time not following the picture" : "", downs, undos, hi, c.floor, last_change_w * 0.25);
        if (!flat) assert(downs >= 1 && undos == 0 && c.floor >= 1 && c.floor <= 3 && last_change_w * 0.25 < 20);
        else assert(downs >= 1 && undos == downs && hi <= 1 && c.floor == 0);
    }
    puts("PASS: stretch family: settles where the busy fits when the GPU's time follows the picture, takes every step back when it does not");
    // late frames (Breath of the Wild's shape: the CPU waits for each frame's fence, so CPU 4 ms and the GPU's time add up; GPU 21 ms at full size, 40 fps, busy 84%): judged by
    // the busy share, a step that lets more frames through moves it by only 1-2 points (84 -> 82%) and some such steps are taken back; judged by the load (busy x 60 / fps), none is
    for (int by_load = 0; by_load < 2; by_load++) {
        nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); c.settle_n = 4; int downs = 0, undos = 0; double fq[3] = {1, 1, 1}, fps = 0, busy = 0;
        for (int w = 0; w < 480; w++) {
            double f = 1 - 0.1 * c.floor; fq[2] = fq[1]; fq[1] = fq[0]; fq[0] = f;
            double gpu = 21 * (0.3 + 0.7 * fq[2] * fq[2]) * (1 + noise()), frame = 4 + gpu; if (frame < 1000 / 60.0) frame = 1000 / 60.0;
            fps = 1000 / frame; busy = gpu * fps / 1000;
            double in = by_load ? nvn_drs_gpu_load(&c, busy, fps, 60, 0) : busy;   // the load once the frames have been late for 3 s
            char why[160]; int k = nvn_drs_gpu_window(&c, 1000000000ull + (uint64_t)w * 250000000ull, in, 4.4, c.floor, 6, why, sizeof why);
            if (k == NVN_DRS_DOWN_BUSY) downs++;
            if (k == NVN_DRS_UNDO) undos++;
            if (k && g_verbose) printf("    late frames%s %6.2f s floor → %d: %s\n", by_load ? " (load)" : " (busy)", w * 0.25, c.floor, why);
        }
        printf("  late frames by the %s: %d downs, %d back for no gain, end floor %d, %.0f fps, GPU busy %.0f%%\n", by_load ? "load" : "busy share", downs, undos, c.floor, fps, 100 * busy);
        if (by_load) assert(undos == 0 && c.floor >= 2 && fps > 59);
        else assert(undos >= 1);
    }
    puts("PASS: GPU time per frame: late frames that a smaller picture lets through count as a gain, no step taken back; the busy share alone took some back");
    // clock room (Mario Kart World on the iPhone 18 Pro Max, 136433517): 60 fps in races with the GPU probe at 2.4x the session's fastest and the GPU 84-88% busy whatever the
    // picture, as iOS lowers the clock until the GPU is busy most of the frame. Without the gate each step was taken back for no gain; with it no step is taken, and the windows
    // left alone are counted in the summary
    for (int room = 0; room < 2; room++) {
        nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); c.settle_n = 4; int downs = 0, undos = 0;
        for (int w = 0; w < 480; w++) {
            c.gpu_room = room;
            char why[160]; int k = nvn_drs_gpu_window(&c, 1000000000ull + (uint64_t)w * 250000000ull, 0.87 + noise(), 4.4, c.floor, 6, why, sizeof why);
            if (k == NVN_DRS_DOWN_BUSY) downs++;
            if (k == NVN_DRS_UNDO) undos++;
            if (k && g_verbose) printf("    clock room %d %6.2f s floor → %d: %s\n", room, w * 0.25, c.floor, why);
        }
        char sm[400]; nvn_drs_gpu_summary(&c, sm, sizeof sm);
        printf("  87%% busy at a low GPU clock for 120 s, %s: %d downs, %d back for no gain\n", room ? "the probe's room seen" : "no probe", downs, undos);
        if (room) { printf("  summary: %s\n", sm); assert(downs == 0 && c.floor == 0 && strstr(sm, "windows over the target left alone")); }
        else assert(downs >= 1 && undos == downs);
    }
    puts("PASS: clock room: a GPU busy at a low clock with the frames on time takes no step; without the probe each step is taken back");
    // Donkey Kong Bananza on c2bfbce88: 60 fps with the GPU 80% busy at a low clock (probe 2.4x), and every 15 s the game's own controller drops to 30 fps for about
    // 1 s (busy 45% then). Counted as late at once, each blip read as a load over 90%, opened the clock-room gate and took a step that the falling load then called a gain:
    // the floor walked to 0.6. Late only after 3 s: no step. A clock that collapsed and stays down (40 fps, busy 84%, probe 2.4x for 30 s) still steps within about 4 s
    { nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); c.settle_n = 4; int downs = 0, hi = 0;
      for (int w = 0; w < 480; w++) {
          int blip = w % 60 >= 50 && w % 60 < 54;   // 4 windows = 1 s at 30 fps every 15 s
          double fps = blip ? 30 : 60, share = (blip ? 0.45 : 0.80) + noise();
          double load = nvn_drs_gpu_load(&c, share, fps, 60, 2.4); char why[160];
          int k = nvn_drs_gpu_window(&c, 1000000000ull + (uint64_t)w * 250000000ull, load, 4.4, c.floor, 6, why, sizeof why);
          if (k == NVN_DRS_DOWN_BUSY) downs++;
          if (k && g_verbose) printf("    blips %6.2f s floor → %d: %s\n", w * 0.25, c.floor, why);
          if (c.floor > hi) hi = c.floor;
      }
      printf("  60 fps at a low GPU clock with a 1 s drop to 30 every 15 s for 120 s: %d downs, highest floor %d\n", downs, hi);
      assert(downs == 0 && hi == 0);
      nvn_drs_gpu d; nvn_drs_gpu_init(&d, 75); d.settle_n = 4; double first = -1;
      for (int w = 0; w < 120; w++) {
          double load = nvn_drs_gpu_load(&d, 0.84 + noise(), 40, 60, 2.4);
          int k = nvn_drs_gpu_window(&d, 1000000000ull + (uint64_t)w * 250000000ull, load, 4.4, d.floor, 6, NULL, 0);
          if (k == NVN_DRS_DOWN_BUSY && first < 0) first = w * 0.25;
      }
      printf("  40 fps at a low GPU clock for 30 s (a collapsed clock): first step at %.2f s\n", first);
      assert(first >= 2.5 && first <= 4.5); }
    puts("PASS: late only when it lasts: the game's own short drops to 30 take no step, a clock that stays down still steps");
    // CPU-bound late frames (Donkey Kong Bananza on c8351b8cf: 48-56 fps for 30 s, frame time about 20 ms, GPU 11-12 ms a frame, busy 57%): GPU time per frame over the
    // target's reads 70-80%, but the GPU is idle 40% of the time; they are not late for the GPU and take no step
    { nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); c.settle_n = 4; int downs = 0;
      for (int w = 0; w < 120; w++) {
          double fps = 50 + 4 * noise() * 25, share = 0.57 + noise();   // noise() is ±0.02: fps 48-52
          double load = nvn_drs_gpu_load(&c, share, fps, 60, 1.3);
          if (nvn_drs_gpu_window(&c, 1000000000ull + (uint64_t)w * 250000000ull, load, 4.4, c.floor, 6, NULL, 0) == NVN_DRS_DOWN_BUSY) downs++;
      }
      printf("  CPU-bound at 50 fps with the GPU 57%% busy for 30 s: %d downs, late windows counted %d\n", downs, c.late_n);
      assert(downs == 0 && c.late_n == 0); }
    puts("PASS: late frames with the GPU idle a quarter of the time or more are the CPU's: no step");
    char s[400]; nvn_drs_gpu c; nvn_drs_gpu_init(&c, 75); nvn_drs_gpu_window(&c, 1000000000ull, 0.9, 4.4, 0, NLEVELS, 0, 0); nvn_drs_gpu_window(&c, 1250000000ull, 0.9, 4.4, 0, NLEVELS, 0, 0);
    nvn_drs_gpu_summary(&c, s, sizeof s); printf("  summary: %s\n", s); assert(strstr(s, "floor 1") && strstr(s, "GPU load 90% > 75%"));
    puts("PASS: the summary names the floor and the last reason");
    return 0;
#endif
}
