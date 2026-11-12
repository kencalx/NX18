// Frame step controller unit tests (nvn_fstep.h): frames are simulated in vsyncs. A frame whose work w fits its hold k stays on screen k vsyncs; a longer one takes w
// (the next frame starts at once, as the display-link wait does when behind). Game time is the sum of the steps, real time the sum of the frame times.
#include "../nvn/nvn_fstep.h"
#include <stdio.h>
#include <string.h>

static int fail, checks;
static void check(int ok, const char *what) { checks++; fail += !ok; printf("%-78s %s\n", what, ok ? "✓" : "✗"); }

typedef struct { nvn_fstep s; double real, game; int next, slow; } sim;
// n frames of work w (vsyncs) each; GPU-or-CPU cost = w; slow: the CPU is reported slowed for reasons other than heat (probes)
static void run(sim *m, int n, double w, int kmin, int kmax, int fixed) {
    for (int i = 0; i < n; i++) {
        int k = m->s.k ? m->s.k : kmin, step = m->next ? m->next : kmin;
        double shown = w > k ? w : k;
        m->real += shown; m->game += step;
        m->next = nvn_fstep_next(&m->s, shown, w, kmin, kmax, fixed, m->slow);
    }
}

// Gaps between probes from the i-th on (vsyncs): each the hold-off of two failed probes over budget (FSTEP_PHOLD_MAX), give or take the probe's own frames
static int gaps_from(const double *gaps, int i, int n) { for (; i < n; i++) if (gaps[i] < FSTEP_PHOLD_MAX || gaps[i] > FSTEP_PHOLD_MAX + 120) return 0; return 1; }

// The same with the host's present snapshots (hle_nvn.c fstep_tick): lateness is what the screen showed 8 presents back (screen = 2 late, 1 on time), so the verdicts of the
// frames before a step up arrive after it. gpu: the GPU's own clock-follows-the-hold reference (nvn_fstep_gpu_slowed) feeds slow; shown_ms > 0 overrides what a frame shows
typedef struct { sim m; nvn_fgpu g; unsigned char lateq[8]; long n; } ssim;
static void srun(ssim *x, int n, double w, double shown_v) {
    for (int i = 0; i < n; i++) {
        sim *m = &x->m; int k = m->s.k ? m->s.k : 1, step = m->next ? m->next : 1;
        double shown = shown_v > 0 ? shown_v : w > k ? w : k;
        m->real += shown; m->game += step;
        if (x->n >= 8) m->s.screen = x->lateq[x->n % 8] ? 2 : 1;
        x->lateq[x->n % 8] = shown > k + FSTEP_LATE; x->n++;
        m->slow = nvn_fstep_gpu_slowed(&x->g, w, k, 1, m->s.probe);
        m->next = nvn_fstep_next(&m->s, shown, w, 1, 3, 0, m->slow);
    }
}
// Breath of the Wild on an iPhone 18 Pro Max (2026-11): GPU 0.86 vsyncs at hold 1 for 20 s, then an area whose GPU work takes 1.4 vsyncs (23 ms) at every hold: hold 1 cannot
// be held, and the GPU at hold 2 is 1.6 times its hold-1 reference. Returns the probes in the next 60 s of real time
static uint64_t heavy_stretch(ssim *x, int screen) {
    for (int i = 0; i < 1200; i++) { if (screen) srun(x, 1, 0.86, 0); else { x->m.slow = nvn_fstep_gpu_slowed(&x->g, 0.86, x->m.s.k ? x->m.s.k : 1, 1, x->m.s.probe); run(&x->m, 1, 0.86, 1, 3, 0); } }
    uint64_t p0 = x->m.s.probes; double t0 = x->m.real;
    while (x->m.real - t0 < 3600) { if (screen) srun(x, 1, 1.4, 0); else { x->m.slow = nvn_fstep_gpu_slowed(&x->g, 1.4, x->m.s.k ? x->m.s.k : 1, 1, x->m.s.probe); run(&x->m, 1, 1.4, 1, 3, 0); } }
    return x->m.s.probes - p0;
}
static void step1(ssim *x, int screen, double w) { if (screen) srun(x, 1, w, 0); else { x->m.slow = nvn_fstep_gpu_slowed(&x->g, w, x->m.s.k ? x->m.s.k : 1, 1, x->m.s.probe); run(&x->m, 1, w, 1, 3, 0); } }
// Real time (vsyncs) from the cost falling to w until the hold is 1, then 600 frames more; *held: the hold stayed 1 through them
static double recover(ssim *x, int screen, double w, int *held) {
    double t0 = x->m.real, t = -1;
    for (int i = 0; i < 2000 && t < 0; i++) { step1(x, screen, w); if (x->m.s.k == 1) t = x->m.real - t0; }
    *held = t >= 0; uint64_t ups = x->m.s.ups;
    for (int i = 0; i < 600; i++) step1(x, screen, w);
    *held = *held && x->m.s.k == 1 && x->m.s.ups == ups;
    return t;
}

// Ocarina of Time on an iPhone 18 Pro Max (X1.0, run B, 90-120 s, log.txt:607-708): hold 1 at a cost of 0.88 (GPU 0.75) for 20 s, then a short burst on the CPU side ends each
// run at hold 1: 3 frames of 1.2 vsyncs whose GPU was 0.98, 0.81, 1.05, 1.13 and 0.92 at the five step ups, the first at once, the next ones 114, 108, 78 and 138 frames after each
// probe began (the runs at hold 1 the log shows). At hold 2 the scene costs about 0.80, a frame of 0.90 every 20 so that no fit trial starts: the probes, as in the log, are what
// brought hold 1 back. stretch: the frames of each stay at hold 2; returns the frames at hold 2 in the first 1,800 of the bursty stretch
static int oot_b(int backoff, int *stretch, int *nst) {
    static const double gb[5] = {0.98, 0.81, 1.05, 1.13, 0.92}; static const int run1[4] = {114, 108, 78, 138};
    sim m = {0}; m.s.backoff = backoff;
    for (int i = 0; i < 1200; i++) { m.s.gpu = 0.75; run(&m, 1, 0.88, 1, 3, 0); }
    int nb = 0, at1 = 1000, burst = 0, cur = 0, f2 = 0; *nst = 0;
    for (int i = 0; i < 1800; i++) {
        int k = m.s.k;
        if (k == 1 && !burst && at1 >= (nb ? run1[(nb - 1) % 4] - 3 : 0)) burst = 3;
        double w = burst ? 1.2 : k == 1 ? 0.88 : i % 20 == 19 ? 0.90 : 0.80;
        m.s.gpu = burst ? gb[nb % 5] : 0.75;
        if (burst && !--burst) nb++;
        run(&m, 1, w, 1, 3, 0);
        if (k > 1) { cur++; f2++; } else if (cur) { if (*nst < 16) stretch[(*nst)++] = cur; cur = 0; }
        if (m.s.k == 1 && k > 1) at1 = 0; else if (m.s.k == 1) at1++;
    }
    return f2;
}
// The same stretch with the bursts on a clock of their own (the CPU side's, which the hold does not move): one every 114, 108, 78 and 138 vsyncs of real time (1.3-2.3 s), 3 frames
// of 1.2 vsyncs with the GPU times above, late at hold 1 and within hold 2. Returns the frames at hold 2 in 1,800 vsyncs; *ups the step ups, *late1 the late frames at hold 1
static int oot_bt(int backoff, uint64_t *ups, int *late1) {
    static const double gb[5] = {0.98, 0.81, 1.05, 1.13, 0.92}; static const int gap[4] = {114, 108, 78, 138};
    sim m = {0}; m.s.backoff = backoff;
    for (int i = 0; i < 1200; i++) { m.s.gpu = 0.75; run(&m, 1, 0.88, 1, 3, 0); }
    uint64_t u0 = m.s.ups; double t0 = m.real, next = t0; int nb = 0, burst = 0, f2 = 0; *late1 = 0;
    while (m.real - t0 < 1800) {
        int k = m.s.k;
        if (!burst && m.real >= next) { burst = 3; next += gap[nb % 4]; }
        double w = burst ? 1.2 : k == 1 ? 0.88 : 0.80;
        m.s.gpu = burst ? gb[nb % 5] : 0.75;
        if (burst && !--burst) nb++;
        run(&m, 1, w, 1, 3, 0);
        if (k > 1) f2++; else *late1 += w > 1 + FSTEP_LATE;
    }
    *ups = m.s.ups - u0; return f2;
}
// Ocarina of Time's heavy areas (run A, log.prev.txt:898-1206): GPU-bound at hold 1 (cost and GPU 1.3), at hold 2 the GPU 1.6 times that (the clock follows the hold), with a short
// burst on the CPU side (GPU 0.95) every 2 s at hold 1; ss: the screen's verdicts. Returns the probes in 60 s of real time; *ups the step ups
static uint64_t oot_a(int backoff, double w1, uint64_t *ups) {
    ssim x = {0}; x.m.s.backoff = backoff; double tb = 0;
    for (int i = 0; i < 1200; i++) { x.m.s.gpu = 0.86; step1(&x, 0, 0.86); }
    uint64_t p0 = x.m.s.probes, u0 = x.m.s.ups; double t0 = x.m.real;
    while (x.m.real - t0 < 3600) {
        int k = x.m.s.k, b = k == 1 && x.m.real - tb > 120; if (b) tb = x.m.real;
        double w = k == 1 ? (b ? 1.35 : w1) : 1.6 * w1; x.m.s.gpu = b ? 0.95 : w;
        x.m.slow = nvn_fstep_gpu_slowed(&x.g, x.m.s.gpu, k ? k : 1, 1, x.m.s.probe); run(&x.m, 1, w, 1, 3, 0);
    }
    *ups = x.m.s.ups - u0; return x.m.s.probes - p0;
}
// The edge of run A's heavy areas (log.prev.txt:906-970): hold 1 near its budget (cost and GPU 0.95) with a short burst on the CPU side (GPU 0.92) 150 frames into each run at
// hold 1, and the GPU at hold 2 1.6 times its hold-1 time. Returns the share of real time at hold 2 in 60 s; *ups the step ups
static double oot_edge(int backoff, uint64_t *ups) {
    ssim x = {0}; x.m.s.backoff = backoff; int at1 = 0, left = 0; double t2 = 0;
    for (int i = 0; i < 1200; i++) { x.m.s.gpu = 0.86; step1(&x, 0, 0.86); }
    uint64_t u0 = x.m.s.ups; double t0 = x.m.real;
    while (x.m.real - t0 < 3600) {
        int k = x.m.s.k; if (k == 1 && ++at1 >= 150 && !left) { left = 3; at1 = 0; }
        int b = left && k == 1; if (left) left--;
        double w = k == 1 ? (b ? 1.35 : 0.95) : 1.52, r0 = x.m.real; x.m.s.gpu = b ? 0.92 : w;
        x.m.slow = nvn_fstep_gpu_slowed(&x.g, x.m.s.gpu, k ? k : 1, 1, x.m.s.probe); run(&x.m, 1, w, 1, 3, 0);
        if (k > 1) t2 += x.m.real - r0;
    }
    *ups = x.m.s.ups - u0; return t2 / (x.m.real - t0);
}
// Ocarina of Time's trip out of the app in run B (log.txt:742-768): hold 1 at 0.85 for 20 s, a frame of 41.3 ms at the focus loss, the frame across the stay (40,454.8 ms: about
// 39.3 s suspended, the rest the focus changes around it), one of 93.2 ms (page-ins), then GPU frames of 26 ms (1.57 vsyncs) for `slow`
// frames and 0.85 after. mode 0: today; 1: the caller marks the frame across the stay (fps_resume). *paid: the vsyncs paid back from the focus loss on, *dropped: dropped then;
// returns the step ups in the 10 s from the focus loss
static uint64_t oot_trip(int mode, int slow, uint64_t *paid, double *dropped) {
    sim m = {0}; run(&m, 1200, 0.85, 1, 3, 0);
    uint64_t u0 = m.s.ups, p0 = m.s.paid; double d0 = m.s.dropped;
    run(&m, 1, 41.3 / (1000.0 / 60), 1, 3, 0);
    double stay = 40454.8 / (1000.0 / 60); m.real += stay; m.game += m.next; m.s.away = mode == 1; m.next = nvn_fstep_next(&m.s, stay, stay, 1, 3, 0, 0);
    run(&m, 1, 93.2 / (1000.0 / 60), 1, 3, 0);
    run(&m, slow, 1.57, 1, 3, 0); run(&m, 600 - slow, 0.85, 1, 3, 0);
    *paid = m.s.paid - p0; *dropped = m.s.dropped - d0;
    return m.s.ups - u0;
}

