// The plain-C part of the NVN layer's GPU diagnostics (../nvn/nvn_gpu_diag.h), on any machine: the GPU busy time the power line prints as 'GPU <x> ms/s busy', the union of
// the Metal 4 command buffers' GPU intervals (overlaps, gaps, one interval inside another, no start time, a late report: the documented undercount, never a double count), the
// figure never passing the wall clock the intervals span, a bad end time or a minute-long interval left out by the feedback handlers' check, and a reader on another thread taking the total while the one writer adds to it (make t_gpu_diag_tsan: no race, and the
// total it reads never goes down). nvn_mtl.m's use of it needs a GPU: its feedback handlers on the Metal 4 queue (gpu_busy_note), hle_nvn.c power_line's line
#include "../nvn/nvn_gpu_diag.h"
#include <pthread.h>
#include <stdio.h>

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %lld, got %lld\n", name, w_, g_); failed++; } } while (0)
#define TRUE(name, cond) do { checks++; if (!(cond)) { fprintf(stderr, "%s: false\n", name); failed++; } } while (0)

static void busy(void) {
    gd_busy b = {0};
    EXPECT("busy: nothing yet", 0, gd_busy_ns(&b));
    gd_busy_add(&b, 1000, 2000); EXPECT("busy: one interval", 1000, gd_busy_ns(&b));
    gd_busy_add(&b, 1500, 3000); EXPECT("busy: an overlap counts once", 2000, gd_busy_ns(&b));
    gd_busy_add(&b, 2200, 2800); EXPECT("busy: one inside another adds nothing", 2000, gd_busy_ns(&b));
    gd_busy_add(&b, 3000, 3200); EXPECT("busy: one starting at the last end adds its length", 2200, gd_busy_ns(&b));
    gd_busy_add(&b, 4000, 4500); EXPECT("busy: a gap is not counted", 2700, gd_busy_ns(&b));
    gd_busy_add(&b, 0, 9000); EXPECT("busy: no start time is skipped (a command buffer that never started)", 2700, gd_busy_ns(&b));
    EXPECT("busy: and does not move the last end", 4500, b.end);
    gd_busy_add(&b, 5000, 5000); gd_busy_add(&b, 6000, 5500); EXPECT("busy: empty and reversed are skipped", 2700, gd_busy_ns(&b));
    gd_busy_add(&b, 3500, 3900); EXPECT("busy: one reported late in a gap before the last end: the documented undercount", 2700, gd_busy_ns(&b));
    gd_busy_add(&b, 4400, 5000); EXPECT("busy: one reaching past the last end counts from it", 3200, gd_busy_ns(&b));
}

// The power line's window: busy over a second of frames, a game command buffer, an upload beside it and a present after it, 60 times; the figure is what the GPU was busy, with
// the upload's overlap counted once
static void window(void) {
    gd_busy b = {0}; const uint64_t ms = 1000000, base = 5000 * ms;   // seconds on the CACurrentMediaTime base, here in ns: a device up for 5 s
    uint64_t before = gd_busy_ns(&b);
    for (uint64_t f = 0; f < 60; f++) {
        uint64_t t = base + f * 16666667;
        gd_busy_add(&b, t, t + 10 * ms);              // the game's submission: 10 ms
        gd_busy_add(&b, t + 2 * ms, t + 3 * ms);      // an upload batch inside it, reported after it
        gd_busy_add(&b, t + 10 * ms, t + 11 * ms);    // the present, right behind it: 1 ms
    }
    uint64_t busy = gd_busy_ns(&b) - before;
    EXPECT("window: 60 frames of 11 ms busy", 660 * ms, busy);
    TRUE("window: never more than the time the intervals span", busy <= 59 * 16666667 + 11 * ms);
    // All of a second busy, in pieces that overlap a lot (as segments and uploads can): the figure stays at the wall clock
    gd_busy c = {0};
    for (uint64_t k = 0; k < 1000; k++) gd_busy_add(&c, base + k * ms, base + k * ms + 5 * ms);
    EXPECT("window: overlapping pieces over 1.004 s count 1.004 s", 1004 * ms, gd_busy_ns(&c));
}

// The feedback handlers' check (gd_busy_add_checked, nvn_mtl.m gpu_busy_note): one bad GPU end time far in the future, from a command buffer that failed or was lost, would
// move the last end forward and leave every later interval counting 0 for the rest of the run ('GPU 0.0 ms/s busy' again). It is left out, as is an interval longer than a
// minute, and the intervals after it still count; real ones, a report a little after its end and one ending within the slack of the report's clock, count as before
static void checked(void) {
    gd_busy b = {0}; const uint64_t ms = 1000000, s = 1000 * ms, now = 5000 * s;   // the report's clock: a device up for 5000 s
    EXPECT("checked: a real interval counts", 1, gd_busy_add_checked(&b, now - 20 * ms, now - 10 * ms, now));
    EXPECT("checked: its length", 10 * ms, gd_busy_ns(&b));
    EXPECT("checked: an end an hour after the report is left out", 0, gd_busy_add_checked(&b, now - 5 * ms, now + 3600 * s, now));
    EXPECT("checked: and does not move the last end", now - 10 * ms, b.end);
    EXPECT("checked: the next real interval still counts", 1, gd_busy_add_checked(&b, now + 1 * ms, now + 5 * ms, now + 6 * ms));
    EXPECT("checked: busy after it", 14 * ms, gd_busy_ns(&b));
    EXPECT("checked: an interval of two minutes is left out", 0, gd_busy_add_checked(&b, now - 120 * s, now + 7 * ms, now + 8 * ms));
    EXPECT("checked: an end within the slack of the report's clock counts", 1, gd_busy_add_checked(&b, now + 10 * ms, now + 20 * ms, now + 15 * ms));
    EXPECT("checked: no start time is left out", 0, gd_busy_add_checked(&b, 0, now, now));
    EXPECT("checked: busy at the end", 24 * ms, gd_busy_ns(&b));
}

// The one writer (the feedback queue) adds back-to-back intervals while a reader (the power line's thread) takes the total: under ThreadSanitizer no race is reported, the
// total read never goes down, and the last one is exactly what was added
static gd_busy g_race; static _Atomic int g_stop;
enum { RACE_N = 200000 };
static void *writer(void *arg) {
    (void)arg;
    for (uint64_t k = 1; k <= RACE_N; k++) gd_busy_add(&g_race, k * 10, k * 10 + 7);   // 7 ns busy every 10 ns
    atomic_store(&g_stop, 1);
    return NULL;
}
static void race(void) {
    pthread_t w; pthread_create(&w, NULL, writer, NULL);
    uint64_t last = 0, reads = 0, down = 0;
    while (!atomic_load(&g_stop)) { uint64_t v = gd_busy_ns(&g_race); if (v < last) down++; last = v; reads++; }
    pthread_join(w, NULL);
    EXPECT("race: the total read never went down", 0, down);
    EXPECT("race: every interval counted", (uint64_t)RACE_N * 7, gd_busy_ns(&g_race));
    fprintf(stderr, "race: %llu reads beside %d adds\n", (unsigned long long)reads, RACE_N);
}

int main(void) {
    busy(); window(); checked(); race();
    printf("t_gpu_diag: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