int main(void) {
    {   // 120 fps (hle_nvn.c fps_high): kmin 1, kmax 2, in ticks of 1/120 s. The target follows the hold, so a hold above what frames take is the game at the right speed
        sim m = {0}; m.s.per_vsync = 2;
        run(&m, 120, 0.7, 1, 2, 0); check(m.s.k == 1, "120 fps: frames of 5.8 ms hold 120");
        check(m.s.hold == FSTEP_HOLD0 * 2, "120 fps: the wait before a trial is the same real time");
        run(&m, 10, 1.6, 1, 2, 0); check(m.s.k == 2, "120 fps: frames of 13 ms step down to 60");
        run(&m, 600, 1.6, 1, 2, 0); check(m.s.k == 2, "120 fps: they stay at 60 while they do not fit");
        run(&m, 60, 4.0, 1, 2, 0); check(m.s.k == 2, "120 fps: 33 ms frames stop at 60, never a longer hold");
        run(&m, 1200, 0.7, 1, 2, 0); check(m.s.k == 1, "120 fps: frames that fit return to 120");
        sim c = {0}; c.s.per_vsync = 2;
        run(&c, 120, 0.7, 1, 2, 0); run(&c, 30, 0.7, 2, 2, 0); check(c.s.k == 2, "120 fps: a cap of 60 (a movie, a 60 Hz screen) holds two ticks");
        run(&c, 120, 0.7, 1, 2, 0); check(c.s.k == 1, "120 fps: the cap's end returns to 120");
    }
    char b[160];
    {   sim m = {0}; run(&m, 600, 0.5, 1, 3, 0);
        check(m.s.k == 1 && m.s.ups == 0 && m.s.paid == 0 && m.game == m.real, "steady 60: hold 1, step 1, game time = real time");
    }
    {   sim m = {0}; run(&m, 120, 0.5, 1, 3, 0); run(&m, 600, 1.32, 1, 3, 0);   // 22 ms frames
        snprintf(b, sizeof b, "steady 22 ms frames: 30 fps after three late frames, no flapping (k %d, ups %llu, downs %llu)", m.s.k, (unsigned long long)m.s.ups, (unsigned long long)m.s.downs);
        check(m.s.k == 2 && m.s.ups == 1 && m.s.downs == 0, b);
        snprintf(b, sizeof b, "  game time %.0f against real time %.2f (debt %.2f)", m.game, m.real, m.s.debt);
        check(m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01 && m.s.debt < 1, b);
    }
    {   sim m = {0}; run(&m, 120, 0.5, 1, 3, 0); run(&m, 300, 1.12, 1, 3, 0);   // 18.7 ms frames: 53 fps
        check(m.s.k == 2 && m.s.ups == 1, "steady 18.7 ms frames (53 fps): 30 fps, not 53 with a payback every 8 frames");
    }
    {   sim m = {0}; run(&m, 120, 0.5, 1, 3, 0);   // present snapshots: the caller judges lateness by the screen
        for (int i = 0; i < 20; i++) { m.s.screen = 1; m.next = nvn_fstep_next(&m.s, 1.0, 1.3, 1, 3, 0, 0); }
        check(m.s.k == 1 && m.s.ups == 0, "snapshots: costly frames the screen shows on time keep hold 1");
        for (int i = 0; i < 3; i++) { m.s.screen = 2; m.next = nvn_fstep_next(&m.s, 1.0, 0.8, 1, 3, 0, 0); }
        check(m.s.k == 2 && m.s.ups == 1, "  three frames late on screen step up, whatever their cost");
        m.next = nvn_fstep_next(&m.s, 2.0, 0.5, 1, 3, 0, 0);
        check(m.s.screen == 0, "  the screen verdict holds for one call");
    }
    {   sim m = {0}; run(&m, 120, 0.5, 1, 3, 0);   // snapshots, a game steadily too slow: frames shown on time keep the cost they do not fit out of the probes' reference
        for (int i = 0; i < 600; i++) { m.s.screen = 1; m.next = nvn_fstep_next(&m.s, 1.0, 1.12, 1, 3, 0, 0); }
        for (int i = 0; i < 3; i++) { m.s.screen = 2; m.next = nvn_fstep_next(&m.s, 1.0, 1.12, 1, 3, 0, 0); }
        for (int i = 0; i < 600; i++) { m.s.screen = 1; m.next = nvn_fstep_next(&m.s, 2.0, 1.12, 1, 3, 0, 0); }
        snprintf(b, sizeof b, "snapshots, 18.7 ms work shown on time at hold 1, then late: hold 2 stays, no probes (k %d, probes %llu)", m.s.k, (unsigned long long)m.s.probes);
        check(m.s.k == 2 && m.s.probes == 0 && m.s.downs == 0, b);
    }
    {   sim m = {0}; run(&m, 60, 0.5, 1, 3, 0);
        m.real += 6; m.game += m.next; m.next = nvn_fstep_next(&m.s, 6, 6, 1, 3, 0, 0);   // one 100 ms hitch
        check(m.next == 2 && m.s.k == 1, "100 ms hitch: the next step pays back one vsync, hold stays 1");
        int two = 0; for (int i = 0; i < 20; i++) { int st = m.next; run(&m, 1, 0.5, 1, 3, 0); two += st == 2; }
        snprintf(b, sizeof b, "  five steps of 2, then 1 (%d steps of 2); game time %.0f = real time %.0f", two, m.game, m.real);
        check(two == 5 && m.game == m.real && m.s.k == 1, b);
    }
    {   sim m = {0}; run(&m, 60, 0.5, 1, 3, 0);
        m.real += 30; m.game += m.next; m.next = nvn_fstep_next(&m.s, 30, 30, 1, 3, 0, 0);   // a 0.5 s stall
        run(&m, 60, 0.5, 1, 3, 0);
        snprintf(b, sizeof b, "0.5 s stall: 15 vsyncs paid back, %.0f dropped, not replayed (paid %llu)", m.s.dropped, (unsigned long long)m.s.paid);
        check(m.s.dropped == 14 && m.s.paid == 15 && m.real - m.game == 14 && m.s.k == 1, b);
    }
    {   sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0);   // a heavy scene: 30 fps
        check(m.s.k == 2, "heavy scene: hold 2");
        run(&m, 29, 0.6, 1, 3, 0);
        check(m.s.k == 2, "  cost drops: 29 frames that fit 1 are not enough");
        run(&m, 1, 0.6, 1, 3, 0);
        check(m.s.k == 1 && m.s.trial == FSTEP_RUN, "  the 30th starts a trial at hold 1");
        run(&m, FSTEP_RUN + 10, 0.6, 1, 3, 0);
        check(m.s.k == 1 && m.s.trial == 0 && m.s.hold == FSTEP_HOLD0 && m.s.failed == 0, "  the trial holds: 60 fps again");
    }
    {   // the cost says 0.6, but frames at hold 1 take 1.5 (the cost misses something): each trial fails, and the trials spread out 1 → 2 → 4 → 8 s
        sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 30, 1.5, 1, 3, 0);
        check(m.s.k == 2, "frames at hold 1 take 1.5 vsyncs: hold 2");
        double last = m.real, gaps[4]; int ng = 0; uint64_t downs = m.s.downs;
        for (int i = 0; i < 4000 && ng < 4; i++) {
            double w = m.s.k == 1 ? 1.5 : 0.6;
            run(&m, 1, w, 1, 3, 0);
            if (m.s.downs != downs) { downs = m.s.downs; gaps[ng++] = m.real - last; last = m.real; }
        }
        snprintf(b, sizeof b, "  trials %.0f, %.0f, %.0f, %.0f vsyncs apart; %llu failed", gaps[0], gaps[1], gaps[2], gaps[3], (unsigned long long)m.s.failed);
        check(ng == 4 && gaps[0] >= 60 && gaps[1] >= 120 && gaps[2] >= 240 && gaps[3] >= 480 && gaps[3] < 560 && m.s.failed >= 3, b);
    }
    {   sim m = {0}; run(&m, 300, 0.5, 2, 2, 0);
        check(m.s.k == 2 && m.next == 2 && m.game == m.real, "30 fps cap: hold 2, step 2");
        m.real += 6; m.game += m.next; m.next = nvn_fstep_next(&m.s, 6, 6, 2, 2, 0, 0);
        int three = 0; for (int i = 0; i < 10; i++) { int st = m.next; run(&m, 1, 0.5, 2, 2, 0); three += st == 3; }
        snprintf(b, sizeof b, "  a hitch at the 30 cap is paid back with steps of 3 (%d), hold stays 2", three);
        check(three == 4 && m.s.k == 2 && m.game == m.real, b);
        run(&m, 300, 3.5, 2, 2, 0);
        check(m.s.k == 2, "  frames longer than the hold at the 30 cap: hold stays 2 (the 30 Hz link holds only even counts)");
    }
    {   sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 1, 0.5, 2, 3, 0);
        check(m.s.k == 2, "movie flag (kmin 2): hold 2 at once");
        run(&m, 120, 0.5, 2, 3, 0); run(&m, 1, 0.5, 1, 3, 0);
        check(m.s.k == 1 && m.s.ups == 0 && m.s.late == 0, "  movie ends (kmin 1): hold 1 at once");
    }
    {   // A 60 fps movie (nvn_fstep.pin: Ocarina of Time's opening, nn::codec, about 16.5 ms of GPU a frame on an iPhone): hold 1 while it plays, whatever the frames cost; no step
        // up, trial or probe, and the game's time stays real time through the debt. Before, three late frames at 1.1 vsyncs stepped to hold 2 and the probes back kept failing
        sim m = {0}; run(&m, 600, 0.6, 1, 3, 0);
        uint64_t ups = m.s.ups, probes = m.s.probes, downs = m.s.downs; double r0 = m.real, g0 = m.game;
        m.s.pin = 1;
        for (int i = 0; i < 9000; i++) run(&m, 1, i % 10 < 3 ? 1.15 : 0.98, 1, 3, 0);   // 150 s of frames around the budget: three of 19 ms in every ten
        snprintf(b, sizeof b, "60 fps movie (pin): hold 1 for 150 s of frames at 0.98-1.15 vsyncs (k %d, %llu up, %llu probes)", m.s.k, (unsigned long long)(m.s.ups - ups), (unsigned long long)(m.s.probes - probes));
        check(m.s.k == 1 && m.s.ups == ups && m.s.probes == probes && m.s.downs == downs, b);
        snprintf(b, sizeof b, "  game time %.0f against real time %.0f (debt %.2f): the late frames are paid back", m.game - g0, m.real - r0, m.s.debt);
        check(m.real - r0 - (m.game - g0) - m.s.debt > -1.01 && m.real - r0 - (m.game - g0) - m.s.debt < 1.01 && m.s.debt < 1.5, b);
        run(&m, 600, 2.4, 1, 3, 0);
        check(m.s.k == 1 && m.s.ups == ups, "  even 40 ms frames (a load during the movie) keep hold 1");
        m.s.pin = 0; run(&m, 3, 1.3, 1, 3, 0);
        check(m.s.k == 2 && m.s.ups == ups + 1, "  the movie ends: three late frames step up again");
        run(&m, 1200, 0.6, 1, 3, 0);
        check(m.s.k == 1, "  and a light scene comes back to hold 1");
    }
    {   // The same without the pin: what the iPhone did (the frame step left hold 1 at the first three late frames)
        sim m = {0}; run(&m, 600, 0.6, 1, 3, 0);
        for (int i = 0; i < 9000; i++) run(&m, 1, i % 10 < 3 ? 1.15 : 0.98, 1, 3, 0);
        snprintf(b, sizeof b, "  without the pin: hold %d, %llu steps up, %llu probes in the 150 s", m.s.k, (unsigned long long)m.s.ups, (unsigned long long)m.s.probes);
        check(m.s.ups >= 1, b);
    }
    {   // The thermal cap (kmin 2) during a 60 fps movie: hold 2, the fastest the cap allows, and never 3; the cap's end during the movie: hold 1 at once
        sim m = {0}; run(&m, 600, 0.6, 1, 3, 0); m.s.pin = 1;
        run(&m, 300, 1.1, 1, 3, 0); run(&m, 1, 1.1, 2, 2, 0);
        check(m.s.k == 2, "60 fps movie under the thermal cap (kmin 2): hold 2 at once");
        run(&m, 600, 2.3, 2, 2, 0);
        check(m.s.k == 2 && m.s.ups == 0, "  frames of 2.3 vsyncs under the cap: hold 2, no step up");
        run(&m, 1, 1.1, 1, 3, 0);
        check(m.s.k == 1 && !m.s.trial && !m.s.probe && m.s.ups == 0, "  the cap ends during the movie: hold 1 at once, no probe to judge");
    }
    {   // A movie's start and end forget the probes' hold-off (two failed probes over budget, nvn_fstep_pheld) as a cap change does: another scene
        ssim x = {0}; heavy_stretch(&x, 0);
        int held_before = nvn_fstep_pheld(&x.m.s, 1) && x.m.s.pk > 0;
        x.m.s.pin = 1; step1(&x, 0, 1.4);
        snprintf(b, sizeof b, "movie start: the hold-off of two failed probes over budget is forgotten (before %d, pover %d, pk %.2f)", held_before, x.m.s.pover, x.m.s.pk);
        check(held_before && x.m.s.pover == 0 && x.m.s.pk == 0 && x.m.s.phold == FSTEP_HOLD0 && x.m.s.k == 1, b);
        for (int i = 0; i < 300; i++) step1(&x, 0, 1.4);
        x.m.s.pover = 2; x.m.s.pk = 1.6; x.m.s.pfrom = 1.4; x.m.s.phold = FSTEP_PHOLD_MAX; x.m.s.hold = FSTEP_HOLD_MAX;   // as if measured during the movie
        x.m.s.pin = 0; step1(&x, 0, 0.6);
        check(x.m.s.pover == 0 && x.m.s.pk == 0 && x.m.s.phold == FSTEP_HOLD0 && x.m.s.hold == FSTEP_HOLD0 && x.m.s.k == 1, "  movie end: forgotten again, the trials' hold-off back to 1 s");
    }
    {   sim m = {0}; run(&m, 600, 0.86, 1, 3, 0); run(&m, 600, 1.5, 2, 2, 0); run(&m, 1, 1.5, 1, 3, 0);
        check(m.s.k == 1 && m.s.grace == FSTEP_GRACE && m.s.trial == FSTEP_RUN && m.s.probes == 1,
              "cap release: count a probe, with all grace frames left for hold 1");
        int frames = 0;
        while (m.s.k == 1 && frames < 100) { run(&m, 1, 1.3, 1, 3, 0); frames++; }
        check(frames == FSTEP_GRACE + 3 && m.s.k == 2 && m.s.failed == 1 && m.s.hold == 2 * FSTEP_HOLD0,
              "  recovery fails after 30 grace frames plus 3 late frames, then doubles the hold-off");
    }
    {   sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 120, 0.5, 1, 3, 2);
        check(m.s.k == 2 && m.next == 2 && m.s.debt == 0, "the game fixes its step at 2 (BotW's VFR override): hold 2, step 2");
        run(&m, 2, 0.5, 1, 3, 0);
        check(m.s.k == 1 && m.next == 1 && m.s.late == 0, "  the override ends: hold 1, step 1, no late frame counted");
    }
    {   // a parked CPU: 20 ms frames at hold 2 never fit hold 1, and without the slow report nothing tries it
        sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0); run(&m, 2000, 1.2, 1, 3, 0);
        check(m.s.k == 2 && m.s.downs == 0 && m.s.probes == 0, "not slowed: 1.2-vsync frames at hold 2 stay at hold 2, no probe");
    }
    {   // the same with the CPU reported slowed: the probe goes to hold 1, its frames take 1.5 vsyncs for 20 frames while the clock rises, then 0.6
        sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0); m.slow = 1;
        int at1 = 0, up_during_grace = 0; uint64_t ups = m.s.ups;
        for (int i = 0; i < 400; i++) {
            double w = m.s.k == 1 ? (at1++ < 20 ? 1.5 : 0.6) : 1.2;
            run(&m, 1, w, 1, 3, 0);
            if (m.s.grace > 0 && m.s.ups != ups) up_during_grace = 1;
        }
        snprintf(b, sizeof b, "slowed, the clock rises: one probe to hold 1 that holds (k %d, probes %llu, failed %llu)", m.s.k, (unsigned long long)m.s.probes, (unsigned long long)m.s.failed);
        check(m.s.k == 1 && m.s.probes == 1 && m.s.failed == 0 && m.s.ups == ups && !up_during_grace && m.s.trial == 0 && m.s.probe == 2 && m.s.hold == FSTEP_HOLD0, b);
        snprintf(b, sizeof b, "  20 late frames in the grace are paid back: game time %.0f against real time %.2f (debt %.2f)", m.game, m.real, m.s.debt);
        check(m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01 && m.s.dropped == 0, b);
    }
    {   // slowed, but hold 1 really does not fit (1.5 there, 1.2 at hold 2): each probe fails after its grace; two that measured hold 1 at 1.5 hold the probes off for 32 s
        // at a time while the cost at hold 2 stays (before: a probe every 8 s for good)
        sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0); m.slow = 1;
        double last = m.real, gaps[16]; int ng = 0, at1 = 0, first_len = -1; uint64_t probes = m.s.probes;
        for (int i = 0; i < 6000; i++) {
            run(&m, 1, m.s.k == 1 ? 1.5 : 1.2, 1, 3, 0);
            if (m.s.k == 1) at1++; else if (at1 && first_len < 0) first_len = at1;
            if (m.s.probes != probes) { probes = m.s.probes; if (ng < 16) gaps[ng++] = m.real - last; last = m.real; }
        }
        snprintf(b, sizeof b, "slowed, hold 1 does not fit: the first probe lasts its grace + 3 late frames (%d frames at hold 1)", first_len);
        check(first_len == FSTEP_GRACE + 3, b);
        snprintf(b, sizeof b, "  two probes %.0f vsyncs apart, then one each 32 s (%d in 200 s, %.0f / %.0f apart; failed %llu, k %d)", ng > 1 ? gaps[1] : 0, ng, ng > 2 ? gaps[2] : 0, ng > 3 ? gaps[3] : 0, (unsigned long long)m.s.failed, m.s.k);
        check(ng >= 5 && ng <= 7 && gaps[1] >= 120 && gaps[1] < FSTEP_PHOLD_MAX && gaps_from(gaps, 2, ng) && m.s.failed == (uint64_t)ng && m.s.k == 2 && m.s.pover >= FSTEP_OVER_N, b);
        snprintf(b, sizeof b, "  game time %.0f against real time %.2f (debt %.2f, dropped %.0f)", m.game, m.real, m.s.debt, m.s.dropped);
        check(m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01 && m.s.dropped == 0, b);
        uint64_t p2 = m.s.probes;
        m.real += 20; m.game += m.next; m.next = nvn_fstep_next(&m.s, 20, 20, 1, 3, 0, 1);   // a load: a stall of 1/3 s
        for (int i = 0; i < 120; i++) run(&m, 1, m.s.k == 1 ? 1.5 : 1.2, 1, 3, 0);
        snprintf(b, sizeof b, "  a load (a stall of 1/3 s) forgets what they measured: a probe again at once (probes %llu → %llu)", (unsigned long long)p2, (unsigned long long)m.s.probes);
        check(m.s.probes == p2 + 1 && m.s.pover < FSTEP_OVER_N, b);
    }
    {   // slowed, hold 1 holds for a while: a probe that holds but whose run at hold 1 ends within 8 s counts as failed, and the next waits twice as long
        sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0); m.slow = 1;
        for (int i = 0; i < 1000 && m.s.probe != 2; i++) run(&m, 1, m.s.k == 1 ? 0.6 : 1.2, 1, 3, 0);
        double hold0 = m.s.hold; uint64_t failed = m.s.failed;
        run(&m, 120, 0.6, 1, 3, 0); run(&m, 3, 1.5, 1, 3, 0);
        snprintf(b, sizeof b, "slowed, hold 1 lasts 2 s after the probe: counted as failed (failed %llu, hold-off %.0f → %.0f vsyncs)", (unsigned long long)m.s.failed, hold0, m.s.hold);
        check(m.s.k == 2 && m.s.failed == failed + 1 && m.s.hold == 2 * hold0 && m.s.probe == 0, b);
        for (int i = 0; i < 2000 && m.s.probe != 2; i++) run(&m, 1, m.s.k == 1 ? 0.6 : 1.2, 1, 3, 0);
        hold0 = m.s.hold; failed = m.s.failed;
        run(&m, 600, 0.6, 1, 3, 0); run(&m, 3, 1.5, 1, 3, 0);
        snprintf(b, sizeof b, "  hold 1 lasts 10 s after the next probe: the hold-off returns to 1 s (failed %llu, hold-off %.0f → %.0f vsyncs)", (unsigned long long)m.s.failed, hold0, m.s.hold);
        check(m.s.k == 2 && m.s.failed == failed && hold0 == 120 && m.s.hold == FSTEP_HOLD0, b);
    }
    {   sim m = {0}; m.slow = 1; run(&m, 600, 0.5, 1, 3, 0);
        check(m.s.k == 1 && m.s.probes == 0 && m.s.downs == 0 && m.game == m.real, "slowed at hold 1 already: nothing to probe");
        sim c = {0}; c.slow = 1; run(&c, 300, 0.5, 2, 2, 0);
        check(c.s.k == 2 && c.s.probes == 0, "  slowed at the 30 cap (kmin 2): nothing to probe");
    }
    {   // Breath of the Wild on an iPhone: GPU 0.86 at hold 1, three heavy frames step to 2, where the GPU clock falls (1.5); after the probe it rises again within 20 frames
        sim m = {0}; nvn_fgpu g = {0}; int at1 = 0, stepped = 0;
        for (int i = 0; i < 2000; i++) {
            double w = i < 600 ? 0.86 : i < 603 ? 1.25 : m.s.k >= 2 ? 1.5 : at1++ < 20 ? 1.5 : 0.86;
            stepped |= i >= 603 && m.s.k == 2;
            m.slow = nvn_fstep_gpu_slowed(&g, w, m.s.k ? m.s.k : 1, 1, m.s.probe);
            run(&m, 1, w, 1, 3, 0);
        }
        snprintf(b, sizeof b, "GPU clock follows the hold (BotW): one probe back to hold 1 that holds (k %d, probes %llu, failed %llu)", m.s.k, (unsigned long long)m.s.probes, (unsigned long long)m.s.failed);
        check(stepped && m.s.k == 1 && m.s.probes == 1 && m.s.failed == 0, b);
        snprintf(b, sizeof b, "  game time %.0f against real time %.2f (debt %.2f, dropped %.0f)", m.game, m.real, m.s.debt, m.s.dropped);
        check(m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01 && m.s.dropped == 0, b);
    }
    {   // a heavier scene at the same clock: 0.86 at hold 1, then 1.12 (19 ms) for good, which is 1.3 times less than enough to call the GPU slowed
        sim m = {0}; nvn_fgpu g = {0};
        for (int i = 0; i < 2000; i++) { double w = i < 600 ? 0.86 : 1.12; m.slow = nvn_fstep_gpu_slowed(&g, w, m.s.k ? m.s.k : 1, 1, m.s.probe); run(&m, 1, w, 1, 3, 0); }
        check(m.s.k == 2 && m.s.probes == 0, "heavier scene, GPU 0.86 → 1.12 at hold 2: not slowed, no probe");
    }
    {   // a loading screen: the GPU at 0.03, then lag on the CPU steps to 2, where the GPU takes 0.17 (5.7 times as much but 3 ms): the CPU holds the frame back, not the GPU
        sim m = {0}; nvn_fgpu g = {0}; int slowed = 0;
        for (int i = 0; i < 1200; i++) { double gp = i < 600 || m.s.k == 1 ? 0.03 : 0.17, w = i < 600 ? 0.5 : 1.3; m.slow = nvn_fstep_gpu_slowed(&g, gp, m.s.k ? m.s.k : 1, 1, m.s.probe); slowed |= m.slow; run(&m, 1, w, 1, 3, 0); }
        check(m.s.k == 2 && !slowed && m.s.probes == 0, "GPU 0.03 → 0.17 under CPU lag: a GPU at 3 ms is not called slowed, no probe");
    }
    {   // the GPU stays slow at hold 1 too: the probes fail, the reference stays the hold-1 time from before, and after two a probe only each 32 s while the GPU stays at 1.5
        // (before: one every 8 s); a cap change (a movie) is another scene, and the cap's end probes again
        sim m = {0}; nvn_fgpu g = {0}; double last = 0, gaps[16]; int ng = 0; uint64_t probes = 0;
        for (int i = 0; i < 6000; i++) {
            double w = i < 600 ? 0.86 : i < 603 ? 1.25 : 1.5;
            m.slow = nvn_fstep_gpu_slowed(&g, w, m.s.k ? m.s.k : 1, 1, m.s.probe);
            run(&m, 1, w, 1, 3, 0);
            if (m.s.probes != probes) { probes = m.s.probes; if (ng < 16) gaps[ng++] = m.real - last; last = m.real; }
        }
        snprintf(b, sizeof b, "GPU slow at hold 1 too: probes fail (%llu of %llu), reference kept at %.2f", (unsigned long long)m.s.failed, (unsigned long long)m.s.probes, g.ref);
        check(ng >= 4 && m.s.failed == (uint64_t)ng && g.ref < 1.0, b);
        snprintf(b, sizeof b, "  probes %.0f, then %.0f and %.0f vsyncs apart; game time %.0f against real time %.2f (debt %.2f)", gaps[1], ng > 2 ? gaps[2] : 0, ng > 3 ? gaps[3] : 0, m.game, m.real, m.s.debt);
        check(gaps[1] >= 120 && gaps[1] < FSTEP_PHOLD_MAX && gaps_from(gaps, 2, ng) && m.s.k >= 2 && m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01, b);
        uint64_t pm = m.s.probes;
        run(&m, 300, 0.5, 2, 2, 0); run(&m, 1, 0.5, 1, 3, 0);
        check(m.s.probes == pm + 1 && m.s.k == 1 && m.s.pover == 0, "  a movie (kmin 2) and its end: a probe at the cap's end, the measurement forgotten");
    }
    {   // Breath of the Wild on an iPhone (2026-10-21): frames of 0.80 / 0.92 vsyncs at hold 1 for 20 s, three pipeline compiles step to 2, and the scene costs the same there:
        // every other frame is above FSTEP_FIT, so no 30 fit in a row; the cost that held hold 1 starts one probe, which holds
        sim m = {0};
        for (int i = 0; i < 1200; i++) run(&m, 1, i % 2 ? 0.92 : 0.80, 1, 3, 0);
        run(&m, 3, 1.6, 1, 3, 0);
        int stepped = m.s.k == 2; double ref = m.s.cref;
        for (int i = 0; i < 600; i++) run(&m, 1, i % 2 ? 0.92 : 0.80, 1, 3, 0);
        snprintf(b, sizeof b, "hitch after 20 s at hold 1, same cost at hold 2 (BotW): one probe back that holds (k %d, probes %llu, failed %llu)", m.s.k, (unsigned long long)m.s.probes, (unsigned long long)m.s.failed);
        check(stepped && ref > 0.84 && ref < 0.88 && m.s.k == 1 && m.s.probes == 1 && m.s.failed == 0 && m.s.probe == 2 && m.s.downs == 1, b);
        snprintf(b, sizeof b, "  game time %.0f against real time %.2f (debt %.2f, dropped %.0f)", m.game, m.real, m.s.debt, m.s.dropped);
        check(m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01 && m.s.dropped == 0, b);
    }
    {   // the scene gets heavier (1.15 / 1.25 at hold 1, 1.4 times what held): hold 2 and no probe; back to the old scene, the cost that held starts one
        sim m = {0};
        for (int i = 0; i < 1200; i++) run(&m, 1, i % 2 ? 0.92 : 0.80, 1, 3, 0);
        for (int i = 0; i < 1200; i++) run(&m, 1, i % 2 ? 1.25 : 1.15, 1, 3, 0);
        check(m.s.k == 2 && m.s.probes == 0 && m.s.downs == 0, "heavier scene, cost 1.4 times what held hold 1: hold 2, no probe");
        for (int i = 0; i < 600; i++) run(&m, 1, i % 2 ? 0.92 : 0.80, 1, 3, 0);
        check(m.s.k == 1 && m.s.probes == 1 && m.s.failed == 0, "  the scene gets lighter again, back to the cost that held: one probe back that holds");
    }
    {   // hold 1 held only 5 s before the hitch: that run proves nothing (a device that steps up every few seconds keeps 30 rather than flap)
        sim m = {0};
        for (int i = 0; i < 300; i++) run(&m, 1, i % 2 ? 0.92 : 0.80, 1, 3, 0);
        run(&m, 3, 1.6, 1, 3, 0);
        for (int i = 0; i < 2000; i++) run(&m, 1, i % 2 ? 0.92 : 0.80, 1, 3, 0);
        check(m.s.k == 2 && m.s.probes == 0 && m.s.cref == 0, "hitch after 5 s at hold 1: no cost that held, no probe");
    }
    {   // the cost at hold 2 is what held, but hold 1 no longer fits (1.3 there): the probes fail and the cost that held is kept; after two a probe only each 32 s while hold 1
        // measured 1.3 and the cost at hold 2 stays (before: one every 8 s). The cost at hold 2 falling to 0.75 brings the estimate for hold 1 to 1.13: a probe again, which holds
        sim m = {0}; double last = 0, gaps[16]; int ng = 0; uint64_t probes = 0;
        run(&m, 1200, 0.86, 1, 3, 0); run(&m, 3, 1.6, 1, 3, 0);
        for (int i = 0; i < 6000; i++) {
            run(&m, 1, m.s.k == 1 ? 1.3 : 0.86, 1, 3, 0);
            if (m.s.probes != probes) { probes = m.s.probes; if (ng < 16) gaps[ng++] = m.real - last; last = m.real; }
        }
        snprintf(b, sizeof b, "same cost at hold 2 but hold 1 does not fit: probes fail (%llu of %llu), cost that held kept at %.2f", (unsigned long long)m.s.failed, (unsigned long long)m.s.probes, m.s.cref);
        check(ng >= 4 && m.s.failed == (uint64_t)ng && m.s.cref > 0.85 && m.s.cref < 0.87, b);
        snprintf(b, sizeof b, "  probes %.0f, then %.0f and %.0f vsyncs apart; game time %.0f against real time %.2f (debt %.2f)", gaps[1], ng > 2 ? gaps[2] : 0, ng > 3 ? gaps[3] : 0, m.game, m.real, m.s.debt);
        check(gaps[1] >= 120 && gaps[1] < FSTEP_PHOLD_MAX && gaps_from(gaps, 2, ng) && m.s.k == 2 && m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01, b);
        uint64_t failed = m.s.failed;
        run(&m, 600, 0.75, 1, 3, 0);
        snprintf(b, sizeof b, "  the cost at hold 2 falls to 0.75: back to hold 1, and it holds (k %d, probes %llu, failed %llu)", m.s.k, (unsigned long long)m.s.probes, (unsigned long long)m.s.failed);
        check(m.s.k == 1 && m.s.failed == failed, b);
    }
    for (int sustained = 0; sustained < 2; sustained++) {
        // The first movie follows an uninterrupted run: no earlier hitch has saved cref. Only a run of at least 8 s proves that this cost held 60.
        sim m = {0}; run(&m, sustained ? 1200 : 300, 0.86, 1, 3, 0);
        run(&m, 600, 0.5, 2, 2, 0);
        check(sustained ? m.s.cref_at[1] > 0.85 && m.s.cref_at[1] < 0.87 : m.s.cref_at[1] == 0,
              sustained ? "first movie after 20 s at 60: save the sustained run without an earlier hitch"
                        : "first movie after only 5 s at 60: no proven cost to save");
        run(&m, 60, 0.86, 1, 3, 0); uint64_t probes = m.s.probes; run(&m, 3, 1.6, 1, 3, 0);
        for (int i = 0; i < 1200; i++) run(&m, 1, m.s.k == 1 ? 0.86 : 0.9, 1, 3, 0);
        check(sustained ? m.s.k == 1 && m.s.probes > probes : m.s.k == 2 && m.s.probes == probes,
              sustained ? "  hitch 1 s after the first movie: the saved run brings 60 back"
                        : "  hitch after a short unproven run: keep 30 without a same-cost probe");
    }
    {   // Later movies keep the last proven cost through short runs, and replace it after another sustained run at a different cost.
        sim m = {0}; run(&m, 1200, 0.86, 1, 3, 0); run(&m, 120, 0.5, 2, 2, 0);
        run(&m, 120, 0.6, 1, 3, 0); run(&m, 120, 0.5, 2, 2, 0);
        check(m.s.cref_at[1] > 0.85 && m.s.cref_at[1] < 0.87, "second movie after only 2 s: keep the earlier proven cost");
        run(&m, 1200, 0.6, 1, 3, 0); run(&m, 120, 0.5, 2, 2, 0);
        check(m.s.cref_at[1] > 0.59 && m.s.cref_at[1] < 0.61, "  another sustained run before a movie: update the proven cost");
    }
    {   sim m = {0}; run(&m, 1200, 0.86, 1, 3, 0); run(&m, 3, 1.6, 1, 3, 0); double held = m.s.cref; run(&m, 1, 0.5, 2, 3, 0);
        check(held > 0.85 && m.s.cref == 0 && m.s.run <= 2, "movie flag (kmin 2): the cost that held kmin 1 is set aside");
        run(&m, 120, 0.5, 2, 3, 0); run(&m, 1, 0.5, 1, 3, 0);
        check(m.s.cref == held, "  movie ends (kmin 1): the cost that held kmin 1 comes back");
    }
    {   // Tears of the Kingdom's prerendered movies set a 30 cap (kmin 2). A GPU-bound game at 0.86 vsyncs at hold 1 and 0.9 at hold 2 (the clock lowered for the longer hold)
        // has learned the cost that held hold 1 from a hitch; after a 10 s movie, pipeline compiles 1 s in (three frames of 1.6) step it up before 8 s at hold 1 relearn it
        sim m = {0}; run(&m, 1200, 0.86, 1, 3, 0); run(&m, 3, 1.6, 1, 3, 0);
        for (int i = 0; i < 1200; i++) run(&m, 1, m.s.k == 1 ? 0.86 : 0.9, 1, 3, 0);
        double held = m.s.cref; int at1 = 0;
        run(&m, 600, 0.5, 2, 2, 0); run(&m, 60, 0.86, 1, 3, 0); run(&m, 3, 1.6, 1, 3, 0);
        for (int i = 0; i < 1200; i++) { run(&m, 1, m.s.k == 1 ? 0.86 : 0.9, 1, 3, 0); at1 += i >= 600 && m.s.k == 1; }
        snprintf(b, sizeof b, "  a hitch 1 s after a movie: the cost that held hold 1 starts a probe (k %d, at hold 1 %d of the last 600)", m.s.k, at1);
        check(held > 0.85 && m.s.k == 1 && at1 == 600, b);
    }
    // The iOS thermal cap (hle_nvn.c thermal_capped): 30 fps from frame 600 for 30 s. Breath of the Wild on an iPhone, GPU-bound: 0.86 vsyncs (14.4 ms) at hold 1, 1.5 (25 ms)
    // at hold 2, where the clock follows the hold. After the cap and after each run at hold 2, the first 10 frames at hold 1 take 1.5 until the clock rises again; c = 1: the
    // first 60 frames after the cap (a clock slower to come back), so the probe at the cap's end fails; c = 2: hold 1 takes 1.3 for good after the cap (a heavier scene)
    for (int c = 0; c < 3; c++) {
        static const char *const what[] = {"thermal cap ends: the probe's grace covers the clock, hold 1 at once and it stays (k %d, %d steps up after the cap, at hold 1 %d of the last 600)",
                                           "  the clock takes 1 s: the probe fails, the GPU against hold 1's own reference starts another (k %d, %d steps up, at hold 1 %d of the last 600)",
                                           "  hold 1 no longer fits (1.3): a probe at most every 8 s, at hold 1 %d of the last 600; game time %.0f against real time %.2f (probes %llu)"};
        int rise = 600 + 1800, since1 = 0, at1 = 0, n = rise + 3600; uint64_t probes = 0, ups = 0; double last = 0, gap = 1e9;
        sim m = {0}; nvn_fgpu g = {0};
        for (int i = 0; i < n; i++) {
            int kmin = i >= 600 && i < rise ? 2 : 1, kmax = kmin == 2 ? 2 : 3, k = m.s.k ? m.s.k : kmin;
            since1 = k == 1 ? since1 + 1 : 0;
            double w = k >= 2 ? 1.5 : i < rise ? 0.86 : c == 2 ? 1.3 : since1 <= 10 || (c == 1 && i < rise + 60) ? 1.5 : 0.86;
            m.slow = nvn_fstep_gpu_slowed(&g, w, k, kmin, m.s.probe);
            run(&m, 1, w, kmin, kmax, 0);
            if (i == rise - 1) ups = m.s.ups;
            if (i >= n - 600) at1 += m.s.k == 1;
            if (i > rise + 1200 && m.s.probes != probes) { if (last) gap = gap < m.real - last ? gap : m.real - last; last = m.real; }
            probes = m.s.probes;
        }
        int up = (int)(m.s.ups - ups);
        if (c < 2) { snprintf(b, sizeof b, what[c], m.s.k, up, at1); check(m.s.k == 1 && at1 == 600 && (c || !up), b); }
        else {
            snprintf(b, sizeof b, what[c], at1, m.game, m.real, (unsigned long long)m.s.probes);
            check(at1 < 100 && gap >= FSTEP_HOLD_MAX && m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01, b);
        }
    }
    {   // 165 Hz with virtual ticks (nvn_mtl.m link_range): cheap frames show on the refreshes nearest their slots, 12.1 / 18.2 ms at hold 1, 30.3 / 36.4 at 2, 48.5 / 54.5 at 3
        for (int sl = 1; sl >= 0; sl--) {
            nvn_fstep s = {.k = 3, .step = 3, .kmin = 1, .hold = FSTEP_HOLD0, .shown_slack = sl ? 60.0 / 165 : 0};
            for (int i = 0; i < 360; i++) {
                double ms = s.k == 3 ? (i % 4 ? 48.485 : 54.545) : s.k == 2 ? (i % 2 ? 30.303 : 36.364) : (i % 4 ? 18.182 : 12.121);
                nvn_fstep_next(&s, ms * 60 / 1000, 0.6, 1, 3, 0, 0);
            }
            snprintf(b, sizeof b, sl ? "165 Hz, cheap frames at hold 3, one refresh of slack: trials back to 2 and 1 (k %d, downs %llu)"
                                     : "  without the slack the 54.5 ms frames count as late: hold 3 (20 fps) for good (k %d, downs %llu)", s.k, (unsigned long long)s.downs);
            check(sl ? s.k == 1 && s.downs == 2 : s.k == 3 && s.downs == 0, b);
        }
        sim m = {0}; m.s.shown_slack = 60.0 / 165; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.32, 1, 3, 0);
        check(m.s.k == 2, "  the slack does not hide work: 22 ms frames still step to hold 2");
    }
    {   // A controller that raises the clock slowly (the Mac): the probe's frames at hold 1 start at 1.5 vsyncs and get 0.6% cheaper each frame, so they fit only after about 52 frames.
        // Without the ramp rule the probe fails after its 30 grace frames and 3 late ones; with it (nvn_fstep.ramp) the grace is renewed while the frames keep getting cheaper and the probe holds
        for (int ramp = 0; ramp <= 1; ramp++) {
            sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0); m.slow = 1; m.s.ramp = ramp;
            int at1 = 0, first_len = -1;
            for (int i = 0; i < 400; i++) {
                double w = m.s.k == 1 ? fmax(0.6, 1.5 * pow(0.994, at1)) : 1.2;
                run(&m, 1, w, 1, 3, 0);
                if (m.s.k == 1) at1++; else if (at1 && first_len < 0) first_len = at1;
            }
            if (!ramp) {
                snprintf(b, sizeof b, "slowed, the clock rises slowly: without the ramp rule the probe fails after grace + 3 frames (%d frames at hold 1, failed %llu)", first_len, (unsigned long long)m.s.failed);
                check(first_len == FSTEP_GRACE + 3 && m.s.failed >= 1, b);
            } else {
                snprintf(b, sizeof b, "  with it the grace is renewed twice and the probe holds (k %d, probes %llu, failed %llu, grace frames %d)", m.s.k, (unsigned long long)m.s.probes, (unsigned long long)m.s.failed, m.s.ptotal);
                check(m.s.k == 1 && m.s.probes == 1 && m.s.failed == 0 && m.s.probe == 2 && m.s.trial == 0 && m.s.ptotal == 3 * FSTEP_GRACE && first_len < 0, b);
                snprintf(b, sizeof b, "  its late frames are paid back: game time %.0f against real time %.2f (debt %.2f)", m.game, m.real, m.s.debt);
                check(m.real - m.game - m.s.debt > -1.01 && m.real - m.game - m.s.debt < 1.01 && m.s.dropped == 0, b);
            }
        }
    }
    {   // The ramp rule with a cost that does not fall (1.5 flat), one that falls and then stops short of the hold (1.6 down to 1.3), and one that keeps falling but never reaches it (3.0 at 0.5% a frame):
        // the probe lasts grace + 3, two windows + 3, and FSTEP_PROBE_MAX + 3 frames
        static const char *const what[] = {"ramp rule, the cost does not fall: the probe lasts its grace + 3 late frames as before (%d frames at hold 1)",
                                           "  the cost falls, then holds at 1.3: one more window, then the probe fails (%d frames at hold 1)",
                                           "  the cost keeps falling without reaching the hold: the grace ends at FSTEP_PROBE_MAX (%d frames at hold 1, failed %llu)"};
        static const int want[] = {FSTEP_GRACE + 3, 2 * FSTEP_GRACE + 3, FSTEP_PROBE_MAX + 3};
        for (int c = 0; c < 3; c++) {
            sim m = {0}; run(&m, 60, 0.5, 1, 3, 0); run(&m, 300, 1.3, 1, 3, 0); m.slow = 1; m.s.ramp = 1;
            int at1 = 0, first_len = -1;
            for (int i = 0; i < 600 && first_len < 0; i++) {
                double w = m.s.k != 1 ? 1.2 : c == 0 ? 1.5 : c == 1 ? fmax(1.3, 1.6 * pow(0.99, at1)) : 3.0 * pow(0.995, at1);
                run(&m, 1, w, 1, 3, 0);
                if (m.s.k == 1) at1++; else if (at1 && first_len < 0) first_len = at1;
            }
            snprintf(b, sizeof b, what[c], first_len, (unsigned long long)m.s.failed);
            check(first_len == want[c] && m.s.k == 2 && m.s.failed == 1, b);
        }
    }
    // A GPU-bound stretch hold 1 cannot hold (BotW on an iPhone, 2026-11: GPU 22–24 ms at hold 2, 1.6–1.7 times its hold-1 time, and as much in each probe back to hold 1).
    // Before, a probe failed every 2–3 s for as long as the area lasted, each a stutter of 3 late frames; the measured cost at hold 1 now keeps the probes off after two
    for (int screen = 1; screen >= 0; screen--) {
        ssim x = {0}; uint64_t p = heavy_stretch(&x, screen);
        snprintf(b, sizeof b, "%sGPU-bound at 1.4 vsyncs for 60 s%s: two probes, a third 32 s on (%llu, %llu failed, k %d)", screen ? "" : "  ", screen ? " (screen verdicts)" : ", judged by cost",
                 (unsigned long long)p, (unsigned long long)x.m.s.failed, x.m.s.k);
        check(p >= 2 && p <= 3 && x.m.s.k >= 2, b);
        snprintf(b, sizeof b, "  game time %.0f against real time %.2f (debt %.2f, dropped %.0f)", x.m.game, x.m.real, x.m.s.debt, x.m.s.dropped);
        check(x.m.real - x.m.game - x.m.s.debt > -1.01 && x.m.real - x.m.game - x.m.s.debt < 1.01 && x.m.s.dropped == 0, b);
        int held; double t = recover(&x, screen, 0.55, &held);
        snprintf(b, sizeof b, "  the area gets light (0.55, 9 ms): back to hold 1 in %.0f vsyncs, and it holds", t);
        check(held && t <= 120, b);
    }
    // The heavy stretch, then a scene hold 1 can hold whose cost at the longer hold is as high: the GPU clock follows the hold (BotW on an iPhone: 14.4 ms at hold 1, about 25 at
    // hold 2, the heavy area 22–24), here 0.86 at hold 1 once the clock rose within 10 frames and 1.5 at hold 2. The cost at hold 2 does not show the change, so the hold-off of
    // the two failed probes would last until a load (c7f9e835: at hold 2 for good); the probe FSTEP_PHOLD_MAX after the last step up finds hold 1 again
    for (int screen = 1; screen >= 0; screen--) {
        ssim x = {0}; heavy_stretch(&x, screen);
        double t0 = x.m.real, t = -1; int at1 = 0;
        for (int i = 0; i < 4000 && t < 0; i++) {
            int k = x.m.s.k ? x.m.s.k : 1; at1 = k == 1 ? at1 + 1 : 0;
            step1(&x, screen, k >= 2 ? 1.5 : at1 <= 10 ? 1.5 : 0.86);
            if (x.m.s.probe == 2) t = x.m.real - t0;
        }
        for (int i = 0; i < 600; i++) { int k = x.m.s.k ? x.m.s.k : 1; at1 = k == 1 ? at1 + 1 : 0; step1(&x, screen, k >= 2 ? 1.5 : at1 <= 10 ? 1.5 : 0.86); }
        snprintf(b, sizeof b, "%sthen a scene hold 1 holds at 1.5 at hold 2 (the GPU-slowed case%s): a probe that holds after %.0f vsyncs (k %d)", screen ? "  " : "    ", screen ? "" : ", by cost", t, x.m.s.k);
        check(t >= 0 && t <= FSTEP_PHOLD_MAX + 120 && x.m.s.k == 1, b);
    }
    {   // a step the game fixes itself (BotW's cutscenes, the VFR override) is another scene: what the failed probes measured is forgotten
        ssim x = {0}; heavy_stretch(&x, 1);
        int held = x.m.s.pover >= FSTEP_OVER_N;
        run(&x.m, 1, 1.4, 1, 3, 2);
        check(held && x.m.s.pover == 0 && x.m.s.pk == 0, "  the game fixes its own step: the failed probes' measurement is forgotten");
    }
    {   // the scene gets light just after the second failed probe, when the hold-off has doubled twice: recovery does not wait it out
        ssim x = {0};
        for (int i = 0; i < 1200; i++) srun(&x, 1, 0.86, 0);
        for (int i = 0; i < 20000 && x.m.s.failed < 2; i++) srun(&x, 1, 1.4, 0);
        srun(&x, 10, 1.4, 0);
        int held; double t = recover(&x, 1, 0.55, &held);
        snprintf(b, sizeof b, "  the area gets light just after the second failed probe: hold 1 in %.0f vsyncs, and it holds", t);
        check(x.m.s.failed >= 2 && held && t <= 120, b);
    }
    {   // a GPU-bound stretch where hold 1 is only just out of reach (1.12 at hold 1, within FSTEP_OVER of it; 1.4 at the longer holds): the probes go on, but back off
        // 1 → 2 → 4 → 8 → 16 → 32 s (FSTEP_PHOLD_MAX) instead of stopping at 8 s
        ssim x = {0}; double last = 0, gaps[32]; int ng = 0; uint64_t probes = 0;
        for (int i = 0; i < 1200; i++) srun(&x, 1, 0.86, 0);
        while (x.m.real < 1200 + 9000 && ng < 32) {
            srun(&x, 1, x.m.s.k == 1 ? 1.12 : 1.4, 0);
            if (x.m.s.probes != probes) { probes = x.m.s.probes; gaps[ng++] = x.m.real - last; last = x.m.real; }
        }
        snprintf(b, sizeof b, "hold 1 just out of reach (1.12): %d probes in 150 s, %.0f, %.0f, %.0f vsyncs apart", ng, ng > 3 ? gaps[3] : 0, ng > 4 ? gaps[4] : 0, ng > 5 ? gaps[5] : 0);
        check(ng >= 6 && ng <= 8 && gaps[3] >= 480 && gaps[4] >= 960 && gaps[5] >= 1900, b);
    }
    {   // opening a menu (BotW on an iPhone): six frames shown 34 ms late at hold 1 while their work is 0.74 vsyncs. The screen's verdicts arrive 8 presents late, so the three
        // after the step up are about frames made before it: one step up, not 1 → 2 → 3
        ssim x = {0};
        for (int i = 0; i < 1200; i++) srun(&x, 1, 0.72, 0);
        srun(&x, 6, 0.74, 2.04);
        for (int i = 0; i < 12; i++) srun(&x, 1, 0.74, 0);
        snprintf(b, sizeof b, "a hitch of six late frames under budget (screen verdicts): one step up (ups %llu, k %d)", (unsigned long long)x.m.s.ups, x.m.s.k);
        check(x.m.s.ups == 1 && x.m.s.k == 2, b);
        srun(&x, 300, 0.74, 0);
        check(x.m.s.k == 1, "  and back to hold 1 by a trial");
        srun(&x, 3, 0.74, 2.04); srun(&x, 12, 0.74, 0); srun(&x, 3, 2.6, 0); srun(&x, 12, 2.6, 0);
        snprintf(b, sizeof b, "  frames that do not fit the new hold still step up again (k %d)", x.m.s.k);
        check(x.m.s.k == 3, b);
    }
    {   // Ocarina of Time's run B (oot_b): without backoff the replay gives the log's stays at hold 2 (presents 2770-2801, 2915-2976, 3084-3205, 3283-3523: 31, 61, 121 and 240,
        // within the present that starts or ends each); with it (fps_hold_backoff burst) a burst with the GPU under the late line keeps the wait at 1 s, and the one over it (1.13)
        // waits 2 s, not 4 then 8
        static const int log_st[4] = {31, 61, 121, 240};
        int st[16], n, f2 = oot_b(0, st, &n), near = n >= 4; for (int i = 0; i < 4 && near; i++) near = st[i] >= log_st[i] - 1 && st[i] <= log_st[i] + 1;
        snprintf(b, sizeof b, "Ocarina run B, doubling (today): stays at hold 2 of %d, %d, %d, %d frames; %d of 1,800 at hold 2", n > 0 ? st[0] : -1, n > 1 ? st[1] : -1, n > 2 ? st[2] : -1, n > 3 ? st[3] : -1, f2);
        check(near && f2 > 1000, b);
        // Bursts on their own clock (oot_bt): with backoff the four whose GPU fitted are paid back at hold 1, and only the one over the late line (1.13) steps up; before, each
        // burst stepped up and the next probe came after 1 s, switching between 60 and 30 every 1.3-2.3 s (13 step ups in 30 s), more often than doubling. The late frames at
        // hold 1 are the bursts' own (3 each, about 17 bursts): the frames late anyway, at 60 instead of before a second or more at 30
        uint64_t ud, ub; int ld, lb, fd = oot_bt(0, &ud, &ld), fb = oot_bt(1, &ub, &lb);
        snprintf(b, sizeof b, "  bursts every 1.3-2.3 s, doubling / backoff: step ups %llu / %llu, late at hold 1 %d / %d, frames at hold 2 %d / %d", (unsigned long long)ud,
                 (unsigned long long)ub, ld, lb, fd, fb);
        check(ub * 2 < ud && ub <= 4 && lb <= 3 * (1800 / 78 + 1) && fb * 4 < fd, b);
        sim m = {0}; m.s.backoff = 1; for (int i = 0; i < 1200; i++) { m.s.gpu = 0.75; run(&m, 1, 0.88, 1, 3, 0); }
        check(m.s.bursts == 0 && m.s.failed == 0 && m.s.ups == 0, "  backoff changes nothing while hold 1 holds");
        // What is no short burst on the CPU side steps up as before: more than FSTEP_BURST_N late frames, the GPU over the late line, one asking for two vsyncs more, one within
        // FSTEP_RUN frames of the last burst; and a burst pays its lateness back
        m.s.gpu = 0.98; run(&m, 3, 1.4, 1, 3, 0); int one = m.s.bursts == 1 && m.s.ups == 0 && m.s.k == 1;
        m.s.gpu = 0.75; run(&m, 3, 0.88, 1, 3, 0); int paid = m.s.paid == 1 && m.s.debt < 1;   // 1.2 vsyncs behind: one step of 2
        m.s.gpu = 0.98; run(&m, 3, 1.2, 1, 3, 0); int soon = m.s.ups == 1 && m.s.bursts == 1;
        sim l = {0}; l.s.backoff = 1; for (int i = 0; i < 1200; i++) { l.s.gpu = 0.75; run(&l, 1, 0.88, 1, 3, 0); }
        l.s.gpu = 0.98; run(&l, FSTEP_BURST_N, 1.2, 1, 3, 0); int lng = l.s.ups == 0; run(&l, 1, 1.2, 1, 3, 0); lng = lng && l.s.ups == 1 && l.s.bursts == 1;
        sim g = {0}; g.s.backoff = 1; for (int i = 0; i < 1200; i++) { g.s.gpu = 0.75; run(&g, 1, 0.88, 1, 3, 0); }
        g.s.gpu = 1.13; run(&g, 3, 1.2, 1, 3, 0); int gpu = g.s.ups == 1 && !g.s.bursts;
        sim w = {0}; w.s.backoff = 1; for (int i = 0; i < 1200; i++) { w.s.gpu = 0.75; run(&w, 1, 0.88, 1, 3, 0); }
        w.s.gpu = 0.9; run(&w, 3, 2.3, 1, 3, 0); int two = w.s.ups == 1 && w.s.k == 3 && !w.s.bursts;
        check(one && paid && soon && lng && gpu && two, "  a burst is paid back at hold 1; longer, GPU-bound, larger or repeated within 30 frames steps up");
    }
    {   // Ocarina of Time's run A (oot_a): in its GPU-bound areas backoff starts no more probes and no more step ups, at 1.3 vsyncs at hold 1 and just out of reach at 1.12
        uint64_t u0, u1, p0 = oot_a(0, 1.3, &u0), p1 = oot_a(1, 1.3, &u1);
        snprintf(b, sizeof b, "Ocarina run A, GPU-bound at 1.3: probes %llu / %llu, step ups %llu / %llu (doubling / backoff)", (unsigned long long)p0, (unsigned long long)p1, (unsigned long long)u0, (unsigned long long)u1);
        check(p1 == p0 && u1 == u0 && p0 <= 4, b);
        p0 = oot_a(0, 1.12, &u0); p1 = oot_a(1, 1.12, &u1);
        snprintf(b, sizeof b, "  just out of reach at 1.12: probes %llu / %llu, step ups %llu / %llu", (unsigned long long)p0, (unsigned long long)p1, (unsigned long long)u0, (unsigned long long)u1);
        check(p1 == p0 && u1 == u0 && p0 <= 6, b);
        double a0 = oot_edge(0, &u0), a1 = oot_edge(1, &u1);
        snprintf(b, sizeof b, "  at the edge (0.95, a CPU burst every 2.5 s at hold 1): %.0f%% / %.0f%% of the time at hold 2, %llu / %llu step ups a minute", 100 * a0, 100 * a1, (unsigned long long)u0, (unsigned long long)u1);
        check(a1 < a0 && u1 <= u0, b);   // the bursts are paid back at hold 1: more of the minute at 60, and no more steps between 60 and 30
    }
    {   // Ocarina of Time's trip out of the app (oot_trip): today the frame across the stay is late and owes 15 vsyncs (the cap), and with the frames either side three late frames
        // step up; with fps_resume it is on time and owes nothing, and the late frames either side of it (the one after within the 30 of the grace) are paid back without a step up:
        // the payback is their own lateness, 41.3 and 93.2 ms and ten of 26 ms against 16.7 each, nothing for the stay
        uint64_t p0, p1; double d0, d1; uint64_t u0 = oot_trip(0, 10, &p0, &d0), u1 = oot_trip(1, 10, &p1, &d1);
        const double v = 1000.0 / 60, own = (41.3 / v - 1) + (93.2 / v - 1) + 10 * 0.57;
        snprintf(b, sizeof b, "Ocarina's trip out of the app, today: %llu step up, %llu vsyncs paid back, %.0f dropped", (unsigned long long)u0, (unsigned long long)p0, d0);
        check(u0 == 1 && p0 >= 15 && d0 > 2000, b);
        snprintf(b, sizeof b, "  with fps_resume: %llu step ups, %llu paid back (the frames' own lateness %.1f), %.0f dropped", (unsigned long long)u1, (unsigned long long)p1, own, d1);
        check(u1 == 0 && p1 + 1 > own - 1 && p1 <= own + 1 && d1 == 0, b);
        uint64_t u3 = oot_trip(1, 40, &p1, &d1);
        snprintf(b, sizeof b, "  GPU frames of 26 ms past the 30 frames of grace still step up (%llu)", (unsigned long long)u3);
        check(u3 == 1, b);
        sim m = {0}; run(&m, 600, 0.5, 1, 3, 0); m.s.away = 1; run(&m, 1, 0.5, 1, 3, 0);
        check(m.s.away == 0 && m.s.rgrace == FSTEP_GRACE, "  the mark holds for one call");
        double cr = m.s.crun; m.s.away = 1; m.next = nvn_fstep_next(&m.s, 2400, 2400, 1, 3, 0, 0);
        check(m.s.crun == cr && m.s.ups == 0 && m.s.debt < 1, "  the frame across the stay is no cost the scene has, and no debt");
        // A fit trial in progress at the stay: the grace after it does not let it hold. Before, its countdown ran through the grace's late frames, the trial ended as held (the
        // wait back to 1 s), and the step up after the grace was no failed trial
        sim t = {0}; run(&t, 600, 0.5, 1, 3, 0); run(&t, 3, 1.6, 1, 3, 0);
        int k2 = t.s.k; for (int i = 0; i < 200 && !t.s.trial; i++) run(&t, 1, 0.5, 1, 3, 0);
        int tr = t.s.trial && t.s.k == 1; run(&t, 5, 0.5, 1, 3, 0);
        t.s.away = 1; t.next = nvn_fstep_next(&t.s, 2400, 2400, 1, 3, 0, 0);
        run(&t, FSTEP_GRACE, 1.6, 1, 3, 0);
        int during = t.s.trial > 0 && !t.s.failed && t.s.ups == 1; run(&t, 3, 1.6, 1, 3, 0);
        snprintf(b, sizeof b, "  a fit trial across a stay is judged after the grace: failed %llu, the wait %.0f vsyncs", (unsigned long long)t.s.failed, t.s.hold);
        check(k2 == 2 && tr && during && t.s.failed == 1 && t.s.hold == 2 * FSTEP_HOLD0 && t.s.ups == 2, b);
    }
    {   // The long-frame log (nvn_lf_long): 60 fps at 16.7 ms frames with 10 ms of GPU work, then a step up to hold 2. Judged by the running mean alone (held 0, as before the
        // hold was passed) the first frames of 33.3 ms read as long until the mean caught up; judged against their hold none does, and a frame past the hold still counts
        const double v = 1000.0 / 60;
        int alone = 0, held = 0;
        nvn_lfmean a = {16.7, 8}, h = {16.7, 8};
        for (int i = 0; i < 120; i++) { alone += nvn_lf_long(&a, v, 10, 0); held += nvn_lf_long(&h, v, 10, 0); }
        check(!alone && !held, "long frames: none at a steady 16.7 ms");
        int first = alone;
        for (int i = 0; i < 30; i++) { alone += nvn_lf_long(&a, 2 * v + (i % 3 - 1) * 1.5, 10, 0); held += nvn_lf_long(&h, 2 * v + (i % 3 - 1) * 1.5, 10, 2 * v); }
        snprintf(b, sizeof b, "  a step to hold 2: %d frames of 31.8-34.8 ms long by the mean alone, %d against their hold", alone - first, held);
        check(alone - first >= 7 && alone - first <= 10 && held == 0, b);
        nvn_lfmean s = {16.7, 8};
        for (int i = 0; i < 120; i++) nvn_lf_long(&s, v, 10, 0);
        for (int i = 0; i < 3; i++) nvn_lf_long(&s, 2 * v, 10, 2 * v);
        check(nvn_lf_long(&s, 45, 10, 2 * v), "  a 45 ms frame at hold 2 (33.3 ms) is long: past its hold by more than the slack");
        check(!nvn_lf_long(&s, 40, 10, 2 * v), "  a 40 ms frame at hold 2 is not: within the slack of 1.25 holds");
        check(!nvn_lf_long(&s, 2 * v, 25, 2 * v), "  25 ms of GPU work at hold 2 is not long: it fits the hold");
        check(nvn_lf_long(&s, 2 * v, 40, 2 * v), "  40 ms of GPU work at hold 2 is");
        nvn_lfmean o = {16.7, 8};
        for (int i = 0; i < 120; i++) nvn_lf_long(&o, v, 10, 0);
        check(nvn_lf_long(&o, 25, 10, 0) && nvn_lf_long(&o, v, 18, 0), "  at hold 1 a 25 ms frame and 18 ms of GPU work are long, as before");
    }
    printf("== %d checks, %d failed ==\n", checks, fail);
    return fail != 0;
}
